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

    /// An unrecognised type is EMITTED FOR, not refused.
    ///
    /// This is the behaviour change the extension point exists for. Expansion is syntactic:
    /// `Date`, `UUID`, a consumer's `Timestamp` and a genuine nested `@Schema` all arrive
    /// as the same identifier token, so refusing everything unrecognised refused four
    /// perfectly representable types in order to catch the one that is not. The conformance
    /// is now what decides, and only the compiler can check it.
    @Test("an unrecognised type routes through ColumnDecodable rather than being refused")
    func unknownTypesTakeTheHook() {
        for (type, field) in [("Date", "takenAt"), ("UUID", "id"), ("Timestamp", "at"),
                              ("Decimal128", "amount")] {
            let (src, diags) = expandSchemaForTesting("""
            @Schema(sources: true) struct S { var \(field): \(type) }
            """)
            #expect(diags.isEmpty, "\(type) should expand cleanly, got: \(diags)")
            // One generic fetch per column...
            #expect(src.contains("_assayFetchColumn(\n        \(type).self")
                    || src.contains("_assayFetchColumn(\(type).self")
                    || src.contains("\(type).self, from: source"), "for: \(type)")
            // ...and a per-row call that names the type concretely, which is the whole
            // reason this costs 0.47 ns/value and KeyedSource's shape cost 21.
            #expect(src.contains("\(type)(assayColumn:"), "for: \(type)")
            #expect(src.contains(".custom(\"\(type)\")"), "manifest kind, for: \(type)")
        }
    }

    /// `[UInt8]` is a blob column, and the thing that used to block it was upstream.
    ///
    /// This test asserted the opposite until 2026-08-31, and the reason is worth keeping:
    /// the columnar half was built and waiting, but `UInt8` was not a scalar on the TREE
    /// path, so `var payload: [UInt8]` could not appear in any `@Schema` type at all — the
    /// JSON body failed with "type 'UInt8' has no member '_assay'" long before the columnar
    /// body was consulted. Shipping the conformance then would have been a road to a
    /// bricked-up door. The narrow integer widths landed and the door opened.
    @Test("[UInt8] is a bytes column, not a refused collection")
    func bytesIsAScalar() {
        let (src, diags) = expandSchemaForTesting("""
        @Schema(sources: true) struct S { var payload: [UInt8] }
        """)
        #expect(diags.isEmpty, "got: \(diags)")
        #expect(src.contains(".bytes"), "manifest kind")
        #expect(src.contains("[UInt8](assayColumn:"), "goes through ColumnDecodable")
    }

    /// Every narrow width rides `int64Column` and carries its own manifest kind, so a
    /// binder can tell `UInt8` from `Int64` rather than being told they are the same.
    @Test("the narrow integer widths are columnar scalars")
    func narrowWidthsAreColumnar() {
        for (type, kind) in [("Int8", "int8"), ("Int16", "int16"), ("UInt8", "uint8"),
                             ("UInt16", "uint16"), ("UInt32", "uint32"), ("UInt64", "uint64")] {
            let (src, diags) = expandSchemaForTesting("""
            @Schema(sources: true) struct S { var x: \(type) }
            """)
            #expect(diags.isEmpty, "for \(type): \(diags)")
            #expect(src.contains(".\(kind)"), "manifest kind for \(type)")
            #expect(src.contains("int64Column"), "accessor for \(type)")
        }
    }

    /// A genuine nested schema now fails in the type checker rather than at expansion.
    /// Expansion cannot tell it apart from `Date`; what it CAN do is not guess.
    @Test("a tree-shaped field is still refused at expansion")
    func collectionsStillRefused() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(sources: true) struct S { var rows: [Other] }
        """)
        #expect(diags.contains { $0.contains("flat scalar columns") })
    }

    /// `formats: []` with `sources: true` is the ONLY correct spelling for a type that
    /// decodes from a column store and nothing else, so it has to compile.
    ///
    /// It used to be refused, with a diagnostic saying the macro "would generate nothing" —
    /// untrue of that declaration, which emits both a manifest and a batch body. The cost
    /// was not the wrong sentence: a columnar-only type carrying a consumer's own scalar
    /// cannot use `formats: .json` either, because the JSON byte path calls
    /// `T._assay(from: AssayReader…)` and that is not a public protocol requirement. The
    /// only thing that compiled was `formats: .yaml, sources: true` plus a `RawDecodable`
    /// conformance per custom type that would never be called.
    @Test("formats: [] with sources: true expands, and emits a real body")
    func sourcesAloneIsEnough() {
        let (src, diags) = expandSchemaForTesting("""
        @Schema(formats: [], sources: true)
        struct Reading { var id: Int64; var value: Double }
        """)
        #expect(diags.isEmpty, "got: \(diags)")
        #expect(src.contains("_assayManifest"))
        #expect(src.contains("_assayBatch"))
        #expect(src.contains("SourceDecodable"))
        // The point of `formats: []` is what is NOT paid for.
        #expect(!src.contains("JSONAssayable"))
        #expect(!src.contains("RawDecodable"))
    }

    /// The case the guard is actually for, which is still a mistake worth refusing.
    @Test("formats: [] with nothing else at all is still refused")
    func emptyFormatsWithNothingIsStillRefused() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(formats: []) struct S { var a: Int }
        """)
        let d = diags.first { $0.contains("generate nothing") }
        #expect(d != nil)
        // The message enumerates every way out, so `sources` has to appear among them now.
        #expect(d?.contains("sources: true") == true, "got: \(d ?? "none")")
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
    var blobs: [String: BytesColumn] = [:]
    var meta: [String: ColumnMetadata] = [:]

    borrowing func nulls(_ key: StaticString, _ field: Int) -> [Bool]? {
        masks[String(describing: key)]
    }
    borrowing func bytesColumn(_ key: StaticString, _ field: Int) -> BytesColumn? {
        blobs[String(describing: key)]
    }
    borrowing func columnMetadata(_ key: StaticString, _ field: Int) -> ColumnMetadata {
        meta[String(describing: key)] ?? .none
    }
}

