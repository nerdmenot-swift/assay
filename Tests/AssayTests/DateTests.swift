// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The core date engine, pinned two ways:
//
//   GOLDEN cases — epochs computed by hand or taken from the RFCs, so a shared bug in
//   Assay and Foundation cannot hide. 784111777 is RFC 9110's own worked example.
//
//   The DIFFERENTIAL against Foundation's ISO8601DateFormatter lives in
//   Benchmarks/Sources/DiffFuzz, not here: importing Foundation into this test target
//   would pull swift-testing's _Testing_Foundation overlay and its macOS 13 floor —
//   the same trap that put DiffFuzz in the Benchmarks package to begin with.
//===----------------------------------------------------------------------===//

import Testing
@testable import AssayCore

private func iso(_ s: String) -> Double? {
    try? DateParser.parse(s, as: .iso8601).get()
}

private func isoFailure(_ s: String) -> DateParseFailure? {
    if case .failure(let f) = DateParser.parse(s, as: .iso8601) { return f }
    return nil
}

@Suite("ISO-8601 parser")
struct ISO8601Tests {

    @Test("golden epochs, computed independently of both implementations")
    func golden() {
        #expect(iso("1970-01-01T00:00:00Z") == 0)
        #expect(iso("2001-09-09T01:46:40Z") == 1_000_000_000)
        #expect(iso("1994-11-06T08:49:37Z") == 784_111_777)     // RFC 9110's example
        #expect(iso("1969-12-31T23:59:59Z") == -1)
        #expect(iso("2000-02-29T00:00:00Z") == 951_782_400)     // century leap year
    }

    @Test("offsets are subtracted, in both directions")
    func offsets() {
        let utc = iso("2026-01-01T00:00:00Z")!
        #expect(iso("2026-01-01T05:30:00+05:30") == utc)
        #expect(iso("2026-01-01T05:30:00+0530") == utc)
        #expect(iso("2025-12-31T19:00:00-05:00") == utc)
        #expect(iso("2025-12-31T19:00:00-05") == utc)
    }

    @Test("fractional seconds survive, to Double precision")
    func fractions() {
        #expect(iso("1970-01-01T00:00:00.5Z") == 0.5)
        #expect(iso("1970-01-01T00:00:00.125Z") == 0.125)
        // Digits beyond what a Double can hold are consumed, not rejected.
        #expect(iso("1970-01-01T00:00:00.123456789012345Z")! > 0.123456)
    }

    @Test("the permissive corners: t, z, space separator")
    func separators() {
        let expected = iso("2026-08-06T12:00:00Z")!
        #expect(iso("2026-08-06t12:00:00z") == expected)
        #expect(iso("2026-08-06 12:00:00Z") == expected)
    }

    @Test("a leap second carries into the next minute — the POSIX reading")
    func leapSecond() {
        // Foundation rejects :60; Assay accepts it because real logs contain it.
        // 2016-12-31T23:59:60Z is the leap second inserted before 2017.
        #expect(iso("2016-12-31T23:59:60Z") == iso("2017-01-01T00:00:00Z"))
    }

    @Test("every rejection names its field and its position", arguments: [
        ("2026-13-01T00:00:00Z", "month 13"),
        ("2026-02-29T00:00:00Z", "day 29 is out of range for 2026-02"),
        ("2023-02-29T00:00:00Z", "day 29 is out of range for 2023-02"),
        ("1900-02-29T00:00:00Z", "day 29 is out of range for 1900-02"),  // not a leap year
        ("2026-04-31T00:00:00Z", "day 31 is out of range for 2026-04"),
        ("2026-08-06T24:00:00Z", "hour 24"),
        ("2026-08-06T12:60:00Z", "minute 60"),
        ("2026-08-06T12:00:61Z", "second 61"),
        ("2026-08-06X12:00:00Z", "expected 'T'"),
        ("2026-08-06T12:00:00", "offset"),
        ("2026-08-06T12:00:00Zx", "trailing"),
        ("2026/08/06T12:00:00Z", "expected '-'"),
        ("garbage", "4-digit year"),
    ])
    func rejections(_ input: String, _ reasonFragment: String) {
        let failure = isoFailure(input)
        #expect(failure != nil, "\(input) should have been rejected")
        #expect(failure?.reason.contains(reasonFragment) == true,
                "\(input): reason \"\(failure?.reason ?? "")\" should mention \"\(reasonFragment)\"")
    }

    @Test("the failure offset points into the value, at the failing field")
    func failureOffsets() {
        // "2026-02-29..." — the day digits start at offset 8.
        #expect(isoFailure("2026-02-29T00:00:00Z")?.offset == 8)
        // The bad separator is at offset 10.
        #expect(isoFailure("2026-08-06X12:00:00Z")?.offset == 10)
    }
}

@Suite("Unix timestamp parsing")
struct UnixTimestampTests {

