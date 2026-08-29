// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The columnar extension point: how a type Assay has never heard of crosses a column
// store. docs/COLUMN-DECODABLE.md.
//
// WHAT PROBLEM THIS SOLVES. `columnAccessor` in the macro mapped exactly eight spellings
// to four accessors, and every other field type was refused at expansion. That is not a
// list with holes in it; it is the absence of an extension point. A consumer with a
// `Timestamp`, a `Decimal128`, a `CalendarDate` had no route at all, and the fix cannot be
// "add those four accessors" — a protocol that grows one member per type never stops
// growing, and Assay would be learning the vocabulary of one caller's file format.
//
// WHY IT IS NOT A PER-ROW PROTOCOL CALL, WHICH IS WHAT KILLED `KeyedSource`. The measured
// objection recorded in `ColumnarSource.swift` is real: a call through a generic parameter
// inside this library, in a loop the consumer drives, costs 1.6-4.7x, because `@inlinable`
// is forbidden on generated bodies (SE-0193) and the witness call is therefore paid per
// row. Isolated first, across a real module boundary, converting one Int64 per value:
//
//     baseline, copy Int64, no conversion               0.34 ns/value
//     concrete init, as the macro emits it              0.35 ns/value
//     through a generic parameter in the library       21.35 ns/value   <-- KeyedSource
//     through an existential                            3.74 ns/value
//     this design: generic fetch per COLUMN,
//                  concrete init per row                0.47 ns/value
//
// The split is the whole design. `Column._assayFetch` is generic and is called ONCE per
// column, so its cost divides by the row count. The per-row call names a concrete type in
// the consumer's own module -- the macro emits `Timestamp(assayColumn:row:metadata:)`
// exactly as it already emits `Date(timeIntervalSince1970:)` -- so there is no witness
// table to go through and nothing to devirtualize.
//
// Then confirmed IN THIS LIBRARY, which is the number to quote. Same store, same column,
// same two-field schema, 100k rows; the only difference is whether the field is declared
// `Int64` or a `ColumnDecodable` type carried by `Int64` (`runColumnDecodableBenchmarks`):
//
//     Int64, built in                                  42.65 ns/row
//     Micros, ColumnDecodable                          42.29 ns/row     0.99x
//
// Three runs put it at 0.99x, 0.99x and 1.02x -- which is to say the hook is free, and the
// spread is the measurement, not the feature.
//
// WHY THE BYTES COLUMN IS FLAT-PLUS-OFFSETS. `[[UInt8]]` would be one heap allocation per
// row, charged to every reader whether or not it wants a copy, and a parquet or Arrow
// reader already HAS the flat buffer and the offsets because that is how the format stores
// them. Measured over identical arithmetic on identical bytes, at only 16 bytes per row:
//
//     range(at:) into the flat buffer                  54.93 ns/row
//     bytes(at:), one Array per row                    84.23 ns/row     1.53x
//
// 27-29 ns/row across runs, and it grows with the blob. The analogy with `stringColumn`
// returning `[String]` does not carry: short strings ride in small-string form and never
// touch the heap, and a blob never does.
//
// WHY THE CARRIER IS AN ASSOCIATED TYPE AND NOT A FIELD ATTRIBUTE. A macro is syntactic.
// It sees `var takenAt: Timestamp` as an identifier and cannot see conformances, so it
// cannot know whether to ask the source for an integer column or a binary one. The
// alternative is to make the author say so on the field -- `@Column(.int64) var takenAt`
// -- which puts an annotation on every use site, forever, for a fact that belongs to the
// type and never varies. `associatedtype Column` states it once, on the type, and lets the
// macro emit one uniform line for a type it knows nothing about.
//===----------------------------------------------------------------------===//

// MARK: - Column metadata