// MARK: - The extension point, exercised

/// A consumer's own scalar. Assay has never heard of this type, and the point of the
/// exercise is that it does not need to: the `ColumnDecodable` conformance below is the
/// entire columnar integration.
///
/// `@Schema` here supplies the TREE path — `_assay(from:)` for JSON and for `RawValue` —
/// which a field type needs regardless of where it is read from, because a `@Schema` type's
/// standing promise is `T.parse(json:)`. The two halves are independent and both required.
@Schema
struct Instant: Equatable {
    var epochNanoseconds: Int64
}

extension Instant: ColumnDecodable {
    /// `Int64` and not `Double`, which is the reason `AssayCarrier` includes it. A `Double`
    /// carries 2^53 nanoseconds — about 104 days — so it cannot hold a modern instant at
    /// nanosecond resolution at all.
    init?(assayColumn c: borrowing ColumnBuffer<Int64>, row: Int, metadata m: ColumnMetadata) {
        // The unit came from the COLUMN, not from this type. Two files with the same
        // logical schema are allowed to disagree, which is why it cannot live in the type.
        let scale: Int64
        switch m.unit {
        case -9: scale = 1
        case -6: scale = 1_000
        case -3: scale = 1_000_000
        default: return nil          // a unit this type cannot represent: report the row
        }
        // Overflow-checked, and NOT for tidiness. A value that is plausible at microsecond
        // magnitude is 1.7e15, and reading that same column as milliseconds multiplies by
        // 1e6 and leaves Int64 entirely -- so a source that mislabels its unit would trap
        // inside somebody else's decode loop. `init?` already means "I cannot represent
        // this", which is the correct answer and costs one instruction to give.
        let (n, overflowed) = c[row].multipliedReportingOverflow(by: scale)
        guard !overflowed else { return nil }
        epochNanoseconds = n
    }
}

