// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// XML.Node — the full-fidelity XML model. docs/VALUE-MODELS.md §4.
//
// NAMING. The obvious spellings are unavailable: `XMLNode`, `XMLElement` and
// `XMLDocument` are all taken by Foundation (macOS and Mac Catalyst only — see
// cross-platform-audit.md §4). On macOS, `import Foundation` plus `import AssayXML` would
// make every one ambiguous. This is precisely the case EXPERIENCE.md §0 already ruled on
// when it chose `Assayer<T>` over `Schema<T>` because SwiftData exports a `Schema`. Same
// rule, same answer: namespace them. `XML.Element` and `Foundation.XMLElement` are
// different identifiers, so the ambiguity never arises.
//
// SHAPE. XML has neither an object nor an array, and modelling it with JSON vocabulary is
// the transplant error the design note rejects. What it has:
//
//   * elements, with a name, ordered attributes, and ordered children;
//   * character data, CDATA, comments and processing instructions as siblings;
//   * namespaces on names;
//   * **duplicate sibling names as the ordinary case**, not an exception.
//
// `children: [Node]` is the whole point. Mixed content (`<p>Hello <b>x</b>!</p>`) is
// ordinary here rather than a special case, repeated sibling names are natural, and
// attribute-versus-element is a *type* distinction rather than a tag on a key. That last
// one is what makes EXPERIENCE.md §14's promise — placement data preserved so the encoder
// stays additive — structurally true rather than aspirational.
//
// EVERYTHING IN XML IS TEXT. There is no number and no boolean. So a leaf is always a
// `String`, and coercion stays the schema's visible job via `@Coerce` — never implicit,
// per EXPERIENCE.md §7.
//
// THE PARSER IS `XMLParser.swift`, hand-written, and the reason it is hand-written is worth
// keeping: cross-platform-audit.md §4 concluded Foundation's `XMLParser` cannot back this
// model, because its lineNumber/columnNumber are valid only during delegate callbacks and
// carry no byte ranges, so it cannot produce the carets §3 promises. The prescription was a
// hand-written scanner; that is what shipped, and it has since been optimised 1.89× (see
// `Benchmarks/RESULTS.md`).
//===----------------------------------------------------------------------===//

public import AssayCore

/// Namespace. Caseless, so it cannot be instantiated.
public enum XML {}

extension XML {

    /// A qualified name.
    ///
    /// The **prefix is deliberately not stored**: it is presentation, and two documents
    /// using `ns:` and `dc:` for the same URI should compare equal, which is the behaviour
    /// anyone actually wants. Resolution from prefix to URI happens during the parse.
    public struct Name: Sendable, Hashable, ExpressibleByStringLiteral {
        public var local: String
        public var namespaceURI: String?

        public init(_ local: String, namespaceURI: String? = nil) {
            self.local = local
            self.namespaceURI = namespaceURI
        }

        public init(stringLiteral value: String) {
            self.init(value)
        }
    }

    public struct Attribute: Sendable, Hashable {
        public var name: Name
        public var value: String

        /// Where the attribute's VALUE sits in the source, for carets. Excluded from `==`
        /// and `hash`: a span is provenance, not value.
        public var valueSpan: SourceSpan?

        public init(name: Name, value: String, valueSpan: SourceSpan? = nil) {
            self.name = name
            self.value = value
            self.valueSpan = valueSpan
        }

        public init(_ name: String, _ value: String) {
            self.init(name: Name(name), value: value)
        }

        public static func == (a: Attribute, b: Attribute) -> Bool {
            a.name == b.name && a.value == b.value
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(value)
        }
    }

    public struct Element: Sendable, Hashable {
        public var name: Name
        /// Ordered. XML attribute order is not semantically significant, but preserving it
        /// costs nothing and a reordered diff is still a diff.
        public var attributes: [Attribute]
        /// Ordered, and this ordering *is* significant.
        public var children: [Node]

        /// Where this element's CONTENT sits — between `>` and `</`, or the whole tag for
        /// an empty element. That is what a caret should underline when a field decoded
        /// from `<port>notanumber</port>` fails: the text, not the markup around it.
        ///
        /// Excluded from `==` and `hash`, for the same reason as everywhere else: two
        /// documents differing only in layout must stay equal.
        public var contentSpan: SourceSpan?

        public init(name: Name, attributes: [Attribute] = [], children: [Node] = [],
                    contentSpan: SourceSpan? = nil) {
            self.name = name
            self.attributes = attributes
            self.children = children
            self.contentSpan = contentSpan
        }

