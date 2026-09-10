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
// STORAGE, and the two rules that keep it fast. No enum-with-payload per field:
// `case .int64(var a): a.append(v); storage[f] = .int64(a)` copies the array on EVERY
// append, because copy-on-write sees two references during the mutation. And no nested
// `[[Int64]]` either: that spelling paid two copy-on-write checks per cell — the outer
// array's `_modify` and the inner append's — and the outer one is a runtime call. Each
// column is a boxed array reached through a reference; the batch is `~Copyable` so that
// reference is never shared. An `append` is a bounds check, two loads, one array append.
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
/// `@unchecked Sendable`: the batch owns class-backed column tables and reaches them
/// through `Unmanaged`, neither of which the compiler can check — but the batch is
/// `~Copyable`, so exactly one owner ever holds them, and sending it moves that ownership.
@safe public struct RowBatch: ColumnarSource, ~Copyable, @unchecked Sendable {

    /// The columns of one kind, as `[T]` values in tail-allocated slots. This shape is the
    /// result of measuring three others on the 8-column row, and the profile is the record:
    ///   * `[[T]]` — every append paid TWO copy-on-write checks, the outer array's `_modify`
    ///     and the inner append's; the outer one is a runtime call per cell (40 ns/row).
    ///   * a class per column — mutating a class's stored property is DYNAMIC exclusivity
    ///     enforcement, `swift_beginAccess`/`endAccess` and a TLS lookup per cell, 40% of
    ///     the profile (60 ns/row). CLAUDE.md rule 3, met on the way in for once.
    ///   * class refs read out of an array — a retain/release pair per cell on top.
    /// Here the slot is reached through a pointer (no exclusivity, no outer copy-on-write)
    /// and `Unmanaged` (no retain), and the inner `append` pays the one uniqueness check a
    /// hand-written transpose also pays. The `[T]` hands off to the decode with no copy.
    @usableFromInline
    final class ColumnTable<T>: ManagedBuffer<Int, [T]> {
        @usableFromInline
        static func make(slots: Int) -> ColumnTable<T> {
            let t = ColumnTable<T>.create(minimumCapacity: slots) { _ in 0 } as! ColumnTable<T>
            unsafe t.withUnsafeMutablePointerToElements { unsafe $0.initialize(repeating: [], count: slots) }
            t.header = slots
            return t
        }
        deinit {
            let n = header
            _ = unsafe withUnsafeMutablePointerToElements { unsafe $0.deinitialize(count: n) }
        }
        /// The slots. Valid for as long as this object is — which `RowBatch` guarantees by
        /// owning it for as long as it holds the pointer.
        var elements: UnsafeMutablePointer<[T]> {
            unsafe withUnsafeMutablePointerToElements { unsafe $0 }
        }
        /// The slot, for the cold paths. Pointer access: no exclusivity bookkeeping.
        @inlinable @inline(__always)
        func with<R>(_ slot: Int, _ body: (inout [T]) -> R) -> R {
            unsafe withUnsafeMutablePointerToElements { unsafe body(&$0[slot]) }
        }
    }

    /// The storage kind a field's column holds. Fixed by the manifest for the built-in
    /// kinds; decided by the first cell appended for a `.custom` field.
    @usableFromInline
    enum Kind: UInt8, Sendable { case undecided, int64, double, bool, string, bytes, unbound }

    /// Per manifest field, in ONE array: an append reads one element of it, not one element
    /// of each of six. `slot` indexes the kind's column table below.
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

    /// Per SOURCE column, what an append needs — the field, and a copy of its kind and
    /// slot — so the hot path does one bounds-checked load, not two. `field` is -1 for an
    /// unbound column. Kept in step with `fields[field]` by `allocate`.
    @safe @usableFromInline
    struct ColumnState: @unchecked Sendable {
        @usableFromInline var field: Int32
        @usableFromInline var kind: Kind
        /// The `[T]` this column appends to — the tail-allocated slot itself, so the hot
        /// path is `self → columns → slot → array`, one hop shorter than an index.
        @unsafe @usableFromInline var slot: UnsafeMutableRawPointer?
        @usableFromInline init(field: Int32, kind: Kind, slot: UnsafeMutableRawPointer?) {
            self.field = field; self.kind = kind; unsafe self.slot = slot
        }
    }
    @usableFromInline var columns: [ColumnState]

