// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

// `RowBatch`: rows in, typed columns out, decoded by the same `_assayBatch` as any column
// store. docs/ROWS.md.

@Schema(keys: .snakeCase, sources: true)
struct RB: Equatable {
    var id: Int64
    var name: String
    var score: Double
    var active: Bool
    var blob: [UInt8] = []
    var nickname: String?
    var retries: Int32 = 3
}

/// haul's shape of custom scalar: an Int64 carrier whose unit travels as metadata.
struct RBStamp: ColumnDecodable, Equatable {
    var micros: Int64
    init?(assayColumn c: borrowing ColumnBuffer<Int64>, row: Int, metadata m: ColumnMetadata) {
        guard m.unit == -6 else { return nil }
        micros = c[row]
    }
}

@Schema(formats: [], sources: true)
struct RBStamped: Equatable {
    var at: RBStamp
    var label: String?
}

@Suite("RowBatch")
struct RowBatchTests {

    static let columns = ["id", "name", "score", "active", "blob", "nickname", "retries"]

    func batch(_ rows: [[Any?]], columns: [String] = columns) -> RowBatch {
        var b = RowBatch(manifest: RB._assayManifest, columns: columns, capacity: 8)
        for row in rows {
            b.beginRow()
            for (i, cell) in row.enumerated() {
                switch cell {
                case nil: b.appendNull(column: i)
                case let v as Int64: b.append(int64: v, column: i)
                case let v as Int: b.append(int64: Int64(v), column: i)
                case let v as Double: b.append(double: v, column: i)
                case let v as Bool: b.append(bool: v, column: i)
                case let v as String: b.append(string: v, column: i)
                case let v as [UInt8]: b.append(bytes: v, column: i)
                default: Issue.record("unsupported cell \(String(describing: cell))")
                }
            }
        }
        b.finishRow()
        return b
    }

