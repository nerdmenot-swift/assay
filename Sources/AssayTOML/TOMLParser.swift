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
            sink.add(Issue(code: .tooManyBytes,
                           params: ["maxBytes": .int(limits.maxBytes)]))
            return nil
        }
        return unsafe bytes.withUnsafeBufferPointer { buf -> Node? in
            guard let base = buf.baseAddress else { return .table([]) }
            if let bad = unsafe UTF8Validation.firstInvalid(base, buf.count) {
                sink.add(Issue(code: .invalidUTF8, params: ["offset": .int(bad)],
                               location: SourceSpan(lo: bad, len: 1)))
                return nil
            }
            var reader = unsafe AssayReader(base: base, count: buf.count, limits: limits)
            reader.advanceBy(unsafe UTF8Validation.bomLength(base, buf.count))
            var parser = Parser(limits: limits)
            return parser.parseDocument(&reader, &sink)
        }
    }
}

// MARK: - The table under construction

extension TOML {

    /// A table while the document is still being read. A class, because a dotted key or a
    /// header reaches into the tree at an arbitrary depth and mutates one node; with value
    /// types that is a path-copying write per line.
    final class TableBuilder {
        enum Origin {
            /// `[a]` — explicitly defined; a second header is an error.
            case header
            /// `a.b = 1` — defined by dotted keys in one scope; a later header is an error,
            /// but a header for a SUB-table is not.
            case dotted
            /// `[a.b]` created `a` — exists but is not yet defined; a later `[a]` defines it.
            case implicit
        }

        var origin: Origin
        var keys: [String] = []
        var entries: [Entry] = []
        var spans: [SourceSpan?] = []
        var index: [String: Int] = [:]

        init(origin: Origin) { self.origin = origin }

        @discardableResult
        func add(_ key: String, _ entry: Entry, span: SourceSpan?) -> Int {
            let i = keys.count
            keys.append(key)
            entries.append(entry)
            spans.append(span)
            index[key] = i
            return i
        }
    }

    enum Entry {
        /// A closed value: a scalar, a static array, or an inline table.
        case value(Node)
        /// An open table, reachable by later headers and dotted keys.
        case table(TableBuilder)
        /// `[[a]]` — headers append; `[a.b]` descends into the last.
        case array([TableBuilder])
    }

    struct Parser {
        let limits: Limits
        let root = TableBuilder(origin: .header)
        /// The table the current `key = value` lines land in; changed by each header.
        var current: TableBuilder

        init(limits: Limits) {
            self.limits = limits
            self.current = root
        }
    }
}

// MARK: - Document structure

extension TOML.Parser {

    mutating func parseDocument(_ r: inout AssayReader, _ sink: inout IssueSink) -> TOML.Node? {
        while true {
            guard skipBlankLines(&r, &sink) else { return nil }
            guard let c = r.currentByte else { break }
            if c == UInt8(ascii: "[") {
                guard parseHeader(&r, &sink) else { return nil }
            } else {
                guard parseKeyValue(&r, &sink, into: current) else { return nil }
            }
            guard endOfLine(&r, &sink) else { return nil }
        }
        return finish(root)
    }

