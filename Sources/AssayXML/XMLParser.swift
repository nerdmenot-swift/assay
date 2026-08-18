// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A hand-written, pure-Swift XML parser producing XML.Document.
//
// WHY HAND-WRITTEN. cross-platform-audit.md §4 rules out every alternative:
//   * `XMLDocument` is macOS + Mac Catalyst only, so a cross-Apple-platform library
//     cannot use it at all.
//   * `XMLParser` exposes `lineNumber`/`columnNumber` only *during* delegate callbacks,
//     with no byte ranges — so it cannot produce the carets EXPERIENCE.md §3 promises.
//   * swift-foundation has reimplemented **zero** XML, so this will not improve.
//   * Every third-party Swift XML library bottoms out in libxml2, which on Android drags
//     liblzma and libiconv behind it.
//
// SECURITY IS NOT OPTIONAL HERE. XML's attack surface is the reason `parse(body:
// contentType:accepting:)` has no default in EXPERIENCE.md §12. This parser:
//   * **refuses external entities outright** (XXE) — no network, no filesystem, ever;
//   * caps internal entity expansion (billion laughs / quadratic blowup);
//   * caps nesting depth via `Limits.maxDepth`;
//   * treats a DOCTYPE's internal subset as declarations to *skip*, not to honour.
//
// Scope: XML 1.0, UTF-8. Not supported, deliberately and stated rather than discovered:
// DTD validation, external entities, XML 1.1, non-UTF-8 encodings, XInclude, XSD.
// That is the same line compnerd/xylem draws, and for the same reasons.
//===----------------------------------------------------------------------===//

public import AssayCore

extension XML {

    /// Parse a document. Every issue is collected, not just the first.
    public static func parse(
        _ bytes: [UInt8],
        limits: Limits = .default
    ) throws(XMLParseError) -> Document {
        var sink = IssueSink(limits: limits)
        guard let doc = decode(bytes, into: &sink, limits: limits), sink.isValid else {
            throw XMLParseError(issues: sink.issues)
        }
        return doc
    }

    public static func parse(
        _ text: String,
        limits: Limits = .default
    ) throws(XMLParseError) -> Document {
        try parse(Array(text.utf8), limits: limits)
    }

    /// Non-throwing form.
    public static func decode(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> Document? {
        if bytes.count > limits.maxBytes {
            sink.add(Issue(code: .tooManyBytes,
                           params: ["maxBytes": .int(limits.maxBytes)]))
            return nil
        }
        return bytes.withUnsafeBufferPointer { buf -> Document? in
            guard let base = buf.baseAddress else { return nil }
            // Same whole-buffer UTF-8 pass as the JSON path, for the same reason: it is
            // one linear pass, and it removes validation from every String built after.
            if let bad = UTF8Validation.firstInvalid(base, buf.count) {
                sink.add(Issue(code: .invalidUTF8, params: ["offset": .int(bad)],
                               location: SourceSpan(lo: bad, len: 1)))
                return nil
            }
            var reader = AssayReader(base: base, count: buf.count, limits: limits)
            var parser = Parser(limits: limits, inputBytes: buf.count)
            return parser.parseDocument(&reader, &sink)
        }
    }
}

public struct XMLParseError: Error, Sendable {
    public var issues: [Issue]
    public init(issues: [Issue]) { self.issues = issues }
}

extension XML {

    /// The parser state. A struct, and never escaping, so it stays on the stack.
    struct Parser {
        let limits: Limits
        /// Internal general entities from the DOCTYPE internal subset.
        var entities: [String: String] = [:]
        /// Entities currently being expanded, so `<!ENTITY a "&a;">` is caught as a cycle
        /// rather than recursing until the stack runs out. XML 1.0 §4.1 forbids recursion
        /// outright, so this is a well-formedness error and not a budget question.
        var expanding: Set<String> = []
        /// Total bytes produced by entity expansion, capped to stop billion-laughs.
        var expansionBudget: Int
        /// Namespace bindings, as a stack of scopes: prefix -> URI. "" is the default ns.
        var namespaces: [[String: String]] = [[:]]

