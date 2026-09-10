// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A typed row-to-column accumulator. docs/ROWS.md.
//
// THE PROBLEM IT SOLVES. Assay's fast structured seam is `ColumnarSource`: one array per
// field, one batch decode, ~10 ns/row. Parquet and Arrow arrive that way. Everything else
// arrives as ROWS — a SQL result set, a CSV record, an Excel row, an NDJSON line — and a
// row-shaped source had two choices: build a `RawValue.mapping` per row and take the tree
// path (~95 ns/row), or write its own transpose. This is the transpose, written once.
//
// WHY THIS AND NOT A ROW PROTOCOL. `KeyedSource` — decode one record at a time through a
// protocol the source conforms to — was built, measured and removed (docs/KEYED-SOURCE.md).
// Its per-row calls went OUT of a generic decode body through a witness table, 1.6–4.7x in a
// driver, and it could not hold a borrowed row. The lesson is about direction: here the
// per-cell calls go INTO a concrete struct (`append` on `RowBatch` is a direct call the
// caller's module can inline), and the decode happens once per batch through the existing
// `_assayBatch`. Nothing in this file knows what SQL, CSV or Excel are.
//
// STORAGE, and the one rule that keeps it fast. There is no enum-with-payload per field:
// `case .int64(var a): a.append(v); storage[f] = .int64(a)` copies the array on EVERY
// append, because copy-on-write sees two references during the mutation. Instead each
// kind has one array of columns (`ints: [[Int64]]`, …) and a field maps to a slot in it;
// `ints[slot].append(v)` mutates in place through `Array`'s accessor. An `append` is a
// bounds check, two array reads and one array append.
//
// TYPED, NOT CONVERTING. A cell is stored as what the source said it was. A text cell
// appended to an `Int` field is dropped and counted, so the batch reports `missing_column
// (expected int)` once — and the schema's `coerceScalars` / `@Coerce` policy, generated
// into the batch body, is where text becomes a number. The policy stays the schema's.
//
// NULLS AND SHORT ROWS follow Arrow's model: values are dense, a validity mask says which
// rows are null, and the mask exists only once a null has been seen. A row that never
// touched a field gets a null there when the next row begins, so a ragged row is MISSING
// for that field rather than a misaligned column for every row after it.
//===----------------------------------------------------------------------===//

/// A batch of rows accumulated into typed columns, decodable by `T.batch(from:)`.
///
/// Bind once with the source's column names (or a positional `BoundPlan`), then per row:
/// `beginRow()`, one `append` per cell in the source's own column order, and when the batch
/// is full, hand it to `batch(from:)`. `RowDecoder<T>` wraps this with chunking and global
/// row numbers; use it unless you need the buffer itself.
public struct RowBatch: ColumnarSource, Sendable {

    /// The storage kind a field's column holds. Fixed by the manifest for the built-in
    /// kinds; decided by the first cell appended for a `.custom` field.
    @usableFromInline
    enum Kind: UInt8, Sendable { case undecided, int64, double, bool, string, bytes }

    /// Per manifest field, in ONE array: an append reads one element of it, not one element
    /// of each of six. `slot` indexes the kind's column array below.
    @usableFromInline
    struct FieldState: Sendable {
        @usableFromInline var kind: Kind
        @usableFromInline var slot: Int32
        /// Cells appended at a kind the field cannot hold: a wiring mistake in the driver,
        /// or text offered to a numeric field. Any rejection invalidates the column.
        @usableFromInline var rejected: Int32
        /// Whether any source column feeds this field. An unbound field serves no column
        /// — `nil`, so the decode reports `missing_column` — rather than an empty one.
        @usableFromInline var bound: Bool
        @usableFromInline init(kind: Kind, bound: Bool) {
            self.kind = kind; slot = -1; rejected = 0; self.bound = bound
        }
    }
    @usableFromInline var fields: [FieldState]
    @usableFromInline var nullMask: [[Bool]?]
    @usableFromInline var metadata: [ColumnMetadata]

    /// Which fields the open row has a cell for — a bit per field, so "exactly one cell per
    /// field per row" is one AND and one OR rather than a counter per field. Fields past
    /// the 64th use `overflowFilled`; a manifest that wide is rare and pays a little more.
    @usableFromInline var touched: UInt64 = 0
    @usableFromInline var overflowFilled: [Int]

    /// Per SOURCE column: the manifest field it feeds, or -1.
    @usableFromInline let fieldOf: [Int32]

