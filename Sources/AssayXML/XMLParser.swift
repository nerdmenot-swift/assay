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
    ) throws(AssayError) -> Document {
        var sink = IssueSink(limits: limits)
        guard let doc = decode(bytes, into: &sink, limits: limits), sink.isValid else {
            throw AssayError(issues: sink.issues, source: SourceBytes(bytes), sourceName: "<input>")
        }
        return doc
    }

    public static func parse(
        _ text: String,
        limits: Limits = .default
    ) throws(AssayError) -> Document {
        try parse(Array(text.utf8), limits: limits)
    }

    /// Non-throwing form.
    public static func decode(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> Document? {
        withDocument(bytes, into: &sink, limits: limits, as: XMLNodeBuilder.self)
    }

    /// Straight to `RawValue`, in ONE pass: no `XML.Element` tree is built only to be
    /// projected and dropped (`docs/EFFICIENCY.md` rows 12 and 17). This is what
    /// `parse(xml:)` uses, and it is public so that what it uses can be tested against
    /// `decode` + `RawValue(_:)`. The root's name travels alongside, because `@XML(root:)`
    /// is checked against it and a `RawValue` has nowhere to keep it.
    ///
    /// Lossy exactly as the projection is (`docs/VALUE-MODELS.md` §5): attributes and child
    /// elements share one keyspace, and comments, instructions and namespaces are dropped.
    public static func decodeRaw(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> (rootName: String, value: RawValue)? {
        guard
            let doc = withDocument(
                bytes, into: &sink, limits: limits,
                as: XMLRawBuilder.self)
        else { return nil }
        return (doc.rootName, doc.value)
    }

    /// Byte limit, UTF-8 validation, BOM, reader, parser: shared by both doors, so neither
    /// can grow a check the other lacks.
    static func withDocument<B: XMLBuilding>(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits,
        as builder: B.Type
    ) -> B.Output? {
        if bytes.count > limits.maxBytes {
            sink.add(
                Issue(
                    code: .tooManyBytes,
                    params: ["maxBytes": .int(limits.maxBytes)]))
            return nil
        }
        return unsafe bytes.withUnsafeBufferPointer { buf -> B.Output? in
            guard let base = buf.baseAddress else { return nil }
            // Same whole-buffer UTF-8 pass as the JSON path, for the same reason: it is
            // one linear pass, and it removes validation from every String built after.
            if let bad = unsafe UTF8Validation.firstInvalid(base, buf.count) {
                sink.add(
                    Issue(
                        code: .invalidUTF8, params: ["offset": .int(bad)],
                        location: SourceSpan(lo: bad, len: 1)))
                return nil
            }
            var reader = unsafe AssayReader(base: base, count: buf.count, limits: limits)
            reader.advance(by: unsafe UTF8Validation.bomLength(base, buf.count))
            var parser = Parser<B>(limits: limits, inputBytes: buf.count)
            return parser.parseDocument(&reader, &sink)
        }
    }
}

extension XML {

    /// The parser state. A struct, and never escaping, so it stays on the stack.
    /// Generic over what it builds: `XMLNodeBuilder` for the element tree,
    /// `XMLRawBuilder` for `RawValue` with no tree in between (`XMLBuilder.swift`).
    struct Parser<B: XMLBuilding> {

        /// Where the duplicate-attribute check stops scanning and starts hashing.
        ///
        /// Below this a linear scan over a contiguous array beats a `Set` and allocates
        /// nothing — the original reasoning, which holds. Above it the scan is quadratic.
        /// 16 is comfortably past "a handful"; the crossover is not sharp, and what
        /// matters is that one exists at all.
        static var attributeSetThreshold: Int { 16 }

        let limits: Limits
        /// Element child counts by depth, for `parseElement`'s reservation.
        var hints = _ShapeHints()
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
        ) -> B.Output? {
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
                r.report(&sink, .xmlNoRoot)
                return nil
            }
            guard let root = parseElement(&r, &sink, depth: 0) else { return nil }

            // Trailing content after the root: only whitespace, comments and PIs are legal.
            while true {
                skipSpace(&r)
                if r.isAtEnd { break }
                if r.matches("<!--") { _ = parseComment(&r, &sink); continue }
                if r.matches("<?") { _ = parseProcessingInstruction(&r, &sink); continue }
                r.report(&sink, .trailingContent)
                return nil
            }

            return B.document(root: root, prolog: prolog)
        }

        @inline(never)
        mutating func resolveAttributes(
            _ r: borrowing AssayReader, _ sink: inout IssueSink,
            _ rawAttributes: [(Range<Int>, String, SourceSpan, SourceSpan)],
            elementName: Range<Int>
        ) -> [XML.Attribute] {
            var attributes: [XML.Attribute] = []
            attributes.reserveCapacity(rawAttributes.count)
            // Duplicates are found by scanning what has been appended already, not with a
            // Set. Elements have a handful of attributes, where a linear scan over a
            // contiguous array beats hashing — and the Set was a heap allocation per
            // element for a check that almost never fires.
            //
            // THAT IS RIGHT FOR THE COMMON CASE AND WAS UNBOUNDED FOR THE HOSTILE ONE.
            // The scan is O(a²) in the attribute count, and `XML.Name ==` is a full
            // `String ==` on two fields, so one element with many attributes — legal XML,
            // depth 1, no entities — walks away with the parse. Measured 2026-09-13:
            //
            //     16,000 attrs   161 KB   0.165 s
            //     32,000 attrs   332 KB   0.663 s
            //     64,000 attrs   676 KB   2.651 s        4.0x per doubling
            //
            // Neither guard sees it: `maxDepth` is 1 here and the node budget counts
            // nodes, of which this is one. Same blind spot as the YAML merge key fixed the
            // same day — both bombs are WIDE, and both guards measure depth or count.
            //
            // So: keep the linear scan exactly where it was justified, and build the set
            // once the count passes the point where hashing wins. Below the threshold this
            // is byte-for-byte the old path, allocation included (none).
            var seen: Set<XML.Name>? = nil
            for (nameRange, v, span, valueSpan) in rawAttributes {
                let resolved = resolve(r, nameRange, isAttribute: true)
                if seen == nil, attributes.count == Self.attributeSetThreshold {
                    var s = Set<XML.Name>(minimumCapacity: rawAttributes.count)
                    for a in attributes { s.insert(a.name) }
                    seen = s
                }
                let duplicate: Bool
                if seen != nil {
                    duplicate = !seen!.insert(resolved).inserted
                } else {
                    duplicate = attributes.contains(where: { $0.name == resolved })
                }
                // Duplicate attributes are a well-formedness error in XML, unlike
                // duplicate child elements which are ordinary.
                if duplicate {
                    // Cold: build the reported name only when there is something to report.
                    let n = r.string(from: nameRange.lowerBound, to: nameRange.upperBound)
                    let e = r.string(from: elementName.lowerBound, to: elementName.upperBound)
                    sink.add(
                        Issue(
                            code: .duplicateKey,
                            path: [.key(e), .key(n)],
                            received: n, location: span))
                }
                attributes.append(
                    XML.Attribute(
                        name: resolved, value: v,
                        valueSpan: valueSpan))
            }

            return attributes
        }

        /// SHAPE MEMORY keyed by DEPTH AND SIBLING POSITION (`_ShapeHints`): how many children
        /// to reserve, from what the element in the same position of the previous record held.
        /// By depth alone the hint thrashed, because siblings of different shapes share a depth
        /// (four one-child leaves, then a ten-child `<tags>`), and a leaf's hint of 1 made
        /// `<tags>` grow 1 -> 2 -> 4 -> 8 -> 16 (array-10/xml +2,000 blocks per call,
        /// 2026-09-19). The i-th child of a repeated record keeps its shape. Positions past 31
        /// share a bucket, so the table stays at most 64 x 32. A position with no hint yet
        /// falls back to the DEPTH's hint, floored at 4 (the parser's old fixed reservation);
        /// without that the first 31 records each met a fresh bucket, +34 blocks per call.
        ///
        /// Out of line so the recursive frame does not grow: see `resolveAttributes`.
        @inline(never)
        func childReservation(depth: Int, position: Int) -> Int {
            let positional = hints.items(at: depth &* 32 &+ Swift.min(position, 31))
            return positional > 0 ? positional : Swift.max(hints.members(at: depth), 4)
        }

        /// Record a finished element's child count. The depth hint is read only for a fresh
        /// position, so it is written only then: at most 32 times per depth per document.
        /// Writing it for every element cost a retain, a release and two uniqueness checks per
        /// element (+3-5% instructions).
        @inline(never)
        mutating func recordChildren(_ n: Int, depth: Int, position: Int) {
            let key = depth &* 32 &+ Swift.min(position, 31)
            if hints.items(at: key) == 0 { hints.setMembers(n, at: depth) }
            hints.setItems(Swift.max(n, 1), at: key)
        }

        // MARK: Elements

        mutating func parseElement(
            _ r: inout AssayReader,
            _ sink: inout IssueSink,
            depth: Int,
            /// Which element child of its parent this is, for the shape-memory key.
            position: Int = 0
        ) -> B.Value? {
            guard depth < limits.maxDepth else {
                r.report(&sink, .depthExceeded, params: ["maxDepth": .int(limits.maxDepth)])
                return nil
            }
            // NO `guard r.consume("<")` HERE, and that is deliberate. Both call sites
            // (the root, above, and the child loop below) already establish that the
            // current byte is `<` before calling, so the guard could not fail — and a
            // check that cannot fail reads exactly like a check that passed. It was
            // removed on 2026-09-13 along with its `xml_expected_element` code, which
            // `IssueCodeCoverageTests` had listed as unprovokable for that reason.
            r.advance(by: 1)

            let nameStart = r.byteOffset
            guard let nameRange = scanNameRange(&r) else {
                r.report(&sink, .xmlBadName)
                return nil
            }
            // The element's name as written is NOT built as a String here: it is needed only
            // by error paths, which build it from `nameRange`, and the close tag is checked
            // against it byte for byte. Building it (and the close tag's name) cost two String
            // constructions and releases per element on every clean parse.
            let nameLength = nameRange.count

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

            var name = resolve(r, nameRange, isAttribute: false)
            // Resolved OUT OF LINE too, for the same stack reason as `scanAttributes`: the
            // loop's tuples, set and issue construction were in this recursive frame, and a
            // debug build at the default maxDepth of 64 had only a few levels of headroom on a
            // 512 KB thread (Swift Testing's worker stack). Measured 2026-09-19.
            var attributes = resolveAttributes(r, &sink, rawAttributes, elementName: nameRange)

            // Empty element: <tag/>. There is no content to underline, so the caret goes
            // under the tag name — the only thing in the document that exists.
            if r.consume("/>") {
                return B.emptyElement(
                    name: consume name, attributes: consume attributes,
                    contentSpan: SourceSpan(
                        lo: nameStart,
                        len: nameLength))
            }
            guard r.consume(">") else {
                r.report(&sink, .xmlUnterminatedTag)
                return nil
            }
            // Everything between `>` and the matching `</` is this element's content, and
            // that is what a schema issue about this element is about.
            let contentStart = r.byteOffset

            // ONE accumulator, not a handful of locals: this function recurses, so what it
            // holds is multiplied by depth (see this file's `scanAttributes` note).
            var children = B.makeChildren(
                name: &name, attributes: &attributes,
                reserving: childReservation(depth: depth, position: position))
            var elementChildren = 0
            var contentEnd = contentStart

            while true {
                guard !r.isAtEnd else {
                    let rawName = r.string(from: nameRange.lowerBound, to: nameRange.upperBound)
                    sink.add(
                        Issue(
                            code: .xmlUnclosedElement,
                            path: [.key(rawName)],
                            received: rawName,
                            location: SourceSpan(lo: nameStart, len: nameLength)))
                    return nil
                }

                // Markup dispatches on the byte after `<`: a child element, the common case,
                // used to fail four `matches` (`</`, `<!--`, `<![CDATA[`, `<?`) first.
                // `if`s, not a `switch`, so the close tag's `break` still leaves the loop.
                if r.currentByte == UInt8(ascii: "<") {
                    let next = r.byte(at: 1)
                    if next == UInt8(ascii: "/") {
                        contentEnd = r.byteOffset
                        _ = r.consume("</")
                        guard let closeRange = scanNameRange(&r) else {
                            r.report(&sink, .xmlBadName)
                            return nil
                        }
                        skipSpace(&r)
                        guard r.consume(">") else {
                            r.report(&sink, .xmlUnterminatedTag)
                            return nil
                        }
                        guard sameBytes(r, closeRange, nameRange) else {
                            let rawName = r.string(
                                from: nameRange.lowerBound, to: nameRange.upperBound)
                            let close = r.string(
                                from: closeRange.lowerBound, to: closeRange.upperBound)
                            sink.add(
                                Issue(
                                    code: .xmlMismatchedTag,
                                    path: [.key(rawName)],
                                    params: ["expected": .string(rawName), "found": .string(close)],
                                    received: close,
                                    location: SourceSpan(lo: nameStart, len: nameLength)))
                            return nil
                        }
                        break
                    }

                    if next == UInt8(ascii: "!") {
                        if r.matches("<!--") {
                            guard let text = parseCommentText(&r, &sink) else { return nil }
                            B.appendComment(&children, text)
                            continue
                        }
                        if r.matches("<![CDATA[") {
                            guard let text = parseCDATAText(&r, &sink) else { return nil }
                            B.appendText(&children, text, isCDATA: true)
                            continue
                        }
                    }
                    if next == UInt8(ascii: "?") {
                        guard let pi = parseInstructionParts(&r, &sink) else { return nil }
                        B.appendInstruction(&children, target: pi.target, data: pi.data)
                        continue
                    }
                    guard
                        let child = parseElement(
                            &r, &sink, depth: depth + 1,
                            position: elementChildren)
                    else {
                        return nil
                    }
                    B.appendElement(&children, child)
                    elementChildren &+= 1
                    continue
                }

                guard let text = parseText(&r, &sink) else { return nil }
                if !text.isEmpty { B.appendText(&children, text, isCDATA: false) }
            }

            recordChildren(B.childCount(children), depth: depth, position: position)
            // `consume`: MOVE the accumulator into the finished element. Passing it without
            // this copied the whole thing — three retains per element (count.py explain), the
            // same trap `docs/EFFICIENCY.md` rows 14 and 16 record.
            return B.finish(
                consume children, name: consume name,
                attributes: consume attributes,
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
                    r.report(&sink, .xmlUnterminatedTag)
                    return false
                }
                if c == UInt8(ascii: ">") || c == UInt8(ascii: "/") { return true }

                let attrStart = r.byteOffset
                guard let aRange = scanNameRange(&r) else {
                    r.report(&sink, .xmlBadAttributeName)
                    return false
                }
                skipSpace(&r)
                guard r.consume("=") else {
                    r.report(&sink, .xmlExpectedEquals)
                    return false
                }
                skipSpace(&r)
                let valueStart = r.byteOffset
                guard let aValue = parseAttributeValue(&r, &sink) else { return false }
                // Inside the quotes, which is what a caret should underline.
                let valueSpan = SourceSpan(
                    lo: valueStart + 1,
                    len: max(0, r.byteOffset - valueStart - 2))

                if bytes(r, aRange, equal: "xmlns") {
                    scope[""] = aValue
                } else if bytes(r, aRange, hasPrefix: "xmlns:") {
                    scope[r.string(from: aRange.lowerBound + 6, to: aRange.upperBound)] = aValue
                } else {
                    rawAttributes.append(
                        (
                            aRange, aValue,
                            SourceSpan(lo: attrStart, len: r.byteOffset - attrStart),
                            valueSpan
                        ))
                }
            }
        }

        /// A name's byte RANGE, without building a `String` for it.
        mutating func scanNameRange(_ r: inout AssayReader) -> Range<Int>? {
            guard let first = r.currentByte, isNameStart(first) else { return nil }
            let start = r.byteOffset
            while let c = r.currentByte, isNameChar(c) { r.advance(by: 1) }
            return start..<r.byteOffset
        }

        /// Whether the bytes in `range` are exactly `literal`.
        @inline(never)
        func bytes(
            _ r: borrowing AssayReader, _ range: Range<Int>,
            equal literal: StaticString
        ) -> Bool {
            let n = literal.utf8CodeUnitCount
            guard range.count == n else { return false }
            return bytesMatch(r, range.lowerBound, literal, n)
        }

        /// Whether the bytes in `range` begin with `literal`.
        @inline(never)
        func bytes(
            _ r: borrowing AssayReader, _ range: Range<Int>,
            hasPrefix literal: StaticString
        ) -> Bool {
            let n = literal.utf8CodeUnitCount
            guard range.count >= n else { return false }
            return bytesMatch(r, range.lowerBound, literal, n)
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
        /// Split a possibly-prefixed name and attach its namespace.
        ///
        /// **The colon is found in the SOURCE BYTES, not in the String.** Both
        /// `String.firstIndex` and `String.utf8.firstIndex` walk a view with a
        /// representation check per byte — the first is grapheme-based and was half of all
        /// parse time, and the second, which replaced it, still measured 236 samples and
        /// was the third largest cost in the parser. Reading `r.byte(absolute:)` over a
        /// range already in hand is the same number of byte comparisons through a plain
        /// bounds-checked load, and it builds no intermediate String for the unprefixed
        /// case — which is nearly every name.
        ///
        /// Third time on this one function. `String`'s convenient spellings are convenient.
        func resolve(
            _ r: borrowing AssayReader, _ range: Range<Int>, isAttribute: Bool
        ) -> XML.Name {
            var colonAt = -1
            for i in range where r.byte(absolute: i) == UInt8(ascii: ":") {
                colonAt = i
                break
            }
            guard colonAt >= 0 else {
                let whole = r.string(from: range.lowerBound, to: range.upperBound)
                if isAttribute { return XML.Name(whole) }
                return XML.Name(whole, namespaceURI: lookup(""))
            }
            let prefix = r.string(from: range.lowerBound, to: colonAt)
            let local = r.string(from: colonAt + 1, to: range.upperBound)
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
                default: out.append(b)
                }
                previousWasCR = false
            }
            return String(decoding: out, as: UTF8.self)
        }

        // MARK: Leaves

        /// The node form, for the prolog and trailing content, where a `Node` is what the
        /// document keeps. An element's children go through the builder instead.
        mutating func parseComment(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> XML.Node? {
            parseCommentText(&r, &sink).map { .comment($0) }
        }

        mutating func parseCommentText(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> String? {
            _ = r.consume("<!--")
            let start = r.byteOffset
            while !r.isAtEnd {
                if r.matches("-->") {
                    let text = r.string(from: start, to: r.byteOffset)
                    _ = r.consume("-->")
                    return normalizeLineEndings(text)
                }
                r.advance(by: 1)
            }
            r.report(&sink, .xmlUnterminatedComment)
            return nil
        }

        mutating func parseCDATAText(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> String? {
            _ = r.consume("<![CDATA[")
            let start = r.byteOffset
            while !r.isAtEnd {
                if r.matches("]]>") {
                    let text = r.string(from: start, to: r.byteOffset)
                    _ = r.consume("]]>")
                    return normalizeLineEndings(text)
                }
                r.advance(by: 1)
            }
            r.report(&sink, .xmlUnterminatedCdata)
            return nil
        }

        /// The node form, for the prolog and trailing content.
        mutating func parseProcessingInstruction(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> XML.Node? {
            guard let parts = parseInstructionParts(&r, &sink) else { return nil }
            return .processingInstruction(target: parts.target, data: parts.data)
        }

        mutating func parseInstructionParts(
            _ r: inout AssayReader, _ sink: inout IssueSink
        ) -> (target: String, data: String)? {
            _ = r.consume("<?")
            guard let target = scanName(&r) else {
                r.report(&sink, .xmlBadPiTarget)
                return nil
            }
            skipSpace(&r)
            let start = r.byteOffset
            while !r.isAtEnd {
                if r.matches("?>") {
                    let data = r.string(from: start, to: r.byteOffset)
                    _ = r.consume("?>")
                    return (target, normalizeLineEndings(data))
                }
                r.advance(by: 1)
            }
            r.report(&sink, .xmlUnterminatedPi)
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
                if c == UInt8(ascii: "&") { sawEntity = true } else if c == 0x0D { sawCR = true }
                r.advance(by: 1)
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
                quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'")
            else {
                r.report(&sink, .xmlUnquotedAttribute)
                return nil
            }
            r.advance(by: 1)
            let start = r.byteOffset
            var sawEntity = false
            var sawWhitespace = false
            while let c = r.currentByte, c != quote {
                if c == UInt8(ascii: "&") {
                    sawEntity = true
                } else if c == 0x0D || c == 0x0A || c == 0x09 {
                    sawWhitespace = true
                } else if c == UInt8(ascii: "<") {
                    r.report(&sink, .xmlRawLtInAttribute)
                    return nil
                }
                r.advance(by: 1)
            }
            guard r.currentByte == quote else {
                r.report(&sink, .xmlUnterminatedAttribute)
                return nil
            }
            // Same one-pass rule as parseText: the loop above already saw every byte.
            let slice = r.string(from: start, to: r.byteOffset)
            let raw = sawWhitespace ? normalizeAttributeWhitespace(slice) : slice
            r.advance(by: 1)
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
                    r.report(&sink, .xmlUnterminatedEntity)
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
                            sink.add(
                                Issue(
                                    code: .xmlBadCharacterReference,
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
                            sink.add(
                                Issue(
                                    code: .xmlRecursiveEntity,
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
                        sink.add(
                            Issue(
                                code: .xmlUndeclaredEntity,
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
                    sink.add(
                        Issue(
                            code: .xmlEntityExpansionLimit,
                            params: ["entity": .string(name)]))
                    return nil
                }
                out += replacement
            }
            out += rest
            return out
        }

        func numericCharacterReference(_ name: String) -> Unicode.Scalar? {
            var digits = Substring(name.dropFirst())  // drop '#'
            let radix: Int
            if digits.first == "x" || digits.first == "X" {
                digits = digits.dropFirst()
                radix = 16
            } else {
                radix = 10
            }
            guard let value = UInt32(digits, radix: radix),
                let scalar = Unicode.Scalar(value)
            else { return nil }
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
                if c == UInt8(ascii: "[") { depth += 1; r.advance(by: 1); continue }
                if c == UInt8(ascii: "]") { depth -= 1; r.advance(by: 1); continue }
                if c == UInt8(ascii: ">") && depth <= 0 {
                    r.advance(by: 1)
                    if sawExternalID {
                        // A warning, not an error: the document is still parseable, and
                        // the external declarations are simply not honoured.
                        sink.add(
                            warning: Warning(
                                code: .xmlExternalDtdIgnored,
                                params: [
                                    "reason": .string(
                                        "external DTD subsets and entities are never fetched (XXE)")
                                ]))
                    }
                    return true
                }
                r.advance(by: 1)
            }
            r.report(&sink, .xmlUnterminatedDoctype)
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
                quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'")
            else {
                // No literal value means SYSTEM/PUBLIC — an external entity. Refused.
                sink.add(
                    warning: Warning(
                        code: .xmlExternalEntityIgnored,
                        params: ["entity": .string(name)]))
                _ = skipUntil(&r, ">", &sink)
                return
            }
            r.advance(by: 1)
            let start = r.byteOffset
            while let c = r.currentByte, c != quote { r.advance(by: 1) }
            let value = r.string(from: start, to: r.byteOffset)
            r.advance(by: 1)
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

        /// Whether two ranges of the document hold the same bytes: a close tag against its
        /// open tag, without building either name. Bytes, not `String ==`, which would also
        /// accept a canonically-equivalent spelling; XML 1.0 §3 requires the end tag's Name
        /// to MATCH the start tag's, and libxml2 compares bytes.
        func sameBytes(_ r: borrowing AssayReader, _ a: Range<Int>, _ b: Range<Int>) -> Bool {
            guard a.count == b.count else { return false }
            var i = 0
            while i < a.count {
                if r.byte(absolute: a.lowerBound &+ i) != r.byte(absolute: b.lowerBound &+ i) {
                    return false
                }
                i &+= 1
            }
            return true
        }

        mutating func scanName(_ r: inout AssayReader) -> String? {
            guard let first = r.currentByte, isNameStart(first) else { return nil }
            let start = r.byteOffset
            while let c = r.currentByte, isNameChar(c) { r.advance(by: 1) }
            return r.string(from: start, to: r.byteOffset)
        }

        func skipSpace(_ r: inout AssayReader) {
            while let c = r.currentByte,
                c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
            {
                r.advance(by: 1)
            }
        }

        mutating func skipUntil(
            _ r: inout AssayReader, _ terminator: StaticString, _ sink: inout IssueSink
        ) -> Bool {
            while !r.isAtEnd {
                if r.consume(terminator) { return true }
                r.advance(by: 1)
            }
            r.report(&sink, .malformedDocument)
            return false
        }
    }
}