        init(limits: Limits, inputBytes: Int) {
            self.limits = limits
            // BOUNDED BY RATIO, not by an absolute size, which is the same rule
            // `Tests/AssayTests/AmplificationTests.swift` applies everywhere else: the
            // question a resource-exhaustion bound has to answer is "how much output can a
            // small input buy?"
            //
            // A flat 8 MB cap answered it wrong, and this is not hypothetical — once nested
            // entities actually expanded, the classic billion-laughs document produced
            // 1,000,000 bytes from 290 and passed, because a megabyte is comfortably under
            // eight. The amplification is the attack; the absolute figure is beside the
            // point.
            //
            // 32x matches the node-per-byte bound used for YAML aliases, with a 64 KB floor
            // so a small document may still use entities freely. Nothing legitimate comes
            // close: entity text is short and reused, so real expansion is a few times the
            // input at most.
            self.expansionBudget = min(limits.maxBytes, max(64 << 10, inputBytes &* 32))
        }

        // MARK: Document

        mutating func parseDocument(
            _ r: inout AssayReader,
            _ sink: inout IssueSink
        ) -> XML.Document? {
            var prolog: [XML.Node] = []

            while true {
                skipSpace(&r)
                if r.consume("<?xml") {
                    // The XML declaration. Encoding is not honoured — this parser is
                    // UTF-8 only and says so rather than pretending otherwise.
                    guard skipUntil(&r, "?>", &sink) else { return nil }
                    continue
                }
                if r.matches("<!--") {
                    guard let c = parseComment(&r, &sink) else { return nil }
                    prolog.append(c)
                    continue
                }
                if r.matches("<?") {
                    guard let pi = parseProcessingInstruction(&r, &sink) else { return nil }
                    prolog.append(pi)
                    continue
                }
                if r.matches("<!DOCTYPE") {
                    guard parseDoctype(&r, &sink) else { return nil }
                    continue
                }
                break
            }

            skipSpace(&r)
            guard r.currentByte == UInt8(ascii: "<") else {
                r.report(&sink, .custom("xml_no_root"))
                return nil
            }
            guard let root = parseElement(&r, &sink, depth: 0) else { return nil }

            // Trailing content after the root: only whitespace, comments and PIs are legal.
            while true {
                skipSpace(&r)
                if r.atEnd { break }
                if r.matches("<!--") { _ = parseComment(&r, &sink); continue }
                if r.matches("<?") { _ = parseProcessingInstruction(&r, &sink); continue }
                r.report(&sink, .trailingContent)
                return nil
            }

            return XML.Document(root: root, prolog: prolog)
        }

        // MARK: Elements