    // The columns, by kind.
    @usableFromInline var ints: [[Int64]] = []
    @usableFromInline var doubles: [[Double]] = []
    @usableFromInline var bools: [[Bool]] = []
    @usableFromInline var strings: [[String]] = []
    @usableFromInline var byteBlobs: [[UInt8]] = []
    @usableFromInline var byteOffsets: [[Int]] = []

    @usableFromInline var completedRows: Int = 0
    @usableFromInline var rowOpen: Bool = false
    @usableFromInline let capacity: Int

    /// Bind by name: `columns` in the source's order, resolved against the manifest once.
    public init(manifest: FieldManifest, columns: [String], capacity: Int = 4096) {
        self.init(manifest: manifest, plan: BoundPlan(manifest: manifest, columns: columns),
                  capacity: capacity)
    }

    /// Bind by position: the source's column `i` feeds manifest field `f` where
    /// `plan[f] == i`. `BoundPlan(slots: Array(0..<n))` when the columns ARE the manifest.
    public init(manifest: FieldManifest, plan: BoundPlan, capacity: Int = 4096) {
        let n = manifest.fields.count
        self.capacity = Swift.max(capacity, 1)
        var kinds: [Kind] = []
        kinds.reserveCapacity(n)
        for f in manifest.fields {
            switch f.kind {
            case .int, .int64, .int32, .uint, .int8, .int16, .uint8, .uint16, .uint32, .uint64:
                kinds.append(.int64)
            case .double, .float: kinds.append(.double)
            case .bool: kinds.append(.bool)
            case .string: kinds.append(.string)
            case .bytes: kinds.append(.bytes)
            case .custom: kinds.append(.undecided)
            }
        }
        self.fields = kinds.enumerated().map { FieldState(kind: $1, bound: plan[$0] >= 0) }
        self.nullMask = [[Bool]?](repeating: nil, count: n)
        self.metadata = [ColumnMetadata](repeating: .none, count: n)
        self.overflowFilled = n > 64 ? [Int](repeating: 0, count: n - 64) : []
        // Invert the plan: field -> source column becomes source column -> field. The
        // widest source column any field binds to sizes the table; a column past it is
        // simply unbound.
        var width = 0
        for f in 0..<n where plan[f] >= 0 { width = Swift.max(width, plan[f] + 1) }
        var inverse = [Int32](repeating: -1, count: width)
        for f in 0..<n where plan[f] >= 0 { inverse[plan[f]] = Int32(f) }
        self.fieldOf = inverse
        for f in 0..<n where kinds[f] != .undecided { allocate(f, kinds[f]) }
    }

    /// How many cells field `f` has, counting the open row's.
    @inlinable
    func filledCount(_ f: Int) -> Int {
        completedRows + (isTouched(f) ? 1 : 0)
    }

    @inlinable
    func isTouched(_ f: Int) -> Bool {
        f < 64 ? touched & (1 << UInt64(f)) != 0 : overflowFilled[f - 64] > completedRows
    }

    @inlinable
    mutating func touch(_ f: Int) {
        if f < 64 { touched |= 1 << UInt64(f) } else { overflowFilled[f - 64] = completedRows + 1 }
    }

    /// Give field `f` a column of kind `k`. Called at init for the built-in kinds and on
    /// first append for a `.custom` field — which may already have seen nulls, so the new
    /// column is back-filled with placeholders to keep it dense and aligned.
    @usableFromInline
    mutating func allocate(_ f: Int, _ k: Kind) {
        fields[f].kind = k
        let behind = filledCount(f)
        switch k {
        case .int64:
            fields[f].slot = Int32(ints.count)
            ints.append([Int64](repeating: 0, count: behind))
            ints[ints.count - 1].reserveCapacity(capacity)
        case .double:
            fields[f].slot = Int32(doubles.count)
            doubles.append([Double](repeating: 0, count: behind))
            doubles[doubles.count - 1].reserveCapacity(capacity)
        case .bool:
            fields[f].slot = Int32(bools.count)
            bools.append([Bool](repeating: false, count: behind))
            bools[bools.count - 1].reserveCapacity(capacity)
        case .string:
            fields[f].slot = Int32(strings.count)
            strings.append([String](repeating: "", count: behind))
            strings[strings.count - 1].reserveCapacity(capacity)
        case .bytes:
            fields[f].slot = Int32(byteBlobs.count)
            byteBlobs.append([])
            byteOffsets.append([Int](repeating: 0, count: behind + 1))
            byteOffsets[byteOffsets.count - 1].reserveCapacity(capacity + 1)
        case .undecided:
            break
        }
    }