    /// `[a.b]` or `[[a.b]]`.
    mutating func parseHeader(_ r: inout AssayReader, _ sink: inout IssueSink) -> Bool {
        let headerStart = r.byteOffset
        r.advanceBy(1)
        let isArray = r.currentByte == UInt8(ascii: "[")
        if isArray { r.advanceBy(1) }
        guard let path = parseKeyPath(&r, &sink) else { return false }
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
            r.report(&sink, .depthExceeded, params: ["maxDepth": .int(limits.maxDepth)],
                     span: SourceSpan(lo: headerStart, len: r.byteOffset - headerStart))
            return false
        }
        let span = SourceSpan(lo: headerStart, len: r.byteOffset - headerStart)
        guard let table = define(path: path, array: isArray, span: span, &r, &sink) else { return false }
        current = table
        return true
    }

    /// `key = value`, into `table`. Also the body of an inline table.
    mutating func parseKeyValue(
        _ r: inout AssayReader, _ sink: inout IssueSink, into table: TOML.TableBuilder
    ) -> Bool {
        guard let path = parseKeyPath(&r, &sink) else { return false }
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
            r.report(&sink, .depthExceeded, params: ["maxDepth": .int(limits.maxDepth)],
                     span: path[0].span)
            return false
        }
        return assign(path: path, value: value, span: span, into: table, &r, &sink)
    }

    // MARK: The two walks

    /// A header. Intermediates may be anything open; the last segment is defined here.
    func define(
        path: [KeySegment], array: Bool, span: SourceSpan,
        _ r: inout AssayReader, _ sink: inout IssueSink
    ) -> TOML.TableBuilder? {
        var table = root
        for seg in path.dropLast() {
            guard let next = descend(table, seg, creating: .implicit, throughArrays: true, &r, &sink) else {
                return nil
            }
            table = next
        }
        let last = path[path.count - 1]
        if let i = table.index[last.text] {
            switch table.entries[i] {
            case .table(let existing) where !array && existing.origin == .implicit:
                existing.origin = .header
                table.spans[i] = span
                return existing
            case .array(var elements) where array:
                let element = TOML.TableBuilder(origin: .header)
                elements.append(element)
                table.entries[i] = .array(elements)
                return element
            case .table, .array:
                r.report(&sink, .tomlRedefinedTable, params: ["key": .string(last.text)], span: last.span)
                return nil
            case .value(let v):
                r.report(&sink, closedCode(v), params: ["key": .string(last.text)], span: last.span)
                return nil
            }
        }
        let element = TOML.TableBuilder(origin: .header)
        table.add(last.text, array ? .array([element]) : .table(element), span: span)
        return element
    }

    /// A `key = value` line. Intermediates may only be tables that dotted keys created,
    /// and the last segment must be new.
    func assign(
        path: [KeySegment], value: TOML.Node, span: SourceSpan, into start: TOML.TableBuilder,
        _ r: inout AssayReader, _ sink: inout IssueSink
    ) -> Bool {
        var table = start
        for seg in path.dropLast() {
            guard let next = descend(table, seg, creating: .dotted, throughArrays: false, &r, &sink) else {
                return false
            }
            table = next
        }
        let last = path[path.count - 1]
        if table.index[last.text] != nil {
            r.report(&sink, .duplicateKey, params: ["received": .string(last.text)], span: last.span)
            return false
        }
        table.add(last.text, .value(value), span: span)
        return true
    }

    /// One intermediate step of either walk. `creating` is the origin a missing table
    /// gets; `throughArrays` is whether `[[a]]` may be stepped into (headers yes, dotted
    /// keys no — `a.b = 1` when `a` is an array of tables is an error).
    func descend(
        _ table: TOML.TableBuilder, _ seg: KeySegment, creating: TOML.TableBuilder.Origin,
        throughArrays: Bool, _ r: inout AssayReader, _ sink: inout IssueSink
    ) -> TOML.TableBuilder? {
        guard let i = table.index[seg.text] else {
            let child = TOML.TableBuilder(origin: creating)
            table.add(seg.text, .table(child), span: nil)
            return child
        }
        switch table.entries[i] {
        case .table(let child):
            // A header may pass through any open table. Dotted keys may only extend a
            // table that dotted keys made: `[a] b.c = 1` after `[a.b]` is an error.
            if creating == .dotted, child.origin != .dotted {
                r.report(&sink, .tomlRedefinedTable, params: ["key": .string(seg.text)], span: seg.span)
                return nil
            }
            return child
        case .array(let elements) where throughArrays:
            return elements[elements.count - 1]
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

    func finish(_ table: TOML.TableBuilder) -> TOML.Node {
        var members: [TOML.Member] = []
        members.reserveCapacity(table.keys.count)
        for i in 0..<table.keys.count {
            let value: TOML.Node
            switch table.entries[i] {
            case .value(let v): value = v
            case .table(let t): value = finish(t)
            case .array(let ts): value = .array(ts.map(finish))
            }
            members.append(TOML.Member(key: table.keys[i], value: value, span: table.spans[i]))
        }
        return .table(members)
    }
}

// MARK: - Keys

extension TOML.Parser {

    struct KeySegment {
        var text: String
        var span: SourceSpan
    }

    /// `a`, `"a b"`, `'a.b'`, `a . b.c` — one or more segments joined by dots.
    mutating func parseKeyPath(_ r: inout AssayReader, _ sink: inout IssueSink) -> [KeySegment]? {
        var out: [KeySegment] = []
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
        return KeySegment(text: r.string(from: start, to: r.byteOffset),
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