        mutating func parseElement(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            depth: Int
        ) -> XML.Element? {
            guard depth < limits.maxDepth else {
                r.report(&sink, .depthExceeded, params: ["maxDepth": .int(limits.maxDepth)])
                return nil
            }
            guard r.consume("<") else {
                r.report(&sink, .custom("xml_expected_element"))
                return nil
            }

            let nameStart = r.byteOffset
            guard let rawName = scanName(&r) else {
                r.report(&sink, .custom("xml_bad_name"))
                return nil
            }

            // Attributes are parsed OUT OF LINE, in `scanAttributes` below. That is a
            // stack decision, not a tidiness one: `parseElement` recurses, so every byte in
            // its frame is paid `maxDepth` times over. See the note on `scanAttributes`.
            var rawAttributes: [(Range<Int>, String, SourceSpan, SourceSpan)] = []
            var scope: [String: String] = [:]
            guard scanAttributes(&r, &sink, into: &rawAttributes, scope: &scope) else {
                return nil
            }

            // Push a scope ONLY when this element declares one. Most elements declare no
            // namespace at all, and pushing an empty dictionary for each of them costs an
            // array append per element and makes every `lookup` walk a stack that is mostly
            // empty frames.
            let pushedScope = !scope.isEmpty
            if pushedScope { namespaces.append(scope) }
            defer { if pushedScope { namespaces.removeLast() } }

            let name = resolve(rawName, isAttribute: false)
            var attributes: [XML.Attribute] = []
            attributes.reserveCapacity(rawAttributes.count)
            // Duplicates are found by scanning what has been appended already, not with a
            // Set. Elements have a handful of attributes, where a linear scan over a
            // contiguous array beats hashing — and the Set was a heap allocation per
            // element for a check that almost never fires.
            for (nameRange, v, span, valueSpan) in rawAttributes {
                let n = r.string(from: nameRange.lowerBound, to: nameRange.upperBound)
                let resolved = resolve(n, isAttribute: true)
                // Duplicate attributes are a well-formedness error in XML, unlike
                // duplicate child elements which are ordinary.
                if attributes.contains(where: { $0.name == resolved }) {
                    sink.add(Issue(code: .duplicateKey,
                                   path: [.key(rawName), .key(n)],
                                   received: n, location: span))
                }
                attributes.append(XML.Attribute(name: resolved, value: v,
                                                valueSpan: valueSpan))
            }

            // Empty element: <tag/>. There is no content to underline, so the caret goes
            // under the tag name — the only thing in the document that exists.
            if r.consume("/>") {
                return XML.Element(name: name, attributes: attributes, children: [],
                                   contentSpan: SourceSpan(lo: nameStart,
                                                           len: rawName.utf8.count))
            }
            guard r.consume(">") else {
                r.report(&sink, .custom("xml_unterminated_tag"))
                return nil
            }
            // Everything between `>` and the matching `</` is this element's content, and
            // that is what a schema issue about this element is about.
            let contentStart = r.byteOffset

            var children: [XML.Node] = []
            // Elements with children usually have several, and the profile showed this
            // array's 1->2->4 growth chain as the largest single source of allocation in
            // the parser. A leaf over-reserves three slots of a transient buffer, which is
            // cheaper than the reallocations it avoids everywhere else.
            children.reserveCapacity(4)
            var contentEnd = contentStart

            while true {
                guard !r.atEnd else {
                    sink.add(Issue(code: .custom("xml_unclosed_element"),
                                   path: [.key(rawName)],
                                   received: rawName,
                                   location: SourceSpan(lo: nameStart, len: rawName.utf8.count)))
                    return nil
                }

                if r.matches("</") {
                    contentEnd = r.byteOffset
                    _ = r.consume("</")
                    guard let close = scanName(&r) else {
                        r.report(&sink, .custom("xml_bad_name"))
                        return nil
                    }
                    skipSpace(&r)
                    guard r.consume(">") else {
                        r.report(&sink, .custom("xml_unterminated_tag"))
                        return nil
                    }
                    guard close == rawName else {
                        sink.add(Issue(
                            code: .custom("xml_mismatched_tag"),
                            path: [.key(rawName)],
                            params: ["expected": .string(rawName), "found": .string(close)],
                            received: close,
                            location: SourceSpan(lo: nameStart, len: rawName.utf8.count)))
                        return nil
                    }
                    break
                }

                if r.matches("<!--") {
                    guard let c = parseComment(&r, &sink) else { return nil }
                    children.append(c)
                    continue
                }
                if r.matches("<![CDATA[") {
                    guard let c = parseCDATA(&r, &sink) else { return nil }
                    children.append(c)
                    continue
                }
                if r.matches("<?") {
                    guard let pi = parseProcessingInstruction(&r, &sink) else { return nil }
                    children.append(pi)
                    continue
                }
                if r.currentByte == UInt8(ascii: "<") {
                    guard let child = parseElement(&r, &sink, depth: depth + 1) else {
                        return nil
                    }
                    children.append(.element(child))
                    continue
                }

                guard let text = parseText(&r, &sink) else { return nil }
                if !text.isEmpty { children.append(.text(text)) }
            }

            return XML.Element(name: name, attributes: attributes, children: children,
                               contentSpan: SourceSpan(
                                   lo: contentStart,
                                   len: max(0, contentEnd - contentStart)))
        }

