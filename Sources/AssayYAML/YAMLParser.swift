// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A hand-written, pure-Swift YAML parser producing YAML.Node.
//
// WHY HAND-WRITTEN. perf-swift-libraries.md §5 measures the alternative: Yams allocates a
// `Tag` class per node (each holding two strong refs), a `String` per scalar eagerly, an
// `Event` class per libyaml event, runs `Dictionary(grouping:)` per mapping purely to
// detect duplicate keys, and does O(N·K) mapping lookup with a Tag allocation per probe.
// It is "the largest available headroom anywhere in the Swift survey". Vendoring libyaml
// also means vendoring C, with the Windows `__declspec(dllimport)` trap and the Android /
// Wasm / static-musl breakage that comes with it.
//
// SCOPE, stated rather than discovered. YAML 1.2 is enormous and this covers the subset a
// configuration file actually uses:
//
//   SUPPORTED  block mappings and sequences (indentation), flow mappings `{}` and
//              sequences `[]`, all five scalar styles (plain, single, double, literal `|`,
//              folded `>`) with chomping indicators, comments, anchors `&a` and aliases
//              `*a`, tags `!!str` / `!Foo`, multiple documents `---` / `...`, merge keys
//              `<<`, explicit keys `? `/`: `, non-string keys.
//
//   NOT        directives beyond `%YAML`/`%TAG` (skipped), complex multi-line plain
//              scalars in flow context, YAML 1.1 sexagesimals, binary/timestamp
//              resolution, and set/omap/pairs types. Those all parse as scalars or fail
//              with a real diagnostic rather than being silently mis-resolved.
//
// RESOLUTION IS NOT DONE HERE. Scalars keep their raw text, style, tag and anchor;
// `resolvedInt` / `resolvedBool` / `isNull` are consulted on demand by the caller. That is
// what sidesteps the Norway problem instead of inheriting it — `NO` stays the string "NO"
// until someone asks a question whose answer depends on it.
//
// SECURITY. Alias expansion is bounded by a total-node budget, because billion-laughs is a
// YAML attack as much as an XML one, and depth alone does not stop it.
//===----------------------------------------------------------------------===//

public import AssayCore

extension YAML {

    /// Parse a single-document stream.
    public static func parse(
        _ bytes: [UInt8],
        limits: Limits = .default
    ) throws(AssayError) -> Node {
        let docs = try parseAll(bytes, limits: limits)
        guard let first = docs.first else {
            throw AssayError(
                issues: [Issue(code: .yamlEmptyStream)], source: SourceBytes(bytes),
                sourceName: "<input>")
        }
        guard docs.count == 1 else {
            throw AssayError(
                issues: [
                    Issue(
                        code: .yamlMultipleDocuments,
                        params: ["count": .int(docs.count)])
                ],
                source: SourceBytes(bytes), sourceName: "<input>")
        }
        return first
    }

    /// Parse every document in the stream. `EXPERIENCE.md` §12's `parseAll(yaml:)`.
    public static func parseAll(
        _ bytes: [UInt8],
        limits: Limits = .default
    ) throws(AssayError) -> [Node] {
        var sink = IssueSink(limits: limits)
        let docs = decodeAll(bytes, into: &sink, limits: limits)
        guard sink.isValid else {
            throw AssayError(issues: sink.issues, source: SourceBytes(bytes), sourceName: "<input>")
        }
        return docs
    }

    public static func parse(
        _ text: String, limits: Limits = .default
    ) throws(AssayError) -> Node {
        try parse(Array(text.utf8), limits: limits)
    }

    public static func parseAll(
        _ text: String, limits: Limits = .default
    ) throws(AssayError) -> [Node] {
        try parseAll(Array(text.utf8), limits: limits)
    }

