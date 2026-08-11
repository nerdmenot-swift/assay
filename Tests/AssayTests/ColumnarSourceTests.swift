// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Decoding a batch from a column store. docs/KEYED-SOURCE.md.
//
// The two things that matter more than the happy path: the inversion must change cost and
// never meaning (a batch-filled row equals the row a tree decode produces, field for
// field), and the five presence states survive it — absent column, validity mask, declared
// default and required are four different answers, and a source that conflates them is
// worse than no source at all.
//
// The row-at-a-time half of this path was removed after measurement; the reasoning lives
// in the header of `Sources/AssayCore/ColumnarSource.swift`.
//===----------------------------------------------------------------------===//

import Testing
import Assay

@Schema(keys: .snakeCase, sources: true)
struct Row: Equatable {
    var id: Int
    var name: String
    @Validate(.range(0...120)) var age: Int
    var score: Double
    var active: Bool
    var nickname: String?
    var retries: Int = 3
}

@Suite("The field manifest")
struct ManifestTests {

    @Test("the manifest describes the type at compile time")
    func manifest() {
        let m = Row._assayManifest
        #expect(m.keys == ["id", "name", "age", "score", "active", "nickname", "retries"])
        #expect(m.fields.first { $0.key == "nickname" }?.isOptional == true)
        #expect(m.fields.first { $0.key == "retries" }?.hasDefault == true)
        #expect(m.fields.first { $0.key == "retries" }?.isRequired == false)
        #expect(m.fields.first { $0.key == "name" }?.isRequired == true)
        #expect(m.fields.first { $0.key == "score" }?.kind == .double)
        // This is what a source binds against once per batch instead of per record.
        #expect(m.fields.count == 7)
    }
}

@Suite("Columnar diagnostics")
struct ColumnarDiagnosticTests {

    @Test("a collection field is refused — a columnar source is flat scalar columns")
    func collectionRefused() {
        for src in ["@Schema(sources: true) struct S { var tags: [String] }",
                    "@Schema(sources: true) struct S { var m: [String: Int] }"] {
            let (_, diags) = expandSchemaForTesting(src)
            #expect(diags.contains { $0.contains("flat scalar columns") }, "for: \(src)")
        }
    }

