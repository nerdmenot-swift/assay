// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

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
// THE MODEL WAS BUILT BEFORE THE PARSER, deliberately — docs/VALUE-MODELS.md §2 makes the
// point that the model has to be right before a parser is written against it, and the
// unresolved-scalar decision above is why. `parse(yaml:)` lives in `YAMLParser.swift`.
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

        /// Where the VALUE sits in the source document, for carets.
        ///
        /// YAML parses to a node model before anything schema-shaped runs, so without this
        /// the byte offset is gone by the time a `@Validate` rule fires — which is why a
        /// YAML schema issue used to render with no caret while the identical JSON one
        /// pointed straight at the offending value. It rides on the pair rather than on
        /// `Node` because that is the granularity a schema field needs: "the value at this
        /// key", which is what every field-level issue is about.
        ///
        /// **Excluded from `==` and `hash`.** Two documents that differ only in whitespace
        /// must still compare equal; a span is provenance, not value.
        public var valueSpan: SourceSpan?

        public init(key: Node, value: Node, valueSpan: SourceSpan? = nil) {
            self.key = key
            self.value = value
            self.valueSpan = valueSpan
        }

        public static func == (a: Pair, b: Pair) -> Bool {
            a.key == b.key && a.value == b.value
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(key)
            hasher.combine(value)
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

    /// The core-schema resolution for one plain scalar, with the payload already in hand.
    ///
    /// The order is load-bearing and is the order the five accessors were called in: null,
    /// bool, int, float, then string. Each of the typed forms requires `style == .plain`
    /// and either no tag or its own tag, which is why a quoted `"true"` stays a string —
    /// the tests below are the accessors' guards, inlined, not a reinterpretation of them.
    @inlinable
    init(resolving s: YAML.Scalar) {
        guard s.style == .plain else { self = .string(s.content); return }
        let tag = s.tag
        let c = s.content

        if tag == nil || tag == "!!null" {
            if c.isEmpty || c == "null" || c == "Null" || c == "NULL" || c == "~" {
                self = .null
                return
            }
        }
        if tag == nil || tag == "!!bool" {
            switch c {
            case "true", "True", "TRUE": self = .bool(true); return
            case "false", "False", "FALSE": self = .bool(false); return
            default: break
            }
        }
        if tag == nil || tag == "!!int" {
            if let i = Int64(c) { self = .int(i); return }
        }
        if tag == nil || tag == "!!float" {
            switch c {
            case ".inf", ".Inf", ".INF", "+.inf": self = .double(.infinity); return
            case "-.inf", "-.Inf", "-.INF": self = .double(-.infinity); return
            case ".nan", ".NaN", ".NAN": self = .double(.nan); return
            default:
                // OUT OF RANGE DOES NOT RESOLVE. `Double("1e309")` is `+infinity` and
                // `Double("1e-400")` is zero, and neither is what the document says — the
                // same refusal the JSON and TOML paths make, so a struct means the same
                // thing whichever format its bytes arrived in.
                //
                // Here the answer is to leave it UNRESOLVED rather than to raise an issue:
                // the core schema's rule, stated at the top of this file, is that a plain
                // scalar it cannot resolve stays a `.string`. The schema then reports
                // `must be a double, found "1e309"` with the literal in hand, which is a
                // better sentence than anything this function could produce without a sink.
                // The explicit `.inf` and `.nan` spellings are handled above and unaffected.
                // The SIGNIFICAND decides whether a zero result underflowed — scanning the
                // whole literal makes `0.0e-400` look significant because of the `4`, and
                // that one is honestly zero.
                if let d = Double(c), d.isFinite,
                   d != 0 || !c.prefix(while: { $0 != "e" && $0 != "E" })
                               .contains(where: { $0 >= "1" && $0 <= "9" }) {
                    self = .double(d)
                    return
                }
            }
        }
        self = .string(c)
    }

    /// The same projection, but taking the tree by value and MOVING every scalar's text into
    /// the result rather than retaining it.
    ///
    /// The struct-decode doors parse a tree, project it, and drop it; the borrowing form
    /// above retained each `String` into the `RawValue` and released it again when the tree
    /// died — a retain/release pair per scalar, per key, for nothing. Each child is swapped
    /// out of its array for an empty placeholder (an empty array is a static singleton, so
    /// the swap neither retains nor allocates), which leaves the element uniquely held by
    /// this frame and lets its payload move. The placeholders are not free — destroying one
    /// is a `swift_release` on the immortal empty-array storage, a call with no atomic in it
    /// — and that is the trade `docs/EFFICIENCY.md` records: ~30k String retain/release
    /// pairs per 1,000 documents for ~8k of those calls.
    @usableFromInline
    init?(consuming node: consuming YAML.Node) {
        // The payload is bound OUTSIDE the switch. A switch subject lives until the end of
        // the matched case's body, so a `case .sequence(var items)` that mutated in place
        // shared its buffer with the still-live subject and every swap copied the array.
        var items: [YAML.Node] = []
        var pairs: [YAML.Pair] = []
        let isSequence: Bool
        switch consume node {
        case .scalar(let s):
            self = RawValue(resolving: s)
            return
        case .sequence(let xs): items = xs; isSequence = true
        case .mapping(let ps): pairs = ps; isSequence = false
        }

        // Both loops write straight into the result's storage. `append` inside a closure
        // re-checked uniqueness on every element, which the borrowing form did not pay.
        var ok = true
        if isSequence {
            let out = unsafe items.withUnsafeMutableBufferPointer { src in
                unsafe [RawValue](unsafeUninitializedCapacity: src.count) { dst, count in
                    for i in src.indices {
                        var item = YAML.Node.sequence([])
                        unsafe swap(&item, &src[i])
                        guard let v = RawValue(consuming: consume item) else {
                            ok = false; break
                        }
                        unsafe (dst.baseAddress! + count).initialize(to: v)
                        count += 1
                    }
                }
            }
            guard ok else { return nil }
            self = .sequence(out)
            return
        }
        let out = unsafe pairs.withUnsafeMutableBufferPointer { src in
            unsafe [RawValue.Member](unsafeUninitializedCapacity: src.count) { dst, count in
                for i in src.indices {
                    var keyNode = YAML.Node.sequence([])
                    unsafe swap(&keyNode, &src[i].key)
                    guard case .scalar(let k) = consume keyNode else { ok = false; break }
                    var value = YAML.Node.sequence([])
                    unsafe swap(&value, &src[i].value)
                    guard let v = RawValue(consuming: consume value) else {
                        ok = false; break
                    }
                    unsafe (dst.baseAddress! + count).initialize(
                        to: .init(key: k.content, value: v, span: src[i].valueSpan))
                    count += 1
                }
            }
        }
        guard ok else { return nil }
        self = .mapping(out)
    }

    /// Returns nil when the node contains a mapping key that is not a plain scalar, since
    /// `RawValue.mapping` is `String`-keyed by construction.
    public init?(_ node: YAML.Node) {
        switch node {
        case .scalar(let s):
            // ONE DESTRUCTURE. This read `node.isNull`, `node.resolvedBool`,
            // `node.resolvedInt`, `node.resolvedDouble` and `node.content` in turn, and
            // every one of those re-matched `case .scalar(let s)` and re-retained the
            // `YAML.Scalar` — five enum matches and five ARC pairs per scalar node, on the
            // path every YAML struct decode goes through. The resolver below takes the
            // payload once and applies the same tests in the same order.
            self = RawValue(resolving: s)

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
                out.append(.init(key: k.content, value: v, span: p.valueSpan))
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
