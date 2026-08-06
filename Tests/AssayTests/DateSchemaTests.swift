// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// @Schema with Date fields, end to end.
//
// `Date` here is a LOCAL STUB, and that is the point, not a workaround: the macro keys
// on the type NAME and emits `Date(timeIntervalSince1970:)` unqualified, which resolves
// to whatever `Date` means in the user's file. These tests prove that seam directly.
// (They also cannot import Foundation: swift-testing's _Testing_Foundation overlay has
// a macOS 13 floor and this package refuses a platforms clause.) The same generated
// code against the real Foundation.Date runs in Benchmarks/DiffFuzz and AssayBench.
//===----------------------------------------------------------------------===//

import Testing
import Assay

/// The stand-in. Everything the generated code needs from a date type: the initializer
/// it emits and the property validation reads.
struct Date: Sendable, Equatable {
    var timeIntervalSince1970: Double
    init(timeIntervalSince1970: Double) { self.timeIntervalSince1970 = timeIntervalSince1970 }
}

@Schema(keys: .snakeCase)
struct Event {
    var name: String
    var createdAt: Date                                   // ISO-8601, the default
    @DateFormat(.unixSeconds) var recordedAt: Date
    @DateFormat(.iso8601, .unixMillis) var updatedAt: Date // candidate chain
    var deletedAt: Date?
}

@Schema(keys: .snakeCase, formats: .all)
struct Audit {
    var action: String
    var at: Date
}

@Schema
struct Window {
    @Validate(.after("2020-01-01"), .before("2030-01-01T00:00:00Z"))
    var opens: Date
    @Validate(.between("2020-01-01", "2030-01-01"))
    var closes: Date
}

@Schema
struct Sturdy {
    @Fallback(Date(timeIntervalSince1970: 0)) var seen: Date
    @DateFormat(.pattern("yyyy-MM-dd")) var day: Date
    var stamps: [Date] = []
}

@Suite("@Schema Date fields")
struct DateSchemaTests {

    @Test("the four declaration shapes decode")
    func shapes() throws {
        let e = try Event.parse(json: Array("""
        {"name": "deploy",
         "created_at": "2026-08-06T12:00:00Z",
         "recorded_at": 1754481600,
         "updated_at": "2026-08-06T12:00:00Z",
         "deleted_at": null}
        """.utf8))
        #expect(e.createdAt == Date(timeIntervalSince1970: 1_786_017_600))
        #expect(e.recordedAt == Date(timeIntervalSince1970: 1_754_481_600))
        #expect(e.updatedAt == e.createdAt)
        #expect(e.deletedAt == nil)
    }

