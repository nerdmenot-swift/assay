// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A hand-written, pure-Swift TOML 1.0.0 parser producing TOML.Node.
//
// WHY HAND-WRITTEN. The same reason as YAML and XML: the alternatives are C (toml++ via a
// wrapper, which brings the Windows dllimport and static-musl problems the YAML header
// lists) or a Swift port that allocates a class per node. And TOML is small enough that a
// complete, conformant parser is under a thousand lines — the official `toml-test` suite
// is the acceptance criterion, run from `DiffFuzz`, and `TOMLKit` (toml++) is the
// differential oracle.
//
// SCOPE. All of TOML 1.0.0: bare / quoted / dotted keys, the four string forms with every
// escape, integers in four bases with underscores, floats with `inf`/`nan`, the four
// date-time kinds, arrays (multi-line, trailing comma), inline tables, `[table]` and
// `[[array of tables]]` headers, and every redefinition rule the specification states.
// Nothing from TOML 1.1 (newlines in inline tables, `\e`, `\x`, optional seconds) — those
// are refused, so a document that parses here parses everywhere.
//
// FIRST ERROR STOPS. A TOML document is line-structured but a table header or a dotted
// key changes the meaning of every line after it, so there is no honest way to resume;
// the parser reports one issue with a caret and returns nil. Schema issues on a parsed
// document are still collected in full, as on every format.
//
// THE REDEFINITION RULES are the whole difficulty, and they live in one place —
// `TableBuilder` and the two walks (`define(header:)` and `assign(path:)`) below. Each
// table remembers how it came to exist (a header, dotted keys, or implicitly as the
// parent of a header), because the specification's rules are all in terms of that:
//
//   `[a]` twice                                   → error
//   `[a.b]` then `[a]`                            → fine; `a` was implicit, now defined
//   `a.b = 1` then `[a]`                          → error; dotted keys define a table
//   `[a]` `b.c = 1` then `[a.b]`                  → error, but `[a.b.d]` is fine
//   `a = { b = 1 }` then `a.c = 2` or `[a.c]`     → error; inline tables are closed
//   `a = [{}]` then `[[a]]`                       → error; a static array is a value
//   `[[a]]` then `[a]`                            → error; `[a.b]` descends into the last
//
// Every value except an open table is CLOSED the moment it is parsed, including inline
// tables and arrays, and that single fact implements most of the list.
//===----------------------------------------------------------------------===//

public import AssayCore

extension TOML {

    /// Parse a document. Throws an `AssayError` carrying the source, so printing it shows
    /// a caret.
    public static func parse(
        _ bytes: [UInt8],
        limits: Limits = .default
    ) throws(AssayError) -> Node {
        var sink = IssueSink(limits: limits)
        let node = decode(bytes, into: &sink, limits: limits)
        guard sink.isValid, let node else {
            throw AssayError(issues: sink.issues, source: SourceBytes(bytes), sourceName: "<input>")
        }
        return node
    }

    public static func parse(
        _ text: String, limits: Limits = .default
    ) throws(AssayError) -> Node {
        try parse(Array(text.utf8), limits: limits)
    }

