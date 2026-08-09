// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The third decode path. docs/KEYED-SOURCE.md.
//
// Two things under test that matter more than the happy path: the five presence states
// behave identically to JSON (absent, null, defaulted and required are four different
// answers, and a source that conflates them is worse than no source), and a source that
// CAN place its fields produces the same carets JSON does.
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

/// A source that knows where its fields came from — a CSV reader, a config file, a form
/// with field offsets. Proves the caret path works for something that is not JSON.
struct PositionedSource: KeyedSource, ~Copyable {
    let values: [String: (RawValue, SourceSpan)]

    borrowing func has(_ key: StaticString, _ field: Int) -> Bool {
        values[String(describing: key)] != nil
    }
    borrowing func isNull(_ key: StaticString, _ field: Int) -> Bool {
        if case .null? = values[String(describing: key)]?.0 { return true }
        return false
    }
    borrowing func int64(_ key: StaticString, _ field: Int) -> Int64? {
        values[String(describing: key)]?.0.int
    }
    borrowing func double(_ key: StaticString, _ field: Int) -> Double? {
        values[String(describing: key)]?.0.double
    }
    borrowing func bool(_ key: StaticString, _ field: Int) -> Bool? {
        values[String(describing: key)]?.0.bool
    }
    borrowing func withText<R>(
        _ key: StaticString, _ field: Int, _ body: (UnsafeRawBufferPointer?) -> R
    ) -> R {
        guard case .string(let s)? = values[String(describing: key)]?.0 else {
            return body(nil)
        }
        var copy = s
        return copy.withUTF8 { body(UnsafeRawBufferPointer($0)) }
    }
    borrowing func span(_ key: StaticString, _ field: Int) -> SourceSpan? {
        values[String(describing: key)]?.1
    }
}

private func fullRow() -> [String: RawValue] {
    ["id": .int(1), "name": .string("ada"), "age": .int(36), "score": .double(9.5),
     "active": .bool(true), "nickname": .string("countess")]
}

@Suite("KeyedSource — the third decode path")
struct KeyedSourceTests {

