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
    ) throws(YAMLParseError) -> Node {
        let docs = try parseAll(bytes, limits: limits)
        guard let first = docs.first else {
            throw YAMLParseError(issues: [Issue(code: .custom("yaml_empty_stream"))])
        }
        guard docs.count == 1 else {
            throw YAMLParseError(issues: [Issue(
                code: .custom("yaml_multiple_documents"),
                params: ["count": .int(docs.count)])])
        }
        return first
    }

    /// Parse every document in the stream. `EXPERIENCE.md` §12's `parseAll(yaml:)`.
    public static func parseAll(
        _ bytes: [UInt8],
        limits: Limits = .default
    ) throws(YAMLParseError) -> [Node] {
        var sink = IssueSink(limits: limits)
        let docs = decodeAll(bytes, into: &sink, limits: limits)
        guard sink.isValid else { throw YAMLParseError(issues: sink.issues) }
        return docs
    }

    public static func parse(
        _ text: String, limits: Limits = .default
    ) throws(YAMLParseError) -> Node {
        try parse(Array(text.utf8), limits: limits)
    }

    public static func parseAll(
        _ text: String, limits: Limits = .default
    ) throws(YAMLParseError) -> [Node] {
        try parseAll(Array(text.utf8), limits: limits)
    }

    /// Non-throwing form.
    public static func decodeAll(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> [Node] {
        if bytes.count > limits.maxBytes {
            sink.add(Issue(code: .tooManyBytes,
                           params: ["maxBytes": .int(limits.maxBytes)]))
            return []
        }
        return bytes.withUnsafeBufferPointer { buf -> [Node] in
            guard let base = buf.baseAddress else { return [] }
            if let bad = UTF8Validation.firstInvalid(base, buf.count) {
                sink.add(Issue(code: .invalidUTF8, params: ["offset": .int(bad)],
                               location: SourceSpan(lo: bad, len: 1)))
                return []
            }
            var reader = AssayReader(base: base, count: buf.count, limits: limits)
            var parser = Parser(limits: limits)
            return parser.parseStream(&reader, &sink)
        }
    }
}

public struct YAMLParseError: Error, Sendable {
    public var issues: [Issue]
    public init(issues: [Issue]) { self.issues = issues }
}

extension YAML {

    struct Parser {
        let limits: Limits
        var anchors: [String: Node] = [:]
        /// Bounds total alias expansion. Depth alone does not stop billion-laughs.
        var nodeBudget: Int

        init(limits: Limits) {
            self.limits = limits
            self.nodeBudget = min(limits.maxBytes / 8, 1 << 20)
        }

        // MARK: Stream

