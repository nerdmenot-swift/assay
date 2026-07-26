//===----------------------------------------------------------------------===//
// YAML.Node — the full-fidelity YAML model. docs/VALUE-MODELS.md §4.
//
// This is the model that killed the unified-RawValue design, and it is worth being precise
// about why. **YAML permits any node as a mapping key.** `{[1, 2]: x}` and
// `{? {a: b} : c}` are legal. A `[String: RawValue]`-shaped model cannot represent them,
// so a unified type would have had to *reject valid documents* — which is a design
// failure, not a narrowing.
//
// Three things this model keeps that a JSON-shaped one throws away:
//
//   * **Non-string keys**, so no valid document is unrepresentable.
//   * **Tags** (`!!int`, `!Foo`). These are data. Dropping them with a warning, as the
//     unified draft did, loses information the document explicitly carried.
//   * **Scalar style** (plain / quoted / literal / folded). Presentation, yes — but the
//     deferred encoder in EXPERIENCE.md §14 needs it, because rewriting a literal block as
//     a double-quoted scalar is technically equivalent and practically a diff nobody wants.
//
// Scalar content stays **unresolved text** with the tag alongside, so resolution is the
// consumer's decision. That is also how this sidesteps the Norway problem — `NO` is
// `.scalar(content: "NO", tag: nil)` here, and whether that means `false` is a question
// answered by the schema, not silently by the parser.
//
// NOTE: no parser yet. AssayYAML currently vends the model only; `parse(yaml:)` lands with
// the scanner. The type is built first deliberately — docs/VALUE-MODELS.md §2 makes the
// point that the model has to be right before the parser is written against it.
//===----------------------------------------------------------------------===//

public import AssayCore

/// Namespace. Caseless, so it cannot be instantiated.
public enum YAML {}

extension YAML {

    /// How a scalar was written. Presentation rather than data, retained for round-tripping.
    public enum ScalarStyle: Sendable, Hashable {
        case plain           // key: value
        case singleQuoted    // key: 'value'
        case doubleQuoted    // key: "value"
        case literal         // key: |
        case folded          // key: >
    }

    /// A leaf. Content is the **unresolved** text: resolution to int/bool/null is the
    /// consumer's call, informed by `tag`.
    public struct Scalar: Sendable, Hashable {
        public var content: String
        public var style: ScalarStyle
        /// `!!int`, `!!str`, `!Foo`. Nil means "resolve by the core schema".
        public var tag: String?
        /// The `&name` this node was anchored with, if any. Retained for encoding.
        public var anchor: String?

        public init(
            content: String,
            style: ScalarStyle = .plain,
            tag: String? = nil,
            anchor: String? = nil
        ) {
            self.content = content
            self.style = style
            self.tag = tag
            self.anchor = anchor
        }
    }

    /// One mapping entry. Both sides are `Node`, which is the whole point.
    public struct Pair: Sendable, Hashable {
        public var key: Node
        public var value: Node

        public init(key: Node, value: Node) {
            self.key = key
            self.value = value
        }
    }

    /// A YAML node.
    ///
    /// No `indirect`: recursion runs through `Array`, which already provides the
    /// indirection, so a scalar is stored inline rather than boxed.
    public enum Node: Sendable, Hashable {
        case scalar(Scalar)
        case sequence([Node])
        case mapping([Pair])
    }
}

// MARK: - Accessors

extension YAML.Node {

    public var scalar: YAML.Scalar? {
        if case .scalar(let s) = self { return s }
        return nil
    }

    /// The raw text of a scalar, unresolved.
    public var content: String? { scalar?.content }

    public var sequence: [YAML.Node]? {
        if case .sequence(let xs) = self { return xs }
        return nil
    }

    public var mapping: [YAML.Pair]? {
        if case .mapping(let p) = self { return p }
        return nil
    }

