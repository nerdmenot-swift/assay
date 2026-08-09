// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The third decode path: a source that is ALREADY PARSED and addressable by key.
// docs/KEYED-SOURCE.md.
//
// Database rows, CSV records, property lists, `[String: Any]`, form data and environment
// blocks are all the same shape — fields already separated, addressable by name, and
// nothing tree-shaped. Reaching them today means building a `RawValue` first, which costs
// an allocation per value per record and throws away the source's own layout. A reader
// doing millions of rows cannot pay that.
//
// `~Copyable` and NOT `~Escapable`, deliberately: `AssayReader` already refused
// `~Escapable` in the public surface because `@_lifetime` is still an experimental feature
// and would gate the whole library on one. The protocol is shaped so the constraint can be
// added later without a source break — the same bet already placed there, not a new one.
//===----------------------------------------------------------------------===//

/// A source of already-parsed, key-addressable fields.
///
/// **Every accessor receives both the key and the field's INDEX in the type's
/// `FieldManifest`.** That pair is what makes two-phase binding possible without a second
/// protocol: an *unbound* source ignores the index and looks the key up; a *bound* source
/// ignores the key and indexes a plan it resolved once for the whole stream. The macro
/// knows the index at compile time, so it costs the caller nothing to pass.
///
/// Accessors are `borrowing` and return optionals rather than throwing: a `nil` means "this
/// source cannot give you that", and the decoder decides whether that is a missing field, a
/// null, or a type mismatch by asking `has` and `isNull`. That split is what lets one
/// protocol serve a database row (where null is a first-class value) and an environment
/// block (where it is not).
public protocol KeyedSource: ~Copyable {

    /// Whether the key exists at all. Absence and null are different things —
    /// `EXPERIENCE.md` §6's five presence states depend on the distinction.
    borrowing func has(_ key: StaticString, _ field: Int) -> Bool

    /// Whether the key exists and holds a null.
    borrowing func isNull(_ key: StaticString, _ field: Int) -> Bool

    borrowing func int64(_ key: StaticString, _ field: Int) -> Int64?
    borrowing func double(_ key: StaticString, _ field: Int) -> Double?
    borrowing func bool(_ key: StaticString, _ field: Int) -> Bool?

    /// Text, without requiring a `String` to exist.
    ///
    /// The callback shape is the point: a source over a byte buffer hands out a borrowed
    /// range and allocates nothing, and only a field actually declared `String` ever
    /// materialises one. A source that already holds `String`s implements it in two lines.
    borrowing func withText<R>(
        _ key: StaticString, _ field: Int, _ body: (UnsafeRawBufferPointer?) -> R
    ) -> R

    /// Text as a `String`.
    ///
    /// Defaulted via `withText`, so a byte-backed source implements only that one. **A
    /// source that already holds `String`s must implement this instead**: the default
    /// costs it a full copy per string field (`String` → bytes → `String`), and
    /// measurement put that copy at most of the third path's cost against the `RawValue`
    /// path — which simply hands back the `String` it is already holding. Most
    /// already-parsed sources are in that second category, so this is the requirement
    /// that decides whether the path is worth using.
    borrowing func string(_ key: StaticString, _ field: Int) -> String?

    /// Where this field came from, if the source can say. Sources that cannot return `nil`
    /// and get position-free diagnostics, which the renderer has always handled.
    borrowing func span(_ key: StaticString, _ field: Int) -> SourceSpan?
}

extension KeyedSource where Self: ~Copyable {
    /// Default: `nil`, so a source that has no notion of position says so once.
    public borrowing func span(_ key: StaticString, _ field: Int) -> SourceSpan? { nil }

    /// The byte-backed default. Correct for any source, and a full copy for one that is
    /// already holding a `String` — those should implement `string` directly.
    public borrowing func string(_ key: StaticString, _ field: Int) -> String? {
        withText(key, field) { buf in
            guard let buf, let base = buf.baseAddress else { return nil }
            return unsafe String(decoding: UnsafeRawBufferPointer(start: base,
                                                                  count: buf.count),
                                 as: UTF8.self)
        }
    }

    /// Historical spelling, kept as a convenience for callers.
    public borrowing func text(_ key: StaticString, _ field: Int) -> String? {
        string(key, field)
    }
}

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
        /// A nested `@Schema` type, named. Not decodable from a flat source in the first
        /// increment; present so a binder can see it and refuse.
        case nested(String)
    }

    public let fields: [Field]
    public init(fields: [Field]) { self.fields = fields }

    /// Keys in declaration order — what a binder resolves once per stream.
    public var keys: [String] { fields.map(\.key) }
}

