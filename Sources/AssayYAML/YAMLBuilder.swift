// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// What a YAML parse builds.
//
// There are two answers, and until 2026-09-20 there was one: the parser built a
// `YAML.Node` tree, and `parse(yaml:)` then projected that tree into `RawValue` and dropped
// it. Two trees for one decode — about 2,000 heap blocks and a fifth of the instructions of
// `base/yaml-struct` (`docs/EFFICIENCY.md` rows 12 and 17).
//
// So the parser is generic over what it builds, with two conformances in this file and no
// second parser: one grammar, one set of diagnostics, and no way for the two paths to drift.
// It is the same split TOML got (`finish` / `finishRaw`), one layer lower, because TOML
// drains an arena at the end while YAML builds as it reads.
//
// FOUR THINGS MAKE THIS LESS OBVIOUS THAN IT LOOKS, and each is why a method below exists:
//
//   1. A TAG ARRIVES AFTER THE SCALAR. `parseNode` scans `&anchor` and `!!tag` before it
//      knows what kind of node follows, and `RawValue`'s resolution depends on both the tag
//      and the style. So the RawValue builder keeps a scalar UNRESOLVED (`.scalar(text,
//      style, tag)`) and resolves only when it becomes a value — `decorate` rewrites the
//      tag on the way past, exactly as the node builder mutates `Scalar.tag`.
//
//   2. A KEY WANTS RAW TEXT WHILE A VALUE WANTS RESOLUTION. `{1: x}` has the key "1" and
//      `RawValue.Member.key` is a `String`. The unresolved case answers both questions:
//      `keyText` for a key, resolution for a value.
//
//   3. A KEY CAN BE A NON-SCALAR (`? [a, b] : c`). The node model represents that; `RawValue`
//      cannot. `mapping` therefore returns nil and the parser reports
//      `.yamlUnrepresentableKey` — the same code the entry point used to report after the
//      projection failed, now raised where the key is read.
//
//   4. MERGE KEYS DEDUPE ON KEYS. `<<: *base` skips a key the mapping already has, and what
//      "already has" means differs: whole-node equality for the node model, String equality
//      for `RawValue`. Each builder brings its own `merge`.
//===----------------------------------------------------------------------===//

import AssayCore

/// What a YAML parse builds. Two conformances: the node tree, and `RawValue` directly.
///
/// THE ACCUMULATORS ARE THE RESULT. A builder names the array a collection is gathered into
/// (`Items`, `Pairs`) and the parser fills THAT, so finishing a collection moves the array
/// rather than converting it. Gathering into a neutral array and converting at the end cost
/// one extra allocation per container — blocks did not fall at all, which is most of what
/// removing a tree was for (measured 2026-09-20).
protocol YAMLBuilding {
    associatedtype Value

    /// What a sequence is gathered into: `[YAML.Node]` or `[RawValue]`.
    associatedtype Items
    /// What a mapping is gathered into: `[YAML.Pair]` or `[RawValue.Member]`.
    associatedtype Pairs

    /// A scalar. `style` and `tag` are both load-bearing for `RawValue` resolution, which is
    /// why they travel together rather than being attached afterwards.
    static func scalar(_ text: consuming String, style: YAML.ScalarStyle, tag: String?) -> Value

    /// The properties `parseNode` scanned before it knew what followed (`&a`, `!!int`).
    static func decorate(_ v: inout Value, anchor: String?, tag: String?)

    static func makeItems(reserving n: Int) -> Items
    static func append(_ items: inout Items, _ v: consuming Value)
    static func itemCount(_ items: borrowing Items) -> Int
    static func sequence(_ items: consuming Items) -> Value

    static func makePairs(reserving n: Int) -> Pairs
    /// False when the key cannot be represented — `RawValue`'s keys are Strings and
    /// `? [a, b] : c` is legal YAML (this file's header, note 3). The parser reports it.
    static func appendPair(_ pairs: inout Pairs, key: consuming Value,
                           value: consuming Value, span: SourceSpan?) -> Bool
    static func pairCount(_ pairs: borrowing Pairs) -> Int
    static func mapping(_ pairs: consuming Pairs) -> Value

    /// `<<` with no tag: YAML 1.1's merge directive rather than a key. `inout` so a builder
    /// can inspect the key in place instead of copying it per mapping entry.
    static func isMergeKey(_ v: inout Value) -> Bool

    /// How many pairs `source` would contribute, without merging it.
    static func mergedCount(_ source: Value) -> Int

    /// Merge `source` into `pairs`, skipping any key already present.
    static func merge(_ pairs: inout Pairs, from source: Value)
}

// MARK: - The node tree

/// Builds `YAML.Node`: full fidelity, every style, tag, anchor and non-string key kept.
enum YAMLNodeBuilder: YAMLBuilding {
    typealias Value = YAML.Node
    typealias Items = [YAML.Node]
    typealias Pairs = [YAML.Pair]