        /// Parse an element's attributes, up to the `>` or `/>`.
        ///
        /// **`@inline(never)`, and that is load-bearing.** `parseElement` is recursive, so
        /// its frame size is multiplied by `Limits.maxDepth` — 64 by default. This loop's
        /// locals inlined into it grew that frame past what a thread stack allows, and a
        /// 5,000-deep document then died with SIGBUS inside the amplification suite, nowhere
        /// near the code that caused it. Swift Testing runs on threads with far less stack
        /// than the main thread, which is what made it visible at all.
        ///
        /// The rule this is an instance of: **in a recursive descent parser, keep the
        /// recursive function's frame small.** Work that does not itself recurse belongs
        /// behind a call.
        ///
        /// Names are collected as byte RANGES rather than Strings. Most attribute names are
        /// examined and discarded — `xmlns` and `xmlns:foo` are namespace declarations that
        /// never become attributes — and building a String for each, then asking
        /// `hasPrefix("xmlns:")` (Character-based, with the same cost `firstIndex` had) and
        /// `String(dropFirst(6))`, is allocation and grapheme walking to throw the result
        /// away. It also keeps the tuple free of a second String, so the array needs no ARC.
        @inline(never)
        mutating func scanAttributes(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            into rawAttributes: inout [(Range<Int>, String, SourceSpan, SourceSpan)],
            scope: inout [String: String]
        ) -> Bool {
            while true {
                skipSpace(&r)
                guard let c = r.currentByte else {
                    r.report(&sink, .custom("xml_unterminated_tag"))
                    return false
                }
                if c == UInt8(ascii: ">") || c == UInt8(ascii: "/") { return true }

                let attrStart = r.byteOffset
                guard let aRange = scanNameRange(&r) else {
                    r.report(&sink, .custom("xml_bad_attribute_name"))
                    return false
                }
                skipSpace(&r)
                guard r.consume("=") else {
                    r.report(&sink, .custom("xml_expected_equals"))
                    return false
                }
                skipSpace(&r)
                let valueStart = r.byteOffset
                guard let aValue = parseAttributeValue(&r, &sink) else { return false }
                // Inside the quotes, which is what a caret should underline.
                let valueSpan = SourceSpan(lo: valueStart + 1,
                                           len: max(0, r.byteOffset - valueStart - 2))

                if bytes(r, aRange, equal: "xmlns") {
                    scope[""] = aValue
                } else if bytes(r, aRange, hasPrefix: "xmlns:") {
                    scope[r.string(from: aRange.lowerBound + 6, to: aRange.upperBound)] = aValue
                } else {
                    rawAttributes.append(
                        (aRange, aValue,
                         SourceSpan(lo: attrStart, len: r.byteOffset - attrStart),
                         valueSpan))
                }
            }
        }

        /// A name's byte RANGE, without building a `String` for it.
        mutating func scanNameRange(_ r: inout AssayReader) -> Range<Int>? {
            guard let first = r.currentByte, isNameStart(first) else { return nil }
            let start = r.byteOffset
            while let c = r.currentByte, isNameChar(c) { r.advanceBy(1) }
            return start..<r.byteOffset
        }

        /// Whether the bytes in `range` are exactly `literal`.
        @inline(never)
        func bytes(_ r: borrowing AssayReader, _ range: Range<Int>,
                   equal literal: StaticString) -> Bool {
            let n = literal.utf8CodeUnitCount
            guard range.count == n else { return false }
            return unsafe bytesMatch(r, range.lowerBound, literal, n)
        }

        /// Whether the bytes in `range` begin with `literal`.
        @inline(never)
        func bytes(_ r: borrowing AssayReader, _ range: Range<Int>,
                   hasPrefix literal: StaticString) -> Bool {
            let n = literal.utf8CodeUnitCount
            guard range.count >= n else { return false }
            return unsafe bytesMatch(r, range.lowerBound, literal, n)
        }

