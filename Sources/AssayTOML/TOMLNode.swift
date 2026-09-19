// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// TOML 1.0.0, as a tree.
//
// TOML is the smallest of the four formats and the only one that is TYPED on the wire: a
// bare `1` is an integer, `"1"` is a string, `1979-05-27` is a date, and the parser does
// not get to guess. That is the opposite of YAML's Norway problem and the reason this
// node model resolves scalars at parse time where YAML's keeps the text.
//
// DATE-TIMES ARE THE ONE VALUE `RawValue` CANNOT HOLD. TOML has four kinds — offset
// date-time, local date-time, local date, local time — and `RawValue` has no date case
// (docs/VALUE-MODELS.md: it is the intersection of the formats, and JSON has no date
// either). The projection carries them as `.string` in RFC 3339 spelling with a `T`
// separator, which is exactly the text the schema's `Date` path already parses, so
// `var when: Date` decodes from TOML with no new code. `TOML.Node` keeps the kind, for a
// caller who wants to know which of the four it was.
//
// TABLES ARE ORDERED AND KEYED BY STRING. A TOML key is always a string — bare, quoted,
// or dotted — so unlike YAML there is no unrepresentable-key case, and the projection to
// `RawValue` never fails.
//===----------------------------------------------------------------------===//

public import AssayCore

public enum TOML {}

extension TOML {

    /// One of TOML's four date-time kinds, carrying its canonical RFC 3339 text.
    ///
    /// The text is normalised on the way in: a space separator becomes `T`, and the
    /// components have been range-checked (a 13th month or a 25th hour is a parse
    /// error, as the specification requires). Fractional seconds and the offset are kept
    /// exactly as written.
    public enum DateTime: Sendable, Hashable {
        /// `1979-05-27T07:32:00Z`, `1979-05-27T00:32:00.999-07:00` — an instant.
        case offsetDateTime(String)
        /// `1979-05-27T07:32:00` — a wall-clock time with no zone.
        case localDateTime(String)
        /// `1979-05-27`.
        case localDate(String)
        /// `07:32:00`, `00:32:00.999999`.
        case localTime(String)

        /// The RFC 3339 text.
        public var text: String {
            switch self {
            case .offsetDateTime(let s), .localDateTime(let s), .localDate(let s), .localTime(let s):
                return s
            }
        }
    }

    /// One key/value pair of a table, in document order.
    public struct Member: Sendable, Hashable {
        /// The key, unquoted and unescaped. A dotted key `a.b = 1` produces nested tables,
        /// so a member's key is always a single segment.
        public var key: String
        public var value: Node
        /// Where the VALUE sits in the source, so a schema issue on this member can carry
        /// a caret. Excluded from equality and hashing: two documents differing only in
        /// whitespace are the same tree.
        public var span: SourceSpan?

        public init(key: String, value: Node, span: SourceSpan? = nil) {
            self.key = key
            self.value = value
            self.span = span
        }

