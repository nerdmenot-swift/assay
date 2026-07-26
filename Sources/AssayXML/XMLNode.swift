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
// NOTE: no parser yet. AssayXML currently vends the model only. cross-platform-audit.md
// §4 already concluded `XMLParser` cannot back this (its lineNumber/columnNumber are valid
// only during delegate callbacks, with no byte ranges, so it cannot produce the carets
// §3 promises) — a hand-written scanner or a vendored pure-Swift parser is required.
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

        public init(name: Name, value: String) {
            self.name = name
            self.value = value
        }

        public init(_ name: String, _ value: String) {
            self.init(name: Name(name), value: value)
        }
    }

    public struct Element: Sendable, Hashable {
        public var name: Name
        /// Ordered. XML attribute order is not semantically significant, but preserving it
        /// costs nothing and a reordered diff is still a diff.
        public var attributes: [Attribute]
        /// Ordered, and this ordering *is* significant.
        public var children: [Node]

        public init(name: Name, attributes: [Attribute] = [], children: [Node] = []) {
            self.name = name
            self.attributes = attributes
            self.children = children
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
        var members: [Member] = []

        // Attributes first, then children, both in document order. Duplicates are kept —
        // `<tag/><tag/>` is ordinary XML and a Dictionary would silently drop one.
        for a in element.attributes {
            members.append(.init(key: a.name.local, value: .string(a.value)))
        }

        for child in element.children {
            switch child {
            case .element(let e):
                members.append(.init(key: e.name.local, value: RawValue(e)))
            case .text(let s), .cdata(let s):
                // Character data has no key. Whitespace-only runs between elements are
                // formatting, not data, and are dropped; anything else is preserved under
                // a reserved key so it is not silently lost.
                if !s.allSatisfy(\.isWhitespace) {
                    members.append(.init(key: "", value: .string(s)))
                }
            case .comment, .processingInstruction:
                break
            }
        }

        // A leaf element — no attributes, no child elements — projects to its text
        // directly, so `<port>8080</port>` becomes `.string("8080")` rather than a
        // single-member mapping. Note `.string`, not `.int`: coercion is `@Coerce`'s job.
        if element.attributes.isEmpty && element.childElements.isEmpty {
            self = .string(element.text)
            return
        }

        self = .mapping(members)
    }

    public init(_ document: XML.Document) {
        self.init(document.root)
    }
}