        @inline(never)
        func bytesMatch(
            _ r: borrowing AssayReader, _ start: Int, _ literal: StaticString, _ n: Int
        ) -> Bool {
            let p = unsafe literal.utf8Start
            var i = 0
            while i < n {
                guard let b = r.byte(absolute: start + i), unsafe b == p[i] else {
                    return false
                }
                i += 1
            }
            return true
        }

        // MARK: Namespace resolution

        /// Resolve a possibly-prefixed name against the binding stack.
        ///
        /// The prefix itself is discarded — it is presentation. Two documents using `ns:`
        /// and `dc:` for the same URI compare equal, which is what anyone actually wants.
        ///
        /// An *unprefixed attribute* is NOT in the default namespace, per the Namespaces
        /// spec. That asymmetry with elements is real and easy to get wrong.
        /// Split a possibly-prefixed name at its colon.
        ///
        /// **Over `raw.utf8`, never over `raw`.** `String.firstIndex(of: ":")` iterates by
        /// Character, which means grapheme breaking, `validateScalarIndex`, `_allASCII` and
        /// a full `String ==` per position — and this runs once per element AND once per
        /// attribute. Profiling put that family of calls at roughly half of all parse time,
        /// far ahead of anything doing real work.
        ///
        /// A byte scan is exact here rather than approximate: `:` is ASCII 0x3A, UTF-8 is
        /// self-synchronizing, and no continuation byte can be 0x3A, so a colon byte is
        /// always a colon character. Element names may be non-ASCII and this stays correct
        /// for them.
        ///
        /// This is the one lesson from libxml2 that transfers wholesale — it works on bytes
        /// because C has no other option, while Swift makes the expensive thing the default
        /// spelling.
        ///
        /// TRIED AND REJECTED: noticing the colon inside `scanName`, which already walks
        /// these bytes, so that this function needs no search at all. It is the obvious next
        /// step and it measured **167 MB/s against 195** — one comparison per name byte, on
        /// every name, costs more than one `firstIndex` over the handful of bytes a name
        /// has. Do not re-derive it.
        func resolve(_ raw: String, isAttribute: Bool) -> XML.Name {
            let utf8 = raw.utf8
            guard let colon = utf8.firstIndex(of: UInt8(ascii: ":")) else {
                if isAttribute { return XML.Name(raw) }
                return XML.Name(raw, namespaceURI: lookup(""))
            }
            let prefix = String(raw[raw.startIndex..<colon])
            let local = String(raw[utf8.index(after: colon)...])
            if prefix == "xml" {
                return XML.Name(local, namespaceURI: "http://www.w3.org/XML/1998/namespace")
            }
            return XML.Name(local, namespaceURI: lookup(prefix))
        }

        func lookup(_ prefix: String) -> String? {
            for scope in namespaces.reversed() {
                if let uri = scope[prefix] { return uri.isEmpty ? nil : uri }
            }
            return nil
        }

        // MARK: Line endings

        /// XML 1.0 §2.11: translate `\r\n` and bare `\r` to `\n` in everything parsed —
        /// text, CDATA, comments, PI data. Applied BEFORE entity expansion, so a
        /// character reference `&#13;` survives literally: the spec normalises the
        /// document's line endings, not the references.
        func normalizeLineEndings(_ s: String) -> String {
            guard s.utf8.contains(0x0D) else { return s }
            var out: [UInt8] = []
            out.reserveCapacity(s.utf8.count)
            var previousWasCR = false
            for b in s.utf8 {
                if b == 0x0D { out.append(0x0A); previousWasCR = true; continue }
                if b != 0x0A || !previousWasCR { out.append(b) }
                previousWasCR = false
            }
            return String(decoding: out, as: UTF8.self)
        }

