//===----------------------------------------------------------------------===//
// JSON.Value — the full-fidelity JSON model. docs/VALUE-MODELS.md §4.
//
// Namespaced rather than flat (`JSON.Value`, not `JSONValue`) for symmetry with
// `XML.Node`, where flat spelling collides with Foundation. See §3 of the design note.
//
// Two decisions worth knowing:
//
//   * **Object members are ORDERED and duplicates are preserved.** RFC 8259 leaves
//     duplicate keys undefined, and silently dropping one is the worst available answer.
//     A Dictionary would also cost a SipHash per key on construction — the exact overhead
//     PERFORMANCE.md §1.2 identifies as Foundation's largest structural cost.
//
//   * **No `indirect`.** Recursion runs through `Array`, which already provides the
//     indirection, so scalars are stored inline in the enum rather than boxed. An
//     `indirect enum` here would allocate a box per node — the `[String: Any]` cost in a
//     nicer costume.
//===----------------------------------------------------------------------===//

/// Namespace. Caseless, so it cannot be instantiated.
public enum JSON {}

extension JSON {

    /// A JSON value, exactly as the document expressed it.
    public enum Value: Sendable, Hashable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([Value])
        case object([Member])

        /// One `"key": value` pair. A struct rather than a tuple so the object can be
        /// `Hashable`, and so the ordering is visible in the type.
        public struct Member: Sendable, Hashable {
            public var key: String
            public var value: Value

            public init(key: String, value: Value) {
                self.key = key
                self.value = value
            }
        }
    }
}

// MARK: - Accessors

extension JSON.Value {
    public var isNull: Bool { if case .null = self { return true }; return false }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// A `.double` that happens to be integral does not convert. See `RawValue.int`.
    public var int: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

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

    public var array: [JSON.Value]? {
        if case .array(let xs) = self { return xs }
        return nil
    }

    public var object: [Member]? {
        if case .object(let m) = self { return m }
        return nil
    }

    /// First member with this key. Duplicates are preserved in storage, so `all(_:)`
    /// exists for the case where that matters.
    public subscript(_ key: String) -> JSON.Value? {
        guard case .object(let members) = self else { return nil }
        for m in members where m.key == key { return m.value }
        return nil
    }

    public func all(_ key: String) -> [JSON.Value] {
        guard case .object(let members) = self else { return [] }
        return members.lazy.filter { $0.key == key }.map(\.value)
    }

    public subscript(_ index: Int) -> JSON.Value? {
        guard case .array(let xs) = self, xs.indices.contains(index) else { return nil }
        return xs[index]
    }
}

// MARK: - Hashable, bit-pattern for doubles

extension JSON.Value {
    public static func == (lhs: JSON.Value, rhs: JSON.Value) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a.bitPattern == b.bitPattern
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(1); hasher.combine(b)
        case .int(let i): hasher.combine(2); hasher.combine(i)
        case .double(let d): hasher.combine(3); hasher.combine(d.bitPattern)
        case .string(let s): hasher.combine(4); hasher.combine(s)
        case .array(let xs): hasher.combine(5); hasher.combine(xs)
        case .object(let m): hasher.combine(6); hasher.combine(m)
        }
    }
}

// MARK: - Projection to RawValue
//
// **Total.** JSON is the format `RawValue` was shaped around, so nothing is lost.

extension RawValue {
    public init(_ value: JSON.Value) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        case .array(let xs): self = .sequence(xs.map(RawValue.init))
        case .object(let members):
            self = .mapping(members.map { Member(key: $0.key, value: RawValue($0.value)) })
        }
    }
}

// MARK: - Literals

extension JSON.Value: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension JSON.Value: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSON.Value: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}
extension JSON.Value: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension JSON.Value: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSON.Value: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSON.Value...) { self = .array(elements) }
}