    @Test("a nested @Schema field is refused, pointing at the document")
    func nestedRefused() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(sources: true) struct S { var inner: Other }
        """)
        #expect(diags.contains { $0.contains("KEYED-SOURCE.md") })
    }

    @Test("sources: false emits nothing — the compile budget is why it is opt-in")
    func optInIsReal() {
        let (without, _) = expandSchemaForTesting("@Schema struct S { var a: Int }")
        let (with, _) = expandSchemaForTesting("@Schema(sources: true) struct S { var a: Int }")
        #expect(!without.contains("_assayManifest"))
        #expect(with.contains("_assayManifest"))
        #expect(with.contains("ColumnarSource"))
    }
}

@Suite("Two-phase binding")
struct BoundPlanTests {

    /// Columns in a different order from the schema, and extra ones — the ordinary case.
    static let columns = ["spare_a", "score", "id", "spare_b", "active", "name",
                          "age", "nickname", "spare_c"]

    @Test("the plan maps manifest order to the source's own order")
    func planOrder() {
        let plan = BoundPlan(manifest: Row._assayManifest, columns: Self.columns)
        // Manifest order is id, name, age, score, active, nickname, retries.
        #expect(plan[0] == 2, "id is the source's third column")
        #expect(plan[1] == 5, "name is the source's sixth")
        #expect(plan[3] == 1, "score is the source's second")
        #expect(plan[6] == BoundPlan.absent, "retries is absent and defaulted")
    }

    @Test("an out-of-range field index is absent rather than a trap")
    func outOfRange() {
        let plan = BoundPlan(manifest: Row._assayManifest, columns: Self.columns)
        #expect(plan[-1] == BoundPlan.absent)
        #expect(plan[99] == BoundPlan.absent)
        #expect(plan.count == 7)
    }

    @Test("binding fails fast: a missing required column is reported ONCE, per batch")
    func missingRequiredUpFront() {
        // The point of binding: a column the schema requires and the source lacks is a
        // property of the SOURCE, so it should not be rediscovered a million times.
        let plan = BoundPlan(manifest: Row._assayManifest,
                             columns: ["id", "age", "score", "active"])
        let missing = plan.missingRequired(in: Row._assayManifest)
        #expect(missing == ["name"])
        #expect(BoundPlan(manifest: Row._assayManifest, columns: Self.columns)
                    .missingRequired(in: Row._assayManifest).isEmpty)
    }

    @Test("a duplicate column name binds to the first occurrence")
    func duplicateColumns() {
        let plan = BoundPlan(manifest: Row._assayManifest,
                             columns: ["id", "id", "name", "age", "score", "active"])
        #expect(plan[0] == 0)
    }
}

/// A column store: one array per field, plus Arrow-style validity masks.
struct ColumnStore: ColumnarSource, ~Copyable {
    var rowCount: Int
    var ints: [String: [Int64]] = [:]
    var doubles: [String: [Double]] = [:]
    var bools: [String: [Bool]] = [:]
    var strings: [String: [String]] = [:]
    var masks: [String: [Bool]] = [:]

    borrowing func int64Column(_ key: StaticString, _ field: Int) -> [Int64]? {
        ints[String(describing: key)]
    }
    borrowing func doubleColumn(_ key: StaticString, _ field: Int) -> [Double]? {
        doubles[String(describing: key)]
    }
    borrowing func boolColumn(_ key: StaticString, _ field: Int) -> [Bool]? {
        bools[String(describing: key)]
    }
    borrowing func stringColumn(_ key: StaticString, _ field: Int) -> [String]? {
        strings[String(describing: key)]
    }
    borrowing func nulls(_ key: StaticString, _ field: Int) -> [Bool]? {
        masks[String(describing: key)]
    }
}

@Suite("Columnar batch fill")
struct ColumnarTests {

    static func store(rows n: Int) -> ColumnStore {
        ColumnStore(
            rowCount: n,
            ints: ["id": (0..<n).map { Int64($0) }, "age": (0..<n).map { Int64(20 + $0 % 50) }],
            doubles: ["score": (0..<n).map { Double($0) * 0.5 }],
            bools: ["active": (0..<n).map { $0 % 2 == 0 }],
            strings: ["name": (0..<n).map { "user-\($0)" },
                      "nickname": (0..<n).map { "nick-\($0)" }])
    }

    @Test("a batch decodes every row, and equals what the tree path produces")
    func batchEqualsRowwise() throws {
        let s = Self.store(rows: 64)
        let (values, issues, _) = Row.batch(from: s)
        #expect(issues.isEmpty)
        #expect(values.count == 64)

        // The inversion must change cost, never meaning. The reference is the ordinary
        // JSON path — the same rows, decoded the way every other caller decodes them.
        for r in [0, 1, 31, 63] {
            let json = """
            {"id": \(r), "name": "user-\(r)", "age": \(20 + r % 50), \
            "score": \(Double(r) * 0.5), "active": \(r % 2 == 0), \
            "nickname": "nick-\(r)"}
            """
            let reference = try Row.parse(json: Array(json.utf8))
            #expect(values[r] == reference, "row \(r) differs between batch and JSON")
        }
    }

    @Test("defaults and absent optional columns behave as everywhere else")
    func presence() {
        var s = Self.store(rows: 8)
        s.strings["nickname"] = nil          // optional column simply absent
        let (values, issues, _) = Row.batch(from: s)
        #expect(issues.isEmpty)
        #expect(values.allSatisfy { $0.nickname == nil })
        #expect(values.allSatisfy { $0.retries == 3 }, "no column, so the default applies")
    }

    @Test("a validity mask marks individual rows null, Arrow-style")
    func validityMask() {
        var s = Self.store(rows: 6)
        s.masks["nickname"] = [true, false, true, false, true, false]
        let (values, issues, _) = Row.batch(from: s)
        #expect(issues.isEmpty)
        #expect(values.map { $0.nickname == nil } == [true, false, true, false, true, false])
    }

    /// A missing required column is a property of the SOURCE, not of each row — reporting
    /// it a million times would be useless.
    @Test("a missing required column is reported once for the batch, not once per row")
    func missingColumnReportedOnce() {
        var s = Self.store(rows: 1_000)
        s.strings["name"] = nil
        let (values, issues, _) = Row.batch(from: s)
        #expect(issues.filter { $0.code == .custom("missing_column") }.count == 1,
                "once, not a thousand times")
        #expect(issues.first?.message.contains("not a column") == true)
        #expect(values.isEmpty, "no row can be built without a required field")
    }

    @Test("@Validate runs per row, and the issue names the row")
    func validationPerRow() {
        var s = Self.store(rows: 4)
        s.ints["age"] = [30, 500, 40, 900]        // rows 1 and 3 are out of range
        let (_, issues, _) = Row.batch(from: s)
        #expect(issues.count == 2)
        let paths = issues.map(\.path.pathDescription)
        #expect(paths.contains { $0.contains("[1]") }, "got \(paths)")
        #expect(paths.contains { $0.contains("[3]") }, "got \(paths)")
    }

    @Test("a short column truncates that row rather than trapping")
    func shortColumn() {
        var s = Self.store(rows: 4)
        s.ints["id"] = [0, 1]                      // two values for four rows
        let (values, issues, _) = Row.batch(from: s)
        #expect(values.count == 2, "rows without an id cannot be built")
        #expect(!issues.isEmpty)
    }
}