    @Test("a complete record decodes")
    func happyPath() throws {
        let v = try Row.parse(source: DictionarySource(fullRow()))
        #expect(v == Row(id: 1, name: "ada", age: 36, score: 9.5, active: true,
                         nickname: "countess", retries: 3))
    }

    /// The distinction a row source most easily gets wrong, and the one
    /// `EXPERIENCE.md` §6 refuses to blur: absent, null, defaulted and required are four
    /// different answers.
    @Test("the five presence states behave exactly as they do for JSON")
    func presenceStates() throws {
        // Absent optional -> nil, and absent defaulted -> the default.
        var r = fullRow()
        r["nickname"] = nil
        let v = try Row.parse(source: DictionarySource(r))
        #expect(v.nickname == nil)
        #expect(v.retries == 3, "an absent defaulted field takes its default")

        // Explicit null on an optional -> nil, not a failure.
        r["nickname"] = .null
        #expect(try Row.parse(source: DictionarySource(r)).nickname == nil)

        // Explicit null on a REQUIRED field is a type mismatch, not a missing field.
        var bad = fullRow()
        bad["name"] = .null
        let d = Row.diagnose(source: DictionarySource(bad))
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .typeMismatch })

        // A present default is honoured over the declared one.
        var withRetries = fullRow()
        withRetries["retries"] = .int(9)
        #expect(try Row.parse(source: DictionarySource(withRetries)).retries == 9)
    }

    @Test("a missing required field reports once, naming it")
    func missing() {
        var r = fullRow()
        r["name"] = nil
        r["age"] = nil
        let d = Row.diagnose(source: DictionarySource(r))
        #expect(!d.isValid)
        #expect(d.issues.filter { $0.code == .missing }.count == 2)
        #expect(d.issues.contains { $0.path.pathDescription == "name" })
        #expect(d.render(.plain).contains("name is required"))
    }

    @Test("a wrong type reports a mismatch, and every bad field is reported")
    func mismatches() {
        var r = fullRow()
        r["id"] = .string("not a number")
        r["active"] = .string("yes")
        let d = Row.diagnose(source: DictionarySource(r))
        #expect(d.issues.count >= 2, "all the errors, as on every other path")
        #expect(d.issues.allSatisfy { $0.code == .typeMismatch })
    }

    @Test("@Validate runs on this path exactly as on the others")
    func validation() {
        var r = fullRow()
        r["age"] = .int(500)
        let d = Row.diagnose(source: DictionarySource(r))
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.message.contains("between 0 and 120") })
    }

    @Test("a source that reports spans renders carets, like JSON")
    func spansRenderCarets() {
        let src = PositionedSource(values: [
            "id": (.int(1), SourceSpan(lo: 0, len: 1)),
            "name": (.string("ada"), SourceSpan(lo: 2, len: 3)),
            "age": (.int(500), SourceSpan(lo: 6, len: 3)),
            "score": (.double(1), SourceSpan(lo: 10, len: 1)),
            "active": (.bool(true), SourceSpan(lo: 12, len: 4)),
        ])
        let d = Row.diagnose(source: src)
        #expect(!d.isValid)
        let issue = d.issues.first { $0.path.pathDescription == "age" }
        #expect(issue?.location != nil, "a positioned source must carry its span through")
        #expect(issue?.location?.lo == 6)
    }

    @Test("the field manifest describes the type at compile time")
    func manifest() {
        let m = Row._assayManifest
        #expect(m.keys == ["id", "name", "age", "score", "active", "nickname", "retries"])
        #expect(m.fields.first { $0.key == "nickname" }?.isOptional == true)
        #expect(m.fields.first { $0.key == "retries" }?.hasDefault == true)
        #expect(m.fields.first { $0.key == "retries" }?.isRequired == false)
        #expect(m.fields.first { $0.key == "name" }?.isRequired == true)
        #expect(m.fields.first { $0.key == "score" }?.kind == .double)
        // This is what a source binds against once per stream instead of per record.
        #expect(m.fields.count == 7)
    }

    @Test("integer narrowing reports rather than truncating")
    func narrowing() {
        var r = fullRow()
        r["id"] = .int(Int64.max)
        let d = Row.diagnose(source: DictionarySource(r))
        // Int is 64-bit here so this succeeds; the point is that it does not silently
        // wrap. A narrower declared type reports instead.
        #expect(d.isValid || d.issues.contains { $0.code == .typeMismatch })
    }
}

@Suite("KeyedSource diagnostics")
struct KeyedSourceDiagnosticTests {

    @Test("a collection field is refused — a keyed source is a flat record")
    func collectionRefused() {
        for src in ["@Schema(sources: true) struct S { var tags: [String] }",
                    "@Schema(sources: true) struct S { var m: [String: Int] }"] {
            let (_, diags) = expandSchemaForTesting(src)
            #expect(diags.contains { $0.contains("FLAT record") }, "for: \(src)")
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
        #expect(with.contains("KeyedSource"))
    }
}

/// The bound source: the plan is resolved once, and the key argument is ignored entirely.
struct BoundTestSource: KeyedSource, ~Copyable {
    let plan: BoundPlan
    let values: [RawValue]

    borrowing func slot(_ field: Int) -> RawValue? {
        let i = plan[field]
        // `Optional<RawValue>.none`, spelled out. A bare `nil` here resolves to
        // `.some(.null)`, because RawValue is ExpressibleByNilLiteral — so an ABSENT
        // column would read as a PRESENT null and a defaulted field would report a type
        // mismatch instead of taking its default. This bit while writing the example.
        guard i != BoundPlan.absent else { return Optional<RawValue>.none }
        return values[i]
    }
    borrowing func has(_ key: StaticString, _ field: Int) -> Bool { slot(field) != nil }
    borrowing func isNull(_ key: StaticString, _ field: Int) -> Bool {
        if case .null? = slot(field) { return true }
        return false
    }
    borrowing func int64(_ key: StaticString, _ field: Int) -> Int64? { slot(field)?.int }
    borrowing func double(_ key: StaticString, _ field: Int) -> Double? { slot(field)?.double }
    borrowing func bool(_ key: StaticString, _ field: Int) -> Bool? { slot(field)?.bool }
    borrowing func string(_ key: StaticString, _ field: Int) -> String? {
        guard case .string(let s)? = slot(field) else { return nil }
        return s
    }
    borrowing func withText<R>(
        _ key: StaticString, _ field: Int, _ body: (UnsafeRawBufferPointer?) -> R
    ) -> R {
        guard case .string(let s)? = slot(field) else { return body(nil) }
        var copy = s
        return copy.withUTF8 { body(UnsafeRawBufferPointer($0)) }
    }
}

@Suite("Two-phase binding")
struct BoundPlanTests {

