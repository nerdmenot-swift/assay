// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// [String: T] dictionary fields — the gap that read as a bug rather than a roadmap
// item. A serde without dictionary decode is a wall a user hits in the first ten
// minutes, and PERFORMANCE.md §2.5 calls it the structural worst case, so it needs to
// exist before any of that can be measured rather than assumed.
//===----------------------------------------------------------------------===//

import Testing
import Assay

@Schema
struct Counts {
    var byRegion: [String: Int]
    var weights: [String: Double]?
    var labels: [String: String] = [:]
}

@Schema
struct Team {
    var name: String
}

@Schema
struct DictOrg {
    var teams: [String: Team]
    var matrix: [String: [Int]]
    var deep: [String: [String: Int]]
    var rows: [[String: Int]]
}

@Schema
struct OpenMap {
    var meta: [String: RawValue]
}

@Schema(keys: .snakeCase, formats: .all)
struct RawCounts {
    var byRegion: [String: Int]
    var teams: [String: Team2]
}

@Schema(formats: .all)
struct Team2 {
    var name: String
}

@Suite("[String: T] dictionary fields")
struct DictionaryTests {

    @Test("scalar values, optional dictionaries, defaulted dictionaries")
    func scalars() throws {
        let c = try Counts.parse(json: Array("""
        {"byRegion": {"eu": 3, "us": 5}, "weights": null}
        """.utf8))
        #expect(c.byRegion == ["eu": 3, "us": 5])
        #expect(c.weights == nil)
        #expect(c.labels == [:])       // absent, default applies

        let d = try Counts.parse(json: Array("""
        {"byRegion": {}, "weights": {"a": 0.5}, "labels": {"x": "y"}}
        """.utf8))
        #expect(d.byRegion.isEmpty)
        #expect(d.weights == ["a": 0.5])
        #expect(d.labels == ["x": "y"])
    }

    @Test("nested schema values, arrays in dictionaries, dictionaries in arrays, dictionaries in dictionaries")
    func nesting() throws {
        let o = try DictOrg.parse(json: Array("""
        {"teams": {"core": {"name": "Core"}, "infra": {"name": "Infra"}},
         "matrix": {"a": [1, 2], "b": []},
         "deep": {"outer": {"inner": 7}},
         "rows": [{"x": 1}, {"y": 2}]}
        """.utf8))
        #expect(o.teams["core"]?.name == "Core")
        #expect(o.teams.count == 2)
        #expect(o.matrix["a"] == [1, 2])
        #expect(o.matrix["b"] == [])
        #expect(o.deep["outer"]?["inner"] == 7)
        #expect(o.rows.count == 2)
        #expect(o.rows[1]["y"] == 2)
    }

    @Test("an open map as an ordinary field, not @Extras")
    func openMap() throws {
        let m = try OpenMap.parse(json: Array("""
        {"meta": {"n": 1, "s": "x", "b": true, "z": null, "a": [1], "o": {"k": "v"}}}
        """.utf8))
        #expect(m.meta.count == 6)
        #expect(m.meta["n"] == .int(1))
        #expect(m.meta["b"] == .bool(true))
        #expect(m.meta["z"] == .null)
        #expect(m.meta["o"] == .mapping([.init(key: "k", value: .string("v"))]))
    }

    @Test("duplicate keys keep the last value — JSONDecoder's behaviour")
    func duplicates() throws {
        let c = try Counts.parse(json: Array("""
        {"byRegion": {"eu": 1, "eu": 2}}
        """.utf8))
        #expect(c.byRegion == ["eu": 2])
    }

    @Test("a scalar where the object should be is a type mismatch naming the field")
    func mismatch() {
        let d = Counts.diagnose(json: Array("{\"byRegion\": 5}".utf8))
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .typeMismatch })
    }

    @Test("null on a required dictionary is refused, on an optional one accepted")
    func nulls() {
        #expect(!Counts.diagnose(json: Array("{\"byRegion\": null}".utf8)).isValid)
    }

    @Test("YAML and XML decode dictionaries through the RawValue path")
    func rawPath() throws {
        let y = try RawCounts.parse(yaml: """
        by_region:
          eu: 3
          us: 5
        teams:
          core:
            name: Core
        """)
        #expect(y.byRegion == ["eu": 3, "us": 5])
        #expect(y.teams["core"]?.name == "Core")

        // XML scalars are text; Int values without coercion are a mismatch, reported —
        // never a guess. The coerced variant below is the working XML arm.
        #expect(throws: (any Error).self) {
            try RawCounts.parse(xml: """
            <r><by_region><eu>3</eu><us>5</us></by_region>\
            <teams><core><name>Core</name></core></teams></r>
            """)
        }
    }

    @Test("XML dictionaries with coerced scalars decode")
    func xmlCoerced() throws {
        let x = try CoercedCounts.parse(xml: """
        <r><by_region><eu>3</eu><us>5</us></by_region></r>
        """)
        #expect(x.byRegion == ["eu": 3, "us": 5])
    }
}

@Schema(keys: .snakeCase, coerceScalars: true, formats: .all)
struct CoercedCounts {
    var byRegion: [String: Int]
}

@Suite("Dictionary macro diagnostics")
struct DictionaryDiagnosticTests {

    @Test("a non-String key is a purpose-written error, not a type error in generated code")
    func nonStringKey() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S { var m: [Int: String] }
        """)
        #expect(diags.contains { $0.contains("keyed by String") && $0.contains("'m'") })
    }

    @Test("the walk finds nested offenders too")
    func nested() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S { var m: [String: [Int: Bool]] }
        """)
        #expect(diags.contains { $0.contains("keyed by String") })
    }

    @Test("[[String: Int]] is an array of dictionaries, not a parse failure")
    func arrayOfDicts() {
        let (expansion, diags) = expandSchemaForTesting("""
        @Schema struct S { var rows: [[String: Int]] }
        """)
        #expect(diags.isEmpty)
        #expect(expansion.contains("decodeInt"))
        #expect(expansion.contains("keyString"))
    }
}