    /// Non-throwing form: issues go to the sink, the tree comes back only if there were
    /// none. Always a `.table` when non-nil — a TOML document is a table.
    public static func decode(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> Node? {
        if bytes.count > limits.maxBytes {
            sink.add(
                Issue(
                    code: .tooManyBytes,
                    params: ["maxBytes": .int(limits.maxBytes)]))
            return nil
        }
        return withParser(bytes, &sink, limits, empty: .table([])) { parser, reader, sink in
            guard parser.parseBody(&reader, &sink) else { return nil }
            return parser.finish(0)
        }
    }

    /// Straight to `RawValue`, for the struct-decode doors. The builders are drained into
    /// the projection directly, so no `TOML.Node` table is built only to be projected and
    /// dropped (`docs/EFFICIENCY.md` row 17). Scalars and inline values are still parsed as
    /// `TOML.Node` and moved across.
    static func decodeRaw(
        _ bytes: [UInt8], into sink: inout IssueSink, limits: Limits
    ) -> RawValue? {
        if bytes.count > limits.maxBytes {
            sink.add(
                Issue(
                    code: .tooManyBytes,
                    params: ["maxBytes": .int(limits.maxBytes)]))
            return nil
        }
        return withParser(bytes, &sink, limits, empty: .mapping([])) { parser, reader, sink in
            guard parser.parseBody(&reader, &sink) else { return nil }
            return parser.finishRaw(0)
        }
    }

    /// Validation, BOM and the reader, shared by both doors. Always inlined: as a real
    /// call, the tree door paid +4% to +6% instructions for the closure.
    @inline(__always)
    static func withParser<T>(
        _ bytes: [UInt8], _ sink: inout IssueSink, _ limits: Limits, empty: T,
        _ body: (inout Parser, inout AssayReader, inout IssueSink) -> T?
    ) -> T? {
        unsafe bytes.withUnsafeBufferPointer { buf -> T? in
            guard let base = buf.baseAddress else { return empty }
            if let bad = unsafe UTF8Validation.firstInvalid(base, buf.count) {
                sink.add(
                    Issue(
                        code: .invalidUTF8, params: ["offset": .int(bad)],
                        location: SourceSpan(lo: bad, len: 1)))
                return nil
            }
            var reader = unsafe AssayReader(base: base, count: buf.count, limits: limits)
            reader.advanceBy(unsafe UTF8Validation.bomLength(base, buf.count))
            var parser = Parser(limits: limits)
            return body(&parser, &reader, &sink)
        }
    }
}

// MARK: - The table under construction

extension TOML {

    /// A table while the document is still being read.
    ///
    /// AN ARENA, NOT A CLASS. A dotted key or a header reaches into the tree at an arbitrary
    /// depth and mutates one table, so tables are addressed by INDEX into the parser's
    /// `tables` and mutated in place through it. They were a `final class` until
    /// 2026-09-20, for the same reason, and every property access on a class instance is a
    /// DYNAMIC exclusivity check: `swift_beginAccess`, its thread-local access set and the
    /// matching end, about 15% of `base/toml` (callgrind), plus an object allocation per
    /// table. Through the `inout` parser the checks are static and free.
    struct TableBuilder {
        enum Origin {
            /// `[a]` — explicitly defined; a second header is an error.
            case header
            /// `a.b = 1` — defined by dotted keys in one scope; a later header is an error,
            /// but a header for a SUB-table is not.
            case dotted
            /// `[a.b]` created `a` — exists but is not yet defined; a later `[a]` defines it.
            case implicit
        }

        struct Slot {
            var key: String
            var entry: Entry
            var span: SourceSpan?
        }

        /// ONE array of slots. Until 2026-09-19 this was three parallel arrays (keys,
        /// entries, spans) and a `Dictionary` index, each growing on its own: about 29 heap
        /// blocks per five-key `[[items]]` record (count.py `base/toml`).
        var slots: [Slot] = []
        var origin: Origin
        /// Where this table's key index lives in `Parser.indexes`, or -1. The index is built
        /// only once a table outgrows `linearLimit`: below that, a scan of a handful of short
        /// keys is cheaper than hashing one, the same trade YAML's merge makes; above it,
        /// lookups stay O(1), so a wide table is still linear to build. Out of line because
        /// almost no table has one, and an inline `[String: Int]?` made every arena entry
        /// half as large again (+1.5% to +4.3% heap bytes as the arena grew).
        var indexID: Int32 = -1
        static var linearLimit: Int { 16 }

        /// `reserve` is shape memory: the size of the table the parser just left, which for
        /// consecutive `[[items]]` sections is exact. Bounded by the input: a table
        /// over-reserves only after a larger one, by at most that one's size.
        init(origin: Origin, reserve: Int = 0) {
            self.origin = origin
            if reserve > 0 { slots.reserveCapacity(reserve) }
        }

    }

    enum Entry {
        /// A closed value: a scalar, a static array, or an inline table.
        case value(Node)
        /// An open table, reachable by later headers and dotted keys: its index in `tables`.
        case table(Int)
        /// `[[a]]` — headers append; `[a.b]` descends into the last. Its index in `arrays`.
        case array(Int)
    }

    struct Parser {
        let limits: Limits
        /// Every table of the document, the root at index 0 (`TableBuilder`).
        var tables: [TableBuilder] = [TableBuilder(origin: .header)]
        /// Every `[[a]]`, each the list of its element tables' indices.
        var arrays: [[Int]] = []
        /// Key indexes for the tables that outgrew `TableBuilder.linearLimit`.
        var indexes: [[String: Int]] = []
        /// The table the current `key = value` lines land in; changed by each header.
        var current = 0
        /// `parseKeyPath`'s reused buffer.
        var keyPathBuffer: [KeySegment] = []