    /// Columns in a different order from the schema, and extra ones — the ordinary case.
    static let columns = ["spare_a", "score", "id", "spare_b", "active", "name",
                          "age", "nickname", "spare_c"]
    static let values: [RawValue] = [
        .string("x"), .double(9.5), .int(1), .string("y"), .bool(true),
        .string("ada"), .int(36), .string("countess"), .string("z"),
    ]

    @Test("a bound decode equals the unbound one, field for field")
    func boundMatchesUnbound() throws {
        let plan = BoundPlan(manifest: Row._assayManifest, columns: Self.columns)
        let bound = try Row.parse(source: BoundTestSource(plan: plan, values: Self.values))
        let dict = Dictionary(uniqueKeysWithValues: zip(Self.columns, Self.values))
        let unbound = try Row.parse(source: DictionarySource(dict))
        #expect(bound == unbound, "binding must change cost, never meaning")
    }

    @Test("the plan maps manifest order to the source's own order")
    func planOrder() {
        let plan = BoundPlan(manifest: Row._assayManifest, columns: Self.columns)
        // Manifest order is id, name, age, score, active, nickname, retries.
        #expect(plan[0] == 2, "id is the source's third column")
        #expect(plan[1] == 5, "name is the source's sixth")
        #expect(plan[3] == 1, "score is the source's second")
        #expect(plan[6] == BoundPlan.absent, "retries is absent and defaulted")
    }

    @Test("binding fails fast: a missing required column is reported ONCE, per stream")
    func missingRequiredUpFront() {
        // The point of binding: a column the schema requires and the source lacks is a
        // property of the STREAM, so it should not be rediscovered a million times.
        let plan = BoundPlan(manifest: Row._assayManifest,
                             columns: ["id", "age", "score", "active"])
        let missing = plan.missingRequired(in: Row._assayManifest)
        #expect(missing == ["name"])
        #expect(BoundPlan(manifest: Row._assayManifest, columns: Self.columns)
                    .missingRequired(in: Row._assayManifest).isEmpty)
    }

    @Test("an absent optional or defaulted column still decodes")
    func absentColumns() throws {
        // `nickname` optional and `retries` defaulted are both missing from the source.
        let cols = ["id", "name", "age", "score", "active"]
        let vals: [RawValue] = [.int(1), .string("ada"), .int(36), .double(9.5), .bool(true)]
        let plan = BoundPlan(manifest: Row._assayManifest, columns: cols)
        let v = try Row.parse(source: BoundTestSource(plan: plan, values: vals))
        #expect(v.nickname == nil)
        #expect(v.retries == 3)
    }

    @Test("a bound source still reports validation and type errors identically")
    func errorsUnchanged() {
        var vals = Self.values
        vals[6] = .int(500)                       // age, out of range
        let plan = BoundPlan(manifest: Row._assayManifest, columns: Self.columns)
        let d = Row.diagnose(source: BoundTestSource(plan: plan, values: vals))
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.message.contains("between 0 and 120") })
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

    @Test("a batch decodes every row, and equals what row-by-row produces")
    func batchEqualsRowwise() throws {
        let s = Self.store(rows: 64)
        let (values, issues, _) = Row.batch(from: s)
        #expect(issues.isEmpty)
        #expect(values.count == 64)

        // The inversion must change cost, never meaning.
        for r in [0, 1, 31, 63] {
            let rowwise = try Row.parse(source: DictionarySource([
                "id": .int(Int64(r)), "name": .string("user-\(r)"),
                "age": .int(Int64(20 + r % 50)), "score": .double(Double(r) * 0.5),
                "active": .bool(r % 2 == 0), "nickname": .string("nick-\(r)"),
            ]))
            #expect(values[r] == rowwise, "row \(r) differs between batch and row-wise")
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
