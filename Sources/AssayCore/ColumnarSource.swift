// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Decoding a batch from a COLUMN-FIRST source. docs/KEYED-SOURCE.md.
//
// WHAT THIS FILE IS NOT, AND WHY. It began as half of a general "third decode path" — a
// `KeyedSource` protocol for decoding one record at a time out of anything already parsed
// and addressable by key: database rows, CSV records, plists, form data. That half was
// **removed after measurement**, and the reasoning is worth keeping where the survivor
// lives, because the idea is attractive enough to be reinvented.
//
//   * It lost to the path it was invented to beat. For a row-shaped source, building a
//     `RawValue` and decoding through the existing tree path cost 95 ns; the row path cost
//     311 ns once its presence semantics were correct. The premise that justified it — "an
//     allocation per value per record" — was false. `RawValue.mapping` is ONE allocation
//     per record, and short keys do not allocate at all.
//   * It could not accept the borrowed rows it existed for. A genuinely zero-copy row view
//     is `~Escapable`, and Assay refuses to put an experimental-feature gate on its public
//     surface — the same call `AssayReader` already made.
//   * Its cost lands worst exactly where a driver lives. A `db.query(as: User.self)` loop
//     is generic over the schema, `@inlinable` is forbidden on generated bodies (SE-0193),
//     so the witness-table call is paid per row: 1.6-4.7x.
//
// COLUMNAR SURVIVES BECAUSE NONE OF THAT APPLIES. A column store hands over whole arrays,
// so there is no per-row borrow to escape, no per-row dispatch to pay, and no per-row
// presence ambiguity to translate — the three things that sank the other half. It measures
// a flat ~52 ns/row and 2.07x over decoding the same store row by row.
//
// What a row-shaped reader should do instead is decode into its own type at full speed and
// then call `T.validate(_:)`, which is a seam that costs neither side anything.
//===----------------------------------------------------------------------===//

// MARK: - The field manifest

/// What a `@Schema` type declares, in order, at compile time.
///
/// This is the load-bearing half of the design. A record stream has ONE key set for its
/// whole life, so resolving keys per record is pure waste — a CSV reader doing a
/// byte-comparing scan per field per row is doing millions of comparisons it could have
/// done once. The manifest is what a source binds against to turn that into an array
/// index, and it is also what lets a columnar source invert the loop and fill a batch
/// column-by-column.
///
/// It is published even though the bound decode path is not built yet, because the
/// manifest is the part that has to be right first.
public struct FieldManifest: Sendable {
    public struct Field: Sendable {
        /// The wire key, after `keys:` conversion and `@Key` overrides.
        public let key: String
        public let kind: Kind
        /// `String?` — absent or null both decode to nil.
        public let isOptional: Bool
        /// `= 3` — absent is allowed and the declared value applies.
        public let hasDefault: Bool

        public init(key: String, kind: Kind, isOptional: Bool, hasDefault: Bool) {
            self.key = key
            self.kind = kind
            self.isOptional = isOptional
            self.hasDefault = hasDefault
        }

        /// Whether the source must supply this field for the decode to succeed.
        public var isRequired: Bool { !isOptional && !hasDefault }
    }

    public enum Kind: Sendable, Equatable {
        case string, int, int64, int32, uint, double, float, bool
        case int8, int16, uint8, uint16, uint32, uint64
        /// A `[UInt8]` field — a binary blob, served by `bytesColumn`.
        case bytes
        /// A field whose type is outside the built-in set, carrying its spelling.
        ///
        /// Named for what expansion can actually establish, which is only the complement:
        /// this identifier is not one of the built-ins above. A macro is syntactic — it
        /// sees the token `Timestamp` and nothing else, and cannot know whether that names
        /// a nested `@Schema`, a struct from another module, or a typealias for `Int64`,
        /// because the type checker has not run and will not run until after expansion.
        ///
        /// This case used to be `.nested(String)`, which asserted a fact the expansion is
        /// structurally incapable of establishing and was simply false for `Date`. It is
        /// `.custom` rather than `.unsupported` because such a field is now *decodable*:
        /// the type resolves through `ColumnDecodable`, which is where a consumer's own
        /// scalar — a timestamp, a decimal, a fixed-width identifier — comes across.
        ///
        /// A binder inspecting the manifest still learns exactly what it needs: the
        /// column is not one of the built-in shapes, and the declared spelling is here.
        case custom(String)
    }

    public let fields: [Field]
    public init(fields: [Field]) { self.fields = fields }

    /// Keys in declaration order — what a binder resolves once per stream.
    public var keys: [String] { fields.map(\.key) }
}
// MARK: - Two-phase binding

/// A `FieldManifest` resolved against one source's own layout, once, for a whole stream.
///
/// This is the second phase, and the reason the manifest exists. A record stream has ONE
/// key set for its entire life, so resolving keys per record is pure waste — a reader over
/// a wide table pays a scan per field per row for an answer that never changes. Resolving
/// once turns every subsequent lookup into an array index.
///
/// The plan is deliberately just `[Int]`: field index → whatever the source calls a column,
/// with `absent` for a field the source does not carry. A driver that addresses by
/// statement handle or byte offset stores those instead and this type is not in its way.
public struct BoundPlan: Sendable {
    /// Marks a manifest field the source has no column for. Kept as a sentinel rather than
    /// an optional so the hot path indexes an `[Int]` with no unwrapping.
    public static let absent = -1

