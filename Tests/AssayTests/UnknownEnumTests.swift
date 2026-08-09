// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Open enums: `@Unknown`, and question 2 of docs/ENCODING.md closed.
//
// The decision under test: an unrecognised variant round-trips ONLY when the declaration
// opts in. Writing it back by default would let an attacker-supplied string pass through
// a type that reads, at every use site, as a closed set — the same reasoning that makes
// `accepting:` required with no default on content negotiation.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayYAML
import AssayXML

@Schema(formats: .all, encodes: true)
enum Status: Equatable {
    case active, suspended
    @Unknown case other(String)
}

@Schema(encodes: true)
enum Loose: Equatable {
    case one
    @Unknown(roundTrips: true) case other(String)
}

@Schema(keys: .snakeCase, encodes: true)
enum Renamed: Equatable {
    case inProgress
    @Key("DONE") case done
    @Unknown case other(String)
}

@Schema(formats: .all, encodes: true)
struct Envelope: Equatable {
    var status: Status
}

@Suite("Open enums (@Unknown)")
struct UnknownEnumTests {

    @Test("a known variant decodes as itself; an unknown one is captured, not rejected")
    func decoding() throws {
        #expect(try Envelope.parse(json: Array(#"{"status":"active"}"#.utf8)).status == .active)
        // The whole point: a v1 client meeting a v2 server does not fail.
        let d = Envelope.diagnose(json: Array(#"{"status":"archived"}"#.utf8))
        #expect(d.isValid, "an unrecognised variant must not be an error")
        #expect(d.value?.status == .other("archived"))
    }

    @Test("wire names honour keys: and @Key")
    func naming() throws {
        #expect(Renamed._assayFromWire("in_progress") == .inProgress)
        #expect(Renamed._assayFromWire("DONE") == .done)
        #expect(Renamed._assayFromWire("nope") == .other("nope"))
        #expect(Renamed.inProgress._assayWire == "in_progress")
        #expect(Renamed.done._assayWire == "DONE")
    }

    @Test("known variants encode and round-trip")
    func encodeKnown() throws {
        for s in [Status.active, .suspended] {
            let v = Envelope(status: s)
            #expect(try Envelope.parse(json: v.encodedJSON()) == v)
        }
    }

    /// Question 2's answer, and the reason it is the default.
    @Test("an unrecognised variant is REFUSED by the encoder unless it opted in")
    func unknownRefusedByDefault() {
        let v = Envelope(status: .other("archived"))
        let d = v.diagnoseEncodeJSON()
        #expect(!d.isValid, "writing an unvetted value back must not be silent")
        let issue = d.issues.first { $0.code == .unknownNotEncodable }
        #expect(issue != nil)
        #expect(issue?.received == "archived")
        #expect(issue?.message.contains("roundTrips: true") == true,
                "the error must name the escape hatch")
        #expect(throws: AssayError.self) { try v.encodedJSON() }
    }

    @Test("@Unknown(roundTrips: true) writes it back faithfully")
    func roundTripsOptIn() throws {
        let v = Loose.other("brand-new")
        var sink = IssueSink()
        var w = JSONWriter()
        v._assayEncode(into: &w, into: &sink, at: [])
        #expect(sink.isValid)
        #expect(String(decoding: w.finish(), as: UTF8.self) == "\"brand-new\"")
    }

    @Test("the refusal reaches every format, not just JSON")
    func allFormats() throws {
        let good = Envelope(status: .active)
        #expect(try Envelope.parse(yaml: good.encodedYAML()) == good)
        #expect(try Envelope.parse(xml: good.encodedXML()) == good)

        let bad = Envelope(status: .other("x"))
        #expect(!bad.diagnoseEncodeYAML().isValid, "YAML must refuse it too")
        #expect(!bad.diagnoseEncodeXML().isValid, "XML must refuse it too")
    }

    @Test("open enums decode from YAML and XML as well as JSON")
    func multiFormat() throws {
        #expect(try Envelope.parse(yaml: "status: active\n").status == .active)
        #expect(try Envelope.parse(yaml: "status: brand-new\n").status == .other("brand-new"))
        #expect(try Envelope.parse(xml: "<r><status>active</status></r>").status == .active)
    }
}

@Suite("Open enum diagnostics")
struct UnknownEnumDiagnosticTests {

    @Test("@Schema on an enum with no @Unknown points back at the zero-cost path")
    func noUnknownCase() {
        let (_, diags) = expandSchemaForTesting("@Schema enum E { case a, b }")
        #expect(diags.contains {
            $0.contains("@Unknown") && $0.contains("closed enum needs no macro")
        })
    }

    @Test("an @Unknown case must carry exactly one String")
    func badPayload() {
        for src in ["@Schema enum E { case a; @Unknown case other }",
                    "@Schema enum E { case a; @Unknown case other(Int) }",
                    "@Schema enum E { case a; @Unknown case other(String, Int) }"] {
            let (_, diags) = expandSchemaForTesting(src)
            #expect(diags.contains { $0.contains("exactly one String") }, "for: \(src)")
        }
    }

    @Test("only the @Unknown case may carry an associated value")
    func payloadOnKnownCase() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema enum E { case a(Int); @Unknown case other(String) }
        """)
        #expect(diags.contains { $0.contains("only the") && $0.contains("@Unknown") })
    }

    @Test("two @Unknown cases are refused")
    func twoUnknowns() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema enum E { case a; @Unknown case x(String); @Unknown case y(String) }
        """)
        #expect(diags.contains { $0.contains("only one @Unknown") })
    }
}