        mutating func parseStream(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> [Node] {
            var docs: [Node] = []
            while true {
                skipBlanksAndComments(&r)
                if r.atEnd { break }

                // Document start / end markers.
                if atLineStart(&r), r.matches("---") {
                    r.advanceBy(3)
                    anchors.removeAll(keepingCapacity: true)
                    skipBlanksAndComments(&r)
                    if r.atEnd { docs.append(.scalar(Scalar(content: ""))); break }
                }
                if atLineStart(&r), r.matches("...") {
                    r.advanceBy(3)
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
                if r.atEnd { break }
                if atLineStart(&r), r.matches("---") || r.matches("...") { continue }
                // Anything else at column 0 after a complete document is malformed.
                if !r.atEnd {
                    r.report(&sink, .trailingContent)
                    break
                }
            }
            return docs
        }

        // MARK: Nodes

        mutating func parseNode(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            indent: Int,
            depth: Int
        ) -> Node? {
            guard depth < limits.maxDepth else {
                r.report(&sink, .depthExceeded, params: ["maxDepth": .int(limits.maxDepth)])
                return nil
            }
            nodeBudget -= 1
            guard nodeBudget > 0 else {
                r.report(&sink, .custom("yaml_expansion_limit"))
                return nil
            }

            skipBlanksAndComments(&r)

            // Properties: an anchor and/or a tag, in either order.
            var anchor: String?
            var tag: String?
            while true {
                if r.currentByte == UInt8(ascii: "&") {
                    r.advanceBy(1)
                    anchor = scanToken(&r)
                    skipInlineSpace(&r)
                    continue
                }
                if r.currentByte == UInt8(ascii: "!") {
                    let start = r.byteOffset
                    r.advanceBy(1)
                    if r.currentByte == UInt8(ascii: "!") { r.advanceBy(1) }
                    _ = scanToken(&r)
                    tag = r.string(from: start, to: r.byteOffset)
                    skipInlineSpace(&r)
                    continue
                }
                break
            }

            // Alias.
            if r.currentByte == UInt8(ascii: "*") {
                r.advanceBy(1)
                guard let name = scanToken(&r), let target = anchors[name] else {
                    r.report(&sink, .custom("yaml_undefined_alias"))
                    return nil
                }
                return target
            }

            skipBlanksAndComments(&r)
            var node: Node?

            if r.currentByte == UInt8(ascii: "[") {
                node = parseFlowSequence(&r, &sink, depth: depth)
            } else if r.currentByte == UInt8(ascii: "{") {
                node = parseFlowMapping(&r, &sink, depth: depth)
            } else if r.currentByte == UInt8(ascii: "|") || r.currentByte == UInt8(ascii: ">") {
                node = parseBlockScalar(&r, &sink, indent: indent)
            } else {
                let column = currentColumn(&r)
                if column > indent, let block = tryParseBlock(&r, &sink,
                                                             indent: column, depth: depth) {
                    node = block
                } else {
                    node = parseFlowScalar(&r, &sink)
                }
            }

            guard var result = node else { return nil }

            // Attach properties to a scalar; a collection carries them only via the anchor
            // table, since Node has nowhere to hang them.
            if case .scalar(var s) = result, anchor != nil || tag != nil {
                s.anchor = anchor
                s.tag = tag ?? s.tag
                result = .scalar(s)
            }
            if let a = anchor { anchors[a] = result }
            return result
        }

        /// A block collection if the next construct is one, otherwise nil so the caller
        /// falls back to a scalar.
        mutating func tryParseBlock(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            indent: Int,
            depth: Int
        ) -> Node? {
            let save = r.byteOffset

            // Block sequence: "- " or "-" at end of line.
            if r.currentByte == UInt8(ascii: "-"),
               let next = r.byte(at: 1),
               next == 0x20 || next == 0x0A || next == 0x0D {
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
               let n = r.byte(at: 1), n == 0x20 || n == 0x0A { return true }

            var quote: UInt8?
            while let c = r.currentByte {
                if c == 0x0A { return false }
                if let q = quote {
                    if c == q { quote = nil }
                    r.advanceBy(1)
                    continue
                }
                if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                    quote = c
                    r.advanceBy(1)
                    continue
                }
                if c == UInt8(ascii: "#") { return false }
                if c == UInt8(ascii: ":") {
                    let n = r.byte(at: 1)
                    if n == nil || n == 0x20 || n == 0x0A || n == 0x0D { return true }
                }
                r.advanceBy(1)
            }
            return false
        }

        // MARK: Block collections

        mutating func parseBlockSequence(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            indent: Int,
            depth: Int
        ) -> Node? {
            var items: [Node] = []
            while true {
                skipBlanksAndComments(&r)
                if r.atEnd { break }
                let column = currentColumn(&r)
                if column < indent { break }
                if column > indent { break }
                guard r.currentByte == UInt8(ascii: "-"),
                      let next = r.byte(at: 1),
                      next == 0x20 || next == 0x0A || next == 0x0D else { break }

                r.advanceBy(1)
                skipInlineSpace(&r)

                // An empty entry: "-" alone on a line.
                if r.currentByte == 0x0A || r.atEnd {
                    items.append(.scalar(Scalar(content: "")))
                    continue
                }
                let itemColumn = currentColumn(&r)
                guard let item = parseNode(&r, &sink, indent: itemColumn - 1,
                                           depth: depth + 1) else { return nil }
                items.append(item)
            }
            return .sequence(items)
        }

        mutating func parseBlockMapping(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            indent: Int,
            depth: Int
        ) -> Node? {
            var pairs: [Pair] = []
            // Merge sources are collected and applied AFTER the mapping is complete.
            // Applying them inline would let `<<:` win over an explicit key that appears
            // later in the document, and YAML says the explicit key always wins
            // regardless of position.
            var mergeSources: [Node] = []
            while true {
                skipBlanksAndComments(&r)
                if r.atEnd { break }
                if atLineStart(&r), r.matches("---") || r.matches("...") { break }
                let column = currentColumn(&r)
                if column != indent { break }

                // Explicit key: "? key" then "\n: value"
                var key: Node
                if r.currentByte == UInt8(ascii: "?"),
                   let n = r.byte(at: 1), n == 0x20 || n == 0x0A {
                    r.advanceBy(1)
                    skipInlineSpace(&r)
                    guard let k = parseNode(&r, &sink, indent: column,
                                            depth: depth + 1) else { return nil }
                    key = k
                    skipBlanksAndComments(&r)
                    guard r.currentByte == UInt8(ascii: ":") else {
                        r.report(&sink, .custom("yaml_expected_value_indicator"))
                        return nil
                    }
                    r.advanceBy(1)
                } else {
                    guard let k = parseKeyScalar(&r, &sink, depth: depth) else { return nil }
                    key = k
                    guard r.currentByte == UInt8(ascii: ":") else {
                        r.report(&sink, .custom("yaml_expected_colon"))
                        return nil
                    }
                    r.advanceBy(1)
                }

                skipInlineSpace(&r)

                // Value on the same line, or a nested block on following lines.
                var value: Node
                if r.currentByte == nil || r.currentByte == 0x0A || r.currentByte == 0x0D
                    || r.currentByte == UInt8(ascii: "#") {
                    skipBlanksAndComments(&r)
                    let nextColumn = currentColumn(&r)
                    if r.atEnd || nextColumn <= indent {
                        value = .scalar(Scalar(content: ""))
                    } else {
                        guard let v = parseNode(&r, &sink, indent: indent,
                                                depth: depth + 1) else { return nil }
                        value = v
                    }
                } else {
                    guard let v = parseNode(&r, &sink, indent: indent,
                                            depth: depth + 1) else { return nil }
                    value = v
                }

                // Merge key. Applied, not preserved — YAML 1.1's `<<` is a directive to the
                // parser, and a consumer seeing a literal "<<" key would be wrong.
                if case .scalar(let ks) = key, ks.content == "<<", ks.tag == nil {
                    mergeSources.append(value)
                } else {
                    pairs.append(Pair(key: key, value: value))
                }
            }
            for source in mergeSources { mergeInto(&pairs, from: source) }
            return .mapping(pairs)
        }

        /// `<<: *base` and `<<: [*a, *b]`. Earlier sources win, and an explicit key in the
        /// mapping always beats a merged one.
        func mergeInto(_ pairs: inout [Pair], from value: Node) {
            func merge(_ node: Node) {
                guard case .mapping(let source) = node else { return }
                for p in source where !pairs.contains(where: { $0.key == p.key }) {
                    pairs.append(p)
                }
            }
            if case .sequence(let sources) = value {
                for s in sources { merge(s) }
            } else {
                merge(value)
            }
        }

        /// A mapping key: quoted, flow collection, or a plain scalar up to the `:`.
        mutating func parseKeyScalar(
            _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
        ) -> Node? {
            if r.currentByte == UInt8(ascii: "[") {
                return parseFlowSequence(&r, &sink, depth: depth)
            }
            if r.currentByte == UInt8(ascii: "{") {
                return parseFlowMapping(&r, &sink, depth: depth)
            }
            if let q = r.currentByte, q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
                return parseQuoted(&r, &sink)
            }
            let start = r.byteOffset
            var end = start
            while let c = r.currentByte {
                if c == 0x0A { break }
                if c == UInt8(ascii: ":") {
                    let n = r.byte(at: 1)
                    if n == nil || n == 0x20 || n == 0x0A || n == 0x0D { break }
                }
                r.advanceBy(1)
                if c != 0x20 && c != 0x09 { end = r.byteOffset }
            }
            return .scalar(Scalar(content: r.string(from: start, to: end)))
        }

        // MARK: Flow collections

        mutating func parseFlowSequence(
            _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
        ) -> Node? {
            guard depth < limits.maxDepth else {
                r.report(&sink, .depthExceeded); return nil
            }
            r.advanceBy(1)                                   // [
            var items: [Node] = []
            while true {
                skipBlanksAndComments(&r)
                guard let c = r.currentByte else {
                    r.report(&sink, .custom("yaml_unterminated_flow_sequence"))
                    return nil
                }
                if c == UInt8(ascii: "]") { r.advanceBy(1); break }

                // Zero-progress guard. A plain flow scalar terminates on , ] } and
                // newline WITHOUT consuming the terminator, so a stray "}" here yields an
                // empty scalar and no advance — and the loop spins forever appending
                // nothing. `[}]` used to hang the parser until the OOM killer arrived.
                // Found by the fuzzer; this is exactly the class it exists to catch.
                let before = r.byteOffset
                guard let item = parseFlowNode(&r, &sink, depth: depth + 1) else { return nil }
                guard r.byteOffset > before else {
                    r.report(&sink, .custom("yaml_unexpected_in_flow"))
                    return nil
                }
                items.append(item)

                skipBlanksAndComments(&r)
                // The separator is not optional: after an item only "," or "]" is legal.
                // Falling through on anything else was the other half of the hang.
                switch r.currentByte {
                case UInt8(ascii: ","): r.advanceBy(1)
                case UInt8(ascii: "]"): r.advanceBy(1); return .sequence(items)
                case nil:
                    r.report(&sink, .custom("yaml_unterminated_flow_sequence"))
                    return nil
                default:
                    r.report(&sink, .custom("yaml_unexpected_in_flow"))
                    return nil
                }
            }
            return .sequence(items)
        }

        mutating func parseFlowMapping(
            _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
        ) -> Node? {
            guard depth < limits.maxDepth else {
                r.report(&sink, .depthExceeded); return nil
            }
            r.advanceBy(1)                                   // {
            var pairs: [Pair] = []
            var mergeSources: [Node] = []
            while true {
                skipBlanksAndComments(&r)
                guard let c = r.currentByte else {
                    r.report(&sink, .custom("yaml_unterminated_flow_mapping"))
                    return nil
                }
                if c == UInt8(ascii: "}") { r.advanceBy(1); break }

                let keyStart = r.byteOffset
                guard let key = parseFlowNode(&r, &sink, depth: depth + 1) else { return nil }
                guard r.byteOffset > keyStart else {
                    r.report(&sink, .custom("yaml_unexpected_in_flow"))
                    return nil
                }
                skipBlanksAndComments(&r)
                guard r.currentByte == UInt8(ascii: ":") else {
                    r.report(&sink, .custom("yaml_expected_colon"))
                    return nil
                }
                r.advanceBy(1)
                skipBlanksAndComments(&r)
                guard let value = parseFlowNode(&r, &sink, depth: depth + 1) else { return nil }

                if case .scalar(let ks) = key, ks.content == "<<" {
                    mergeSources.append(value)
                } else {
                    pairs.append(Pair(key: key, value: value))
                }

                skipBlanksAndComments(&r)
                switch r.currentByte {
                case UInt8(ascii: ","): r.advanceBy(1)
                case UInt8(ascii: "}"):
                    r.advanceBy(1)
                    for source in mergeSources { mergeInto(&pairs, from: source) }
                    return .mapping(pairs)
                case nil:
                    r.report(&sink, .custom("yaml_unterminated_flow_mapping"))
                    return nil
                default:
                    r.report(&sink, .custom("yaml_unexpected_in_flow"))
                    return nil
                }
            }
            for source in mergeSources { mergeInto(&pairs, from: source) }
            return .mapping(pairs)
        }

        mutating func parseFlowNode(
            _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
        ) -> Node? {
            skipBlanksAndComments(&r)
            if r.currentByte == UInt8(ascii: "*") {
                r.advanceBy(1)
                guard let name = scanToken(&r), let target = anchors[name] else {
                    r.report(&sink, .custom("yaml_undefined_alias"))
                    return nil
                }
                return target
            }
            if r.currentByte == UInt8(ascii: "[") {
                return parseFlowSequence(&r, &sink, depth: depth)
            }
            if r.currentByte == UInt8(ascii: "{") {
                return parseFlowMapping(&r, &sink, depth: depth)
            }
            if let q = r.currentByte, q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
                return parseQuoted(&r, &sink)
            }
            // Plain scalar in flow context ends at , ] } : or newline.
            let start = r.byteOffset
            var end = start
            while let c = r.currentByte {
                if c == UInt8(ascii: ",") || c == UInt8(ascii: "]")
                    || c == UInt8(ascii: "}") || c == 0x0A { break }
                if c == UInt8(ascii: ":"), let n = r.byte(at: 1),
                   n == 0x20 || n == UInt8(ascii: ",") || n == UInt8(ascii: "]")
                    || n == UInt8(ascii: "}") { break }
                r.advanceBy(1)
                if c != 0x20 && c != 0x09 { end = r.byteOffset }
            }
            return .scalar(Scalar(content: r.string(from: start, to: end)))
        }