    @Test("absent required dates report as missing")
    func keyStyle() {
        let d = Event.diagnose(json: Array("{\"name\":\"x\"}".utf8))
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .missing })
    }

    @Test("a candidate chain: the fallback format matches, with a warning")
    func fallbackFormatWarns() throws {
        let d = Event.diagnose(json: Array("""
        {"name": "deploy",
         "created_at": "2026-08-06T12:00:00Z",
         "recorded_at": 1754481600,
         "updated_at": 1754481600000}
        """.utf8))
        let e = try d.get()
        #expect(e.updatedAt == Date(timeIntervalSince1970: 1_754_481_600))
        #expect(d.warnings.contains { $0.code == .custom("date_format_fallback") })
        let w = d.warnings.first { $0.code == .custom("date_format_fallback") }
        #expect(w?.params["matched"]?.displayString.contains("milliseconds") == true)
        #expect(w?.params["primary"]?.displayString.contains("ISO-8601") == true)
    }

    @Test("a total miss names every format tried, the reason, and the position")
    func richError() {
        let d = Event.diagnose(json: Array("""
        {"name": "deploy",
         "created_at": "2026-02-30T00:00:00Z",
         "recorded_at": 1754481600,
         "updated_at": "2026-08-06T12:00:00Z"}
        """.utf8))
        #expect(!d.isValid)
        let issue = d.issues.first { $0.code == .custom("invalid_date") }
        #expect(issue != nil)
        #expect(issue?.received == "2026-02-30T00:00:00Z")
        #expect(issue?.params["reason"]?.displayString.contains("day 30 is out of range") == true)
        #expect(issue?.message.contains("must be an ISO-8601 date") == true)
        #expect(issue?.message.contains("day 30 is out of range for 2026-02") == true)
        // The caret is INSIDE the value, on the day field, not just under the string.
        #expect(issue?.location != nil)
    }

    @Test("the chain's error names both formats")
    func chainError() {
        let d = Event.diagnose(json: Array("""
        {"name": "deploy",
         "created_at": "2026-08-06T12:00:00Z",
         "recorded_at": 1754481600,
         "updated_at": "yesterday"}
        """.utf8))
        let issue = d.issues.first { $0.code == .custom("invalid_date") }
        #expect(issue?.params["expected"]?.displayString
                == "ISO-8601 date, or unix timestamp (milliseconds)")
    }

    @Test("null on a required Date is a type mismatch, not a crash or a zero")
    func nullRequired() {
        let d = Event.diagnose(json: Array("""
        {"name": "x", "created_at": null, "recorded_at": 1, "updated_at": 1754481600000}
        """.utf8))
        #expect(!d.isValid)
    }

    @Test("YAML and XML reach the same formats through RawValue")
    func multiFormat() throws {
        let y = try Audit.parse(yaml: "action: login\nat: \"2026-08-06T12:00:00Z\"\n")
        #expect(y.at == Date(timeIntervalSince1970: 1_786_017_600))
        let x = try Audit.parse(xml: "<r><action>login</action><at>2026-08-06T12:00:00Z</at></r>")
        #expect(x.at == y.at)
    }

    @Test("date rules: before, after, between — violations render as dates")
    func rules() throws {
        let ok = try Window.parse(json: Array("""
        {"opens": "2026-08-06T12:00:00Z", "closes": "2026-08-06T13:00:00Z"}
        """.utf8))
        #expect(ok.opens.timeIntervalSince1970 < ok.closes.timeIntervalSince1970)

        let d = Window.diagnose(json: Array("""
        {"opens": "2031-01-01T00:00:00Z", "closes": "2019-06-01T00:00:00Z"}
        """.utf8))
        #expect(!d.isValid)
        let late = d.issues.first { $0.code == .custom("date_not_before") }
        #expect(late?.message == "must be before 2030-01-01T00:00:00Z")
        #expect(late?.received == "2031-01-01T00:00:00Z")     // rendered as a date
        let outside = d.issues.first { $0.code == .custom("date_not_between") }
        #expect(outside?.message == "must be between 2020-01-01 and 2030-01-01")
    }

    @Test("@Fallback, pattern formats, and [Date] arrays")
    func sturdy() throws {
        let s = try Sturdy.parse(json: Array("""
        {"seen": "not a date", "day": "2026-08-06",
         "stamps": ["2026-08-06T12:00:00Z", "2026-08-06T13:00:00Z"]}
        """.utf8))
        // Invalid + @Fallback: the epoch stub, and parse() discards the warning.
        #expect(s.seen == Date(timeIntervalSince1970: 0))
        #expect(s.day == Date(timeIntervalSince1970: 1_785_974_400))
        #expect(s.stamps.count == 2)
        #expect(s.stamps[1].timeIntervalSince1970 - s.stamps[0].timeIntervalSince1970 == 3600)
    }

    @Test("an unparseable rule bound fails every value, loudly")
    func invalidRuleBound() {
        // Built directly — the macro cannot check a non-literal, so the runtime must
        // refuse to validate anything against a bound that did not parse.
        var sink = IssueSink()
        _assayValidate(0.0, [.before("not-a-date")], override: nil, field: "f",
                       at: nil, path: [], &sink)
        #expect(sink.issues.first?.code == .custom("invalid_rule_date"))
        #expect(sink.issues.first?.message.contains("not-a-date") == true)
    }
}