/// Per-column facts the source knows and the schema must not bake in.
///
/// A timestamp's unit is DATA, not type. A parquet column declares milliseconds or
/// microseconds or nanoseconds in its own metadata, and two files with the same logical
/// schema can disagree — so a Swift type that fixes the unit is wrong against half of them.
/// The unit travels here, with the column, and the receiving type reads it.
///
/// The fields are deliberately untyped and generic. Assay does not know what a unit *means*
/// and must not: giving this an enum of time units would be Assay learning one caller's
/// vocabulary, which is the thing this whole file exists to avoid.
public struct ColumnMetadata: Sendable, Equatable {
    /// Scale of the column's values, in whatever the type's own terms are. Conventionally
    /// a power-of-ten exponent for time and decimals: -3 milli, -6 micro, -9 nano.
    public var unit: Int32
    /// Digits after the point, for a fixed-point column.
    public var scale: Int32
    /// Anything else the source and the type have agreed on.
    public var flags: UInt32

    public init(unit: Int32 = 0, scale: Int32 = 0, flags: UInt32 = 0) {
        self.unit = unit
        self.scale = scale
        self.flags = flags
    }

    /// A column with nothing to declare, which is most of them.
    public static let none = ColumnMetadata()
}

// MARK: - Carriers

/// A primitive a column store can physically hand over.
///
/// Closed on purpose, and closed is the point: these are the shapes storage engines
/// actually store, and every consumer scalar is built from one of them. An open set here
/// would be the per-type accessor list again, one level down.
///
/// `Int64` rather than `Double` for whole numbers is load-bearing. A nanosecond timestamp
/// needs 64 bits of integer: `Double` carries 2^53 nanoseconds, which is about 104 days,
/// so a `Double` carrier silently loses precision on any modern instant.
public protocol AssayCarrier: Sendable {
    /// Ask the source for this carrier's column. One call per column, never per row.
    static func _assayFetchValues<S: ColumnarSource & ~Copyable>(
        from source: borrowing S, _ key: StaticString, _ field: Int
    ) -> [Self]?
}

extension Int64: AssayCarrier {
    @inlinable
    public static func _assayFetchValues<S: ColumnarSource & ~Copyable>(
        from source: borrowing S, _ key: StaticString, _ field: Int
    ) -> [Int64]? { source.int64Column(key, field) }
}

extension Double: AssayCarrier {
    @inlinable
    public static func _assayFetchValues<S: ColumnarSource & ~Copyable>(
        from source: borrowing S, _ key: StaticString, _ field: Int
    ) -> [Double]? { source.doubleColumn(key, field) }
}

extension Bool: AssayCarrier {
    @inlinable
    public static func _assayFetchValues<S: ColumnarSource & ~Copyable>(
        from source: borrowing S, _ key: StaticString, _ field: Int
    ) -> [Bool]? { source.boolColumn(key, field) }
}

extension String: AssayCarrier {
    @inlinable
    public static func _assayFetchValues<S: ColumnarSource & ~Copyable>(
        from source: borrowing S, _ key: StaticString, _ field: Int
    ) -> [String]? { source.stringColumn(key, field) }
}

// MARK: - Storage

/// One column, fetched. What a `ColumnDecodable` type names as its `Column`.
public protocol ColumnStorage: Sendable {
    /// One call per column for a whole batch. Generic, and that is affordable precisely
    /// because it is not per row.
    static func _assayFetch<S: ColumnarSource & ~Copyable>(
        from source: borrowing S, _ key: StaticString, _ field: Int
    ) -> Self?

    var count: Int { get }
    /// Which rows are null, or `nil` when none are.
    var nulls: [Bool]? { get }
    var metadata: ColumnMetadata { get }
}

/// A column of a fixed carrier: integers, doubles, booleans, strings.
public struct ColumnBuffer<Element: AssayCarrier>: ColumnStorage {
    public let values: [Element]
    public let nulls: [Bool]?
    public let metadata: ColumnMetadata

    public init(values: [Element], nulls: [Bool]? = nil, metadata: ColumnMetadata = .none) {
        self.values = values
        self.nulls = nulls
        self.metadata = metadata
    }

    @inlinable public var count: Int { values.count }
    @inlinable public subscript(row: Int) -> Element { values[row] }

