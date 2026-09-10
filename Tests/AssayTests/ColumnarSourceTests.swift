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
    @Test("an @AsyncCheck on a sources: true type is refused — the batch is synchronous")
    func asyncCheckRefused() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(sources: true) struct S {
            var a: Int
            @AsyncCheck static func f(_ v: S, _ i: inout Issues<S>) async {}
        }
        """)
        #expect(diags.contains { $0.contains("@AsyncCheck") && $0.contains("synchronous") }, "\(diags)")
    }

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
        let missing = plan._missingRequired(in: Row._assayManifest)
        #expect(missing == ["name"])
        #expect(BoundPlan(manifest: Row._assayManifest, columns: Self.columns)
                    ._missingRequired(in: Row._assayManifest).isEmpty)
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