    /// Lookup by a plain string key — the overwhelmingly common case, without forcing the
    /// caller to construct a `Node` to index with.
    public subscript(_ key: String) -> YAML.Node? {
        guard case .mapping(let pairs) = self else { return nil }
        for p in pairs {
            if case .scalar(let s) = p.key, s.content == key { return p.value }
        }
        return nil
    }

    /// Lookup by an arbitrary node key, for the documents that need it.
    public subscript(node key: YAML.Node) -> YAML.Node? {
        guard case .mapping(let pairs) = self else { return nil }
        for p in pairs where p.key == key { return p.value }
        return nil
    }

    public subscript(_ index: Int) -> YAML.Node? {
        guard case .sequence(let xs) = self, xs.indices.contains(index) else { return nil }
        return xs[index]
    }

    /// Core-schema resolution, applied on demand rather than during the parse.
    ///
    /// YAML 1.2's core schema, deliberately and only: `true`/`True`/`TRUE` and the `false`
    /// spellings. **`yes`/`no`/`on`/`off` are NOT booleans** — that is YAML 1.1, it is the
    /// Norway problem, and resolving them here would reintroduce it. A document that wants
    /// them boolean can say so with a tag.
    public var resolvedBool: Bool? {
        guard let s = scalar, s.style == .plain, s.tag == nil || s.tag == "!!bool" else {
            return nil
        }
        switch s.content {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: return nil
        }
    }

    public var resolvedInt: Int64? {
        guard let s = scalar, s.style == .plain, s.tag == nil || s.tag == "!!int" else {
            return nil
        }
        return Int64(s.content)
    }

    public var resolvedDouble: Double? {
        guard let s = scalar, s.style == .plain, s.tag == nil || s.tag == "!!float" else {
            return nil
        }
        switch s.content {
        case ".inf", ".Inf", ".INF", "+.inf": return .infinity
        case "-.inf", "-.Inf", "-.INF": return -.infinity
        case ".nan", ".NaN", ".NAN": return .nan
        default: return Double(s.content)
        }
    }

    /// A plain, untagged scalar spelled as YAML 1.2 null.
    public var isNull: Bool {
        guard let s = scalar, s.style == .plain, s.tag == nil || s.tag == "!!null" else {
            return false
        }
        return s.content.isEmpty || s.content == "null" || s.content == "Null"
            || s.content == "NULL" || s.content == "~"
    }
}

// MARK: - Projection to RawValue
//
// **Lossy, and here is exactly how** (docs/VALUE-MODELS.md §5):
//   * fails outright on a non-string mapping key — unrepresentable, not coerced;
//   * drops tags, scalar styles and anchors;
//   * resolves scalars by the core schema, so an unresolvable plain scalar becomes
//     `.string` rather than guessing.

extension RawValue {

    /// Returns nil when the node contains a mapping key that is not a plain scalar, since
    /// `RawValue.mapping` is `String`-keyed by construction.
    public init?(_ node: YAML.Node) {
        switch node {
        case .scalar:
            if node.isNull { self = .null }
            else if let b = node.resolvedBool { self = .bool(b) }
            else if let i = node.resolvedInt { self = .int(i) }
            else if let d = node.resolvedDouble { self = .double(d) }
            else { self = .string(node.content ?? "") }

        case .sequence(let items):
            var out: [RawValue] = []
            out.reserveCapacity(items.count)
            for item in items {
                guard let v = RawValue(item) else { return nil }
                out.append(v)
            }
            self = .sequence(out)

        case .mapping(let pairs):
            var out: [RawValue.Member] = []
            out.reserveCapacity(pairs.count)
            for p in pairs {
                // The narrowing that makes this projection lossy rather than total.
                guard case .scalar(let k) = p.key else { return nil }
                guard let v = RawValue(p.value) else { return nil }
                out.append(.init(key: k.content, value: v))
            }
            self = .mapping(out)
        }
    }
}

// MARK: - Literals

extension YAML.Node: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .scalar(YAML.Scalar(content: value))
    }
}

extension YAML.Node: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: YAML.Node...) { self = .sequence(elements) }
}