    static func scalar(
        _ text: consuming String, style: YAML.ScalarStyle, tag: String?
    ) -> YAML.Node {
        .scalar(YAML.Scalar(content: consume text, style: style, tag: tag))
    }

    /// Only a scalar carries them: `Node` has nowhere to hang a collection's tag, which is
    /// what the projection dropped anyway.
    static func decorate(_ v: inout YAML.Node, anchor: String?, tag: String?) {
        guard anchor != nil || tag != nil, case .scalar(var s) = v else { return }
        s.anchor = anchor
        s.tag = tag ?? s.tag
        v = .scalar(s)
    }

    static func makeItems(reserving n: Int) -> [YAML.Node] {
        var out: [YAML.Node] = []
        out.reserveCapacity(n)
        return out
    }

    static func append(_ items: inout [YAML.Node], _ v: consuming YAML.Node) {
        items.append(consume v)
    }

    static func itemCount(_ items: borrowing [YAML.Node]) -> Int { items.count }

    static func sequence(_ items: consuming [YAML.Node]) -> YAML.Node {
        .sequence(consume items)
    }

    static func makePairs(reserving n: Int) -> [YAML.Pair] {
        var out: [YAML.Pair] = []
        out.reserveCapacity(n)
        return out
    }

    /// Always representable: the node model is why `? [a, b] : c` parses at all.
    static func appendPair(
        _ pairs: inout [YAML.Pair], key: consuming YAML.Node,
        value: consuming YAML.Node, span: SourceSpan?
    ) -> Bool {
        pairs.append(YAML.Pair(key: consume key, value: consume value, valueSpan: span))
        return true
    }

    static func pairCount(_ pairs: borrowing [YAML.Pair]) -> Int { pairs.count }

    static func mapping(_ pairs: consuming [YAML.Pair]) -> YAML.Node { .mapping(consume pairs) }

    static func isMergeKey(_ v: inout YAML.Node) -> Bool {
        if case .scalar(let s) = v { return s.content == "<<" && s.tag == nil }
        return false
    }

    static func mergedCount(_ source: YAML.Node) -> Int {
        switch source {
        case .mapping(let p): return p.count
        case .sequence(let xs):
            var n = 0
            for x in xs { if case .mapping(let p) = x { n += p.count } }
            return n
        default: return 0
        }
    }

    /// Earlier sources win, and an explicit key beats a merged one whatever its position.
    ///
    /// THE SET IS NOT AN OPTIMISATION, IT IS THE DIFFERENCE BETWEEN LINEAR AND QUADRATIC.
    /// A scan of every accumulated pair for every merged pair made a 1 MB document with one
    /// `<<:` take 3.5 s against 5 ms without the merge line, quadrupling per doubling
    /// (measured 2026-09-13). Nothing else saw it: the node count stays small, so neither the
    /// alias budget nor `maxDepth` fires, and the amplification tests cover alias bombs rather
    /// than merge width. Below the threshold a scan of a handful of short keys beats hashing.
    static func merge(_ pairs: inout [YAML.Pair], from source: YAML.Node) {
        let total = pairs.count + mergedCount(source)
        if total > YAML.mergeSetThreshold {
            var present = Set<YAML.Node>(minimumCapacity: total)
            for p in pairs { present.insert(p.key) }
            mergeEach(source) { p in
                if present.insert(p.key).inserted { pairs.append(p) }
            }
        } else {
            mergeEach(source) { p in
                if !pairs.contains(where: { $0.key == p.key }) { pairs.append(p) }
            }
        }
    }

    /// Every pair a merge source offers: a mapping's own, or every mapping in a sequence.
    /// A non-mapping source is silently ignored, as it was before.
    private static func mergeEach(_ source: YAML.Node, _ body: (YAML.Pair) -> Void) {
        switch source {
        case .mapping(let members): for m in members { body(m) }
        case .sequence(let items): for item in items { mergeEach(item, body) }
        default: break
        }
    }
}

// MARK: - RawValue, directly

/// Builds `RawValue`: what every `@Schema` type decodes from, with no node tree in between.
enum YAMLRawBuilder: YAMLBuilding {

    typealias Items = [RawValue]
    typealias Pairs = [RawValue.Member]

    /// One value under construction: either an unresolved scalar (its `text`) or a finished
    /// `RawValue`.
    ///
    /// The text is its OWN field rather than a `.string` payload, so `takeText` and `takeRaw`
    /// can swap it out instead of copying it: reading a String back out of an enum payload
    /// cost a retain per key and per scalar value (+36,000 on nested-3/yaml-struct), because
    /// Swift cannot partially consume an enum. The size this costs does not matter any more —
    /// the accumulators hold `[RawValue]` and `[RawValue.Member]`, so a `Value` only ever
    /// lives in a local.
    ///
    /// `unresolved` is what makes a key possible: `{1: x}` needs the TEXT "1" for its key and
    /// the resolution `1` only if it is used as a value (this file's header, notes 1 and 2).
    @usableFromInline
    struct Value {
        var text: String
        var raw: RawValue
        var style: YAML.ScalarStyle
        var unresolved: Bool