        public static func == (a: Element, b: Element) -> Bool {
            a.name == b.name && a.attributes == b.attributes && a.children == b.children
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(attributes)
            hasher.combine(children)
        }

        public init(_ name: String, attributes: [Attribute] = [], children: [Node] = []) {
            self.init(name: Name(name), attributes: attributes, children: children)
        }
    }

    /// Anything that can appear as a child.
    ///
    /// No `indirect`: `Element.children` is an `Array`, which provides the indirection.
    public enum Node: Sendable, Hashable {
        case element(Element)
        case text(String)
        case cdata(String)
        case comment(String)
        case processingInstruction(target: String, data: String)
    }

    /// A parsed document. Named `Document`, not `XMLDocument`, for the reason in the
    /// file header.
    public struct Document: Sendable, Hashable {
        public var root: Element
        /// Comments and processing instructions before the root element.
        public var prolog: [Node]

        public init(root: Element, prolog: [Node] = []) {
            self.root = root
            self.prolog = prolog
        }
    }
}

// MARK: - Accessors

extension XML.Node {
    public var element: XML.Element? {
        if case .element(let e) = self { return e }
        return nil
    }

    /// Character data only. CDATA counts; comments and PIs do not.
    public var text: String? {
        switch self {
        case .text(let s), .cdata(let s): return s
        default: return nil
        }
    }
}

extension XML.Element {

    /// Attribute value by local name, ignoring namespace.
    public subscript(attribute name: String) -> String? {
        for a in attributes where a.name.local == name { return a.value }
        return nil
    }

    public subscript(attribute name: XML.Name) -> String? {
        for a in attributes where a.name == name { return a.value }
        return nil
    }

    /// Child elements with this local name, in document order. Returns an array rather
    /// than an optional because repetition is the *ordinary* case in XML — a singular
    /// accessor would be the wrong default and would quietly hide the second one.
    public func elements(named name: String) -> [XML.Element] {
        children.compactMap { child in
            guard case .element(let e) = child, e.name.local == name else { return nil }
            return e
        }
    }

    /// Whether any child is an element, without building the array `childElements` would.
    ///
    /// A leaf test is the hottest question asked of an element, and `childElements` answers
    /// it by allocating a `[XML.Element]` and retaining every child's buffers.
    public var hasChildElements: Bool {
        for c in children { if case .element = c { return true } }
        return false
    }

    public var childElements: [XML.Element] {
        children.compactMap(\.element)
    }

    /// First child element with this local name.
    public subscript(_ name: String) -> XML.Element? {
        for child in children {
            if case .element(let e) = child, e.name.local == name { return e }
        }
        return nil
    }

    /// All character data in this element's direct children, concatenated. CDATA included,
    /// comments and PIs excluded.
    ///
    /// This is the accessor most callers want and it is *lossy on purpose*: for mixed
    /// content it discards the interleaved elements. Walk `children` when that matters.
    public var text: String {
        var out = ""
        for child in children {
            if let t = child.text { out += t }
        }
        return out
    }

    /// True when this element has both character data and child elements, i.e. the case
    /// `text` silently flattens.
    public var hasMixedContent: Bool {
        var sawText = false
        var sawElement = false
        for child in children {
            switch child {
            case .text(let s), .cdata(let s):
                if !s.allSatisfy(\.isWhitespace) { sawText = true }
            case .element: sawElement = true
            default: break
            }
        }
        return sawText && sawElement
    }
}

// MARK: - Projection to RawValue
//
// **The lossiest of the three** (docs/VALUE-MODELS.md §5):
//   * every scalar becomes `.string` — XML has no number or boolean type;
//   * attributes and child elements flatten into one keyspace, so the distinction that
//     `@XML(.attribute)` exists to express is gone;
//   * comments, processing instructions, namespaces and mixed-content interleaving are
//     dropped.
//
// A caller who needs any of that declares `[String: XML.Node]` instead and keeps fidelity
// at the cost of format neutrality. That trade is the entire point of having both types.

extension RawValue {