        // MARK: Scalars

        mutating func parseFlowScalar(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> Node? {
            if let q = r.currentByte, q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
                return parseQuoted(&r, &sink)
            }
            // Plain scalar to end of line, trailing whitespace and comments trimmed.
            let start = r.byteOffset
            var end = start
            while let c = r.currentByte {
                if c == 0x0A || c == 0x0D { break }
                if c == UInt8(ascii: "#"), let p = r.byte(at: -1), p == 0x20 || p == 0x09 {
                    break
                }
                r.advanceBy(1)
                if c != 0x20 && c != 0x09 { end = r.byteOffset }
            }
            return .scalar(Scalar(content: r.string(from: start, to: end), style: .plain))
        }

        mutating func parseQuoted(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> Node? {
            let quote = r.currentByte!
            let double = quote == UInt8(ascii: "\"")
            r.advanceBy(1)

            let start = r.byteOffset
            var needsUnescape = false
            while let c = r.currentByte {
                if c == quote {
                    if !double, r.byte(at: 1) == quote {          // '' is a literal '
                        needsUnescape = true
                        r.advanceBy(2)
                        continue
                    }
                    break
                }
                if double, c == UInt8(ascii: "\\") {
                    needsUnescape = true
                    r.advanceBy(2)
                    continue
                }
                r.advanceBy(1)
            }
            guard r.currentByte == quote else {
                r.report(&sink, .custom("yaml_unterminated_quoted_scalar"))
                return nil
            }
            let raw = r.string(from: start, to: r.byteOffset)
            r.advanceBy(1)

            let content: String
            if !needsUnescape {
                content = raw                                    // fast path: one copy
            } else if double {
                guard let u = unescapeDouble(raw, &r, &sink) else { return nil }
                content = u
            } else {
                content = raw.replacingOccurrencesOfDoubledQuote()
            }
            return .scalar(Scalar(content: content,
                                  style: double ? .doubleQuoted : .singleQuoted))
        }

        func unescapeDouble(
            _ raw: String, _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> String? {
            var out = ""
            out.reserveCapacity(raw.count)
            var i = raw.startIndex
            while i < raw.endIndex {
                let c = raw[i]
                if c != "\\" { out.append(c); i = raw.index(after: i); continue }
                i = raw.index(after: i)
                guard i < raw.endIndex else { break }
                let e = raw[i]
                i = raw.index(after: i)
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "a": out.append("\u{07}")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "v": out.append("\u{0B}")
                case "e": out.append("\u{1B}")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "/": out.append("/")
                case " ": out.append(" ")
                case "x", "u", "U":
                    let width = e == "x" ? 2 : (e == "u" ? 4 : 8)
                    var hex = ""
                    var n = 0
                    while n < width, i < raw.endIndex {
                        hex.append(raw[i]); i = raw.index(after: i); n += 1
                    }
                    guard let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) else {
                        r.report(&sink, .custom("yaml_bad_escape"))
                        return nil
                    }
                    out.unicodeScalars.append(s)
                default:
                    r.report(&sink, .custom("yaml_bad_escape"))
                    return nil
                }
            }
            return out
        }