    /// The row this cell belongs to must be the open one, exactly once per field: a second
    /// cell for the same field in one row, or a cell with no `beginRow()`, would shift
    /// every later row of that column. Refused as a rejected cell instead.
    @inlinable
    func inRow(_ f: Int) -> Bool { rowOpen && !isTouched(f) }

    // MARK: Rows

    /// Completed rows. The row being built is not counted until the next `beginRow()` or
    /// `finishRow()`.
    public var rowCount: Int { completedRows }

    /// Start a row, finishing the previous one if it is still open.
    @inlinable
    public mutating func beginRow() {
        if rowOpen { finishRow() }
        rowOpen = true
    }

    /// Finish the open row: any field it did not touch gets a null. Idempotent.
    @inlinable
    public mutating func finishRow() {
        guard rowOpen else { return }
        // The common case — every field touched — is one compare and no loop.
        if fields.count <= 64 && touched == (fields.count == 64 ? .max : (1 << UInt64(fields.count)) - 1) {
            completedRows += 1
            touched = 0
            rowOpen = false
            return
        }
        backfill()
    }

    /// The uncommon case: a ragged row. Cold.
    @inline(never)
    @usableFromInline
    mutating func backfill() {
        for f in 0..<fields.count where !isTouched(f) {
            appendNull(field: f)
        }
        completedRows += 1
        touched = 0
        rowOpen = false
    }

    /// Cells that arrived at a kind their field cannot hold, by manifest field — a wiring
    /// mistake in the driver, or text offered to a numeric field without `coerceScalars`.
    public var rejectedCells: [Int] { fields.map { Int($0.rejected) } }

    /// Empty the batch for reuse. Column storage is kept, so a steady-state reader
    /// allocates nothing per batch.
    public mutating func removeAll(keepingCapacity: Bool = true) {
        for i in ints.indices { ints[i].removeAll(keepingCapacity: keepingCapacity) }
        for i in doubles.indices { doubles[i].removeAll(keepingCapacity: keepingCapacity) }
        for i in bools.indices { bools[i].removeAll(keepingCapacity: keepingCapacity) }
        for i in strings.indices { strings[i].removeAll(keepingCapacity: keepingCapacity) }
        for i in byteBlobs.indices {
            byteBlobs[i].removeAll(keepingCapacity: keepingCapacity)
            byteOffsets[i].removeAll(keepingCapacity: keepingCapacity)
            byteOffsets[i].append(0)
        }
        for f in nullMask.indices { nullMask[f] = nil }
        for f in fields.indices { fields[f].rejected = 0 }
        for i in overflowFilled.indices { overflowFilled[i] = 0 }
        touched = 0
        completedRows = 0
        rowOpen = false
    }

    // MARK: Cells, by SOURCE column

    /// The field a source column feeds, or nil for an unbound column.
    @inlinable
    func field(_ column: Int) -> Int? {
        guard column >= 0, column < fieldOf.count else { return nil }
        let f = fieldOf[column]
        return f >= 0 ? Int(f) : nil
    }

    @inlinable
    public mutating func append(int64 v: Int64, column: Int) {
        guard let f = field(column) else { return }
        if fields[f].kind == .undecided { allocate(f, .int64) }
        guard fields[f].kind == .int64, inRow(f) else { reject(f); return }
        ints[Int(fields[f].slot)].append(v)
        touch(f)
    }

    @inlinable
    public mutating func append(double v: Double, column: Int) {
        guard let f = field(column) else { return }
        if fields[f].kind == .undecided { allocate(f, .double) }
        guard fields[f].kind == .double, inRow(f) else { reject(f); return }
        doubles[Int(fields[f].slot)].append(v)
        touch(f)
    }

    @inlinable
    public mutating func append(bool v: Bool, column: Int) {
        guard let f = field(column) else { return }
        if fields[f].kind == .undecided { allocate(f, .bool) }
        guard fields[f].kind == .bool, inRow(f) else { reject(f); return }
        bools[Int(fields[f].slot)].append(v)
        touch(f)
    }

    @inlinable
    public mutating func append(string v: String, column: Int) {
        guard let f = field(column) else { return }
        if fields[f].kind == .undecided { allocate(f, .string) }
        guard fields[f].kind == .string, inRow(f) else { reject(f); return }
        strings[Int(fields[f].slot)].append(v)
        touch(f)
    }

    /// Text as bytes — a CSV field, a text-format wire value. Becomes a `String`.
    @inlinable
    public mutating func append<C: Collection<UInt8>>(text v: C, column: Int) {
        append(string: String(decoding: v, as: UTF8.self), column: column)
    }

