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

        public init(key: String, value: RawValue) {
            self.key = key
            self.value = value
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
//
// docs/VALUE-MODELS.md open question 3. `Double`'s IEEE equality says NaN != NaN, which
// violates Hashable's contract (a value must equal itself). Rather than leave the
// conformance quietly dishonest, `.double` compares and hashes by **bit pattern**.
//
// Two visible consequences, documented rather than discovered:
//   * `.double(.nan) == .double(.nan)` is **true** here, unlike `Double`'s own `==`.
//   * `.double(0.0) == .double(-0.0)` is **false** here, unlike `Double`'s own `==`.
//
// This is the same trade the standard library makes for `Double` as a Dictionary key via
// `Hashable`, and it is the only choice that keeps `RawValue` usable in a Set or as a key.

extension RawValue {
    public static func == (lhs: RawValue, rhs: RawValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a.bitPattern == b.bitPattern
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
            hasher.combine(3); hasher.combine(d.bitPattern)
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