    @inlinable
    public static func _assayFetch<S: ColumnarSource & ~Copyable>(
        from source: borrowing S, _ key: StaticString, _ field: Int
    ) -> ColumnBuffer<Element>? {
        guard let values = Element._assayFetchValues(from: source, key, field) else {
            return nil
        }
        return ColumnBuffer(values: values,
                            nulls: source.nulls(key, field),
                            metadata: source.columnMetadata(key, field))
    }
}

extension ColumnBuffer: Equatable where Element: Equatable {}

/// A column of binary blobs, in Arrow's varbinary layout: every row's bytes concatenated
/// into one buffer, plus `count + 1` offsets into it.
///
/// NOT `[[UInt8]]`, and the difference is the reason this shape was chosen deliberately
/// rather than by analogy with `stringColumn`. `[[UInt8]]` is one heap allocation per row,
/// which a reader must pay on the way in and cannot avoid: a parquet or Arrow reader
/// already HAS the flat buffer and the offsets, because that is how the format stores them,
/// so handing them over is a move and handing over `[[UInt8]]` is N allocations and N
/// copies. The analogy with `[String]` does not hold either — short strings ride in
/// small-string form and never touch the heap, and blobs never do.
///
/// A source that genuinely has separate blobs can still build one with `init(rows:)`.
public struct BytesColumn: ColumnStorage {
    /// Every row's bytes, concatenated.
    public let bytes: [UInt8]
    /// `count + 1` offsets into `bytes`. Row `r` is `bytes[offsets[r]..<offsets[r+1]]`.
    public let offsets: [Int]
    public let nulls: [Bool]?
    public let metadata: ColumnMetadata

    public init(bytes: [UInt8], offsets: [Int],
                nulls: [Bool]? = nil, metadata: ColumnMetadata = .none) {
        self.bytes = bytes
        self.offsets = offsets
        self.nulls = nulls
        self.metadata = metadata
    }

    /// For a source that really does hold separate blobs. A reader that already has the
    /// flat layout should use the memberwise initialiser and copy nothing.
    public init(rows: [[UInt8]], nulls: [Bool]? = nil, metadata: ColumnMetadata = .none) {
        var flat: [UInt8] = []
        flat.reserveCapacity(rows.reduce(0) { $0 + $1.count })
        var offs: [Int] = [0]
        offs.reserveCapacity(rows.count + 1)
        for r in rows {
            flat.append(contentsOf: r)
            offs.append(flat.count)
        }
        self.init(bytes: flat, offsets: offs, nulls: nulls, metadata: metadata)
    }

    @inlinable public var count: Int { Swift.max(0, offsets.count - 1) }

    /// The half-open range of `bytes` holding row `r`, or `nil` if `r` is out of range or
    /// the offsets are not monotonic. Validated here so neither caller has to trust the
    /// source: a malformed offsets array is a data error, not a trap.
    @inlinable
    public func range(at row: Int) -> Range<Int>? {
        guard row >= 0, row + 1 < offsets.count else { return nil }
        let lo = offsets[row], hi = offsets[row + 1]
        guard lo >= 0, lo <= hi, hi <= bytes.count else { return nil }
        return lo..<hi
    }

    /// Row `r`'s bytes as a view over the flat buffer. Nothing is copied.
    ///
    /// `ArraySlice` rather than `Span`, and not by preference: `Array.span` is macOS 26 and
    /// this package's floor is macOS 11, so a `Span` accessor would be available to a
    /// fraction of callers and absent for the rest. A slice costs one retain/release of the
    /// shared buffer per call and copies no bytes. For a hot loop that wants neither, read
    /// `range(at:)` and index `bytes` directly — that is free, and safe.
    @inlinable
    public func slice(at row: Int) -> ArraySlice<UInt8>? {
        guard let r = range(at: row) else { return nil }
        return bytes[r]
    }

    /// Row `r`'s bytes, copied. The escape hatch for a type that needs to keep them.
    @inlinable
    public func bytes(at row: Int) -> [UInt8]? {
        guard let r = range(at: row) else { return nil }
        return Array(bytes[r])
    }