        init(limits: Limits) {
            self.limits = limits
        }

        /// `TableBuilder.find`, reading the arena in place. Calling the method on
        /// `tables[t]` took a mutable access to the element (a uniqueness check per lookup)
        /// and copied the key it compared against.
        func find(_ key: borrowing String, in t: Int) -> Int? {
            let id = tables[t].indexID
            if id >= 0 { return indexes[Int(id)][copy key] }
            let n = tables[t].slots.count
            var i = 0
            while i < n {
                if tables[t].slots[i].key == key { return i }
                i &+= 1
            }
            return nil
        }

        @discardableResult
        /// `consuming`: the caller's key and entry MOVE into the slot. Borrowed parameters
        /// made every stored key and value a copy (count.py explain, 2026-09-19).
        mutating func add(
            _ key: consuming String, _ entry: consuming Entry, span: SourceSpan?, to t: Int
        ) -> Int {
            let i = tables[t].slots.count
            let id = tables[t].indexID
            // The index takes its copy of the key BEFORE the slot takes the key itself.
            if id >= 0 { indexes[Int(id)][copy key] = i }
            tables[t].slots.append(
                TableBuilder.Slot(
                    key: consume key, entry: consume entry,
                    span: span))
            if id < 0, tables[t].slots.count > TableBuilder.linearLimit {
                var built = [String: Int](minimumCapacity: tables[t].slots.count * 2)
                for (j, slot) in tables[t].slots.enumerated() { built[slot.key] = j }
                indexes.append(built)
                tables[t].indexID = Int32(indexes.count &- 1)
            }
            return i
        }

        mutating func newTable(_ origin: TableBuilder.Origin, reserve: Int = 0) -> Int {
            tables.append(TableBuilder(origin: origin, reserve: reserve))
            return tables.count &- 1
        }
    }
}

// MARK: - Document structure

extension TOML.Parser {

    /// Every line into the builders; `finish` or `finishRaw` turns them into the result.
    mutating func parseBody(_ r: inout AssayReader, _ sink: inout IssueSink) -> Bool {
        while true {
            guard skipBlankLines(&r, &sink) else { return false }
            guard let c = r.currentByte else { break }
            if c == UInt8(ascii: "[") {
                guard parseHeader(&r, &sink) else { return false }
            } else {
                guard parseKeyValue(&r, &sink, into: current) else { return false }
            }
            guard endOfLine(&r, &sink) else { return false }
        }
        return true
    }

    /// `[a.b]` or `[[a.b]]`.
    mutating func parseHeader(_ r: inout AssayReader, _ sink: inout IssueSink) -> Bool {
        let headerStart = r.byteOffset
        r.advanceBy(1)
        let isArray = r.currentByte == UInt8(ascii: "[")
        if isArray { r.advanceBy(1) }
        guard var path = parseKeyPath(&r, &sink) else { return false }
        skipSpace(&r)
        guard r.currentByte == UInt8(ascii: "]") else {
            r.report(&sink, .tomlUnterminatedTableHeader)
            return false
        }
        r.advanceBy(1)
        if isArray {
            guard r.currentByte == UInt8(ascii: "]") else {
                r.report(&sink, .tomlUnterminatedTableHeader)
                return false
            }
            r.advanceBy(1)
        }
        if path.count > limits.maxDepth {
            r.report(
                &sink, .depthExceeded, params: ["maxDepth": .int(limits.maxDepth)],
                span: SourceSpan(lo: headerStart, len: r.byteOffset - headerStart))
            return false
        }
        let span = SourceSpan(lo: headerStart, len: r.byteOffset - headerStart)
        let defined = define(
            path: &path, array: isArray, span: span,
            reserve: tables[current].slots.count, &r, &sink)
        keyPathBuffer = consume path
        guard let table = defined else { return false }
        current = table
        return true
    }