    public init(_ element: XML.Element) {
        // THE LEAF TEST COMES FIRST. It used to come last — after `members` had been built
        // and after this initialiser had RECURSED into every child — and then discarded all
        // of it. It also asked `element.childElements.isEmpty`, and `childElements` is
        // `children.compactMap(\.element)`: a whole new array, retaining each child's
        // attributes and children buffers, to answer a yes/no question.
        //
        // Every XML and XML-plist decode paid this, and leaves are most of a document.
        // Measured 2026-09-13 over 100,000 leaf elements: hoisting the test took the
        // projection from 0.0123 s to 0.0030 s — the projection had been costing more than
        // the parse that produced it.
        if element.attributes.isEmpty, !element.hasChildElements {
            self = .string(element.text)
            return
        }

        var members: [Member] = []
        members.reserveCapacity(element.attributes.count + element.children.count)

        // Attributes first, then children, both in document order. Duplicates are kept —
        // `<tag/><tag/>` is ordinary XML and a Dictionary would silently drop one.
        for a in element.attributes {
            members.append(.init(key: a.name.local, value: .string(a.value),
                                 span: a.valueSpan))
        }

        for child in element.children {
            switch child {
            case .element(let e):
                members.append(.init(key: e.name.local, value: RawValue(e),
                                     span: e.contentSpan))
            case .text(let s), .cdata(let s):
                // Character data has no key. Whitespace-only runs between elements are
                // formatting, not data, and are dropped; anything else is preserved under
                // a reserved key so it is not silently lost.
                if !s.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
                    members.append(.init(key: "", value: .string(s)))
                }
            case .comment, .processingInstruction:
                break
            }
        }

        self = .mapping(members)
    }

    public init(_ document: XML.Document) {
        self.init(document.root)
    }

    /// The same projection, taking the document by value and MOVING its strings into the
    /// result. The struct-decode doors parse, project and drop; borrowing copied every
    /// child out of `children` (the copy retains its name, attributes and children), and
    /// the tree then released all of it. `docs/EFFICIENCY.md` row 14 is the same change
    /// for YAML and TOML, with the traps it found.
    @usableFromInline
    init(consuming document: consuming XML.Document) {
        var root = XML.Element(name: XML.Name(""))
        swap(&root, &document.root)
        self.init(consuming: consume root)
    }

    @usableFromInline
    init(consuming element: consuming XML.Element) {
        var attributes: [XML.Attribute] = []
        swap(&attributes, &element.attributes)
        var children: [XML.Node] = []
        swap(&children, &element.children)

        // The leaf test first, as in the borrowing form. One text child, the ordinary
        // leaf, moves out whole; anything else concatenates as `text` does.
        if attributes.isEmpty, !children.contains(where: { if case .element = $0 { true } else { false } }) {
            if children.count == 1 {
                switch children.removeLast() {
                case .text(let s), .cdata(let s): self = .string(s)
                default: self = .string("")
                }
                return
            }
            var text = ""
            for c in children {
                switch c {
                case .text(let s), .cdata(let s): text += s
                default: break
                }
            }
            self = .string(text)
            return
        }

        // Written straight into the result's storage: `append` inside these closures
        // re-checked uniqueness per member. Capacity is exact or over by the whitespace
        // runs that are dropped; `count` says how many were written.
        let capacity = attributes.count + children.count
        let members = unsafe children.withUnsafeMutableBufferPointer { kids in
                unsafe [Member](unsafeUninitializedCapacity: capacity) { dst, count in
                    // Skipped when empty, which is most elements: mutable access to the
                    // empty-array singleton goes through the make-unique path every time.
                    if !attributes.isEmpty {
                        unsafe attributes.withUnsafeMutableBufferPointer { attrs in
                            for i in attrs.indices {
                                var key = ""
                                unsafe swap(&key, &attrs[i].name.local)
                                var value = ""
                                unsafe swap(&value, &attrs[i].value)
                                unsafe (dst.baseAddress! + count).initialize(
                                    to: .init(key: consume key, value: .string(consume value),
                                              span: attrs[i].valueSpan))
                                count += 1
                            }
                        }
                    }
                    for i in kids.indices {
                        var child = XML.Node.text("")
                        unsafe swap(&child, &kids[i])
                        // Bound OUTSIDE the switch: a switch subject lives to the end of
                        // the case body, and an element still shared with it would copy
                        // its arrays on the first mutation, and so would every element
                        // under it.
                        var element: XML.Element? = nil
                        var text: String? = nil
                        switch consume child {
                        case .element(let e): element = e
                        case .text(let s), .cdata(let s): text = s
                        case .comment, .processingInstruction: break
                        }
                        if var e = element.take() {
                            var key = ""
                            swap(&key, &e.name.local)
                            let span = e.contentSpan
                            unsafe (dst.baseAddress! + count).initialize(
                                to: .init(key: consume key,
                                          value: RawValue(consuming: consume e), span: span))
                            count += 1
                        } else if let s = text.take(), !s.utf8.allSatisfy({
                            $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D
                        }) {
                            unsafe (dst.baseAddress! + count).initialize(
                                to: .init(key: "", value: .string(s)))
                            count += 1
                        }
                    }
                }
        }

        self = .mapping(members)
    }
}