    /// Non-throwing form.
    public static func decodeAll(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> [Node] {
        withStream(bytes, into: &sink, limits: limits, as: YAMLNodeBuilder.self)
    }

    /// Straight to `RawValue`, in ONE pass: no `YAML.Node` tree is built only to be
    /// projected and dropped (`docs/EFFICIENCY.md` rows 12 and 17). This is what
    /// `parse(yaml:)` and `diagnose(yaml:)` use, and it is public so that what they use can
    /// be tested against `decodeAll` + `RawValue(_:)` document for document.
    ///
    /// Lossy exactly as the projection is (`docs/VALUE-MODELS.md` §5): tags, styles and
    /// anchors do not survive, and a non-string mapping key is reported as
    /// `.yamlUnrepresentableKey` rather than coerced. `decodeAll` keeps all of it.
    public static func decodeAllRaw(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> [RawValue] {
        withStream(bytes, into: &sink, limits: limits, as: YAMLRawBuilder.self)
            .map { YAMLRawBuilder.resolve($0) }
    }

    /// Byte limit, UTF-8 validation, BOM, reader, parser: shared by both doors, so neither
    /// can grow a check the other lacks.
    static func withStream<B: YAMLBuilding>(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits,
        as builder: B.Type
    ) -> [B.Value] {
        if bytes.count > limits.maxBytes {
            sink.add(
                Issue(
                    code: .tooManyBytes,
                    params: ["maxBytes": .int(limits.maxBytes)]))
            return []
        }
        return unsafe bytes.withUnsafeBufferPointer { buf -> [B.Value] in
            guard let base = buf.baseAddress else { return [] }
            if let bad = unsafe UTF8Validation.firstInvalid(base, buf.count) {
                sink.add(
                    Issue(
                        code: .invalidUTF8, params: ["offset": .int(bad)],
                        location: SourceSpan(lo: bad, len: 1)))
                return []
            }
            var reader = unsafe AssayReader(base: base, count: buf.count, limits: limits)
            reader.advance(by: unsafe UTF8Validation.bomLength(base, buf.count))
            var parser = Parser<B>(limits: limits)
            return parser.parseStream(&reader, &sink)
        }
    }
}

extension YAML {

    /// Generic over what it builds: `YAMLNodeBuilder` for the node tree,
    /// `YAMLRawBuilder` for `RawValue` with no tree in between. One grammar, two outputs —
    /// see `YAMLBuilder.swift`.
    struct Parser<B: YAMLBuilding> {
        let limits: Limits
        var anchors: [String: B.Value] = [:]
        /// Shape memory: each sequence and mapping reserves what the previous one at its
        /// depth held (`_ShapeHints`). Without it a five-key mapping grew 0 → 1 → 2 → 4 → 8,
        /// four allocations per record (count.py `base/yaml`, 8,001 of 8,014 blocks).
        var hints = _ShapeHints()
        /// How many nodes each anchor expands to, so an alias can be charged its
        /// EXPANDED size rather than one unit. Without this the budget below does not
        /// bound anything: `Node` is a value type, so an alias shares storage and the
        /// parsed result is a cheap DAG — but every consumer that walks it (the
        /// `RawValue` projection every schema decode goes through, most of all)
        /// materialises the DAG into a tree, exponentially. 331 bytes reached 11.4
        /// million nodes with zero issues reported before this existed.
        var anchorCost: [String: Int] = [:]
        /// Bounds total alias expansion. Depth alone does not stop billion-laughs.
        var nodeBudget: Int

        init(limits: Limits) {
            self.limits = limits
            self.nodeBudget = min(limits.maxBytes / 8, 1 << 20)
        }

        /// Spend `n` units of the expansion budget. The single place the budget is
        /// charged, because it previously was not: `parseFlowNode` had its own alias
        /// arm that charged nothing, so every bound below applied to block style only.
        mutating func chargeNode(
            _ n: Int, r: inout AssayReader, sink: inout IssueSink
        ) -> Bool {
            nodeBudget -= n
            guard nodeBudget > 0 else {
                r.report(&sink, .yamlExpansionLimit)
                return false
            }
            return true
        }

        // MARK: Stream

        mutating func parseStream(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> [B.Value] {
            var docs: [B.Value] = []
            while true {
                skipBlanksAndComments(&r)
                if r.isAtEnd { break }

                // Document start / end markers.
                if atLineStart(&r), r.matches("---") {
                    r.advance(by: 3)
                    anchors.removeAll(keepingCapacity: true)
                    skipBlanksAndComments(&r)
                    if r.isAtEnd { docs.append(B.scalar("", style: .plain, tag: nil)); break }
                }
                if atLineStart(&r), r.matches("...") {
                    r.advance(by: 3)
                    continue
                }
                // A directive line: %YAML, %TAG. Skipped, not honoured.
                if atLineStart(&r), r.currentByte == UInt8(ascii: "%") {
                    skipLine(&r)
                    continue
                }

                guard let node = parseNode(&r, &sink, indent: -1, depth: 0) else { break }
                docs.append(node)

                skipBlanksAndComments(&r)
                if r.isAtEnd { break }
                if atLineStart(&r), r.matches("---") || r.matches("...") { continue }
                // Anything else at column 0 after a complete document is malformed.
                if !r.isAtEnd {
                    r.report(&sink, .trailingContent)
                    break
                }
            }
            return docs
        }

        /// The span of what was just parsed, from `start` to the cursor, with trailing
        /// whitespace, separators and any line comment removed.
        ///
        /// Trimming is the whole job. A YAML value parse stops wherever the next construct
        /// begins — after the newline, after blank lines, after a `#` comment, after the
        /// `,` in flow style — so the raw start-to-cursor range routinely runs to the end
        /// of the document. Underlining all of that is worse than underlining nothing.
        ///
        /// **Scanned BACKWARD from the end, and bounded to one line.** The obvious version
        /// walks forward from `start` tracking quote state to find the comment, which is
        /// correct and costs a second pass over every value: it measured a 25% regression
        /// on `YAML.parse` (6.86x over Yams down to 5.18x), because the scan is O(value)
        /// and runs per pair. Backward from the end stops at the previous newline, so it is
        /// O(one line) regardless of how large the value is.
        ///
        /// Two guards make the backward scan safe without quote tracking:
        ///
        ///   * A value ending in `"` or `'` is a quoted scalar, so any `#` inside it is
        ///     content — `key: "a # b"` must keep its hash.
        ///   * If the backward walk reaches a newline before `start`, the value spans
        ///     several lines and no trailing comment can belong to it. A `#` inside a
        ///     block scalar therefore stays put.
        ///
        /// `#` only opens a comment when preceded by whitespace or at the start of a line,
        /// which is what makes `key: a#b` a single plain scalar rather than a comment.
        func trimmedSpan(_ r: inout AssayReader, from start: Int) -> SourceSpan? {
            var end = r.byteOffset
            guard end > start else { return nil }

            @inline(__always) func isBlank(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

            while end > start {
                guard let b = r.byte(absolute: end - 1) else { break }
                if isBlank(b) || b == 0x0A || b == 0x0D || b == UInt8(ascii: ",") {
                    end -= 1
                    continue
                }
                break
            }
            guard end > start else { return nil }

            // A quoted scalar owns every byte inside its quotes.
            let last = r.byte(absolute: end - 1)
            if last != UInt8(ascii: "\""), last != UInt8(ascii: "'") {
                var i = end - 1
                while i > start {
                    guard let b = r.byte(absolute: i) else { break }
                    if b == 0x0A || b == 0x0D { break }  // multi-line: no comment
                    if b == UInt8(ascii: "#"), let prev = r.byte(absolute: i - 1),
                        isBlank(prev)
                    {
                        end = i
                        while end > start, let p = r.byte(absolute: end - 1), isBlank(p) {
                            end -= 1
                        }
                        break
                    }
                    i -= 1
                }
            }

            guard end > start else { return nil }
            return SourceSpan(lo: start, len: end - start)
        }

        // MARK: Nodes

        mutating func parseNode(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            indent: Int,
            depth: Int,
            /// True for a block mapping's VALUE, where a block sequence may sit at the key's
            /// own column rather than past it (YAML 1.2 §8.2.1). Nowhere else: a sequence
            /// entry at its parent sequence's column is a sibling, not a child.
            indentlessSequence: Bool = false
        ) -> B.Value? {
            guard depth < limits.maxDepth else {
                r.report(&sink, .depthExceeded, params: ["maxDepth": .int(limits.maxDepth)])
                return nil
            }
            // Captured before the charge so an anchored node's cost is everything its
            // subtree consumed, including nested aliases at their own expanded cost.
            let budgetAtEntry = nodeBudget
            guard chargeNode(1, r: &r, sink: &sink) else { return nil }

            skipBlanksAndComments(&r)

            // Properties: an anchor and/or a tag, in either order.
            var anchor: String?
            var tag: String?
            while true {
                if r.currentByte == UInt8(ascii: "&") {
                    r.advance(by: 1)
                    anchor = scanToken(&r)
                    skipInlineSpace(&r)
                    continue
                }
                if r.currentByte == UInt8(ascii: "!") {
                    let start = r.byteOffset
                    r.advance(by: 1)
                    if r.currentByte == UInt8(ascii: "!") { r.advance(by: 1) }
                    _ = scanToken(&r)
                    tag = r.string(from: start, to: r.byteOffset)
                    skipInlineSpace(&r)
                    continue
                }
                break
            }

            // Alias. Charged its expanded size — see `anchorCost`.
            if r.currentByte == UInt8(ascii: "*") {
                // `&q *p` is not YAML. An alias is a REFERENCE to an already-anchored node,
                // not a node of its own, so it cannot carry properties — libyaml rejects it
                // and the differential oracle caught this the first time flow anchors were
                // added. Block style had accepted it since anchors existed, silently
                // DISCARDING the `&q` (the early return below skips the recording), so a
                // later `*q` failed with "undefined alias" and named the wrong problem.
                guard anchor == nil else {
                    r.report(&sink, .yamlAnchorOnAlias)
                    return nil
                }
                r.advance(by: 1)
                guard let name = scanToken(&r), let target = anchors[name] else {
                    r.report(&sink, .yamlUndefinedAlias)
                    return nil
                }
                guard chargeNode(anchorCost[name] ?? 1, r: &r, sink: &sink) else { return nil }
                return target
            }

            skipBlanksAndComments(&r)
            var node: B.Value?

            if r.currentByte == UInt8(ascii: "[") {
                node = parseFlowSequence(&r, &sink, depth: depth)
            } else if r.currentByte == UInt8(ascii: "{") {
                node = parseFlowMapping(&r, &sink, depth: depth)
            } else if r.currentByte == UInt8(ascii: "|") || r.currentByte == UInt8(ascii: ">") {
                node = parseBlockScalar(&r, &sink, indent: indent)
            } else {
                let column = currentColumn(&r)
                if column > indent,
                    let block = tryParseBlock(
                        &r, &sink,
                        indent: column, depth: depth)
                {
                    node = block
                } else if indentlessSequence, column == indent, isSequenceEntry(&r) {
                    node = parseBlockSequence(&r, &sink, indent: column, depth: depth)
                } else {
                    node = parseFlowScalar(&r, &sink, indent: indent)
                }
            }

            // `consume`: MOVE the parsed node into `result`. Without it, `result` was a copy
            // (a retain for each String in the scalar) and `node` was destroyed at scope end:
            // one copy per node (count.py explain, 2026-09-19).
            guard var result = consume node else { return nil }

            // Attach the properties scanned above. What that means is the builder's
            // business: the node model hangs them on a scalar, and the RawValue builder
            // rewrites the unresolved scalar's tag so resolution sees it (`YAMLBuilder.swift`,
            // note 1).
            if anchor != nil || tag != nil {
                B.decorate(&result, anchor: anchor, tag: tag)
            }
            if let a = anchor {
                anchors[a] = result
                anchorCost[a] = max(1, budgetAtEntry - nodeBudget)
            }
            return result
        }

        /// A block collection if the next construct is one, otherwise nil so the caller
        /// falls back to a scalar.
        mutating func tryParseBlock(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            indent: Int,
            depth: Int
        ) -> B.Value? {
            let save = r.byteOffset

            // Block sequence: "- " or "-" at end of line.
            if r.currentByte == UInt8(ascii: "-"),
                let next = r.byte(at: 1),
                next == 0x20 || next == 0x0A || next == 0x0D
            {
                return parseBlockSequence(&r, &sink, indent: indent, depth: depth)
            }

            // Block mapping: a key followed by ":" then space or newline.
            if isBlockMappingStart(&r) {
                return parseBlockMapping(&r, &sink, indent: indent, depth: depth)
            }

            r.seek(to: save)
            return nil
        }

        /// Look ahead on this line for a `: ` that is not inside quotes.
        mutating func isBlockMappingStart(_ r: inout AssayReader) -> Bool {
            let save = r.byteOffset
            defer { r.seek(to: save) }

            // Explicit key form: "? "
            if r.currentByte == UInt8(ascii: "?"),
                let n = r.byte(at: 1), n == 0x20 || n == 0x0A
            {
                return true
            }

            var quote: UInt8?
            while let c = r.currentByte {
                if c == 0x0A { return false }
                if let q = quote {
                    if c == q { quote = nil }
                    r.advance(by: 1)
                    continue
                }
                if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                    quote = c
                    r.advance(by: 1)
                    continue
                }
                if c == UInt8(ascii: "#") { return false }
                if c == UInt8(ascii: ":") {
                    let n = r.byte(at: 1)
                    if n == nil || n == 0x20 || n == 0x0A || n == 0x0D { return true }
                }
                r.advance(by: 1)
            }
            return false
        }
    }
}