        /// XML 1.0 §3.3.3: in an attribute value, each literal whitespace character
        /// becomes a space — with line-ending normalisation applied first, so `\r\n` is
        /// ONE space, not two. Also before expansion: `&#10;` keeps its newline.
        func normalizeAttributeWhitespace(_ s: String) -> String {
            guard s.utf8.contains(where: { $0 == 0x0D || $0 == 0x0A || $0 == 0x09 })
            else { return s }
            var out: [UInt8] = []
            out.reserveCapacity(s.utf8.count)
            var previousWasCR = false
            for b in s.utf8 {
                switch b {
                case 0x0D: out.append(0x20); previousWasCR = true; continue
                case 0x0A: if !previousWasCR { out.append(0x20) }
                case 0x09: out.append(0x20)
                default:   out.append(b)
                }
                previousWasCR = false
            }
            return String(decoding: out, as: UTF8.self)
        }

        // MARK: Leaves

        mutating func parseComment(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> XML.Node? {
            _ = r.consume("<!--")
            let start = r.byteOffset
            while !r.atEnd {
                if r.matches("-->") {
                    let text = r.string(from: start, to: r.byteOffset)
                    _ = r.consume("-->")
                    return .comment(normalizeLineEndings(text))
                }
                r.advanceBy(1)
            }
            r.report(&sink, .custom("xml_unterminated_comment"))
            return nil
        }

        mutating func parseCDATA(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> XML.Node? {
            _ = r.consume("<![CDATA[")
            let start = r.byteOffset
            while !r.atEnd {
                if r.matches("]]>") {
                    let text = r.string(from: start, to: r.byteOffset)
                    _ = r.consume("]]>")
                    return .cdata(normalizeLineEndings(text))
                }
                r.advanceBy(1)
            }
            r.report(&sink, .custom("xml_unterminated_cdata"))
            return nil
        }

        mutating func parseProcessingInstruction(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> XML.Node? {
            _ = r.consume("<?")
            guard let target = scanName(&r) else {
                r.report(&sink, .custom("xml_bad_pi_target"))
                return nil
            }
            skipSpace(&r)
            let start = r.byteOffset
            while !r.atEnd {
                if r.matches("?>") {
                    let data = r.string(from: start, to: r.byteOffset)
                    _ = r.consume("?>")
                    return .processingInstruction(target: target,
                                                  data: normalizeLineEndings(data))
                }
                r.advanceBy(1)
            }
            r.report(&sink, .custom("xml_unterminated_pi"))
            return nil
        }

        /// Character data up to the next `<`, with entity references resolved.
        mutating func parseText(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> String? {
            let start = r.byteOffset
            var sawEntity = false
            var sawCR = false
            // ONE pass. The scan already looks at every byte to find `<`, so noticing `&`
            // and CR here is free — while `normalizeLineEndings` checking `utf8.contains`
            // afterwards is a second walk over the same bytes, and it measured 150 samples
            // across text and attributes. Scanning once for everything you need is the
            // habit libxml2 is built on.
            while let c = r.currentByte, c != UInt8(ascii: "<") {
                if c == UInt8(ascii: "&") { sawEntity = true }
                else if c == 0x0D { sawCR = true }
                r.advanceBy(1)
            }
            let slice = r.string(from: start, to: r.byteOffset)
            let raw = sawCR ? normalizeLineEndings(slice) : slice
            if !sawEntity { return raw }
            return expandEntities(raw, &r, &sink)
        }

        mutating func parseAttributeValue(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> String? {
            guard let quote = r.currentByte,
                  quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
                r.report(&sink, .custom("xml_unquoted_attribute"))
                return nil
            }
            r.advanceBy(1)
            let start = r.byteOffset
            var sawEntity = false
            var sawWhitespace = false
            while let c = r.currentByte, c != quote {
                if c == UInt8(ascii: "&") { sawEntity = true }
                else if c == 0x0D || c == 0x0A || c == 0x09 { sawWhitespace = true }
                else if c == UInt8(ascii: "<") {
                    r.report(&sink, .custom("xml_raw_lt_in_attribute"))
                    return nil
                }
                r.advanceBy(1)
            }
            guard r.currentByte == quote else {
                r.report(&sink, .custom("xml_unterminated_attribute"))
                return nil
            }
            // Same one-pass rule as parseText: the loop above already saw every byte.
            let slice = r.string(from: start, to: r.byteOffset)
            let raw = sawWhitespace ? normalizeAttributeWhitespace(slice) : slice
            r.advanceBy(1)
            return sawEntity ? expandEntities(raw, &r, &sink) : raw
        }

        // MARK: Entities

        /// Resolve `&amp;`, `&#65;`, `&#x41;` and any entity declared in the internal
        /// subset. **External entities are never resolved** — that is XXE.
        mutating func expandEntities(
            _ input: String, _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> String? {
            var out = ""
            out.reserveCapacity(input.count)
            var rest = Substring(input)

            while let amp = rest.firstIndex(of: "&") {
                out += rest[rest.startIndex..<amp]
                rest = rest[rest.index(after: amp)...]
                guard let semi = rest.firstIndex(of: ";") else {
                    r.report(&sink, .custom("xml_unterminated_entity"))
                    return nil
                }
                let name = String(rest[rest.startIndex..<semi])
                rest = rest[rest.index(after: semi)...]

                let replacement: String
                switch name {
                case "lt": replacement = "<"
                case "gt": replacement = ">"
                case "amp": replacement = "&"
                case "quot": replacement = "\""
                case "apos": replacement = "'"
                default:
                    if name.hasPrefix("#") {
                        guard let scalar = numericCharacterReference(name) else {
                            sink.add(Issue(code: .custom("xml_bad_character_reference"),
                                           received: "&\(name);"))
                            return nil
                        }
                        replacement = String(scalar)
                    } else if let declared = entities[name] {
                        // RE-SCAN the replacement. A declared entity's text is itself
                        // markup, so `<!ENTITY b "&a;&a;">` must resolve `a` — appending
                        // the raw text instead, which is what this did until 2026-08-14,
                        // yields the literal string "&a;&a;" and quietly gives the caller
                        // the wrong value.
                        //
                        // It also means the billion-laughs bound is now doing the work the
                        // file header always claimed it did. Before, a nested bomb was
                        // "safe" only because nothing expanded: 290 bytes in, 30 bytes out,
                        // and every one of them wrong. Now the expansion is real and the
                        // budget is what stops it.
                        guard !expanding.contains(name) else {
                            sink.add(Issue(code: .custom("xml_recursive_entity"),
                                           params: ["entity": .string(name)],
                                           received: "&\(name);"))
                            return nil
                        }
                        expanding.insert(name)
                        let resolved = expandEntities(declared, &r, &sink)
                        expanding.remove(name)
                        guard let resolved else { return nil }
                        replacement = resolved
                    } else {
                        // An undeclared entity is an error, never a silent pass-through.
                        // Silently emitting the raw text is how XXE mitigations get bypassed.
                        sink.add(Issue(code: .custom("xml_undeclared_entity"),
                                       params: ["entity": .string(name)],
                                       received: "&\(name);"))
                        return nil
                    }
                }

                // Billion laughs: bound total expansion, not nesting depth. Depth alone
                // does not stop `&a;` repeated ten thousand times. Charged at every level,
                // so a nested bomb pays for the work at each layer rather than only for the
                // bytes that survive to the top — which is the quantity that actually
                // explodes.
                expansionBudget -= replacement.utf8.count
                guard expansionBudget > 0 else {
                    sink.add(Issue(code: .custom("xml_entity_expansion_limit"),
                                   params: ["entity": .string(name)]))
                    return nil
                }
                out += replacement
            }
            out += rest
            return out
        }

        func numericCharacterReference(_ name: String) -> Unicode.Scalar? {
            var digits = Substring(name.dropFirst())      // drop '#'
            let radix: Int
            if digits.first == "x" || digits.first == "X" {
                digits = digits.dropFirst()
                radix = 16
            } else {
                radix = 10
            }
            guard let value = UInt32(digits, radix: radix),
                  let scalar = Unicode.Scalar(value) else { return nil }
            // XML 1.0 forbids most control characters even by reference.
            if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D {
                return nil
            }
            return scalar
        }

        // MARK: DOCTYPE

        /// Skip the DOCTYPE, harvesting only *internal* general entity declarations.
        ///
        /// `SYSTEM` and `PUBLIC` identifiers are recognised so they can be **refused**.
        /// Fetching them is XXE — the vulnerability class that made `accepting:` a
        /// required parameter in EXPERIENCE.md §12 — so this parser has no code path that
        /// could fetch one, by construction rather than by configuration.
        mutating func parseDoctype(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> Bool {
            _ = r.consume("<!DOCTYPE")
            var depth = 0
            var sawExternalID = false

            while let c = r.currentByte {
                if r.matches("SYSTEM") || r.matches("PUBLIC") { sawExternalID = true }
                if r.matches("<!ENTITY") {
                    parseEntityDeclaration(&r, &sink)
                    continue
                }
                if c == UInt8(ascii: "[") { depth += 1; r.advanceBy(1); continue }
                if c == UInt8(ascii: "]") { depth -= 1; r.advanceBy(1); continue }
                if c == UInt8(ascii: ">") && depth <= 0 {
                    r.advanceBy(1)
                    if sawExternalID {
                        // A warning, not an error: the document is still parseable, and
                        // the external declarations are simply not honoured.
                        sink.add(warning: Warning(
                            code: .custom("xml_external_dtd_ignored"),
                            params: ["reason": .string(
                                "external DTD subsets and entities are never fetched (XXE)")]))
                    }
                    return true
                }
                r.advanceBy(1)
            }
            r.report(&sink, .custom("xml_unterminated_doctype"))
            return false
        }

        mutating func parseEntityDeclaration(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) {
            _ = r.consume("<!ENTITY")
            skipSpace(&r)
            // Parameter entities (`%name;`) are not supported; skip the declaration.
            if r.currentByte == UInt8(ascii: "%") {
                _ = skipUntil(&r, ">", &sink)
                return
            }
            guard let name = scanName(&r) else {
                _ = skipUntil(&r, ">", &sink)
                return
            }
            skipSpace(&r)
            guard let quote = r.currentByte,
                  quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
                // No literal value means SYSTEM/PUBLIC — an external entity. Refused.
                sink.add(warning: Warning(
                    code: .custom("xml_external_entity_ignored"),
                    params: ["entity": .string(name)]))
                _ = skipUntil(&r, ">", &sink)
                return
            }
            r.advanceBy(1)
            let start = r.byteOffset
            while let c = r.currentByte, c != quote { r.advanceBy(1) }
            let value = r.string(from: start, to: r.byteOffset)
            r.advanceBy(1)
            entities[name] = value
            _ = skipUntil(&r, ">", &sink)
        }

        // MARK: Lexing

        func isNameStart(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == UInt8(ascii: "_") || c == UInt8(ascii: ":") || c >= 0x80
        }

        func isNameChar(_ c: UInt8) -> Bool {
            isNameStart(c) || (c >= 0x30 && c <= 0x39)
                || c == UInt8(ascii: "-") || c == UInt8(ascii: ".")
        }

        mutating func scanName(_ r: inout AssayReader) -> String? {
            guard let first = r.currentByte, isNameStart(first) else { return nil }
            let start = r.byteOffset
            while let c = r.currentByte, isNameChar(c) { r.advanceBy(1) }
            return r.string(from: start, to: r.byteOffset)
        }

        func skipSpace(_ r: inout AssayReader) {
            while let c = r.currentByte,
                  c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                r.advanceBy(1)
            }
        }

        mutating func skipUntil(
            _ r: inout AssayReader, _ terminator: StaticString, _ sink: inout IssueSink
        ) -> Bool {
            while !r.atEnd {
                if r.consume(terminator) { return true }
                r.advanceBy(1)
            }
            r.report(&sink, .malformedDocument)
            return false
        }
    }
}