        /// Literal `|` and folded `>` block scalars, with chomping (`-` strip, `+` keep)
        /// and an optional explicit indentation indicator.
        mutating func parseBlockScalar(
            _ r: inout AssayReader, _ sink: inout IssueSink, indent: Int
        ) -> Node? {
            let folded = r.currentByte == UInt8(ascii: ">")
            r.advanceBy(1)

            var chomp: Character = "c"                    // c=clip, s=strip, k=keep
            var explicitIndent = 0
            while let c = r.currentByte, c != 0x0A, c != 0x0D {
                if c == UInt8(ascii: "-") { chomp = "s" }
                else if c == UInt8(ascii: "+") { chomp = "k" }
                else if c >= 0x31 && c <= 0x39 { explicitIndent = Int(c - 0x30) }
                r.advanceBy(1)
            }
            skipLine(&r)

            var lines: [String] = []
            var blockIndent = explicitIndent > 0 ? indent + explicitIndent : -1

            while !r.atEnd {
                let lineStart = r.byteOffset
                var column = 0
                while let c = r.currentByte, c == 0x20 { r.advanceBy(1); column += 1 }

                // A blank line belongs to the block regardless of its indentation.
                if r.currentByte == 0x0A || r.currentByte == nil {
                    lines.append("")
                    skipLine(&r)
                    continue
                }
                if blockIndent < 0 { blockIndent = column }
                if column < blockIndent {
                    r.seek(to: lineStart)
                    break
                }
                r.seek(to: lineStart + blockIndent)
                let textStart = r.byteOffset
                while let c = r.currentByte, c != 0x0A, c != 0x0D { r.advanceBy(1) }
                lines.append(r.string(from: textStart, to: r.byteOffset))
                skipLine(&r)
            }

            // Chomping applies to the trailing newlines only.
            while let last = lines.last, last.isEmpty { lines.removeLast() }

            var content: String
            if folded {
                // Folded: a single newline between non-empty lines becomes a space; a
                // blank line becomes a newline; a more-indented line keeps its break.
                var parts: [String] = []
                var current = ""
                for line in lines {
                    if line.isEmpty {
                        parts.append(current); current = ""
                    } else if line.first == " " || line.first == "\t" {
                        if !current.isEmpty { parts.append(current); current = "" }
                        parts.append(line)
                    } else if current.isEmpty {
                        current = line
                    } else {
                        current += " " + line
                    }
                }
                if !current.isEmpty { parts.append(current) }
                content = parts.joined(separator: "\n")
            } else {
                content = lines.joined(separator: "\n")
            }

            switch chomp {
            case "s": break                                    // strip: no trailing newline
            case "k": content += "\n\n"                         // keep (approximate)
            default: if !content.isEmpty { content += "\n" }    // clip: exactly one
            }

            return .scalar(Scalar(content: content, style: folded ? .folded : .literal))
        }