    @inlinable
    public static func _assayFetch<S: ColumnarSource & ~Copyable>(
        from source: borrowing S, _ key: StaticString, _ field: Int
    ) -> BytesColumn? {
        guard var c = source.bytesColumn(key, field) else { return nil }
        // A source is free to leave these on the column itself; when it does not, the
        // per-column accessors are the same seam every other column kind uses.
        if c.nulls == nil, let n = source.nulls(key, field) {
            c = BytesColumn(bytes: c.bytes, offsets: c.offsets,
                            nulls: n, metadata: c.metadata)
        }
        if c.metadata == .none {
            c = BytesColumn(bytes: c.bytes, offsets: c.offsets,
                            nulls: c.nulls, metadata: source.columnMetadata(key, field))
        }
        return c
    }
}

// MARK: - The hook

/// A type that can be decoded from one row of a column store.
///
/// Conform, and every `@Schema(sources: true)` type may declare a field of that type.
/// Assay never learns the type's name: the conformance is the declaration, checked by the
/// compiler at the conformance site rather than by string matching at macro expansion.
///
/// ```swift
/// struct Timestamp {
///     var epochNanoseconds: Int64
/// }
///
/// extension Timestamp: ColumnDecodable {
///     init?(assayColumn c: borrowing ColumnBuffer<Int64>,
///           row: Int, metadata m: ColumnMetadata) {
///         // The unit came from the column, not from this type. -3 milli, -6 micro, -9 nano.
///         let scale: Int64
///         switch m.unit {
///         case -9: scale = 1
///         case -6: scale = 1_000
///         case -3: scale = 1_000_000
///         default: scale = 1_000_000_000
///         }
///         epochNanoseconds = c[row] * scale
///     }
/// }
/// ```
///
/// Returning `nil` reports the row as missing, with the field's path and row index, exactly
/// as a null or a short column does. It is the right answer for a value the column can hold
/// but this type cannot represent.
public protocol ColumnDecodable {
    /// What to ask the source for. `ColumnBuffer<Int64>`, `ColumnBuffer<Double>`,
    /// `ColumnBuffer<Bool>`, `ColumnBuffer<String>` or `BytesColumn`.
    ///
    /// This is what lets the macro emit one uniform line for a type it cannot inspect.
    associatedtype Column: ColumnStorage

    /// Build the value for one row. Called per row and NOT through a witness table: the
    /// macro names this type concretely in the module that declares the schema.
    ///
    /// `metadata` is `column.metadata`, passed separately so the common case reads it
    /// without touching the column.
    init?(assayColumn column: borrowing Column, row: Int, metadata: ColumnMetadata)
}

/// The one column fetch the macro emits, for any `ColumnDecodable` field.
///
/// A free function rather than `T.Column._assayFetch(...)` written inline, because of what
/// it does to the error when the type does NOT conform. Spelling `T.Column` directly
/// produces "'Column' is not a member type of struct 'Timestamp'", which names neither the
/// protocol nor the fix; this produces "requires that 'Timestamp' conform to
/// 'ColumnDecodable'", which names both.
@inlinable
public func _assayFetchColumn<T: ColumnDecodable, S: ColumnarSource & ~Copyable>(
    _: T.Type, from source: borrowing S, _ key: StaticString, _ field: Int
) -> T.Column? {
    T.Column._assayFetch(from: source, key, field)
}

// NO `extension Array: ColumnDecodable where Element == UInt8`, deliberately.
//
// It would compile and it would be unreachable. `UInt8` is not a scalar on the tree path,
// so `var payload: [UInt8]` cannot appear in ANY `@Schema` type -- the JSON body fails with
// "type 'UInt8' has no member '_assay'" long before the columnar body is consulted. A
// conformance here would be a road to a bricked-up door.
//
// Binary data reaches a schema through a consumer type whose `Column` is `BytesColumn`,
// which is what the bytes column is for. Making `[UInt8]` itself a field type means adding
// the small integer widths to the tree path, the encoder and the rule engine -- six files
// and a set of range-checked primitives -- and that is a separate change with its own tests.
// `ROADMAP.md` carries it.