    // PRESENCE IS DERIVED, NOT TRACKED. Field `f` has a cell in the open row exactly when
    // its column is one longer than `completedRows`; nothing is written per cell but the
    // cell. A per-cell bitmask was tried and measured: a read-modify-write on `self`
    // through memory serialises consecutive cells on store forwarding, and that alone was
    // ~12 ns/row. `finishRow` reads eight lengths instead, independently.
    /// Nulls seen by an `.undecided` field, which has no column yet to be long.
    @usableFromInline var pendingNulls: [Int]

    // The columns, by kind: one table each with a slot per field (at most `fields.count`
    // of any kind), owned strongly here and reached per cell through the `Unmanaged`
    // beside it — a class reference read from a stored property is retained and released,
    // and that pair costs more than the append. `slotsUsed` is how many slots of each
    // table a field has claimed.
    @usableFromInline let ints: ColumnTable<Int64>
    @usableFromInline let doubles: ColumnTable<Double>
    @usableFromInline let bools: ColumnTable<Bool>
    @usableFromInline let strings: ColumnTable<String>
    @usableFromInline let blobBytes: ColumnTable<UInt8>
    @usableFromInline let blobOffsets: ColumnTable<Int>
    // The slots themselves, as pointers taken once: a tail-allocated element never moves
    // for the life of its buffer, and the buffers above live as long as the batch. An
    // append is then `intSlots[slot].append(v)` — no closure (a closure capturing the
    // value retained and released it per cell, 4 strings × 200k rows was 40% of the fill),
    // no exclusivity bookkeeping, no copy-on-write check on the table.
    @unsafe @usableFromInline let intSlots: UnsafeMutablePointer<[Int64]>
    @unsafe @usableFromInline let doubleSlots: UnsafeMutablePointer<[Double]>
    @unsafe @usableFromInline let boolSlots: UnsafeMutablePointer<[Bool]>
    @unsafe @usableFromInline let stringSlots: UnsafeMutablePointer<[String]>
    @unsafe @usableFromInline let blobByteSlots: UnsafeMutablePointer<[UInt8]>
    @unsafe @usableFromInline let blobOffsetSlots: UnsafeMutablePointer<[Int]>
    @usableFromInline var slotsUsed: (ints: Int, doubles: Int, bools: Int, strings: Int, blobs: Int) = (0, 0, 0, 0, 0)

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
        self.pendingNulls = [Int](repeating: 0, count: n)
        let slots = Swift.max(n, 1)
        ints = .make(slots: slots); unsafe intSlots = ints.elements
        doubles = .make(slots: slots); unsafe doubleSlots = doubles.elements
        bools = .make(slots: slots); unsafe boolSlots = bools.elements
        strings = .make(slots: slots); unsafe stringSlots = strings.elements
        blobBytes = .make(slots: slots); unsafe blobByteSlots = blobBytes.elements
        blobOffsets = .make(slots: slots); unsafe blobOffsetSlots = blobOffsets.elements
        self.nullMask = [[Bool]?](repeating: nil, count: n)
        self.metadata = [ColumnMetadata](repeating: .none, count: n)
        // Invert the plan: field -> source column becomes source column -> field. The
        // widest source column any field binds to sizes the table; a column past it is
        // simply unbound.
        var width = 0
        for f in 0..<n where plan[f] >= 0 { width = Swift.max(width, plan[f] + 1) }
        var inverse = unsafe [ColumnState](repeating: ColumnState(field: -1, kind: .unbound, slot: nil), count: width)
        for f in 0..<n where plan[f] >= 0 { unsafe inverse[plan[f]] = ColumnState(field: Int32(f), kind: kinds[f], slot: nil) }
        self.columns = inverse
        for f in 0..<n where kinds[f] != .undecided { allocate(f, kinds[f]) }
    }

    /// How many cells field `f` has, counting the open row's: its column's length, or
    /// for a field with no column yet, the nulls it has seen.
    @usableFromInline
    func filledCount(_ f: Int) -> Int {
        let s = Int(fields[f].slot)
        switch fields[f].kind {
        case .int64: return unsafe intSlots[s].count
        case .double: return unsafe doubleSlots[s].count
        case .bool: return unsafe boolSlots[s].count
        case .string: return unsafe stringSlots[s].count
        case .bytes: return unsafe blobOffsetSlots[s].count - 1
        case .undecided, .unbound: return pendingNulls[f]
        }
    }

    @usableFromInline
    func isTouched(_ f: Int) -> Bool { filledCount(f) > completedRows }

    /// Give field `f` a column of kind `k`. Called at init for the built-in kinds and on
    /// first append for a `.custom` field — which may already have seen nulls, so the new
    /// column is back-filled with placeholders to keep it dense and aligned.
    @usableFromInline
    mutating func allocate(_ f: Int, _ k: Kind) {
        // Nulls seen while the field was undecided, to back-fill. At init the kind is
        // already set from the manifest and no slot exists yet, so this must not read one.
        let behind = fields[f].kind == .undecided ? pendingNulls[f] : 0
        fields[f].kind = k
        switch k {
        case .int64:
            fields[f].slot = Int32(slotsUsed.ints); slotsUsed.ints += 1
            ints.with(Int(fields[f].slot)) { $0 = [Int64](repeating: 0, count: behind); $0.reserveCapacity(capacity) }
        case .double:
            fields[f].slot = Int32(slotsUsed.doubles); slotsUsed.doubles += 1
            doubles.with(Int(fields[f].slot)) { $0 = [Double](repeating: 0, count: behind); $0.reserveCapacity(capacity) }
        case .bool:
            fields[f].slot = Int32(slotsUsed.bools); slotsUsed.bools += 1
            bools.with(Int(fields[f].slot)) { $0 = [Bool](repeating: false, count: behind); $0.reserveCapacity(capacity) }
        case .string:
            fields[f].slot = Int32(slotsUsed.strings); slotsUsed.strings += 1
            strings.with(Int(fields[f].slot)) { $0 = [String](repeating: "", count: behind); $0.reserveCapacity(capacity) }
        case .bytes:
            fields[f].slot = Int32(slotsUsed.blobs); slotsUsed.blobs += 1
            blobOffsets.with(Int(fields[f].slot)) { $0 = [Int](repeating: 0, count: behind + 1); $0.reserveCapacity(capacity + 1) }
        case .undecided, .unbound:
            break
        }
        let slot = Int(fields[f].slot)
        let pointer: UnsafeMutableRawPointer?
        switch k {
        case .int64: unsafe pointer = UnsafeMutableRawPointer(intSlots + slot)
        case .double: unsafe pointer = UnsafeMutableRawPointer(doubleSlots + slot)
        case .bool: unsafe pointer = UnsafeMutableRawPointer(boolSlots + slot)
        case .string: unsafe pointer = UnsafeMutableRawPointer(stringSlots + slot)
        case .bytes: unsafe pointer = UnsafeMutableRawPointer(blobByteSlots + slot)
        case .undecided, .unbound: unsafe pointer = nil
        }
        for c in columns.indices where columns[c].field == Int32(f) {
            columns[c].kind = k
            unsafe columns[c].slot = pointer
        }
    }

    // MARK: Rows

    /// Completed rows. The row being built is not counted until the next `beginRow()` or
    /// `finishRow()`.
    public var rowCount: Int { completedRows }

    /// Whether a row is being built — begun and not yet finished.
    @inlinable public var isRowOpen: Bool { rowOpen }

    /// Start a row, finishing the previous one if it is still open.
    @inlinable @inline(__always)
    public mutating func beginRow() {
        if rowOpen { finishRow() }
        rowOpen = true
    }

    /// Finish the open row: any field it did not touch gets a null. Idempotent.
    ///
    /// A row is pending if `beginRow()` opened one, or if any cell arrived without one —
    /// a driver that never calls `beginRow()` still gets its rows, completed here.
    public mutating func finishRow() {
        let next = completedRows + 1
        var pending = rowOpen
        if !pending {
            for f in 0..<fields.count where filledCount(f) >= next { pending = true; break }
        }
        guard pending else { return }
        for f in 0..<fields.count where filledCount(f) < next {
            appendNull(field: f)
        }
        completedRows = next
        rowOpen = false
    }

    /// Cells that arrived at a kind their field cannot hold, by manifest field — a wiring
    /// mistake in the driver, or text offered to a numeric field without `coerceScalars`.
    public var rejectedCells: [Int] { fields.map { Int($0.rejected) } }

    /// Empty the batch for reuse. Column storage is kept, so a steady-state reader
    /// allocates nothing per batch.
    public mutating func removeAll(keepingCapacity: Bool = true) {
        for i in 0..<slotsUsed.ints { ints.with(i) { $0.removeAll(keepingCapacity: keepingCapacity) } }
        for i in 0..<slotsUsed.doubles { doubles.with(i) { $0.removeAll(keepingCapacity: keepingCapacity) } }
        for i in 0..<slotsUsed.bools { bools.with(i) { $0.removeAll(keepingCapacity: keepingCapacity) } }
        for i in 0..<slotsUsed.strings { strings.with(i) { $0.removeAll(keepingCapacity: keepingCapacity) } }
        for i in 0..<slotsUsed.blobs {
            blobBytes.with(i) { $0.removeAll(keepingCapacity: keepingCapacity) }
            blobOffsets.with(i) { $0.removeAll(keepingCapacity: keepingCapacity); $0.append(0) }
        }
        for f in nullMask.indices { nullMask[f] = nil }
        for f in fields.indices { fields[f].rejected = 0 }
        for i in pendingNulls.indices { pendingNulls[i] = 0 }
        completedRows = 0
        rowOpen = false
    }

    // MARK: Cells, by SOURCE column

    /// The field a source column feeds, or nil for an unbound column.
    @inlinable @inline(__always)
    func field(_ column: Int) -> Int? {
        guard column >= 0, column < columns.count else { return nil }
        let f = columns[column].field
        return f >= 0 ? Int(f) : nil
    }

    @inlinable @inline(__always)
    public mutating func append(int64 v: Int64, column: Int) {
        guard column >= 0, column < columns.count else { return }
        var c = columns[column]
        if c.kind == .undecided { allocate(Int(c.field), .int64); c = columns[column] }
        // One compare covers "wrong kind" and "no field at all" (`.unbound`).
        guard c.kind == .int64 else { if c.kind != .unbound { reject(Int(c.field)) }; return }
        let p = unsafe c.slot.unsafelyUnwrapped.assumingMemoryBound(to: [Int64].self)
        // Exactly one cell per field per row: the column must be exactly `completedRows`
        // long. A second cell in the same row, or one after the row was finished, would
        // shift every later row of the column; it is rejected instead.
        guard unsafe p.pointee.count == completedRows else { reject(Int(c.field)); return }
        unsafe p.pointee.append(v)
    }

    @inlinable @inline(__always)
    public mutating func append(double v: Double, column: Int) {
        guard column >= 0, column < columns.count else { return }
        var c = columns[column]
        if c.kind == .undecided { allocate(Int(c.field), .double); c = columns[column] }
        // One compare covers "wrong kind" and "no field at all" (`.unbound`).
        guard c.kind == .double else { if c.kind != .unbound { reject(Int(c.field)) }; return }
        let p = unsafe c.slot.unsafelyUnwrapped.assumingMemoryBound(to: [Double].self)
        // Exactly one cell per field per row: the column must be exactly `completedRows`
        // long. A second cell in the same row, or one after the row was finished, would
        // shift every later row of the column; it is rejected instead.
        guard unsafe p.pointee.count == completedRows else { reject(Int(c.field)); return }
        unsafe p.pointee.append(v)
    }

    @inlinable @inline(__always)
    public mutating func append(bool v: Bool, column: Int) {
        guard column >= 0, column < columns.count else { return }
        var c = columns[column]
        if c.kind == .undecided { allocate(Int(c.field), .bool); c = columns[column] }
        // One compare covers "wrong kind" and "no field at all" (`.unbound`).
        guard c.kind == .bool else { if c.kind != .unbound { reject(Int(c.field)) }; return }
        let p = unsafe c.slot.unsafelyUnwrapped.assumingMemoryBound(to: [Bool].self)
        // Exactly one cell per field per row: the column must be exactly `completedRows`
        // long. A second cell in the same row, or one after the row was finished, would
        // shift every later row of the column; it is rejected instead.
        guard unsafe p.pointee.count == completedRows else { reject(Int(c.field)); return }
        unsafe p.pointee.append(v)
    }

    /// `consuming`: the caller's +1 (a string it just loaded from its row) flows straight
    /// into the column. As a borrowed parameter the compiler copied it in and released the
    /// caller's — a retain/release pair per string cell, and the difference between this
    /// transpose and a hand-written one.
    @inlinable @inline(__always)
    public mutating func append(string v: consuming String, column: Int) {
        guard column >= 0, column < columns.count else { return }
        var c = columns[column]
        if c.kind == .undecided { allocate(Int(c.field), .string); c = columns[column] }
        // One compare covers "wrong kind" and "no field at all" (`.unbound`).
        guard c.kind == .string else { if c.kind != .unbound { reject(Int(c.field)) }; return }
        let p = unsafe c.slot.unsafelyUnwrapped.assumingMemoryBound(to: [String].self)
        // Exactly one cell per field per row: the column must be exactly `completedRows`
        // long. A second cell in the same row, or one after the row was finished, would
        // shift every later row of the column; it is rejected instead.
        guard unsafe p.pointee.count == completedRows else { reject(Int(c.field)); return }
        unsafe p.pointee.append(v)
    }

    /// Text as bytes — a CSV field, a text-format wire value. Becomes a `String`.
    @inlinable
    public mutating func append<C: Collection<UInt8>>(text v: C, column: Int) {
        append(string: String(decoding: v, as: UTF8.self), column: column)
    }

    /// A binary cell, stored flat with offsets (`BytesColumn`'s layout) — no array per row.
    @inlinable
    public mutating func append<C: Collection<UInt8>>(bytes v: C, column: Int) {
        guard column >= 0, column < columns.count else { return }
        var c = columns[column]
        if c.kind == .undecided { allocate(Int(c.field), .bytes); c = columns[column] }
        guard c.kind == .bytes else { if c.kind != .unbound { reject(Int(c.field)) }; return }
        let f = Int(c.field)
        let slot = Int(fields[f].slot)
        guard unsafe blobOffsetSlots[slot].count - 1 == completedRows else { reject(f); return }
        unsafe blobByteSlots[slot].append(contentsOf: v)
        unsafe blobOffsetSlots[slot].append(blobByteSlots[slot].count)
    }

    @inlinable @inline(__always)
    public mutating func appendNull(column: Int) {
        guard let f = field(column) else { return }
        guard !isTouched(f) else { reject(f); return }
        appendNull(field: f)
    }

    /// A null for manifest field `f`: a placeholder value keeps the column dense, and the
    /// mask — created now if this is the first null — marks the row.
    @usableFromInline
    mutating func appendNull(field f: Int) {
        let row = filledCount(f)
        let s = Int(fields[f].slot)
        switch fields[f].kind {
        case .int64: ints.with(s) { $0.append(0) }
        case .double: doubles.with(s) { $0.append(0) }
        case .bool: bools.with(s) { $0.append(false) }
        case .string: strings.with(s) { $0.append("") }
        case .bytes:
            let end = blobBytes.with(s) { $0.count }
            blobOffsets.with(s) { $0.append(end) }
        case .undecided, .unbound:
            // No kind yet and nothing to store: the mask records the null, the count
            // here keeps presence honest, and when the kind is decided `allocate`
            // back-fills placeholders up to it.
            pendingNulls[f] += 1
        }
        // The mask is only as long as the last null: `_assayIsNullAt` treats rows past
        // its end as present. So pad it with `false` up to this row, then mark the row.
        if nullMask[f] == nil { nullMask[f] = [] }
        let short = row - nullMask[f]!.count
        if short > 0 { nullMask[f]!.append(contentsOf: repeatElement(false, count: short)) }
        nullMask[f]!.append(true)
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
        serves(field, .int64) ? ints.with(Int(fields[field].slot)) { $0 } : nil
    }
    public borrowing func doubleColumn(_ key: StaticString, _ field: Int) -> [Double]? {
        serves(field, .double) ? doubles.with(Int(fields[field].slot)) { $0 } : nil
    }
    public borrowing func boolColumn(_ key: StaticString, _ field: Int) -> [Bool]? {
        serves(field, .bool) ? bools.with(Int(fields[field].slot)) { $0 } : nil
    }
    public borrowing func stringColumn(_ key: StaticString, _ field: Int) -> [String]? {
        serves(field, .string) ? strings.with(Int(fields[field].slot)) { $0 } : nil
    }
    public borrowing func bytesColumn(_ key: StaticString, _ field: Int) -> BytesColumn? {
        guard serves(field, .bytes) else { return nil }
        let s = Int(fields[field].slot)
        return BytesColumn(bytes: blobBytes.with(s) { $0 }, offsets: blobOffsets.with(s) { $0 },
                           nulls: nullMask[field], metadata: metadata[field])
    }
    public borrowing func nulls(_ key: StaticString, _ field: Int) -> [Bool]? {
        field >= 0 && field < nullMask.count ? nullMask[field] : nil
    }
    public borrowing func columnMetadata(_ key: StaticString, _ field: Int) -> ColumnMetadata {
        field >= 0 && field < metadata.count ? metadata[field] : .none
    }
}