/// A blob-backed scalar, to exercise the flat-plus-offsets column.
@Schema
struct Fingerprint: Equatable {
    var hex: String
}

extension Fingerprint: ColumnDecodable {
    init?(assayColumn c: borrowing BytesColumn, row: Int, metadata: ColumnMetadata) {
        // Read through the range and index the flat buffer: this copies nothing and
        // retains nothing, which is what flat-plus-offsets buys over `[[UInt8]]`.
        guard let r = c.range(at: row), r.count == 4 else { return nil }
        var out = ""
        out.reserveCapacity(8)
        for i in r { out += String(c.bytes[i], radix: 16, uppercase: false).leftPadded() }
        hex = out
    }
}

extension String {
    fileprivate func leftPadded() -> String { count == 1 ? "0" + self : self }
}

@Schema(sources: true)
struct Sample: Equatable {
    var id: Int64
    var at: Instant
    var mark: Fingerprint
    var note: String?
}

@Suite("The columnar extension point")
struct ColumnDecodableTests {

    static func store(rows n: Int, unit: Int32 = -6) -> ColumnStore {
        ColumnStore(
            rowCount: n,
            ints: ["id": (0..<n).map { Int64($0) },
                   "at": (0..<n).map { Int64(1_700_000_000_000_000 + $0) }],
            blobs: ["mark": BytesColumn(rows: (0..<n).map {
                        [UInt8($0 % 251), 0xAB, 0xCD, UInt8($0 % 7)] })],
            meta: ["at": ColumnMetadata(unit: unit)])
    }

    @Test("a type Assay has never heard of decodes, and the unit comes from the column")
    func customScalar() {
        var sink = IssueSink(limits: .default)
        let rows = Sample._assayBatch(from: Self.store(rows: 64), into: &sink, at: [])
        #expect(sink.issues.isEmpty)
        #expect(rows.count == 64)
        // micros x 1_000 = nanos. The schema never named a unit.
        #expect(rows[3].at == Instant(epochNanoseconds: 1_700_000_000_000_003_000))
        #expect(rows[3].mark == Fingerprint(hex: "03abcd03"))
        #expect(rows[0].note == nil)
    }

    /// The same bytes, the same schema, a different column unit. This is the case a type
    /// that hard-codes its unit gets wrong, and the reason `ColumnMetadata` exists.
    @Test("the same column at a different unit decodes to different instants")
    func unitIsData() {
        var sink = IssueSink(limits: .default)
        let nanos = Sample._assayBatch(from: Self.store(rows: 4, unit: -9), into: &sink, at: [])
        let micros = Sample._assayBatch(from: Self.store(rows: 4, unit: -6), into: &sink, at: [])
        #expect(sink.issues.isEmpty)
        #expect(micros[1].at.epochNanoseconds == nanos[1].at.epochNanoseconds * 1_000)
    }

    /// The same column read at a unit that pushes it out of Int64. A source that mislabels
    /// its metadata must produce issues, not a trap in the caller's loop.
    @Test("a conversion that overflows reports the row rather than trapping")
    func overflowIsReported() {
        var sink = IssueSink(limits: .default)
        // 1.7e15 microseconds read as milliseconds is 1.7e21, well past Int64.
        let rows = Sample._assayBatch(from: Self.store(rows: 3, unit: -3), into: &sink, at: [])
        #expect(rows.isEmpty)
        #expect(sink.issues.count == 3)
        #expect(sink.issues[0].path == [.index(0), .key("at")])
    }

    /// `init?` returning nil is how a type says "this column can hold that, I cannot".
    /// It must land as a normal row issue, with the path and the row index.
    @Test("a conversion that fails reports the row, not the batch")
    func refusedConversion() {
        var sink = IssueSink(limits: .default)
        // unit 0 is the `default:` arm of Instant's initialiser, which returns nil.
        let rows = Sample._assayBatch(from: Self.store(rows: 3, unit: 0), into: &sink, at: [])
        #expect(rows.isEmpty, "every row's required field failed to convert")
        #expect(sink.issues.count == 3, "one per row, not one for the batch")
        #expect(sink.issues.allSatisfy { $0.code == .missing })
        #expect(sink.issues[1].path == [.index(1), .key("at")])
    }