    /// `key = value`, into `table`. Also the body of an inline table.
    mutating func parseKeyValue(
        _ r: inout AssayReader, _ sink: inout IssueSink, into table: Int
    ) -> Bool {
        guard var path = parseKeyPath(&r, &sink) else { return false }
        skipSpace(&r)
        guard r.currentByte == UInt8(ascii: "=") else {
            r.report(&sink, .tomlExpectedEquals)
            return false
        }
        r.advanceBy(1)
        skipSpace(&r)
        let valueStart = r.byteOffset
        guard let value = parseValue(&r, &sink) else { return false }
        let span = SourceSpan(lo: valueStart, len: r.byteOffset - valueStart)
        if path.count > limits.maxDepth {
            r.report(
                &sink, .depthExceeded, params: ["maxDepth": .int(limits.maxDepth)],
                span: path[0].span)
            return false
        }
        let ok = assign(path: &path, value: consume value, span: span, into: table, &r, &sink)
        keyPathBuffer = consume path
        return ok
    }

    // MARK: The two walks

    /// A header. Intermediates may be anything open; the last segment is defined here.
    mutating func define(
        path: inout [KeySegment], array: Bool, span: SourceSpan, reserve: Int,
        _ r: inout AssayReader, _ sink: inout IssueSink
    ) -> Int? {
        var table = 0
        for seg in path.dropLast() {
            guard
                let next = descend(table, seg, creating: .implicit, throughArrays: true, &r, &sink)
            else {
                return nil
            }
            table = next
        }
        // Moved out, as in `assign`.
        var key = ""
        var keySpan = SourceSpan(lo: 0, len: 0)
        unsafe path.withUnsafeMutableBufferPointer {
            unsafe swap(&key, &$0[$0.count - 1].text)
            keySpan = unsafe $0[$0.count - 1].span
        }
        if let i = find(key, in: table) {
            let entry = tables[table].slots[i].entry
            switch entry {
            case .table(let existing) where !array && tables[existing].origin == .implicit:
                tables[existing].origin = .header
                tables[table].slots[i].span = span
                return existing
            case .array(let a) where array:
                let element = newTable(.header, reserve: reserve)
                arrays[a].append(element)
                return element
            case .table, .array:
                r.report(&sink, .tomlRedefinedTable, params: ["key": .string(key)], span: keySpan)
                return nil
            case .value(let v):
                r.report(&sink, closedCode(v), params: ["key": .string(key)], span: keySpan)
                return nil
            }
        }
        let element = newTable(.header, reserve: reserve)
        if array {
            arrays.append([element])
            add(consume key, .array(arrays.count &- 1), span: span, to: table)
        } else {
            add(consume key, .table(element), span: span, to: table)
        }
        return element
    }

    /// A `key = value` line. Intermediates may only be tables that dotted keys created,
    /// and the last segment must be new.
    mutating func assign(
        path: inout [KeySegment], value: consuming TOML.Node, span: SourceSpan,
        into start: Int, _ r: inout AssayReader, _ sink: inout IssueSink
    ) -> Bool {
        var table = start
        for seg in path.dropLast() {
            guard let next = descend(table, seg, creating: .dotted, throughArrays: false, &r, &sink)
            else {
                return false
            }
            table = next
        }
        // The key MOVES out of the path first, and both the lookup and the slot use that:
        // the path is this line's own, and the buffer it goes back to is cleared before its
        // next use. Reading `path[last].text` for the lookup copied it.
        var key = ""
        unsafe path.withUnsafeMutableBufferPointer { unsafe swap(&key, &$0[$0.count - 1].text) }
        if find(key, in: table) != nil {
            r.report(
                &sink, .duplicateKey, params: ["received": .string(key)],
                span: path[path.count - 1].span)
            return false
        }
        add(consume key, .value(consume value), span: span, to: table)
        return true
    }

    /// One intermediate step of either walk. `creating` is the origin a missing table
    /// gets; `throughArrays` is whether `[[a]]` may be stepped into (headers yes, dotted
    /// keys no — `a.b = 1` when `a` is an array of tables is an error).
    mutating func descend(
        _ table: Int, _ seg: KeySegment, creating: TOML.TableBuilder.Origin,
        throughArrays: Bool, _ r: inout AssayReader, _ sink: inout IssueSink
    ) -> Int? {
        guard let i = find(seg.text, in: table) else {
            let child = newTable(creating)
            add(seg.text, .table(child), span: nil, to: table)
            return child
        }
        let entry = tables[table].slots[i].entry
        switch entry {
        case .table(let child):
            // A header may pass through any open table. Dotted keys may only extend a
            // table that dotted keys made: `[a] b.c = 1` after `[a.b]` is an error.
            if creating == .dotted, tables[child].origin != .dotted {
                r.report(
                    &sink, .tomlRedefinedTable, params: ["key": .string(seg.text)], span: seg.span)
                return nil
            }
            return child
        case .array(let a) where throughArrays:
            return arrays[a][arrays[a].count &- 1]
        case .array:
            r.report(&sink, .tomlNotATable, params: ["key": .string(seg.text)], span: seg.span)
            return nil
        case .value(let v):
            r.report(&sink, closedCode(v), params: ["key": .string(seg.text)], span: seg.span)
            return nil
        }
    }

