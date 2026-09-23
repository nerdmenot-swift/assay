// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

// docs/EXPERIENCE.md §4 — the four unknown-key policies, and @Extras as the sink.
// docs/VALUE-MODELS.md open question 2 — @Extras dispatching on a type the macro has
// never heard of, via a per-format protocol.

@Schema(unknownKeys: .collect)
struct Collected {
    var id: String
    @Extras var rest: [String: RawValue]
}

/// The same shape, but keeping full JSON fidelity instead of portability. The only
/// difference is the declared value type — that is the whole trade, written on the struct.
@Schema(unknownKeys: .collect)
struct CollectedFidelity {
    var id: String
    @Extras var rest: [String: JSON.Value]
}

@Schema(unknownKeys: .warn)
struct Warned {
    var timeout: Int
    var retries: Int
}

@Schema(unknownKeys: .reject)
struct Rejected {
    var timeout: Int
}

@Schema
struct IgnoredByDefault {
    var timeout: Int
}

@Suite("Unknown keys and @Extras")
struct ExtrasTests {

    @Test("collect routes unknown keys into the @Extras property")
    func collect() throws {
        let c = try Collected.parse(
            json: #"""
                {"id":"x","count":3,"ratio":1.5,"on":true,"none":null,"tags":["a","b"],
                 "nested":{"k":"v"}}
                """#)
        #expect(c.id == "x")
        #expect(c.rest.count == 6)
        #expect(c.rest["count"] == .int(3))
        #expect(c.rest["ratio"] == .double(1.5))
        #expect(c.rest["on"] == .bool(true))
        #expect(c.rest["none"] == .null)
        #expect(c.rest["tags"] == .sequence([.string("a"), .string("b")]))
        #expect(c.rest["nested"]?["k"] == .string("v"))
        // Declared keys never land in extras.
        #expect(c.rest["id"] == nil)
    }

    @Test("nothing unknown means an empty extras dictionary, not a missing field")
    func collectNothing() throws {
        let c = try Collected.parse(json: #"{"id":"x"}"#)
        #expect(c.id == "x")
        #expect(c.rest.isEmpty)
    }

    @Test("the declared value type picks fidelity vs portability")
    func fidelityVariant() throws {
        // RawValue and JSON.Value are both legal sinks; the struct chooses.
        let f = try CollectedFidelity.parse(json: #"{"id":"x","n":[1,2.5]}"#)
        #expect(f.rest["n"]?[0]?.int == 1)
        #expect(f.rest["n"]?[1]?.double == 2.5)
    }

    @Test("warn produces warnings, not issues, and decoding proceeds")
    func warn() {
        let d = Warned.diagnose(json: #"{"timeout":5,"retries":2,"tiemout":9,"zzz":1}"#)
        #expect(d.isValid)  // warnings do not invalidate
        #expect(d.value?.timeout == 5)
        #expect(d.warnings.count == 2)
        #expect(d.warnings.allSatisfy { $0.code == .unknownKey })
    }

    @Test("did-you-mean fires on a near miss and stays quiet on a far one")
    func _didYouMean() {
        let d = Warned.diagnose(json: #"{"timeout":5,"retries":2,"tiemout":9,"zzz":1}"#)

        let typo = d.warnings.first { $0.params["received"] == .string("tiemout") }
        #expect(typo?.params["didYouMean"] == .string("timeout"))

        // "zzz" is not close to anything. A wrong suggestion is worse than none.
        let far = d.warnings.first { $0.params["received"] == .string("zzz") }
        #expect(far?.params["didYouMean"] == nil)
    }

    @Test("reject turns unknown keys into issues")
    func reject() {
        let d = Rejected.diagnose(json: #"{"timeout":5,"nope":1}"#)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .unknownKey })
        #expect(d.issues.first { $0.code == .unknownKey }?.received == "nope")
    }

    @Test("ignore is the default and stays silent")
    func ignoreDefault() throws {
        let v = try IgnoredByDefault.parse(json: #"{"timeout":5,"a":1,"b":{"c":[1,2]}}"#)
        #expect(v.timeout == 5)
        let d = IgnoredByDefault.diagnose(json: #"{"timeout":5,"a":1}"#)
        #expect(d.warnings.isEmpty)
        #expect(d.issues.isEmpty)
    }

    @Test("collected values keep their source spans for carets")
    func spans() {
        let d = Rejected.diagnose(json: #"{"timeout":5,"nope":1}"#)
        let issue = d.issues.first { $0.code == .unknownKey }
        #expect(issue?.location != nil)
        // The span points at the key itself, not the whole object.
        #expect(issue?.location?.len == 4)  // "nope"
    }

    @Test("deeply nested unknown values are collected whole, not flattened")
    func nestedCollection() throws {
        let c = try Collected.parse(
            json: #"""
                {"id":"x","deep":{"a":{"b":{"c":[1,{"d":true}]}}}}
                """#)
        #expect(c.rest["deep"]?["a"]?["b"]?["c"]?[1]?["d"] == .bool(true))
    }

    @Test("edit distance is bounded, so unrelated keys suggest nothing")
    func editDistanceBounds() {
        // Short keys allow 1 edit, longer ones 2. Verified through the public behaviour
        // rather than the internal helper.
        let d = Warned.diagnose(json: #"{"timeout":1,"retries":1,"retrie":9,"qqqqqqqq":1}"#)
        let near = d.warnings.first { $0.params["received"] == .string("retrie") }
        #expect(near?.params["didYouMean"] == .string("retries"))
        let far = d.warnings.first { $0.params["received"] == .string("qqqqqqqq") }
        #expect(far?.params["didYouMean"] == nil)
    }
}

// MARK: - Parity between the JSON body and the RawValue body
//
// Both bugs below were the same shape: the JSON body had always been right and the
// RawValue body had never been checked against it, because every test of these two
// features used JSON. Found 2026-09-11 by rendering the same example as TOML for the
// website, which is the cheapest differential this project has.

@Schema(keys: .snakeCase, unknownKeys: .collect, formats: .all)
struct PathAndExtras: Equatable {
    var id: Int
    @Key(path: "profile.display_name") var displayName: String
    @Extras var rest: [String: RawValue]
}

@Schema(keys: .snakeCase, unknownKeys: .reject, formats: .all)
struct RejectsUnknown: Equatable { var apiKey: String }

@Suite("JSON and RawValue report unknown keys identically")
struct UnknownKeyParityTests {

    /// A key the schema reached THROUGH is not an unknown key. The JSON dispatch table
    /// has an arm for the prefix so it never reaches the unknown handler; the RawValue
    /// body descends into paths separately and used to collect the prefix as an extra.
    @Test("a @Key(path:) prefix is not collected into @Extras, on either path")
    func pathPrefixIsNotAnExtra() throws {
        let json = #"{"id": 1, "profile": {"display_name": "Jo"}, "other": 2}"#
        let toml = """
            id = 1
            other = 2

            [profile]
            display_name = "Jo"
            """
        let fromJSON = try PathAndExtras.parse(json: json)
        let fromTOML = try PathAndExtras.parse(toml: toml)
        #expect(fromJSON.displayName == "Jo")
        #expect(fromJSON.rest.keys.sorted() == ["other"])
        #expect(
            fromTOML.rest.keys.sorted() == fromJSON.rest.keys.sorted(),
            "TOML collected \(fromTOML.rest.keys.sorted())")
    }

    /// An unknown key carried a source span on JSON and none at all on the RawValue
    /// formats, so the caret was missing exactly where a config file needs it most.
    @Test("an unknown key carries a location on every format")
    func unknownKeyHasALocation() {
        let json = RejectsUnknown.diagnose(json: #"{"api_key": "k", "nope": 1}"#)
        let yaml = RejectsUnknown.diagnose(yaml: "api_key: k\nnope: 1\n")
        let toml = RejectsUnknown.diagnose(toml: "api_key = \"k\"\nnope = 1\n")
        for (name, d) in [("json", json), ("yaml", yaml), ("toml", toml)] {
            let unknown = d.issues.first { $0.code == .unknownKey }
            #expect(unknown != nil, "\(name) reported no unknown key")
            #expect(unknown?.location != nil, "\(name) unknown key has no location")
        }
    }
}