    @Test("a validity mask nulls a custom column exactly as it does a built-in one")
    func nullsApply() {
        var store = Self.store(rows: 4)
        store.masks["at"] = [false, true, false, false]
        var sink = IssueSink(limits: .default)
        let rows = Sample._assayBatch(from: store, into: &sink, at: [])
        #expect(rows.count == 3, "row 1 is null and `at` is required")
        #expect(sink.issues.count == 1)
        #expect(sink.issues[0].path == [.index(1), .key("at")])
    }

    /// A required column the source does not carry is a property of the SOURCE, so it is
    /// reported once — the same rule the built-in columns already follow.
    @Test("a missing custom column is reported once for the batch")
    func missingColumn() {
        var sink = IssueSink(limits: .default)
        var store = Self.store(rows: 100)
        store.ints["at"] = nil
        _ = Sample._assayBatch(from: store, into: &sink, at: [])
        let missing = sink.issues.filter { $0.code == .custom("missing_column") }
        #expect(missing.count == 1)
        #expect(missing.first?.params["expected"] == .string("Instant"),
                "the declared type, not the manifest kind's spelling")
    }
}

@Suite("Bytes columns")
struct BytesColumnTests {

    @Test("flat-plus-offsets round-trips what a row-of-blobs source hands over")
    func roundTrip() {
        let rows: [[UInt8]] = [[], [1], [2, 3, 4], [], [5, 6]]
        let c = BytesColumn(rows: rows)
        #expect(c.count == 5)
        #expect(c.bytes == [1, 2, 3, 4, 5, 6], "one buffer, not five")
        #expect(c.offsets == [0, 0, 1, 4, 4, 6])
        for (i, r) in rows.enumerated() {
            #expect(c.bytes(at: i) == r)
            #expect(c.slice(at: i).map(Array.init) == r)
        }
    }

    /// The offsets come from the source, so they are input, not an invariant. A reader with
    /// a bug must produce a nil row, never a trap in someone else's decode loop.
    @Test("malformed offsets yield nil rows rather than trapping")
    func malformedOffsets() {
        let cases: [[Int]] = [
            [0, 5, 3],           // not monotonic
            [0, 99],             // past the end of the buffer
            [-1, 2],             // negative
            [],                  // no offsets at all
        ]
        for offsets in cases {
            let c = BytesColumn(bytes: [1, 2, 3], offsets: offsets)
            for r in -1...3 {
                #expect(c.bytes(at: r) == nil || c.range(at: r) != nil, "offsets \(offsets)")
                _ = c.slice(at: r)
            }
        }
        // The specific one worth naming: a valid-length offsets array with a backwards pair.
        #expect(BytesColumn(bytes: [1, 2, 3], offsets: [0, 5, 3]).bytes(at: 0) == nil)
        #expect(BytesColumn(bytes: [1, 2, 3], offsets: [0, 2, 99]).bytes(at: 1) == nil)
        #expect(BytesColumn(bytes: [1, 2, 3], offsets: [0, 2, 99]).bytes(at: 0) == [1, 2])
    }

    @Test("a source that leaves nulls and metadata off the column still gets them")
    func fallsBackToPerColumnAccessors() {
        let store = ColumnStore(
            rowCount: 2,
            masks: ["mark": [true, false]],
            blobs: ["mark": BytesColumn(rows: [[1, 2, 3, 4], [5, 6, 7, 8]])],
            meta: ["mark": ColumnMetadata(scale: 7)])
        let c = BytesColumn._assayFetch(from: store, "mark", 0)
        #expect(c?.nulls == [true, false])
        #expect(c?.metadata.scale == 7)
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
