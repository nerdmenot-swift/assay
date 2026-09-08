// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// RawValue — the format-neutral projection. docs/VALUE-MODELS.md §5.
//
// This is deliberately the NARROW intersection of what JSON, YAML and XML can carry: no
// origin tags, no namespaces, no scalar styles, no tags. Its entire job is to be the type
// that means the same thing in all three, so that a schema using `@Extras` stays
// format-neutral — which is what EXPERIENCE.md §18's "the format is a parameter" promises.
//
// Full fidelity lives in the per-format models (`JSON.Value`, `YAML.Node`, `XML.Node`).
// Each of those provides a projection into this type, and each documents its losses. Being
// explicitly lossy is what makes this honest: a caller who declares `RawValue` has said
// "I want portability more than fidelity", and that sentence should be true rather than a
// compromise the library imposed on them.
//===----------------------------------------------------------------------===//

/// A value Assay decoded but was not told about in advance, in a shape every supported
/// format can produce.
public enum RawValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case sequence([RawValue])
    case mapping([Member])

    /// One key/value pair. A struct rather than a tuple so the mapping can be `Hashable`.
    public struct Member: Sendable, Hashable {
        public var key: String
        public var value: RawValue

        /// Where this member's VALUE began in the source document, when the parser knew.
        ///
        /// This is what lets a YAML or XML schema issue render a caret. The JSON path
        /// never needs it — it decodes from bytes with the cursor in hand — but the tree
        /// formats build a node model first, and without this the offset is gone by the
        /// time a rule runs. `nil` is always allowed and always safe: the renderer has
        /// handled span-less issues since the first missing-field error.
        ///
        /// **Excluded from `==` and `hash`, deliberately.** Two documents with the same
        /// content and different whitespace must remain equal, and `@Extras` hands these
        /// to users as ordinary data. A span is provenance, not value.
        public var span: SourceSpan?

        public init(key: String, value: RawValue, span: SourceSpan? = nil) {
            self.key = key
            self.value = value
            self.span = span
        }

        public static func == (a: Member, b: Member) -> Bool {
            a.key == b.key && a.value == b.value
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(key)
            hasher.combine(value)
        }
    }
}

// MARK: - Accessors
//
// Shaped after kotlinx.serialization's `JsonPrimitive.int` / `.double` / `.content`, so a
// caller never has to pattern-match a case to read an ordinary value.

extension RawValue {
    public var isNull: Bool { if case .null = self { return true }; return false }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Integer value. A `.double` that happens to be integral does **not** convert —
    /// silently accepting `8080.5` as `8080` is the class of quiet wrongness this library
    /// exists to avoid.
    public var int: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    /// Numeric value, widening `.int` to `Double`. Lossy above 2^53, as ever.
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var sequence: [RawValue]? {
        if case .sequence(let xs) = self { return xs }
        return nil
    }

    public var mapping: [Member]? {
        if case .mapping(let m) = self { return m }
        return nil
    }

    /// First member with this key. XML and YAML both allow a key to repeat; use
    /// `all(_:)` when that matters.
    public subscript(_ key: String) -> RawValue? {
        guard case .mapping(let members) = self else { return nil }
        for m in members where m.key == key { return m.value }
        return nil
    }

    /// Every member with this key, in document order.
    public func all(_ key: String) -> [RawValue] {
        guard case .mapping(let members) = self else { return [] }
        return members.lazy.filter { $0.key == key }.map(\.value)
    }

    public subscript(_ index: Int) -> RawValue? {
        guard case .sequence(let xs) = self, xs.indices.contains(index) else { return nil }
        return xs[index]
    }
}

// MARK: - Hashable and the NaN problem


/// The bit pattern to hash and compare a `Double` by, with every NaN folded to one.
///
/// Comparing `.double` by raw bit pattern is what makes these models usable in a `Set` or
/// as a dictionary key, and the trade is documented above. It is also, without this fold,
/// **not an equivalence relation**: `Double.nan` is `0x7ff8…` and `Double.signalingNaN` is
/// `0x7ff4…`, so two values that are both NaN compare unequal. Measured on arm64
/// 2026-09-08; the divergence is wider on x86-64, where the default quiet NaN produced by
/// an invalid operation conventionally carries the sign bit that ARM's does not — which is
/// why the property test for this runs on the Linux x86-64 CI leg rather than only here.
///
/// Folding costs one `isNaN` test on a path that no decode touches, and buys reflexivity
/// over the whole `Double` domain, which is what the comment above already promised.
@inlinable
func _assayDoubleKey(_ d: Double) -> UInt64 {
    d.isNaN ? Double.nan.bitPattern : d.bitPattern
}

extension RawValue {
    /// Equality with **float semantics that are not `Double`'s**, deliberately.
    ///
    /// `Double`'s IEEE equality says `NaN != NaN`, which violates `Hashable`'s contract that
    /// a value equals itself. Rather than leave the conformance quietly dishonest, `.double`
    /// compares and hashes by bit pattern with every NaN folded to one. Two consequences,
    /// and they are stated here rather than in a file comment because quick-help is where a
    /// caller will meet them:
    ///
    /// - `.double(.nan) == .double(.nan)` is **true**, unlike `Double`'s own `==`. This holds
    ///   for *any* two NaNs, including `.signalingNaN` and a NaN with a different payload —
    ///   it did not before 2026-09-08, when the fold was added.
    /// - `.double(0.0) == .double(-0.0)` is **false**, unlike `Double`'s own `==`. Kept: the
    ///   writers emit `0` and `-0` distinctly, so it is a real content difference.
    ///
    /// This is the same trade the standard library makes for `Double` as a dictionary key.
    /// It is *not* the trade `@Validate(.unique)` makes on a user's `[Double]` — see there.
    public static func == (lhs: RawValue, rhs: RawValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)):
            return _assayDoubleKey(a) == _assayDoubleKey(b)
        case (.string(let a), .string(let b)): return a == b
        case (.sequence(let a), .sequence(let b)): return a == b
        case (.mapping(let a), .mapping(let b)): return a == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let b):
            hasher.combine(1); hasher.combine(b)
        case .int(let i):
            hasher.combine(2); hasher.combine(i)
        case .double(let d):
            hasher.combine(3); hasher.combine(_assayDoubleKey(d))
        case .string(let s):
            hasher.combine(4); hasher.combine(s)
        case .sequence(let xs):
            hasher.combine(5); hasher.combine(xs)
        case .mapping(let m):
            hasher.combine(6); hasher.combine(m)
        }
    }
}

// MARK: - Literals, for tests and for hand-built values

extension RawValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension RawValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension RawValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension RawValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension RawValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension RawValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: RawValue...) { self = .sequence(elements) }
}