    /// Extending a closed value: an inline table gets its own message, because "is not a
    /// table" would be a lie about the one thing the reader can see it is.
    func closedCode(_ v: TOML.Node) -> IssueCode {
        if case .table = v { return .tomlInlineTableClosed }
        return .tomlNotATable
    }

    // MARK: Finishing

    /// Drains the builder rather than copying out of it: every caller drops the builder
    /// straight after, so each key and value MOVES into the node. Copying was a String
    /// retain per key and an outlined node copy per value (count.py explain, `base/toml`).
    /// `.value(.bool(false))` is the placeholder, trivial to destroy.
    mutating func finish(_ table: Int) -> TOML.Node {
        var slots: [TOML.TableBuilder.Slot] = []
        swap(&slots, &tables[table].slots)
        let members = unsafe slots.withUnsafeMutableBufferPointer { src in
            unsafe [TOML.Member](unsafeUninitializedCapacity: src.count) { dst, count in
                for i in src.indices {
                    var key = ""
                    unsafe swap(&key, &src[i].key)
                    var entry = TOML.Entry.value(.bool(false))
                    unsafe swap(&entry, &src[i].entry)
                    let value: TOML.Node
                    switch consume entry {
                    case .value(let v): value = v
                    case .table(let t): value = finish(t)
                    // The index list is copied out first: `finish` mutates `self`, which a
                    // closure over `arrays[a]` would still be reading.
                    case .array(let a): let ts = arrays[a]; value = .array(ts.map { finish($0) })
                    }
                    unsafe (dst.baseAddress! + i).initialize(
                        to: TOML.Member(key: consume key, value: value, span: src[i].span))
                }
                count = src.count
            }
        }
        return .table(members)
    }

    /// `finish`, producing the `RawValue` projection directly: the same drain, the same
    /// placeholders, with `RawValue(consuming:)` for the closed values.
    mutating func finishRaw(_ table: Int) -> RawValue {
        var slots: [TOML.TableBuilder.Slot] = []
        swap(&slots, &tables[table].slots)
        let members = unsafe slots.withUnsafeMutableBufferPointer { src in
            unsafe [RawValue.Member](unsafeUninitializedCapacity: src.count) { dst, count in
                for i in src.indices {
                    var key = ""
                    unsafe swap(&key, &src[i].key)
                    var entry = TOML.Entry.value(.bool(false))
                    unsafe swap(&entry, &src[i].entry)
                    // Bound outside the switch, then moved: a switch subject lives to the end
                    // of the case body (`docs/EFFICIENCY.md` row 14).
                    var closed: TOML.Node? = nil
                    let value: RawValue
                    switch consume entry {
                    case .value(let v): closed = v; value = .null
                    case .table(let t): value = finishRaw(t)
                    case .array(let a):
                        let ts = arrays[a]; value = .sequence(ts.map { finishRaw($0) })
                    }
                    var moved = value
                    if let v = closed.take() { moved = RawValue(consuming: consume v) }
                    unsafe (dst.baseAddress! + i).initialize(
                        to: RawValue.Member(key: consume key, value: moved, span: src[i].span))
                }
                count = src.count
            }
        }
        return .mapping(members)
    }
}

// MARK: - Keys

extension TOML.Parser {

    struct KeySegment {
        var text: String
        var span: SourceSpan
    }