        /// The `RawValue` this is, resolving an unresolved scalar on the way out.
        @inlinable
        mutating func takeRaw() -> RawValue {
            guard unresolved else {
                var out = RawValue.null
                swap(&out, &raw)
                return out
            }
            unresolved = false
            var t = ""
            swap(&t, &text)
            return RawValue(_resolvingText: consume t, style: style, tag: nil)
        }

        /// The key's text, or nil when this cannot be a key.
        @inlinable
        mutating func takeText() -> String? {
            guard unresolved else { return nil }
            var t = ""
            swap(&t, &text)
            return t
        }
    }

    @inlinable
    static func built(_ raw: RawValue) -> Value {
        Value(text: "", raw: raw, style: .plain, unresolved: false)
    }

    static func scalar(_ text: consuming String, style: YAML.ScalarStyle, tag: String?) -> Value {
        guard let tag else {
            return Value(text: consume text, raw: .null, style: style, unresolved: true)
        }
        // Tagged scalars are rare, so they resolve here rather than making every value carry
        // a tag field.
        return built(RawValue(_resolvingText: consume text, style: style, tag: tag))
    }

    /// A tag arriving after the scalar (`!!str 1`): resolve now, with the tag.
    static func decorate(_ v: inout Value, anchor: String?, tag: String?) {
        guard let tag, v.unresolved else { return }
        var t = ""
        swap(&t, &v.text)
        v.raw = RawValue(_resolvingText: consume t, style: v.style, tag: tag)
        v.unresolved = false
    }

    /// Resolution, for a document root or an anchor's value.
    static func resolve(_ v: consuming Value) -> RawValue {
        var v = v
        return v.takeRaw()
    }

    static func makeItems(reserving n: Int) -> [RawValue] {
        var out: [RawValue] = []
        out.reserveCapacity(n)
        return out
    }

    static func append(_ items: inout [RawValue], _ v: consuming Value) {
        var v = v
        items.append(v.takeRaw())
    }

    static func itemCount(_ items: borrowing [RawValue]) -> Int { items.count }

    static func sequence(_ items: consuming [RawValue]) -> Value {
        built(.sequence(consume items))
    }

    static func makePairs(reserving n: Int) -> [RawValue.Member] {
        var out: [RawValue.Member] = []
        out.reserveCapacity(n)
        return out
    }

    static func appendPair(
        _ pairs: inout [RawValue.Member], key: consuming Value,
        value: consuming Value, span: SourceSpan?
    ) -> Bool {
        var key = key
        var value = value
        guard let text = key.takeText() else { return false }
        pairs.append(RawValue.Member(key: text, value: value.takeRaw(), span: span))
        return true
    }

    static func pairCount(_ pairs: borrowing [RawValue.Member]) -> Int { pairs.count }

    static func mapping(_ pairs: consuming [RawValue.Member]) -> Value {
        built(.mapping(consume pairs))
    }

    static func isMergeKey(_ v: inout Value) -> Bool {
        v.unresolved && v.text == "<<"
    }

    static func mergedCount(_ source: Value) -> Int {
        guard !source.unresolved else { return 0 }
        switch source.raw {
        case .mapping(let m): return m.count
        case .sequence(let xs):
            var n = 0
            for x in xs { if case .mapping(let m) = x { n += m.count } }
            return n
        default: return 0
        }
    }

    /// Dedupes on the key STRING, which is all a `RawValue` key can be, where the node
    /// builder compares whole nodes. Same threshold, same linear-versus-quadratic reason.
    static func merge(_ pairs: inout [RawValue.Member], from source: Value) {
        let total = pairs.count + mergedCount(source)
        if total > YAML.mergeSetThreshold {
            var present = Set<String>(minimumCapacity: total)
            for p in pairs { present.insert(p.key) }
            mergeEach(source) { m in
                if present.insert(m.key).inserted { pairs.append(m) }
            }
        } else {
            mergeEach(source) { m in
                if !pairs.contains(where: { $0.key == m.key }) { pairs.append(m) }
            }
        }
    }

    /// Merge sources are already-built mappings. Cold: a document without `<<:` never
    /// reaches it.
    private static func mergeEach(_ source: Value, _ body: (RawValue.Member) -> Void) {
        guard !source.unresolved else { return }
        switch source.raw {
        case .mapping(let members): for m in members { body(m) }
        case .sequence(let items): for item in items { mergeEach(built(item), body) }
        default: break
        }
    }
}