    @usableFromInline let slots: [Int]

    /// Resolve a manifest against a source's column names, in the source's own order.
    public init(manifest: FieldManifest, columns: [String]) {
        var index: [String: Int] = [:]
        index.reserveCapacity(columns.count)
        for (i, c) in columns.enumerated() where index[c] == nil { index[c] = i }
        self.slots = manifest.fields.map { index[$0.key] ?? BoundPlan.absent }
    }

    /// For a source that resolves positions some other way — a statement handle, a byte
    /// offset table — and only wants the storage.
    public init(slots: [Int]) { self.slots = slots }

    /// The source's own position for a manifest field, or `absent`.
    @inlinable
    public subscript(field: Int) -> Int {
        field >= 0 && field < slots.count ? slots[field] : BoundPlan.absent
    }

    /// Whether every required field was found. A stream binds once, so this is the natural
    /// place to fail fast — before decoding a million rows that will each report the same
    /// missing column.
    public func missingRequired(in manifest: FieldManifest) -> [String] {
        var out: [String] = []
        for (i, f) in manifest.fields.enumerated()
        where f.isRequired && self[i] == BoundPlan.absent {
            out.append(f.key)
        }
        return out
    }

    public var count: Int { slots.count }
}

// MARK: - Columnar batch fill

/// A source whose data is stored COLUMN-first: Parquet, Arrow, a column store, or any
/// reader that already has one array per field.
///
/// Decoding such a source record-by-record is strided by construction — each record
/// touches every column array once, so N records over M columns is N×M jumps between M
/// separate allocations. Inverting the loop makes each column one sequential pass, which
/// is what the hardware wants and what the format was laid out for.
///
/// Nulls follow Arrow's model: a column carries its values densely and a separate validity
/// mask says which rows are absent. A source with no nulls in a column returns `nil` for
/// the mask and pays nothing.
public protocol ColumnarSource: ~Copyable {
    /// Rows in this batch. Every column must be at least this long.
    var rowCount: Int { get }

    borrowing func int64Column(_ key: StaticString, _ field: Int) -> [Int64]?
    borrowing func doubleColumn(_ key: StaticString, _ field: Int) -> [Double]?
    borrowing func boolColumn(_ key: StaticString, _ field: Int) -> [Bool]?
    borrowing func stringColumn(_ key: StaticString, _ field: Int) -> [String]?

    /// A binary column, in Arrow's varbinary layout: every row's bytes concatenated, plus
    /// an offsets array. See `BytesColumn` for why it is not `[[UInt8]]`.
    ///
    /// Defaulted to `nil`. A source whose format has no binary columns implements nothing.
    borrowing func bytesColumn(_ key: StaticString, _ field: Int) -> BytesColumn?

    /// Which rows of this column are null, or `nil` when none are — the validity mask.
    borrowing func nulls(_ key: StaticString, _ field: Int) -> [Bool]?

    /// Per-column facts the SOURCE knows and the schema must not bake in: a timestamp's
    /// unit, a decimal's scale.
    ///
    /// This is the seam that keeps unit out of the type. A parquet timestamp column is
    /// millis or micros or nanos according to its own metadata, and a schema that hard-codes
    /// one is wrong against files that use another — so the unit travels with the column,
    /// as data, and the receiving type reads it. Defaulted, because most columns have none.
    borrowing func columnMetadata(_ key: StaticString, _ field: Int) -> ColumnMetadata
}

extension ColumnarSource where Self: ~Copyable {
    public borrowing func nulls(_ key: StaticString, _ field: Int) -> [Bool]? { nil }
    public borrowing func bytesColumn(_ key: StaticString, _ field: Int) -> BytesColumn? { nil }
    public borrowing func columnMetadata(_ key: StaticString, _ field: Int) -> ColumnMetadata {
        .none
    }
}

/// A column the schema needs and the source does not carry, or carries at the wrong type.
///
/// Reported ONCE for the batch rather than once per row: a missing column is a property of
/// the source, and a reader over a million rows should not be told a million times. This is
/// the same reasoning that puts `BoundPlan.missingRequired` before the first record.
@inline(never)
public func _assayColumnMissing(
    _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString, _ expected: String
) {
    sink.add(Issue(
        code: .custom("missing_column"),
        path: path + [.key(String(describing: key))],
        params: ["expected": .string(expected)]))
}

/// A required field this row has no value for: the column ran short, or its validity mask
/// marks the row null. Reported per ROW, unlike a missing column — this one really is a
/// property of the individual record.
@inline(never)
public func _assayRowMissing(
    _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
) {
    sink.add(Issue(code: .missing, path: path + [.key(String(describing: key))]))
}

/// Whether row `r` of a column is null, given its optional validity mask.
@inlinable
public func _assayIsNullAt(_ mask: [Bool]?, _ r: Int) -> Bool {
    guard let mask, r < mask.count else { return false }
    return mask[r]
}
