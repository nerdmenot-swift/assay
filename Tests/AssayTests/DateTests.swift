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
        #expect(iso("1994-11-06T08:49:37Z") == 784_111_777)  // RFC 9110's example
        #expect(iso("1969-12-31T23:59:59Z") == -1)
        #expect(iso("2000-02-29T00:00:00Z") == 951_782_400)  // century leap year
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

    @Test(
        "every rejection names its field and its position",
        arguments: [
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
            ("garbage", "4-digit year")
        ])
    func rejections(_ input: String, _ reasonFragment: String) {
        let failure = isoFailure(input)
        #expect(failure != nil, "\(input) should have been rejected")
        #expect(
            failure?.reason.contains(reasonFragment) == true,
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
        #expect(
            try! DateParser.parse(seconds: 1_691_234_567, as: .unixSeconds).get()
                == 1_691_234_567)
        #expect(
            try! DateParser.parse(seconds: 1_691_234_567_000, as: .unixMillis).get()
                == 1_691_234_567)
        #expect(
            try! DateParser.parse("1691234567", as: .unixSeconds).get()
                == 1_691_234_567)
        #expect(
            try! DateParser.parse("1691234567.25", as: .unixSeconds).get()
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
        #expect(
            try! DateParser.parse("Sun, 06 Nov 1994 08:49:37 GMT", as: .rfc9110).get()
                == Self.epoch)
        #expect(
            try! DateParser.parse("Sunday, 06-Nov-94 08:49:37 GMT", as: .rfc9110).get()
                == Self.epoch)
        #expect(
            try! DateParser.parse("Sun Nov  6 08:49:37 1994", as: .rfc9110).get()
                == Self.epoch)
    }

    @Test("two-digit years pivot at 70 — the POSIX convention, stated in the header")
    func rfc850Years() {
        let y94 = try! DateParser.parse("Sunday, 06-Nov-94 08:49:37 GMT", as: .rfc9110).get()
        let y26 = try! DateParser.parse("Thursday, 06-Aug-26 08:49:37 GMT", as: .rfc9110).get()
        #expect(y94 == Self.epoch)  // 94 → 1994
        #expect(y26 > 1_700_000_000)  // 26 → 2026, not 1926
    }

    @Test(
        "rejections name the problem",
        arguments: [
            ("Xxx, 06 Nov 1994 08:49:37 GMT", "not a day name"),
            ("Sun, 06 Foo 1994 08:49:37 GMT", "month name"),
            ("Sun, 06 Nov 1994 08:49:37 UTC", "GMT"),
            ("Sun, 31 Feb 1994 08:49:37 GMT", "out of range"),
            ("Sun, 06 Nov 1994 25:49:37 GMT", "hour 25")
        ])
    func rejections(_ input: String, _ fragment: String) {
        if case .failure(let f) = DateParser.parse(input, as: .rfc9110) {
            #expect(
                f.reason.contains(fragment),
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
        #expect(
            try! DateParser.parse("2026-08-06", as: .pattern("yyyy-MM-dd")).get()
                == iso("2026-08-06T00:00:00Z"))
        #expect(
            try! DateParser.parse(
                "06/08/2026 12:30",
                as: .pattern("dd/MM/yyyy HH:mm")
            ).get()
                == iso("2026-08-06T12:30:00Z"))
        // Letter literals are quoted, UTS-35 style — 'T' is the letter, not a field.
        #expect(
            try! DateParser.parse(
                "2026-08-06T12:30:00.250Z",
                as: .pattern("yyyy-MM-dd'T'HH:mm:ss.SSSZ")
            ).get()
                == iso("2026-08-06T12:30:00.25Z"))
        #expect(
            try! DateParser.parse("20260806", as: .pattern("yyyyMMdd")).get()
                == iso("2026-08-06T00:00:00Z"))
    }

    @Test("a pattern with no zone is UTC — deterministic, unlike DateFormatter")
    func noZoneIsUTC() {
        #expect(
            try! DateParser.parse(
                "2026-08-06 05:00",
                as: .pattern("yyyy-MM-dd HH:mm")
            ).get()
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

// MARK: - Every failure message, by the input that produces it
//
// A date parser's error is a message and a byte offset, and the offset is where the caret
// goes. The suites above cover the ranges ("month 13", "day 31"); the SHAPE failures — a
// field that is not digits, a document that stops early, a separator that is not there —
// had no input at all in three of the four parsers. Each row is the smallest change to a
// valid date that reaches one arm.

private let patterned = DateFormat.pattern("yyyy-MM-dd HH:mm:ss.SSSZ")

@Suite("Date parser: failure messages and their offsets")
struct DateFailureTableTests {

    static let iso: [(String, String, Int)] = [
        ("2024", "ends before the month", 4),
        ("2024-1x-01T00:00:00Z", "expected a 2-digit month", 5),
        ("2024-01-0xT00:00:00Z", "expected a 2-digit day", 8),
        ("2024-01-01Txx:00:00Z", "expected a 2-digit hour", 11),
        ("2024-01-01T00:xx:00Z", "expected a 2-digit minute", 14),
        ("2024-01-01T00:00:xxZ", "expected a 2-digit second", 17),
        ("2024-01-01T00:00:00.Z", "expected digits after the decimal point", 20),
        ("2024-01-01T00:00:00+xx", "expected a 2-digit offset hour", 20),
        ("2024-01-01T00:00:00+01:7", "expected a 2-digit offset minute", 23),
        ("2024-01-01T00:00:00X", "expected 'Z' or a ±hh:mm offset", 19),
        // Years below 1000 are padded in the message, so it reads as the date was written.
        ("0099-02-30T00:00:00Z", "day 30 is out of range for 0099-02", 8),
        ("0009-02-30T00:00:00Z", "day 30 is out of range for 0009-02", 8),
        ("0000-02-30T00:00:00Z", "day 30 is out of range for 0000-02", 8)
    ]

    static let http: [(String, String, Int)] = [
        // IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT`
        ("Sun, 06 Nov 1994 08:49:37 GM", "IMF-fixdate is exactly 29 characters", 28),
        ("Sun, xx Nov 1994 08:49:37 GMT", "expected a 2-digit day", 5),
        ("Sun, 06 Nov 19x4 08:49:37 GMT", "expected a 4-digit year", 12),
        ("Sun, 06 Nov 1994 08-49-37 GMT", "expected hh:mm:ss", 19),
        // RFC 850: `Sunday, 06-Nov-94 08:49:37 GMT`
        ("Sunnday, 06-Nov-94 08:49:37 GMT", "'Sunnday' is not a day name", 0),
        ("Sunday,06-Nov-94 08:49:37 GMT", "expected ', ' after the day name", 6),
        ("Sunday, 6-Nov-94 08:49:37 GMT", "expected dd-Mon-yy", 8),
        ("Sunday, 06-Nvv-94 08:49:37 GMT", "expected a month name (Jan…Dec)", 11),
        ("Sunday, 06-Nov 94 08:49:37 GMT", "expected '-' after the month", 14),
        ("Sunday, 06-Nov-9x 08:49:37 GMT", "expected a 2-digit year", 15),
        ("Sunday, 06-Nov-94T08:49:37 GMT", "expected a space before the time", 17),
        ("Sunday, 06-Nov-94 08-49-37 GMT", "expected hh:mm:ss", 20),
        ("Sunday, 06-Nov-94 08:49:37 UTC", "must end with ' GMT'", 26),
        // asctime: `Sun Nov  6 08:49:37 1994`
        ("Sun Nov  6 08:49:37 199", "asctime is exactly 24 characters", 23),
        ("Xxx Nov  6 08:49:37 1994", "'Xxx' is not a day name", 0),
        ("Sun Nvv  6 08:49:37 1994", "expected a month name (Jan…Dec)", 4),
        ("Sun Nov  x 08:49:37 1994", "expected a day of month", 9),
        ("Sun Nov x6 08:49:37 1994", "expected a day of month", 8),
        ("Sun Nov  6 08-49-37 1994", "expected hh:mm:ss", 13),
        ("Sun Nov  6 08:49:37 19x4", "expected a 4-digit year", 20)
    ]

    static let pattern: [(String, String, Int)] = [
        ("2024-1x-01 00:00:00.000Z", "expected a 2-digit month (01-12)", 5),
        ("2024-13-01 00:00:00.000Z", "expected a 2-digit month (01-12)", 5),
        ("2024-01-xx 00:00:00.000Z", "expected a 2-digit day", 8),
        ("2024-01-00 00:00:00.000Z", "expected a 2-digit day", 8),
        // A field that IS two digits and is out of range: the caret belongs on the field.
        // These reported 13, 16 and 19 — the byte after it — until 2026-10-04.
        ("2024-01-01 24:00:00.000Z", "expected a 2-digit hour (00-23)", 11),
        ("2024-01-01 00:60:00.000Z", "expected a 2-digit minute (00-59)", 14),
        ("2024-01-01 00:00:61.000Z", "expected a 2-digit second (00-60)", 17),
        ("2024-01-01 00:00:00.xxZ", "expected 3-digit milliseconds", 20),
        ("2024-01-01 00:00:00.000", "ends before the UTC offset ('Z' or ±hh:mm)", 23),
        ("2024-01-01 00:00:00.000+xx", "expected a 2-digit offset hour", 24),
        ("2024-01-01 00:00:00.000+01:6x", "expected a 2-digit offset minute", 27),
        ("2024-01-01 00:00:00.000Q", "expected 'Z' or a ±hh:mm offset", 23),
        ("2024/01/01 00:00:00.000Z", "expected '-'", 4),
        ("2024-01-01 00:00:00.000Z!", "unexpected trailing characters", 24),
        ("2024-02-30 00:00:00.000Z", "day 30 is out of range for 2024-02", 0)
    ]

    private func check(_ rows: [(String, String, Int)], as format: DateFormat) {
        for (input, reason, offset) in rows {
            guard case .failure(let f) = DateParser.parse(input, as: format) else {
                Issue.record("\(input) parsed; expected: \(reason)")
                continue
            }
            #expect(f.reason == reason, "\(input)")
            #expect(f.offset == offset, "\(input): \(f.reason)")
        }
    }

    @Test("ISO-8601") func isoRows() { check(Self.iso, as: .iso8601) }
    @Test("RFC 9110, all three spellings") func httpRows() { check(Self.http, as: .rfc9110) }
    @Test("a pattern") func patternRows() { check(Self.pattern, as: patterned) }

    @Test("a unix timestamp as text needs digits after its point")
    func unixText() {
        guard case .failure(let f) = DateParser.parse("1700000000.", as: .unixSeconds) else {
            Issue.record("expected a failure")
            return
        }
        #expect(f.reason == "expected digits after the decimal point")
        #expect(f.offset == 11)
    }

    @Test("the three RFC 9110 spellings name the same instant; a pattern takes both offset forms")
    func successes() throws {
        let imf = try DateParser.parse("Sun, 06 Nov 1994 08:49:37 GMT", as: .rfc9110).get()
        #expect(try DateParser.parse("Sunday, 06-Nov-94 08:49:37 GMT", as: .rfc9110).get() == imf)
        #expect(try DateParser.parse("Sun Nov  6 08:49:37 1994", as: .rfc9110).get() == imf)
        // A two-digit asctime day, which takes the other branch of the day read.
        let later = try DateParser.parse("Wed Nov 16 08:49:37 1994", as: .rfc9110).get()
        #expect(later == imf + 10 * 86_400)

        let utc = try DateParser.parse("2024-01-01 00:00:00.000Z", as: patterned).get()
        let east = try DateParser.parse("2024-01-01 00:00:00.000+0130", as: patterned).get()
        let west = try DateParser.parse("2024-01-01 00:00:00.000-01:30", as: patterned).get()
        #expect(east == utc - 5_400 && west == utc + 5_400)
    }

    @Test("an instant with no ISO-8601 spelling formats as the number it is")
    func nonFinite() {
        #expect(DateParser.formatISO8601(.infinity) == "inf")
        #expect(DateParser.formatISO8601(-.infinity) == "-inf")
        #expect(DateParser.formatISO8601(0) == "1970-01-01T00:00:00Z")
    }
}