    @Test("every kind round-trips, in the source's column order")
    func kinds() {
        let b = batch([[1, "a", 1.5, true, [UInt8]([1, 2]), "nick", 7],
                       [2, "b", 2.5, false, [UInt8]([]), nil, nil]])
        let rows = b.rowCount
        #expect(rows == 2)
        let d = RB.batch(from: b)
        #expect(d.isValid, "\(d.issues)")
        #expect(d.values == [
            RB(id: 1, name: "a", score: 1.5, active: true, blob: [1, 2], nickname: "nick", retries: 7),
            RB(id: 2, name: "b", score: 2.5, active: false, blob: [], nickname: nil, retries: 3),
        ])
    }

    @Test("the source's column order is its own; binding is by name")
    func reordered() {
        let cols = ["nickname", "score", "id", "active", "name", "extra"]
        var b = RowBatch(manifest: RB._assayManifest, columns: cols, capacity: 4)
        b.beginRow()
        b.append(string: "n", column: 0); b.append(double: 9, column: 1); b.append(int64: 5, column: 2)
        b.append(bool: true, column: 3); b.append(string: "x", column: 4); b.append(string: "dropped", column: 5)
        b.append(string: "past the end", column: 42)
        b.finishRow()
        let d = RB.batch(from: b)
        #expect(d.values == [RB(id: 5, name: "x", score: 9, active: true, nickname: "n")])
    }

    @Test("positional binding: the columns are the manifest")
    func positional() {
        let plan = BoundPlan(slots: Array(0..<RB._assayManifest.fields.count))
        var b = RowBatch(manifest: RB._assayManifest, plan: plan)
        b.beginRow()
        b.append(int64: 1, column: 0); b.append(string: "p", column: 1); b.append(double: 0, column: 2)
        b.append(bool: false, column: 3); b.append(bytes: [9], column: 4); b.appendNull(column: 5)
        b.append(int64: 2, column: 6)
        b.finishRow()
        #expect(RB.batch(from: b).values == [RB(id: 1, name: "p", score: 0, active: false, blob: [9], nickname: nil, retries: 2)])
    }

    @Test("a null is missing for a required field, nil for an optional one, with the row")
    func nulls() {
        let b = batch([[1, "a", 1.0, true, [UInt8](), nil, 1],
                       [nil, "b", 2.0, true, [UInt8](), "n", 1],
                       [3, "c", 3.0, true, [UInt8](), nil, nil]])
        let d = RB.batch(from: b)
        #expect(d.values.map(\.id) == [1, 3])
        #expect(d.issues.map(\.path) == [[.index(1), .key("id")]])
        #expect(d.values.map(\.retries) == [1, 3])
    }

    @Test("a ragged row is missing what it did not supply, and later rows stay aligned")
    func ragged() {
        let b = batch([[1, "a", 1.0, true],                              // short: blob, nickname, retries untouched
                       [2, "b", 2.0, false, [UInt8]([7]), "n", 9],
                       [3]])                                             // very short
        let d = RB.batch(from: b)
        #expect(d.values == [RB(id: 1, name: "a", score: 1.0, active: true),
                             RB(id: 2, name: "b", score: 2.0, active: false, blob: [7], nickname: "n", retries: 9)])
        #expect(d.issues.map(\.path).contains([.index(2), .key("name")]))
        #expect(d.issues.allSatisfy { $0.path.first == .index(2) })
    }

    // TEXT INTO A NUMERIC FIELD IS NOT A WRONG KIND — it is a CSV, and it takes the
    // column. `RB` does not coerce, so the string column goes unread and the field still
    // reports `missing_column`; what changed is that nothing is REJECTED, so a schema
    // that does coerce can read it. See `csvThroughTheDecoder` below for that half.
    @Test("under inferColumnKinds, text takes a numeric field's column")
    func textAdoptsTheColumn() {
        var b = RowBatch(manifest: RB._assayManifest, columns: Self.columns,
                         inferColumnKinds: true)
        for i in 0..<3 {
            b.beginRow()
            b.append(string: "\(i)", column: 0)          // text into an Int64 field
            b.append(string: "n", column: 1); b.append(double: 1, column: 2); b.append(bool: true, column: 3)
        }
        b.finishRow()
        #expect(b.rejectedCells[0] == 0)
        #expect(b.stringColumn("id", 0) == ["0", "1", "2"])
        #expect(b.int64Column("id", 0) == nil)
        let d = RB.batch(from: b)
        #expect(d.values.isEmpty)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.code == .missingColumn)
        #expect(d.issues.first?.path == [.key("id")])
    }

    @Test("a column that has already taken a real number rejects text after it")
    func mixedKindsAreStillRejected() {
        var b = RowBatch(manifest: RB._assayManifest, columns: Self.columns,
                         inferColumnKinds: true)
        b.beginRow()
        b.append(int64: 1, column: 0)
        b.append(string: "n", column: 1); b.append(double: 1, column: 2); b.append(bool: true, column: 3)
        b.beginRow()
        b.append(string: "two", column: 0)               // the source is mixing kinds
        b.append(string: "n", column: 1); b.append(double: 1, column: 2); b.append(bool: true, column: 3)
        b.finishRow()
        #expect(b.rejectedCells[0] == 1)
        #expect(b.int64Column("id", 0) == nil)           // one rejection invalidates it
        #expect(b.stringColumn("id", 0) == nil)
    }

    @Test("nulls already in the column are carried over when text takes it")
    func adoptionCarriesNullsOver() {
        var b = RowBatch(manifest: RB._assayManifest, columns: Self.columns,
                         inferColumnKinds: true)
        b.beginRow()
        b.appendNull(column: 0)
        b.append(string: "n", column: 1); b.append(double: 1, column: 2); b.append(bool: true, column: 3)
        b.beginRow()
        b.append(string: "7", column: 0)
        b.append(string: "n", column: 1); b.append(double: 1, column: 2); b.append(bool: true, column: 3)
        b.finishRow()
        #expect(b.rejectedCells[0] == 0)
        #expect(b.stringColumn("id", 0)?.count == 2)
        #expect(b.stringColumn("id", 0)?[1] == "7")
        #expect(b.nulls("id", 0)?[0] == true)
    }

    @Test("two cells for one field in a row are rejected; a cell before beginRow starts the row")
    func duplicateCell() {
        var b = RowBatch(manifest: RB._assayManifest, columns: Self.columns)
        b.append(int64: 1, column: 0)                     // no beginRow: it is row 0's cell
        b.append(string: "a", column: 1); b.append(double: 1, column: 2); b.append(bool: true, column: 3)
        b.finishRow()
        let rows = b.rowCount
        #expect(rows == 1)
        #expect(RB.batch(from: b).values.map(\.id) == [1])
        var c = RowBatch(manifest: RB._assayManifest, columns: Self.columns)
        c.beginRow()
        c.append(int64: 1, column: 0)
        c.append(int64: 2, column: 0)
        let twice = c.rejectedCells
        #expect(twice[0] == 1)
    }

    @Test("a custom scalar takes its kind from the first cell and its unit from the batch")
    func custom() {
        var b = RowBatch(manifest: RBStamped._assayManifest, columns: ["at", "label"])
        b.setMetadata(ColumnMetadata(unit: -6), column: 0)
        b.beginRow(); b.appendNull(column: 0); b.append(string: "first is null", column: 1)   // kind still undecided
        b.beginRow(); b.append(int64: 1_700_000_000_000_000, column: 0); b.appendNull(column: 1)
        b.beginRow(); b.append(int64: 1_700_000_000_000_001, column: 0); b.append(string: "l", column: 1)
        b.finishRow()
        let d = RBStamped.batch(from: b)
        #expect(d.values.map(\.at.micros) == [1_700_000_000_000_000, 1_700_000_000_000_001])
        #expect(d.values.map(\.label) == [nil, "l"])
        #expect(d.issues.map(\.path) == [[.index(0), .key("at")]])
    }

    @Test("text cells become strings; bytes stay flat")
    func textAndBytes() {
        var b = RowBatch(manifest: RB._assayManifest, columns: Self.columns)
        b.beginRow()
        b.append(int64: 1, column: 0)
        b.append(text: Array("ünï".utf8), column: 1)
        b.append(double: 0, column: 2); b.append(bool: true, column: 3)
        b.append(bytes: [0xDE, 0xAD], column: 4)
        b.beginRow()
        b.append(int64: 2, column: 0); b.append(text: [], column: 1)
        b.append(double: 0, column: 2); b.append(bool: true, column: 3)
        b.append(bytes: [], column: 4)
        b.finishRow()
        let d = RB.batch(from: b)
        #expect(d.values.map(\.name) == ["ünï", ""])
        #expect(d.values.map(\.blob) == [[0xDE, 0xAD], []])
        let blobs = b.bytesColumn("blob", 4)?.count
        #expect(blobs == 2)
    }

    @Test("removeAll keeps the columns and the binding; the next batch is clean")
    func reuse() {
        var b = batch([[1, "a", 1.0, true, [UInt8](), nil, 1]])
        b.removeAll()
        let rows = b.rowCount
        #expect(rows == 0)
        b.beginRow()
        b.append(int64: 2, column: 0); b.append(string: "b", column: 1); b.append(double: 2, column: 2)
        b.append(bool: false, column: 3); b.append(bytes: [1], column: 4); b.append(string: "n", column: 5)
        b.append(int64: 4, column: 6)
        b.finishRow()
        #expect(RB.batch(from: b).values == [RB(id: 2, name: "b", score: 2, active: false, blob: [1], nickname: "n", retries: 4)])
    }

    @Test("a missing required column reports once and decodes nothing")
    func missingColumn() {
        var b = RowBatch(manifest: RB._assayManifest, columns: ["id", "score", "active"])
        b.beginRow(); b.append(int64: 1, column: 0); b.append(double: 1, column: 1); b.append(bool: true, column: 2)
        b.finishRow()
        let d = RB.batch(from: b)
        #expect(d.values.isEmpty)
        #expect(d.issues.map(\.code) == [.missingColumn])
        #expect(d.issues.first?.path == [.key("name")])
    }

    @Test("20,000 rows stay linear and decode identically to the direct store")
    func linear() {
        var b = RowBatch(manifest: RB._assayManifest, columns: Self.columns, capacity: 20_000)
        for i in 0..<20_000 {
            b.beginRow()
            b.append(int64: Int64(i), column: 0); b.append(string: "r\(i)", column: 1)
            b.append(double: Double(i), column: 2); b.append(bool: i % 2 == 0, column: 3)
            b.append(bytes: [UInt8(i % 256)], column: 4)
            if i % 3 == 0 { b.appendNull(column: 5) } else { b.append(string: "n", column: 5) }
            b.append(int64: Int64(i % 100), column: 6)
        }
        b.finishRow()
        let d = RB.batch(from: b)
        #expect(d.isValid)
        #expect(d.values.count == 20_000)
        #expect(d.values[19_999] == RB(id: 19_999, name: "r19999", score: 19_999, active: false,
                                       blob: [UInt8(19_999 % 256)], nickname: "n", retries: 99))
    }
}