    /// A binary cell, stored flat with offsets (`BytesColumn`'s layout) — no array per row.
    @inlinable
    public mutating func append<C: Collection<UInt8>>(bytes v: C, column: Int) {
        guard let f = field(column) else { return }
        if fields[f].kind == .undecided { allocate(f, .bytes) }
        guard fields[f].kind == .bytes, inRow(f) else { reject(f); return }
        let s = Int(fields[f].slot)
        byteBlobs[s].append(contentsOf: v)
        byteOffsets[s].append(byteBlobs[s].count)
        touch(f)
    }

    @inlinable
    public mutating func appendNull(column: Int) {
        guard let f = field(column), inRow(f) else { if let f = field(column) { reject(f) }; return }
        appendNull(field: f)
    }

    /// A null for manifest field `f`: a placeholder value keeps the column dense, and the
    /// mask — created now if this is the first null — marks the row.
    @usableFromInline
    mutating func appendNull(field f: Int) {
        let row = filledCount(f)
        let s = Int(fields[f].slot)
        switch fields[f].kind {
        case .int64: ints[s].append(0)
        case .double: doubles[s].append(0)
        case .bool: bools[s].append(false)
        case .string: strings[s].append("")
        case .bytes: byteOffsets[s].append(byteBlobs[s].count)
        case .undecided:
            // No kind yet and nothing to store: the mask records the null, and when the
            // kind is decided `allocate` back-fills placeholders up to here.
            break
        }
        // The mask is only as long as the last null: `_assayIsNullAt` treats rows past
        // its end as present. So pad it with `false` up to this row, then mark the row.
        if nullMask[f] == nil { nullMask[f] = [] }
        let short = row - nullMask[f]!.count
        if short > 0 { nullMask[f]!.append(contentsOf: repeatElement(false, count: short)) }
        nullMask[f]!.append(true)
        touch(f)
    }

    /// A cell of the wrong kind, or a second cell for the field in one row: dropped, and
    /// the field's column is invalidated for the batch, so the decode reports one missing
    /// column rather than a misaligned one. Cold.
    @inline(never)
    @usableFromInline
    mutating func reject(_ f: Int) {
        fields[f].rejected &+= 1
    }

    /// Per-column facts the source knows and the schema must not bake in: a timestamp's
    /// unit, a decimal's scale. Set once per batch; `ColumnMetadata` is read per column.
    public mutating func setMetadata(_ m: ColumnMetadata, column: Int) {
        guard let f = field(column) else { return }
        metadata[f] = m
    }

    // MARK: ColumnarSource

    /// Whether field `f` is served at all: its kind matches, and no cell was rejected
    /// (a rejected cell would leave the column one short, and a short column decodes as
    /// a row-level `missing` for every row after it — the wrong report for a wiring error).
    @inlinable
    func serves(_ f: Int, _ k: Kind) -> Bool {
        f >= 0 && f < fields.count && fields[f].bound && fields[f].kind == k && fields[f].rejected == 0
    }

    public borrowing func int64Column(_ key: StaticString, _ field: Int) -> [Int64]? {
        serves(field, .int64) ? ints[Int(fields[field].slot)] : nil
    }
    public borrowing func doubleColumn(_ key: StaticString, _ field: Int) -> [Double]? {
        serves(field, .double) ? doubles[Int(fields[field].slot)] : nil
    }
    public borrowing func boolColumn(_ key: StaticString, _ field: Int) -> [Bool]? {
        serves(field, .bool) ? bools[Int(fields[field].slot)] : nil
    }
    public borrowing func stringColumn(_ key: StaticString, _ field: Int) -> [String]? {
        serves(field, .string) ? strings[Int(fields[field].slot)] : nil
    }
    public borrowing func bytesColumn(_ key: StaticString, _ field: Int) -> BytesColumn? {
        guard serves(field, .bytes) else { return nil }
        let s = Int(fields[field].slot)
        return BytesColumn(bytes: byteBlobs[s], offsets: byteOffsets[s],
                           nulls: nullMask[field], metadata: metadata[field])
    }
    public borrowing func nulls(_ key: StaticString, _ field: Int) -> [Bool]? {
        field >= 0 && field < nullMask.count ? nullMask[field] : nil
    }
    public borrowing func columnMetadata(_ key: StaticString, _ field: Int) -> ColumnMetadata {
        field >= 0 && field < metadata.count ? metadata[field] : .none
    }
}