        // MARK: Lexing

        func atLineStart(_ r: inout AssayReader) -> Bool {
            r.byteOffset == 0 || r.byte(at: -1) == 0x0A
        }

        func currentColumn(_ r: inout AssayReader) -> Int {
            var i = r.byteOffset
            var column = 0
            while i > 0, r.byte(absolute: i - 1) != 0x0A {
                i -= 1
                column += 1
            }
            return column
        }

        mutating func skipInlineSpace(_ r: inout AssayReader) {
            while let c = r.currentByte, c == 0x20 || c == 0x09 { r.advanceBy(1) }
        }

        mutating func skipLine(_ r: inout AssayReader) {
            while let c = r.currentByte, c != 0x0A { r.advanceBy(1) }
            if r.currentByte == 0x0A { r.advanceBy(1) }
        }

        mutating func skipBlanksAndComments(_ r: inout AssayReader) {
            while let c = r.currentByte {
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    r.advanceBy(1)
                    continue
                }
                // A comment starts at line start or after whitespace — `a#b` is a scalar.
                if c == UInt8(ascii: "#") {
                    let p = r.byte(at: -1)
                    if p == nil || p == 0x20 || p == 0x09 || p == 0x0A {
                        skipLine(&r)
                        continue
                    }
                }
                break
            }
        }

        mutating func scanToken(_ r: inout AssayReader) -> String? {
            let start = r.byteOffset
            while let c = r.currentByte,
                  c != 0x20, c != 0x09, c != 0x0A, c != 0x0D,
                  c != UInt8(ascii: ","), c != UInt8(ascii: "["), c != UInt8(ascii: "]"),
                  c != UInt8(ascii: "{"), c != UInt8(ascii: "}") {
                r.advanceBy(1)
            }
            return r.byteOffset > start ? r.string(from: start, to: r.byteOffset) : nil
        }
    }
}

extension String {
    /// `''` inside a single-quoted scalar is a literal `'`.
    func replacingOccurrencesOfDoubledQuote() -> String {
        var out = ""
        out.reserveCapacity(count)
        var i = startIndex
        while i < endIndex {
            let c = self[i]
            out.append(c)
            i = index(after: i)
            if c == "'", i < endIndex, self[i] == "'" { i = index(after: i) }
        }
        return out
    }
}