        public static func == (a: Member, b: Member) -> Bool { a.key == b.key && a.value == b.value }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(key)
            hasher.combine(value)
        }
    }

    /// A TOML value.
    ///
    /// NOT `indirect`, for the reason `JSON.Value` is not: recursion runs through `[Node]` and
    /// `[Member]`, which already provide the indirection, and every payload is small (a
    /// `DateTime` is an enum of Strings). It WAS indirect until 2026-09-19, which boxed every
    /// node of every kind on the heap, `.int` and `.bool` included; count.py charged 10,000 of
    /// `base/toml`'s blocks per call to the `.string` boxes alone.
    public enum Node: Sendable, Hashable {
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case dateTime(DateTime)
        case array([Node])
        /// A table — a header section, an inline table, or one produced by dotted keys.
        /// Members are in document order.
        case table([Member])

        public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
        public var int: Int64? { if case .int(let i) = self { return i }; return nil }
        /// A `.double`, or a `.int` widened.
        public var double: Double? {
            switch self {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }
        public var string: String? { if case .string(let s) = self { return s }; return nil }
        public var dateTime: DateTime? { if case .dateTime(let d) = self { return d }; return nil }
        public var array: [Node]? { if case .array(let a) = self { return a }; return nil }
        public var table: [Member]? { if case .table(let m) = self { return m }; return nil }

        /// The first member named `key` of a table, or nil.
        public subscript(_ key: String) -> Node? {
            guard case .table(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        /// The element at `index` of an array, or nil.
        public subscript(_ index: Int) -> Node? {
            guard case .array(let items) = self, index >= 0, index < items.count else { return nil }
            return items[index]
        }
    }
}

// MARK: - The RawValue projection

extension RawValue {

    /// The format-neutral projection every `@Schema` type decodes from.
    ///
    /// Total, unlike YAML's: every TOML key is a string. Date-times become strings in
    /// RFC 3339 form (see the file header), which is the one lossy step and the reason
    /// `TOML.Node` exists beside this.
    public init(_ node: TOML.Node) {
        switch node {
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        case .dateTime(let dt): self = .string(dt.text)
        case .array(let items):
            var out: [RawValue] = []
            out.reserveCapacity(items.count)
            for item in items { out.append(RawValue(item)) }
            self = .sequence(out)
        case .table(let members):
            var out: [RawValue.Member] = []
            out.reserveCapacity(members.count)
            for m in members {
                out.append(RawValue.Member(key: m.key, value: RawValue(m.value), span: m.span))
            }
            self = .mapping(out)
        }
    }

    /// The same projection, taking the tree by value and MOVING its strings into the result.
    ///
    /// The struct-decode doors parse, project and drop; borrowing retained every key and
    /// string into the RawValue and released it again with the tree. Each child is swapped
    /// out of its (by then unique) array for a placeholder, so its payload moves. The
    /// payload is bound outside the switch because a switch subject lives to the end of the
    /// case body and would keep the array shared. Same shape as YAML's
    /// `RawValue(consuming:)`; `docs/EFFICIENCY.md` row 14 has the measurements that chose it.
    @usableFromInline
    init(consuming node: consuming TOML.Node) {
        switch node {
        case .bool(let b): self = .bool(b); return
        case .int(let i): self = .int(i); return
        case .double(let d): self = .double(d); return
        case .string(let s): self = .string(s); return
        case .dateTime(let dt): self = .string(dt.text); return
        case .array, .table: break
        }
        var (items, members, isArray) = RawValue._takeContainers(consume node)
        // `.bool(false)` is the placeholder: a trivial payload, so destroying the drained
        // array costs no release per slot.
        if isArray {
            let out = unsafe items.withUnsafeMutableBufferPointer { src in
                unsafe [RawValue](unsafeUninitializedCapacity: src.count) { dst, count in
                    for i in src.indices {
                        var item = TOML.Node.bool(false)
                        unsafe swap(&item, &src[i])
                        unsafe (dst.baseAddress! + i).initialize(
                            to: RawValue(consuming: consume item))
                    }
                    count = src.count
                }
            }
            self = .sequence(out)
            return
        }
        let out = unsafe members.withUnsafeMutableBufferPointer { src in
            unsafe [RawValue.Member](unsafeUninitializedCapacity: src.count) { dst, count in
                for i in src.indices {
                    // Key and value into locals of their own: passing `m.value` from a
                    // live `var m` copied it, so the child array arrived shared and the
                    // copy cascaded through every record under it (+2,000 blocks on
                    // base/toml-struct).
                    var key = ""
                    unsafe swap(&key, &src[i].key)
                    var value = TOML.Node.bool(false)
                    unsafe swap(&value, &src[i].value)
                    unsafe (dst.baseAddress! + i).initialize(
                        to: RawValue.Member(key: consume key,
                                            value: RawValue(consuming: consume value),
                                            span: src[i].span))
                }
                count = src.count
            }
        }
        self = .mapping(out)
    }

    /// Out of line on purpose. With the payload bound inside the caller's own switch, the
    /// release build kept the node alive past the loops below and every array was copied
    /// on first mutation (+2,000 blocks on base/toml-struct); returned from here, the node
    /// is dead before the caller touches the arrays.
    @inline(never) @usableFromInline
    static func _takeContainers(
        _ node: consuming TOML.Node
    ) -> ([TOML.Node], [TOML.Member], Bool) {
        switch consume node {
        case .array(let xs): return (xs, [], true)
        case .table(let ms): return ([], ms, false)
        default: return ([], [], false)
        }
    }
}