// MARK: - Per-field accessors generated code calls
//
// One line per field in the expansion, everything conditional here — the same discipline
// the JSON and RawValue bodies follow (docs/COMPILE-TIME.md §3).

/// Absent, or null where null is not allowed, or the wrong type: the three ways a field
/// fails, reported the way every other path reports them.
@inline(never)
public func _assaySourceMissing(
    _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
    _ span: SourceSpan?
) {
    sink.add(Issue(code: .missing, path: path + [.key(String(describing: key))],
                   location: span))
}

@inline(never)
public func _assaySourceMismatch(
    _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
    _ expected: String, _ span: SourceSpan?
) {
    sink.add(Issue(code: .typeMismatch,
                   path: path + [.key(String(describing: key))],
                   params: ["expected": .string(expected)],
                   location: span))
}

/// Classify a field the value accessor could not produce: absent, null, or the wrong
/// Classify a field the value accessor could not produce: absent, null, or the wrong
/// type. Cold — reached only when a field is missing or malformed, never on a good record.
@inline(never)
@usableFromInline
func _assaySourceFailed<S: KeyedSource & ~Copyable, T>(
    _ s: borrowing S, _ key: StaticString, _ field: Int, _ sink: inout IssueSink,
    _ path: [PathComponent], _ expected: String, optional: Bool, hasDefault: Bool
) -> T?? {
    if !s.has(key, field) {
        if optional { return .some(nil) }
        if hasDefault { return nil }
        _assaySourceMissing(&sink, path, key, nil)
        return nil
    }
    if s.isNull(key, field) {
        if optional { return .some(nil) }
        _assaySourceMismatch(&sink, path, key, expected, s.span(key, field))
        return nil
    }
    _assaySourceMismatch(&sink, path, key, expected, s.span(key, field))
    return nil
}

// Every accessor has the same shape, and the shape is what the first benchmark corrected.
//
// It originally asked `has`, then `isNull`, then the value — THREE lookups per field,
// which on a linear-scanning row source meant three scans. Now the value accessor runs
// first and the other two only classify a failure, so a good record costs one lookup per
// field and a bad one pays for its diagnosis. Measured at 2.3x on an eight-field row.

@inlinable
public func _assaySourceString<S: KeyedSource & ~Copyable>(
    _ s: borrowing S, _ key: StaticString, _ field: Int, _ sink: inout IssueSink,
    _ path: [PathComponent], optional: Bool, hasDefault: Bool
) -> String?? {
    if let v = s.string(key, field) { return .some(v) }
    return _assaySourceFailed(s, key, field, &sink, path, "string",
                              optional: optional, hasDefault: hasDefault)
}

@inlinable
public func _assaySourceInt64<S: KeyedSource & ~Copyable>(
    _ s: borrowing S, _ key: StaticString, _ field: Int, _ sink: inout IssueSink,
    _ path: [PathComponent], optional: Bool, hasDefault: Bool
) -> Int64?? {
    if let v = s.int64(key, field) { return .some(v) }
    return _assaySourceFailed(s, key, field, &sink, path, "integer",
                              optional: optional, hasDefault: hasDefault)
}

@inlinable
public func _assaySourceDouble<S: KeyedSource & ~Copyable>(
    _ s: borrowing S, _ key: StaticString, _ field: Int, _ sink: inout IssueSink,
    _ path: [PathComponent], optional: Bool, hasDefault: Bool
) -> Double?? {
    if let v = s.double(key, field) { return .some(v) }
    return _assaySourceFailed(s, key, field, &sink, path, "number",
                              optional: optional, hasDefault: hasDefault)
}

@inlinable
public func _assaySourceBool<S: KeyedSource & ~Copyable>(
    _ s: borrowing S, _ key: StaticString, _ field: Int, _ sink: inout IssueSink,
    _ path: [PathComponent], optional: Bool, hasDefault: Bool
) -> Bool?? {
    if let v = s.bool(key, field) { return .some(v) }
    return _assaySourceFailed(s, key, field, &sink, path, "boolean",
                              optional: optional, hasDefault: hasDefault)
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

    /// Which rows of this column are null, or `nil` when none are — the validity mask.
    borrowing func nulls(_ key: StaticString, _ field: Int) -> [Bool]?
}

extension ColumnarSource where Self: ~Copyable {
    public borrowing func nulls(_ key: StaticString, _ field: Int) -> [Bool]? { nil }
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

/// Whether row `r` of a column is null, given its optional validity mask.
@inlinable
public func _assayIsNullAt(_ mask: [Bool]?, _ r: Int) -> Bool {
    guard let mask, r < mask.count else { return false }
    return mask[r]
}
