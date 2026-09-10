// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The columnar EXTENSION POINT: a consumer's own scalar crossing a column store without
// Assay learning its name (`docs/COLUMN-DECODABLE.md`), bytes columns, and the batch
// fill. Split out of ColumnarSourceTests.swift on 2026-09-10; the fixtures it needs are
// declared here.
//===----------------------------------------------------------------------===//

import Testing
import Assay

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

/// The row path is emitted differently depending on whether the loop needs it eagerly:
/// inlined into the failure branches when the schema has no rules, bound once per row when
/// it does. Both spellings have to produce the same diagnostics, so both are pinned here.
@Schema(sources: true)
struct RowPathPlain: Equatable { var a: Int64; var b: Int64 }

@Schema(sources: true)
struct RowPathRuled: Equatable {
    var a: Int64
    @Validate(.range(0...100)) var b: Int64
}

@Suite("Row indices survive both row-path spellings")
struct RowPathTests {

    /// A store whose second column stops early, so rows 2 and 3 are missing `b`.
    struct Short: ColumnarSource {
        var rowCount = 4
        borrowing func int64Column(_ k: StaticString, _ f: Int) -> [Int64]? {
            f == 0 ? [1, 2, 3, 4] : [1, 2]
        }
        borrowing func doubleColumn(_ k: StaticString, _ f: Int) -> [Double]? { nil }
        borrowing func boolColumn(_ k: StaticString, _ f: Int) -> [Bool]? { nil }
        borrowing func stringColumn(_ k: StaticString, _ f: Int) -> [String]? { nil }
    }

    /// No rules — the path is built inside `_assayRowMissing`'s branch. If that expression
    /// were ever wrong, this is where it shows: the index has to be the row that failed,
    /// not the row the loop happened to be on when the value was materialised.
    @Test("a rule-free schema names the failing row")
    func plainNamesTheRow() {
        var sink = IssueSink(limits: .default)
        let rows = RowPathPlain._assayBatch(from: Short(), into: &sink, at: [])
        #expect(rows.count == 2)
        #expect(sink.issues.map(\.path) == [[.index(2), .key("b")], [.index(3), .key("b")]])
    }

    /// Rules present — the binding is kept, and must still be the same path.
    @Test("a rule-carrying schema names the failing row identically")
    func ruledNamesTheRow() {
        var sink = IssueSink(limits: .default)
        let rows = RowPathRuled._assayBatch(from: Short(), into: &sink, at: [])
        #expect(rows.count == 2)
        #expect(sink.issues.map(\.path) == [[.index(2), .key("b")], [.index(3), .key("b")]])
    }

    /// And a rule failure, which is the other reader of the path.
    @Test("a rule failure carries the row index")
    func ruleFailureCarriesIndex() {
        struct Bad: ColumnarSource {
            var rowCount = 3
            borrowing func int64Column(_ k: StaticString, _ f: Int) -> [Int64]? {
                f == 0 ? [1, 2, 3] : [5, 999, 7]
            }
            borrowing func doubleColumn(_ k: StaticString, _ f: Int) -> [Double]? { nil }
            borrowing func boolColumn(_ k: StaticString, _ f: Int) -> [Bool]? { nil }
            borrowing func stringColumn(_ k: StaticString, _ f: Int) -> [String]? { nil }
        }
        var sink = IssueSink(limits: .default)
        _ = RowPathRuled._assayBatch(from: Bad(), into: &sink, at: [])
        #expect(sink.issues.count == 1)
        #expect(sink.issues[0].path == [.index(1), .key("b")])
    }

    /// A non-empty parent path must survive too — the inlined form appends to it rather
    /// than replacing it.
    @Test("a nested parent path is preserved, not discarded")
    func parentPathPreserved() {
        var sink = IssueSink(limits: .default)
        _ = RowPathPlain._assayBatch(from: Short(), into: &sink, at: [.key("data")])
        #expect(sink.issues.first?.path == [.key("data"), .index(2), .key("b")])
    }
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
        let missing = sink.issues.filter { $0.code == .missingColumn }
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
        #expect(issues.filter { $0.code == .missingColumn }.count == 1,
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
