// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

// Text cells on the columnar path — a CSV, an Excel sheet, a text-format SQL value — under
// the schema's own coercion policy, and dates from text. docs/ROWS.md §C.

@Schema(coerceScalars: true, formats: [], sources: true)
struct CSVRow: Equatable {
    var id: Int
    var ratio: Double
    var active: Bool
    var small: Int8
    var when: Date                                  // ISO-8601 by default
    @DateFormat(.unixSeconds) var stamp: Date
    var note: String?
}

@Schema(formats: [], sources: true)
struct TwoFormats { @DateFormat(.iso8601, .unixSeconds) var at: Date }

@Schema(coerceScalars: true, formats: [], sources: true)
struct BytesFromText: Equatable { var id: Int; var payload: [UInt8] }

@Schema(formats: [], sources: true)
struct StrictRow: Equatable {
    var id: Int
    @Coerce var count: Int
}

/// Cells as text, every column.
struct TextStore: ColumnarSource {
    var rows: [[String?]]
    var columns: [String]
    var rowCount: Int { rows.count }
    func col(_ key: StaticString) -> Int? { columns.firstIndex(of: String(describing: key)) }
    borrowing func stringColumn(_ key: StaticString, _ f: Int) -> [String]? {
        guard let c = col(key) else { return nil }
        return rows.map { $0[c] ?? "" }
    }
    borrowing func nulls(_ key: StaticString, _ f: Int) -> [Bool]? {
        guard let c = col(key) else { return nil }
        let m = rows.map { $0[c] == nil }
        return m.contains(true) ? m : nil
    }
    borrowing func int64Column(_ key: StaticString, _ f: Int) -> [Int64]? { nil }
    borrowing func doubleColumn(_ key: StaticString, _ f: Int) -> [Double]? { nil }
    borrowing func boolColumn(_ key: StaticString, _ f: Int) -> [Bool]? { nil }
}

@Suite("Text cells on the columnar path")
struct ColumnarCoercionTests {

    static let columns = ["id", "ratio", "active", "small", "when", "stamp", "note"]

    @Test("a CSV-shaped store decodes under coerceScalars, by the tree path's rules")
    func csv() {
        let store = TextStore(rows: [
            ["1", "0.5", "true", "7", "2026-09-10T12:00:00Z", "1700000000", "n"],
            ["2", "1e3", "NO", "-128", "2026-01-01T00:00:00+01:00", "0", nil],
        ], columns: Self.columns)
        let d = CSVRow.batch(from: store)
        #expect(d.isValid, "\(d.issues)")
        #expect(d.values.count == 2)
        #expect(d.values[0].id == 1 && d.values[0].ratio == 0.5 && d.values[0].active == true && d.values[0].small == 7)
        #expect(d.values[0].when.timeIntervalSince1970 == 1_789_041_600)
        #expect(d.values[0].stamp.timeIntervalSince1970 == 1_700_000_000)
        #expect(d.values[1].ratio == 1000 && d.values[1].active == false && d.values[1].small == -128)
        #expect(d.values[1].when.timeIntervalSince1970 == 1_767_222_000)
        #expect(d.values[1].note == nil)
    }

    @Test("a cell that is not the declared scalar is type_mismatch, with the row and the text")
    func mismatch() {
        let store = TextStore(rows: [
            ["1", "0.5", "true", "1", "2026-09-10T12:00:00Z", "1", nil],
            ["x", "0.5", "true", "1", "2026-09-10T12:00:00Z", "1", nil],
            ["3", "high", "true", "1", "2026-09-10T12:00:00Z", "1", nil],
            ["4", "0.5", "maybe", "1", "2026-09-10T12:00:00Z", "1", nil],
            ["5", "0.5", "true", "300", "2026-09-10T12:00:00Z", "1", nil],
            ["6", "0.5", "true", "1", "yesterday", "1", nil],
            ["7", "8080.5", "true", "1", "2026-09-10T12:00:00Z", "1", nil],
        ], columns: Self.columns)
        let d = CSVRow.batch(from: store)
        #expect(d.values.map(\.id) == [1, 7])
        let paths = d.issues.map(\.path.pathDescription)
        #expect(paths == ["[1].id", "[2].ratio", "[3].active", "[4].small", "[5].when"], "\(paths)")
        #expect(d.issues[0].code == .typeMismatch && d.issues[0].received == "\"x\"")
        #expect(d.issues[3].code == .numberOverflow)
        #expect(d.issues[4].code == .invalidDate)
    }

    @Test("without coercion a text column for a number is a missing column; @Coerce per field opts in")
    func strict() {
        let store = TextStore(rows: [["1", "2"]], columns: ["id", "count"])
        let d = StrictRow.batch(from: store)
        #expect(d.values.isEmpty)
        #expect(d.issues.map(\.code) == [.missingColumn])
        #expect(d.issues.first?.path == [.key("id")])
    }

    @Test("a typed column is still preferred, and a Date still takes an Int64 column with its unit")
    func typedFirst() {
        var b = RowBatch(manifest: CSVRow._assayManifest, columns: Self.columns)
        b.setMetadata(ColumnMetadata(unit: -3), column: 4)
        b.beginRow()
        b.append(int64: 9, column: 0); b.append(double: 2, column: 1); b.append(bool: true, column: 2)
        b.append(int64: 3, column: 3); b.append(int64: 1_700_000_000_500, column: 4)
        b.append(string: "1700000000", column: 5); b.appendNull(column: 6)
        b.finishRow()
        let d = CSVRow.batch(from: b)
        #expect(d.isValid, "\(d.issues)")
        #expect(d.values.first?.when.timeIntervalSince1970 == 1_700_000_000.5)
        #expect(d.values.first?.stamp.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test("a bytes carrier takes a text column as its bytes — a UUID's 36 characters, a blob's text")
    func textAsBytes() {
        let store = TextStore(rows: [["7", "abc"], ["8", ""]], columns: ["id", "payload"])
        let d = BytesFromText.batch(from: store)
        #expect(d.isValid, "\(d.issues)")
        #expect(d.values.map(\.payload) == [Array("abc".utf8), []])
    }

    @Test("a @DateFormat candidate chain warns on a fallback match, per row")
    func dateFallbackWarns() {
        let store = TextStore(rows: [["2026-09-10T12:00:00Z"], ["1700000000"]], columns: ["at"])
        let d = TwoFormats.batch(from: store)
        #expect(d.isValid)
        #expect(d.warnings.map(\.path) == [[.index(1), .key("at")]])
    }
}