    /// `a`, `"a b"`, `'a.b'`, `a . b.c` — one or more segments joined by dots.
    ///
    /// ONE BUFFER, reused across lines. A fresh array per `key = value` line was 5 of a
    /// five-key record's heap blocks (count.py `base/toml`, 2026-09-19). The buffer is HANDED
    /// OVER: swapped out here, and given back by the caller when it is done with the path
    /// (`keyPathBuffer = consume path`). Keeping a shared copy instead, as this did first,
    /// meant the caller never owned its key strings, so each one was copied into its table
    /// slot. An inline table's keys, parsed while the outer path is still out, find the
    /// buffer empty and allocate, exactly as a fresh array would.
    mutating func parseKeyPath(_ r: inout AssayReader, _ sink: inout IssueSink) -> [KeySegment]? {
        var out: [KeySegment] = []
        swap(&out, &keyPathBuffer)
        out.removeAll(keepingCapacity: true)
        while true {
            skipSpace(&r)
            guard let seg = parseSimpleKey(&r, &sink) else { return nil }
            out.append(seg)
            skipSpace(&r)
            guard r.currentByte == UInt8(ascii: ".") else { return out }
            r.advanceBy(1)
        }
    }

    mutating func parseSimpleKey(_ r: inout AssayReader, _ sink: inout IssueSink) -> KeySegment? {
        let start = r.byteOffset
        guard let c = r.currentByte else {
            r.report(&sink, .tomlExpectedKey)
            return nil
        }
        if c == UInt8(ascii: "\"") {
            // A multi-line string is not a key; `""" k """ = 1` is refused.
            if r.byte(at: 1) == UInt8(ascii: "\""), r.byte(at: 2) == UInt8(ascii: "\"") {
                r.report(&sink, .tomlExpectedKey)
                return nil
            }
            guard let s = scanBasicString(&r, &sink, multiline: false) else { return nil }
            return KeySegment(text: s, span: SourceSpan(lo: start, len: r.byteOffset - start))
        }
        if c == UInt8(ascii: "'") {
            if r.byte(at: 1) == UInt8(ascii: "'"), r.byte(at: 2) == UInt8(ascii: "'") {
                r.report(&sink, .tomlExpectedKey)
                return nil
            }
            guard let s = scanLiteralString(&r, &sink, multiline: false) else { return nil }
            return KeySegment(text: s, span: SourceSpan(lo: start, len: r.byteOffset - start))
        }
        while let b = r.currentByte, isBareKeyByte(b) { r.advanceBy(1) }
        guard r.byteOffset > start else {
            r.report(&sink, .tomlExpectedKey)
            return nil
        }
        return KeySegment(
            text: r.string(from: start, to: r.byteOffset),
            span: SourceSpan(lo: start, len: r.byteOffset - start))
    }

    func isBareKeyByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39)
            || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")
    }
}

// MARK: - Whitespace, comments, line ends

extension TOML.Parser {

    /// Spaces and tabs. TOML's whitespace is exactly those two bytes.
    func skipSpace(_ r: inout AssayReader) {
        while let c = r.currentByte, c == 0x20 || c == 0x09 { r.advanceBy(1) }
    }

    /// A `#` comment up to (not including) the line end. Control characters other than
    /// tab are not permitted in comments, and a bare CR is not a line end.
    func skipComment(_ r: inout AssayReader, _ sink: inout IssueSink) -> Bool {
        guard r.currentByte == UInt8(ascii: "#") else { return true }
        while let c = r.currentByte, c != 0x0A {
            if c == 0x0D, r.byte(at: 1) == 0x0A { return true }
            if c < 0x20 && c != 0x09 || c == 0x7F {
                r.report(&sink, .tomlControlCharacter)
                return false
            }
            r.advanceBy(1)
        }
        return true
    }

    /// LF or CRLF. Anything else is not a line end.
    func consumeNewline(_ r: inout AssayReader) -> Bool {
        if r.currentByte == 0x0A { r.advanceBy(1); return true }
        if r.currentByte == 0x0D, r.byte(at: 1) == 0x0A { r.advanceBy(2); return true }
        return false
    }

    /// After a header or a key/value: whitespace, an optional comment, then a newline or
    /// the end of the document. `a = 1 b = 2` on one line is the error this reports.
    func endOfLine(_ r: inout AssayReader, _ sink: inout IssueSink) -> Bool {
        skipSpace(&r)
        guard skipComment(&r, &sink) else { return false }
        if r.atEnd || consumeNewline(&r) { return true }
        r.report(&sink, .tomlExpectedNewline)
        return false
    }

    /// Whitespace, newlines and comments — between lines, and inside arrays.
    func skipBlankLines(_ r: inout AssayReader, _ sink: inout IssueSink) -> Bool {
        while true {
            skipSpace(&r)
            guard skipComment(&r, &sink) else { return false }
            guard consumeNewline(&r) else { return true }
        }
    }
}