    @Test("seconds and milliseconds, number and digit-string")
    func forms() {
        #expect(try! DateParser.parse(seconds: 1_691_234_567, as: .unixSeconds).get()
                == 1_691_234_567)
        #expect(try! DateParser.parse(seconds: 1_691_234_567_000, as: .unixMillis).get()
                == 1_691_234_567)
        #expect(try! DateParser.parse("1691234567", as: .unixSeconds).get()
                == 1_691_234_567)
        #expect(try! DateParser.parse("1691234567.25", as: .unixSeconds).get()
                == 1_691_234_567.25)
        #expect(try! DateParser.parse("-86400", as: .unixSeconds).get() == -86_400)
    }

    @Test("what a timestamp is not")
    func rejections() {
        // Scientific notation is a number, not a timestamp.
        if case .success = DateParser.parse("1e9", as: .unixSeconds) {
            Issue.record("1e9 should not parse as a timestamp")
        }
        if case .success = DateParser.parse(seconds: .infinity, as: .unixSeconds) {
            Issue.record("infinity should not parse")
        }
        if case .success = DateParser.parse(seconds: 1e17, as: .unixSeconds) {
            Issue.record("absurd magnitudes should not parse")
        }
        // A number fed to a text format says so rather than crashing into it.
        if case .failure(let f) = DateParser.parse(seconds: 5, as: .iso8601) {
            #expect(f.reason.contains("text"))
        } else {
            Issue.record("a number should not satisfy .iso8601")
        }
    }
}

@Suite("RFC 9110 HTTP dates")
struct HTTPDateTests {

    // RFC 9110 §5.6.7 gives all three forms for the same instant.
    static let epoch: Double = 784_111_777

    @Test("all three forms the spec requires a parser to accept")
    func threeForms() {
        #expect(try! DateParser.parse("Sun, 06 Nov 1994 08:49:37 GMT", as: .rfc9110).get()
                == Self.epoch)
        #expect(try! DateParser.parse("Sunday, 06-Nov-94 08:49:37 GMT", as: .rfc9110).get()
                == Self.epoch)
        #expect(try! DateParser.parse("Sun Nov  6 08:49:37 1994", as: .rfc9110).get()
                == Self.epoch)
    }

    @Test("two-digit years pivot at 70 — the POSIX convention, stated in the header")
    func rfc850Years() {
        let y94 = try! DateParser.parse("Sunday, 06-Nov-94 08:49:37 GMT", as: .rfc9110).get()
        let y26 = try! DateParser.parse("Thursday, 06-Aug-26 08:49:37 GMT", as: .rfc9110).get()
        #expect(y94 == Self.epoch)                       // 94 → 1994
        #expect(y26 > 1_700_000_000)                     // 26 → 2026, not 1926
    }

    @Test("rejections name the problem", arguments: [
        ("Xxx, 06 Nov 1994 08:49:37 GMT", "not a day name"),
        ("Sun, 06 Foo 1994 08:49:37 GMT", "month name"),
        ("Sun, 06 Nov 1994 08:49:37 UTC", "GMT"),
        ("Sun, 31 Feb 1994 08:49:37 GMT", "out of range"),
        ("Sun, 06 Nov 1994 25:49:37 GMT", "hour 25"),
    ])
    func rejections(_ input: String, _ fragment: String) {
        if case .failure(let f) = DateParser.parse(input, as: .rfc9110) {
            #expect(f.reason.contains(fragment),
                    "\(input): \"\(f.reason)\" should mention \"\(fragment)\"")
        } else {
            Issue.record("\(input) should have been rejected")
        }
    }
}

@Suite("Fixed patterns")
struct PatternTests {

    @Test("date-only, datetime, millis, zone")
    func shapes() {
        #expect(try! DateParser.parse("2026-08-06", as: .pattern("yyyy-MM-dd")).get()
                == iso("2026-08-06T00:00:00Z"))
        #expect(try! DateParser.parse("06/08/2026 12:30",
                                      as: .pattern("dd/MM/yyyy HH:mm")).get()
                == iso("2026-08-06T12:30:00Z"))
        // Letter literals are quoted, UTS-35 style — 'T' is the letter, not a field.
        #expect(try! DateParser.parse("2026-08-06T12:30:00.250Z",
                                      as: .pattern("yyyy-MM-dd'T'HH:mm:ss.SSSZ")).get()
                == iso("2026-08-06T12:30:00.25Z"))
        #expect(try! DateParser.parse("20260806", as: .pattern("yyyyMMdd")).get()
                == iso("2026-08-06T00:00:00Z"))
    }

    @Test("a pattern with no zone is UTC — deterministic, unlike DateFormatter")
    func noZoneIsUTC() {
        #expect(try! DateParser.parse("2026-08-06 05:00",
                                      as: .pattern("yyyy-MM-dd HH:mm")).get()
                == iso("2026-08-06T05:00:00Z"))
    }

    @Test("unsupported fields are named, with the supported list")
    func unsupportedFields() {
        if case .failure(let why) = DateParser.compilePattern("EEE, dd MMM yyyy") {
            #expect(why.contains("'EEE'"))
            #expect(why.contains("yyyy MM dd HH mm ss SSS Z"))
        } else {
            Issue.record("EEE should not compile")
        }
        if case .failure(let why) = DateParser.compilePattern("HH:mm") {
            #expect(why.contains("yyyy"))
        } else {
            Issue.record("a pattern without a date should not compile")
        }
    }

    @Test("day range is validated against the month the pattern parsed")
    func dayRange() {
        if case .success = DateParser.parse("2026-02-30", as: .pattern("yyyy-MM-dd")) {
            Issue.record("Feb 30 should not parse")
        }
    }
}

