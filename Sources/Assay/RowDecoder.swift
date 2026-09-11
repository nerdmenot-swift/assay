// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The driver-facing side of the row path. docs/ROWS.md.
//
// `RowBatch` is the buffer; this is what a driver holds: one per result set, fed a row at
// a time, flushed every `batchSize` rows into a `BatchDiagnosis<T>`. A million-row query
// never holds a million rows, and an issue on the 250,003rd row says `[250003]`, not the
// `[3]` its batch would have said — the offset is added to the few paths that are actually
// reported, never to the rows that are not.
//
// Deliberately NOT a protocol the source conforms to, and NOT a `decodeAll(rows:)` over some
// row abstraction: either would be the `KeyedSource` shape (docs/KEYED-SOURCE.md) with the
// per-row call going out of a generic body. The driver's loop stays in the driver, calling
// into this concrete type; the generic call — `_assayBatch` — happens once per flush.
//===----------------------------------------------------------------------===//

public import AssayCore

/// Decodes rows of `T` as they arrive, in batches.
///
///     var dec = RowDecoder<User>(columns: resultSet.columnNames)
///     for row in resultSet {
///         dec.beginRow()
///         for (i, cell) in row.enumerated() { … dec.append(int64: v, column: i) … }
///         if dec.isFull { consume(dec.flush()) }
///     }
///     consume(dec.finish())
///
/// Bind by name (`columns:` in the source's own order) or by position (`plan:` — the
/// identity plan when the SELECT list *is* the manifest).
public struct RowDecoder<T: SourceDecodable>: ~Copyable {

    @usableFromInline var batch: RowBatch
    @usableFromInline let batchSize: Int
    @usableFromInline let limits: Limits
    /// Rows already flushed — what the next flush's row indices are offset by.
    public private(set) var rowOffset: Int = 0

    /// The binding this decoder resolved once; a source that addresses columns some other
    /// way can inspect it.
    public let plan: BoundPlan
    /// Required fields the source has no column for — known before the first row, so a
    /// driver can fail fast instead of decoding a million rows that each report it.
    public let missingColumns: [String]

    public init(columns: [String], batchSize: Int = 4096, limits: Limits = .default,
                inferColumnKinds: Bool = false) {
        self.init(plan: BoundPlan(manifest: T._assayManifest, columns: columns),
                  batchSize: batchSize, limits: limits, inferColumnKinds: inferColumnKinds)
    }

    /// `inferColumnKinds: true` when your cells are not the kind the field declares — a
    /// CSV, a database in text mode, a spreadsheet. Each column's storage then comes from
    /// its first cell, so `append(text:)` into an `Int` field yields a string column the
    /// schema parses under `coerceScalars`. It measures 40.9 ns/row against 32.7 for the
    /// declared-kind path, 1.25×, which is why it is a flag rather than the behaviour;
    /// `RowBatch`'s initialiser has the measurement and the two free-of-charge designs
    /// that were tried first and refused.
    public init(plan: BoundPlan, batchSize: Int = 4096, limits: Limits = .default,
                inferColumnKinds: Bool = false) {
        let manifest = T._assayManifest
        self.plan = plan
        self.batchSize = Swift.max(batchSize, 1)
        self.limits = limits
        self.missingColumns = plan._missingRequired(in: manifest)
        self.batch = RowBatch(manifest: manifest, plan: plan, capacity: self.batchSize,
                              inferColumnKinds: inferColumnKinds)
    }

    // MARK: Feeding

    @inlinable public mutating func beginRow() { batch.beginRow() }

    @inlinable public mutating func append(int64 v: Int64, column: Int) { batch.append(int64: v, column: column) }
    @inlinable public mutating func append(double v: Double, column: Int) { batch.append(double: v, column: column) }
    @inlinable public mutating func append(bool v: Bool, column: Int) { batch.append(bool: v, column: column) }
    @inlinable public mutating func append(string v: consuming String, column: Int) { batch.append(string: v, column: column) }
    @inlinable public mutating func append<C: Collection<UInt8>>(text v: C, column: Int) { batch.append(text: v, column: column) }
    @inlinable public mutating func append<C: Collection<UInt8>>(bytes v: C, column: Int) { batch.append(bytes: v, column: column) }
    @inlinable public mutating func appendNull(column: Int) { batch.appendNull(column: column) }

    /// Per-column facts — a timestamp's unit, a decimal's scale. Survives flushes.
    public mutating func setMetadata(_ m: ColumnMetadata, column: Int) {
        batch.setMetadata(m, column: column)
    }

    /// Cells that arrived at a kind their field cannot hold, since the last flush.
    public var rejectedCells: [Int] { batch.rejectedCells }

    /// The buffer holds `batchSize` rows, counting the one being built. Check it after a
    /// row's cells are appended: `flush()` finishes the open row, so a check between
    /// `beginRow()` and the row's cells would flush a row of nulls.
    @inlinable public var isFull: Bool { batch.rowCount + (batch.isRowOpen ? 1 : 0) >= batchSize }

    // MARK: Flushing

    /// Finish the row being built, decode every row buffered, reset the buffer, advance
    /// the offset. Issues and warnings carry global row indices. `truncatedIssues` is per
    /// flush.
    public mutating func flush() -> BatchDiagnosis<T> {
        batch.finishRow()
        var sink = IssueSink(limits: limits)
        let values = T._assayBatch(from: batch, into: &sink, at: [])
        let n = batch.rowCount
        batch.removeAll(keepingCapacity: true)
        let result = BatchDiagnosis(values: values,
                                    issues: offset(sink.issues, by: rowOffset),
                                    warnings: offset(sink.warnings, by: rowOffset),
                                    truncatedIssues: sink.truncatedIssues)
        rowOffset += n
        return result
    }

    /// The last flush. The same as `flush()`; named for the call site that reads better.
    public mutating func finish() -> BatchDiagnosis<T> { flush() }

    /// Cold: runs only over what was reported. The batch body files the row at depth 0
    /// (it is called with an empty path), so the index is the first component.
    private func offset(_ issues: [Issue], by base: Int) -> [Issue] {
        guard base > 0 else { return issues }
        return issues.map { issue in
            var i = issue
            if case .index(let r)? = i.path.first { i.path[0] = .index(r + base) }
            return i
        }
    }

    private func offset(_ warnings: [Warning], by base: Int) -> [Warning] {
        guard base > 0 else { return warnings }
        return warnings.map { w in
            var v = w
            if case .index(let r)? = v.path.first { v.path[0] = .index(r + base) }
            return v
        }
    }
}
