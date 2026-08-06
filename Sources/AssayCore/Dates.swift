// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Dates, without Foundation. ROADMAP.md §2, unblocked.
//
// The design question that kept this deferred was "where does the epoch conversion live,
// given the core's no-Foundation rule?" The answer that unblocks it: the conversion is
// ARITHMETIC, not calendar lookup. Howard Hinnant's days-from-civil algorithm turns a
// proleptic-Gregorian date into a day number in a handful of integer operations, no
// tables, no locale, no time zone database. The core parses text into epoch seconds as a
// `Double`; the macro-generated code wraps that in `Date(timeIntervalSince1970:)` — an
// initializer that resolves in the USER's module, which must already import a Foundation
// flavour for `var created: Date` to have type-checked at all. No protocol, no retroactive
// conformance, no AssayFoundation requirement.
//
// Foundation's `ISO8601DateFormatter` allocates an NSDateComponents round trip per parse
// and reaches ICU; the arithmetic actually required is two dozen integer operations.
// PERFORMANCE.md §13.2 lists this as an unclaimed win — the claim is settled by
// `Benchmarks`, not asserted here.
//
// EVERY FAILURE NAMES ITS POSITION AND ITS REASON. "invalid date" is the error message
// this library exists to not produce. A failed parse says which byte and what was
// expected — "day 31 is out of range for 2026-02" — because the caret renderer can then
// put the caret under the exact field.
//
// Leap seconds: `:60` is ACCEPTED and carries arithmetically (23:59:60 is the same POSIX
// instant as the next 00:00:00). ISO 8601 permits it, real logs contain it, and POSIX
// time is what `Date` measures. Foundation rejects it; the differential tests pin the
// deliberate divergence.
//
// Two-digit years (RFC 850 form): RFC 9110 says to interpret relative to "now", and the
// core has no clock. The POSIX convention is used instead — 70-99 is 19xx, 00-69 is 20xx —
// which is deterministic, matches every C runtime, and is documented here rather than
// discovered in production in 2070.
//===----------------------------------------------------------------------===//

// MARK: - The format

/// How a `Date` field reads its wire value. An ordered list of these is a candidate
/// chain: the first that matches wins, a later match warns (the same contract as
/// `@Key(_:or:)`), and a total miss reports every format it tried.
public enum DateFormat: Sendable, Equatable {
    /// `2026-08-06T12:30:00Z`, offsets `±hh:mm`/`±hhmm`/`±hh`, optional fractional
    /// seconds, `T`/`t`/space separator. The default for `Date` fields.
    case iso8601
    /// A JSON number (or all-digit string) of seconds since 1970-01-01T00:00:00Z.
    /// Fractional seconds survive.
    case unixSeconds
    /// A JSON number (or all-digit string) of milliseconds since the epoch.
    case unixMillis
    /// The three HTTP date forms of RFC 9110 §5.6.7 — IMF-fixdate
    /// (`Sun, 06 Nov 1994 08:49:37 GMT`), obsolete RFC 850, and asctime. A parser
    /// "MUST accept all three"; this one does.
    case rfc9110
    /// A fixed field subset — `yyyy MM dd HH mm ss SSS Z` plus literal characters —
    /// implemented directly, identical on every platform, no locale, no ICU. Not
    /// UTS-35: month names, eras, and week-based years are deliberately absent.
    case pattern(String)

    /// For error messages: "must be an ISO-8601 date".
    public var displayName: String {
        switch self {
        case .iso8601:        return "ISO-8601 date"
        case .unixSeconds:    return "unix timestamp (seconds)"
        case .unixMillis:     return "unix timestamp (milliseconds)"
        case .rfc9110:        return "HTTP date (RFC 9110)"
        case .pattern(let p): return "date matching \"\(p)\""
        }
    }

    /// Whether a bare JSON number can satisfy this format.
    @usableFromInline
    var acceptsNumber: Bool {
        switch self {
        case .unixSeconds, .unixMillis: return true
        default: return false
        }
    }
}

/// Why a parse failed, positioned. `offset` is a byte index into the text that was
/// parsed, pointing at the field that failed, so a renderer can place a caret inside
/// the value, not just under it.
public struct DateParseFailure: Sendable, Equatable, Error {
    public var reason: String
    public var offset: Int

    @usableFromInline
    init(_ reason: String, at offset: Int) {
        self.reason = reason
        self.offset = offset
    }
}

// MARK: - Civil arithmetic

/// Hinnant's `days_from_civil`: proleptic Gregorian date → days since 1970-01-01.
/// Pure integer arithmetic, exact over ±5.8 million years — no loops, no tables.
@usableFromInline
func epochDays(year: Int, month: Int, day: Int) -> Int {
    let y = year - (month <= 2 ? 1 : 0)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400                                        // [0, 399]
    let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                // [0, 146096]
    return era * 146097 + doe - 719468
}

@usableFromInline
func isLeapYear(_ y: Int) -> Bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

@usableFromInline
func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    case 2: return isLeapYear(year) ? 29 : 28
    default: return 0
    }
}

/// Civil date-time → epoch seconds. Seconds may be 60 (leap second) — the arithmetic
/// carries it into the next minute, which is the POSIX reading.
@usableFromInline
func epochSeconds(
    year: Int, month: Int, day: Int,
    hour: Int, minute: Int, second: Int,
    fraction: Double, offsetSeconds: Int
) -> Double {
    let days = epochDays(year: year, month: month, day: day)
    let secs = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
    return Double(secs) + fraction
}

// MARK: - The parsers

public enum DateParser {

    /// Parse `text` according to `format`. The failure names the byte and the field.
    public static func parse(
        _ text: String, as format: DateFormat
    ) -> Result<Double, DateParseFailure> {
        // A date is a couple of dozen bytes; the copy into a safe container is noise
        // next to the String the scanner already materialised.
        parse(Array(text.utf8), as: format)
    }

    /// The number entry: `.unixSeconds` / `.unixMillis` fed from a JSON number token.
    public static func parse(
        seconds value: Double, as format: DateFormat
    ) -> Result<Double, DateParseFailure> {
        switch format {
        case .unixSeconds: return validated(value)
        case .unixMillis:  return validated(value / 1_000)
        default:
            return .failure(.init("\(format.displayName) is text, not a number", at: 0))
        }
    }

    /// Reject non-finite and absurd values rather than smuggling them into a `Date`.
    /// The bound is ±2^53 seconds (±285 million years), the range in which a Double
    /// still resolves individual seconds exactly.
    @usableFromInline
    static func validated(_ s: Double) -> Result<Double, DateParseFailure> {
        guard s.isFinite else {
            return .failure(.init("timestamp is not a finite number", at: 0))
        }
        guard abs(s) <= 9_007_199_254_740_992.0 else {
            return .failure(.init("timestamp is out of range", at: 0))
        }
        return .success(s)
    }

    @usableFromInline
    static func parse(
        _ b: [UInt8], as format: DateFormat
    ) -> Result<Double, DateParseFailure> {
        switch format {
        case .iso8601:        return parseISO8601(b)
        case .unixSeconds:    return parseUnixText(b, millis: false)
        case .unixMillis:     return parseUnixText(b, millis: true)
        case .rfc9110:        return parseHTTPDate(b)
        case .pattern(let p): return parsePattern(b, pattern: p)
        }
    }

    // MARK: ISO-8601

    /// `YYYY-MM-DD` `[Tt ]` `hh:mm:ss` `[.fff…]` `(Z|z|±hh[[:]mm])`, nothing after.
    @usableFromInline
    static func parseISO8601(
        _ b: [UInt8]
    ) -> Result<Double, DateParseFailure> {
        var i = 0

        func digits(_ n: Int, _ what: String) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for k in i..<(i + n) {
                let d = b[k] &- 0x30
                guard d <= 9 else { return nil }
                v = v * 10 + Int(d)
            }
            i += n
            return v
        }
        func expect(_ byte: UInt8, _ what: String) -> DateParseFailure? {
            guard i < b.count else {
                return .init("ends before the \(what)", at: i)
            }
            guard b[i] == byte else {
                return .init("expected '\(Character(UnicodeScalar(byte)))' before the \(what)", at: i)
            }
            i += 1
            return nil
        }

        guard let year = digits(4, "year") else {
            return .failure(.init("expected a 4-digit year", at: i))
        }
        if let e = expect(0x2D, "month") { return .failure(e) }
        guard let month = digits(2, "month") else {
            return .failure(.init("expected a 2-digit month", at: i))
        }
        guard (1...12).contains(month) else {
            return .failure(.init("month \(pad2(month)) is out of range", at: i - 2))
        }
        if let e = expect(0x2D, "day") { return .failure(e) }
        guard let day = digits(2, "day") else {
            return .failure(.init("expected a 2-digit day", at: i))
        }
        guard day >= 1 && day <= daysIn(month: month, year: year) else {
            return .failure(.init(
                "day \(pad2(day)) is out of range for \(pad4(year))-\(pad2(month))", at: i - 2))
        }

        guard i < b.count, b[i] == 0x54 || b[i] == 0x74 || b[i] == 0x20 else {
            return .failure(.init(
                i < b.count ? "expected 'T' between date and time" : "ends before the time",
                at: i))
        }
        i += 1

        guard let hour = digits(2, "hour") else {
            return .failure(.init("expected a 2-digit hour", at: i))
        }
        guard hour <= 23 else {
            return .failure(.init("hour \(pad2(hour)) is out of range", at: i - 2))
        }
        if let e = expect(0x3A, "minute") { return .failure(e) }
        guard let minute = digits(2, "minute") else {
            return .failure(.init("expected a 2-digit minute", at: i))
        }
        guard minute <= 59 else {
            return .failure(.init("minute \(pad2(minute)) is out of range", at: i - 2))
        }
        if let e = expect(0x3A, "second") { return .failure(e) }
        guard let second = digits(2, "second") else {
            return .failure(.init("expected a 2-digit second", at: i))
        }
        // 60 is a leap second: legal ISO 8601, present in real logs, carried by the
        // epoch arithmetic into the next minute (the POSIX reading).
        guard second <= 60 else {
            return .failure(.init("second \(pad2(second)) is out of range", at: i - 2))
        }

        var fraction = 0.0
        if i < b.count, b[i] == 0x2E {
            i += 1
            let start = i
            var scale = 1.0
            var value = 0.0
            while i < b.count, b[i] &- 0x30 <= 9 {
                // Beyond nanoseconds the digits still consume but cannot move a Double.
                if scale > 1e-12 {
                    scale /= 10
                    value += Double(b[i] &- 0x30) * scale
                }
                i += 1
            }
            guard i > start else {
                return .failure(.init("expected digits after the decimal point", at: i))
            }
            fraction = value
        }

        // Offset. `Z`, or ±hh, ±hhmm, ±hh:mm.
        guard i < b.count else {
            return .failure(.init("ends before the UTC offset ('Z' or ±hh:mm)", at: i))
        }
        var offset = 0
        switch b[i] {
        case 0x5A, 0x7A:            // Z z
            i += 1
        case 0x2B, 0x2D:            // + -
            let negative = b[i] == 0x2D
            i += 1
            guard let oh = digits(2, "offset hour"), oh <= 23 else {
                return .failure(.init("expected a 2-digit offset hour", at: i))
            }
            var om = 0
            if i < b.count {
                if b[i] == 0x3A { i += 1 }
                if i < b.count, b[i] &- 0x30 <= 9 {
                    guard let m = digits(2, "offset minute"), m <= 59 else {
                        return .failure(.init("expected a 2-digit offset minute", at: i))
                    }
                    om = m
                }
            }
            offset = (oh * 3_600 + om * 60) * (negative ? -1 : 1)
        default:
            return .failure(.init("expected 'Z' or a ±hh:mm offset", at: i))
        }

        guard i == b.count else {
            return .failure(.init("unexpected trailing characters", at: i))
        }
        return .success(epochSeconds(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second,
            fraction: fraction, offsetSeconds: offset))
    }

    // MARK: Unix timestamps as text

    /// Some APIs quote their epochs. `[-]digits[.digits]` and nothing else — this is not
    /// a general number parser, and "1e9" is not a timestamp.
    @usableFromInline
    static func parseUnixText(
        _ b: [UInt8], millis: Bool
    ) -> Result<Double, DateParseFailure> {
        var i = 0
        var negative = false
        if i < b.count, b[i] == 0x2D { negative = true; i += 1 }
        let start = i
        var whole = 0.0
        while i < b.count, b[i] &- 0x30 <= 9 {
            whole = whole * 10 + Double(b[i] &- 0x30)
            i += 1
        }
        guard i > start else {
            return .failure(.init("expected a numeric timestamp", at: i))
        }
        var fraction = 0.0
        if i < b.count, b[i] == 0x2E {
            i += 1
            let fs = i
            var scale = 1.0
            while i < b.count, b[i] &- 0x30 <= 9 {
                if scale > 1e-12 {
                    scale /= 10
                    fraction += Double(b[i] &- 0x30) * scale
                }
                i += 1
            }
            guard i > fs else {
                return .failure(.init("expected digits after the decimal point", at: i))
            }
        }
        guard i == b.count else {
            return .failure(.init("unexpected trailing characters", at: i))
        }
        let value = (whole + fraction) * (negative ? -1 : 1)
        return parse(seconds: value, as: millis ? .unixMillis : .unixSeconds)
    }

    // MARK: RFC 9110 HTTP dates

    @usableFromInline
    static let monthNames: [[UInt8]] = [
        Array("Jan".utf8), Array("Feb".utf8), Array("Mar".utf8), Array("Apr".utf8),
        Array("May".utf8), Array("Jun".utf8), Array("Jul".utf8), Array("Aug".utf8),
        Array("Sep".utf8), Array("Oct".utf8), Array("Nov".utf8), Array("Dec".utf8),
    ]

    @usableFromInline
    static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    @usableFromInline
    static let longDayNames = ["Monday", "Tuesday", "Wednesday", "Thursday",
                               "Friday", "Saturday", "Sunday"]

    /// All three forms RFC 9110 §5.6.7 requires a parser to accept: IMF-fixdate,
    /// obsolete RFC 850, and C's asctime. The day name is validated as a name but not
    /// cross-checked against the date — the spec's own leniency.
    @usableFromInline
    static func parseHTTPDate(
        _ b: [UInt8]
    ) -> Result<Double, DateParseFailure> {
        // Dispatch on the first comma: after 3 bytes → IMF-fixdate; later → RFC 850;
        // absent → asctime.
        var comma: Int? = nil
        for (k, byte) in b.enumerated() where byte == 0x2C { comma = k; break }
        switch comma {
        case 3:  return parseIMFFixdate(b)
        case nil: return parseAsctime(b)
        default: return parseRFC850(b)
        }
    }

    @usableFromInline
    static func matchMonth(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 3 <= b.count else { return nil }
        for (m, name) in monthNames.enumerated()
        where b[i] == name[0] && b[i + 1] == name[1] && b[i + 2] == name[2] {
            return m + 1
        }
        return nil
    }

    @usableFromInline
    static func fixedDigits(_ b: [UInt8], _ i: inout Int, _ n: Int) -> Int? {
        guard i + n <= b.count else { return nil }
        var v = 0
        for k in i..<(i + n) {
            let d = b[k] &- 0x30
            guard d <= 9 else { return nil }
            v = v * 10 + Int(d)
        }
        i += n
        return v
    }

    /// `Sun, 06 Nov 1994 08:49:37 GMT`
    @usableFromInline
    static func parseIMFFixdate(
        _ b: [UInt8]
    ) -> Result<Double, DateParseFailure> {
        guard b.count == 29 else {
            return .failure(.init("IMF-fixdate is exactly 29 characters", at: b.count))
        }
        let day3 = String(decoding: b[0..<3], as: UTF8.self)
        guard dayNames.contains(day3) else {
            return .failure(.init("'\(day3)' is not a day name", at: 0))
        }
        var i = 5
        guard let day = fixedDigits(b, &i, 2), b[i] == 0x20 else {
            return .failure(.init("expected a 2-digit day", at: 5))
        }
        i += 1
        guard let month = matchMonth(b, i) else {
            return .failure(.init("expected a month name (Jan…Dec)", at: i))
        }
        i += 3
        guard b[i] == 0x20 else { return .failure(.init("expected a space", at: i)) }
        i += 1
        guard let year = fixedDigits(b, &i, 4) else {
            return .failure(.init("expected a 4-digit year", at: i))
        }
        guard b[i] == 0x20 else { return .failure(.init("expected a space", at: i)) }
        i += 1
        guard let (h, m, s, e) = clock(b, &i) else {
            return .failure(.init("expected hh:mm:ss", at: i))
        }
        if let e { return .failure(e) }
        guard i + 4 == b.count, b[i] == 0x20,
              b[i + 1] == 0x47, b[i + 2] == 0x4D, b[i + 3] == 0x54 else {
            return .failure(.init("must end with ' GMT'", at: i))
        }
        return finishHTTP(year: year, month: month, day: day, h: h, m: m, s: s, at: 5)
    }

    /// `Sunday, 06-Nov-94 08:49:37 GMT` — the obsolete RFC 850 form.
    @usableFromInline
    static func parseRFC850(
        _ b: [UInt8]
    ) -> Result<Double, DateParseFailure> {
        var i = 0
        while i < b.count, b[i] != 0x2C { i += 1 }
        let dayName = String(decoding: b[0..<i], as: UTF8.self)
        guard longDayNames.contains(dayName) else {
            return .failure(.init("'\(dayName)' is not a day name", at: 0))
        }
        guard i + 2 < b.count, b[i] == 0x2C, b[i + 1] == 0x20 else {
            return .failure(.init("expected ', ' after the day name", at: i))
        }
        i += 2
        let dayAt = i
        guard let day = fixedDigits(b, &i, 2), i < b.count, b[i] == 0x2D else {
            return .failure(.init("expected dd-Mon-yy", at: dayAt))
        }
        i += 1
        guard let month = matchMonth(b, i) else {
            return .failure(.init("expected a month name (Jan…Dec)", at: i))
        }
        i += 3
        guard i < b.count, b[i] == 0x2D else {
            return .failure(.init("expected '-' after the month", at: i))
        }
        i += 1
        guard let yy = fixedDigits(b, &i, 2) else {
            return .failure(.init("expected a 2-digit year", at: i))
        }
        // No clock in the core, so RFC 9110's "more than 50 years in the future" rule
        // becomes the fixed POSIX pivot: 70-99 → 19xx, 00-69 → 20xx.
        let year = yy >= 70 ? 1900 + yy : 2000 + yy
        guard i < b.count, b[i] == 0x20 else {
            return .failure(.init("expected a space before the time", at: i))
        }
        i += 1
        guard let (h, m, s, e) = clock(b, &i) else {
            return .failure(.init("expected hh:mm:ss", at: i))
        }
        if let e { return .failure(e) }
        guard i + 4 == b.count, b[i] == 0x20,
              b[i + 1] == 0x47, b[i + 2] == 0x4D, b[i + 3] == 0x54 else {
            return .failure(.init("must end with ' GMT'", at: i))
        }
        return finishHTTP(year: year, month: month, day: day, h: h, m: m, s: s, at: dayAt)
    }

    /// `Sun Nov  6 08:49:37 1994` — asctime, day-of-month space-padded.
    @usableFromInline
    static func parseAsctime(
        _ b: [UInt8]
    ) -> Result<Double, DateParseFailure> {
        guard b.count == 24 else {
            return .failure(.init("asctime is exactly 24 characters", at: b.count))
        }
        let day3 = String(decoding: b[0..<3], as: UTF8.self)
        guard dayNames.contains(day3) else {
            return .failure(.init("'\(day3)' is not a day name", at: 0))
        }
        guard b[3] == 0x20 else { return .failure(.init("expected a space", at: 3)) }
        guard let month = matchMonth(b, 4) else {
            return .failure(.init("expected a month name (Jan…Dec)", at: 4))
        }
        guard b[7] == 0x20 else { return .failure(.init("expected a space", at: 7)) }
        var day = 0
        if b[8] == 0x20 {
            let d = b[9] &- 0x30
            guard d >= 1 && d <= 9 else {
                return .failure(.init("expected a day of month", at: 9))
            }
            day = Int(d)
        } else {
            let hi = b[8] &- 0x30, lo = b[9] &- 0x30
            guard hi <= 9 && lo <= 9 else {
                return .failure(.init("expected a day of month", at: 8))
            }
            day = Int(hi) * 10 + Int(lo)
        }
        guard b[10] == 0x20 else { return .failure(.init("expected a space", at: 10)) }
        var i = 11
        guard let (h, m, s, e) = clock(b, &i) else {
            return .failure(.init("expected hh:mm:ss", at: i))
        }
        if let e { return .failure(e) }
        guard b[19] == 0x20 else { return .failure(.init("expected a space", at: 19)) }
        i = 20
        guard let year = fixedDigits(b, &i, 4) else {
            return .failure(.init("expected a 4-digit year", at: 20))
        }
        return finishHTTP(year: year, month: month, day: day, h: h, m: m, s: s, at: 8)
    }

    /// `hh:mm:ss` with range checks. Returns nil if the shape is absent; a non-nil
    /// failure if the shape is present but a field is out of range.
    @usableFromInline
    static func clock(
        _ b: [UInt8], _ i: inout Int
    ) -> (Int, Int, Int, DateParseFailure?)? {
        let at = i
        guard let h = fixedDigits(b, &i, 2), i < b.count, b[i] == 0x3A else { return nil }
        i += 1
        guard let m = fixedDigits(b, &i, 2), i < b.count, b[i] == 0x3A else { return nil }
        i += 1
        guard let s = fixedDigits(b, &i, 2) else { return nil }
        if h > 23 { return (h, m, s, .init("hour \(pad2(h)) is out of range", at: at)) }
        if m > 59 { return (h, m, s, .init("minute \(pad2(m)) is out of range", at: at + 3)) }
        if s > 60 { return (h, m, s, .init("second \(pad2(s)) is out of range", at: at + 6)) }
        return (h, m, s, nil)
    }

    @usableFromInline
    static func finishHTTP(
        year: Int, month: Int, day: Int, h: Int, m: Int, s: Int, at dayOffset: Int
    ) -> Result<Double, DateParseFailure> {
        guard day >= 1 && day <= daysIn(month: month, year: year) else {
            return .failure(.init(
                "day \(pad2(day)) is out of range for \(pad4(year))-\(pad2(month))",
                at: dayOffset))
        }
        return .success(epochSeconds(
            year: year, month: month, day: day, hour: h, minute: m, second: s,
            fraction: 0, offsetSeconds: 0))
    }

    // MARK: Fixed patterns

    /// One token of a compiled pattern.
    @usableFromInline
    enum PatternToken: Equatable {
        case year4, month2, day2, hour2, minute2, second2, millis3, zone
        case literal(UInt8)
    }

    /// The compile outcome. Not `Result`, whose `Failure` must be an `Error`; the
    /// failure here is a diagnostic sentence, not a thrown thing.
    @usableFromInline
    enum PatternCompileResult {
        case success([PatternToken])
        case failure(String)
    }

    /// `yyyy MM dd HH mm ss SSS Z` plus literals. Returns the reason a pattern is
    /// malformed so both the macro (at expansion, as a diagnostic) and the runtime
    /// (for a hand-built `Assayer`) reject it with the same words.
    @usableFromInline
    static func compilePattern(_ pattern: String) -> PatternCompileResult {
        var tokens: [PatternToken] = []
        let bytes = Array(pattern.utf8)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            // UTS-35-style quoting for letter literals: 'T' is the letter, '' is an
            // apostrophe. Without this, "yyyy-MM-dd'T'HH:mm:ss" cannot be written.
            if c == 0x27 {
                i += 1
                if i < bytes.count, bytes[i] == 0x27 {
                    tokens.append(.literal(0x27))
                    i += 1
                    continue
                }
                var closed = false
                while i < bytes.count {
                    if bytes[i] == 0x27 { closed = true; i += 1; break }
                    tokens.append(.literal(bytes[i]))
                    i += 1
                }
                guard closed else {
                    return .failure("unterminated quote in date pattern")
                }
                continue
            }
            let isLetter = (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A
            if !isLetter {
                tokens.append(.literal(c))
                i += 1
                continue
            }
            var run = 1
            while i + run < bytes.count, bytes[i + run] == c { run += 1 }
            switch (Character(UnicodeScalar(c)), run) {
            case ("y", 4): tokens.append(.year4)
            case ("M", 2): tokens.append(.month2)
            case ("d", 2): tokens.append(.day2)
            case ("H", 2): tokens.append(.hour2)
            case ("m", 2): tokens.append(.minute2)
            case ("s", 2): tokens.append(.second2)
            case ("S", 3): tokens.append(.millis3)
            case ("Z", 1): tokens.append(.zone)
            default:
                let field = String(repeating: String(UnicodeScalar(c)), count: run)
                return .failure(
                    "unsupported pattern field '\(field)'; supported fields are "
                    + "yyyy MM dd HH mm ss SSS Z, plus non-letter literals")
            }
            i += run
        }
        guard tokens.contains(.year4), tokens.contains(.month2), tokens.contains(.day2) else {
            return .failure("a date pattern needs at least yyyy, MM and dd to name an instant")
        }
        return .success(tokens)
    }

    @usableFromInline
    static func parsePattern(
        _ b: [UInt8], pattern: String
    ) -> Result<Double, DateParseFailure> {
        let tokens: [PatternToken]
        switch compilePattern(pattern) {
        case .success(let t): tokens = t
        case .failure(let why): return .failure(.init(why, at: 0))
        }

        var i = 0
        var year = 0, month = 1, day = 1, hour = 0, minute = 0, second = 0
        var fraction = 0.0
        var offset = 0

        func take(_ n: Int) -> Int? { fixedDigits(b, &i, n) }

        for token in tokens {
            switch token {
            case .year4:
                guard let v = take(4) else {
                    return .failure(.init("expected a 4-digit year", at: i))
                }
                year = v
            case .month2:
                guard let v = take(2), (1...12).contains(v) else {
                    return .failure(.init("expected a 2-digit month (01-12)", at: i))
                }
                month = v
            case .day2:
                guard let v = take(2), v >= 1 else {
                    return .failure(.init("expected a 2-digit day", at: i))
                }
                day = v
            case .hour2:
                guard let v = take(2), v <= 23 else {
                    return .failure(.init("expected a 2-digit hour (00-23)", at: i))
                }
                hour = v
            case .minute2:
                guard let v = take(2), v <= 59 else {
                    return .failure(.init("expected a 2-digit minute (00-59)", at: i))
                }
                minute = v
            case .second2:
                guard let v = take(2), v <= 60 else {
                    return .failure(.init("expected a 2-digit second (00-60)", at: i))
                }
                second = v
            case .millis3:
                guard let v = take(3) else {
                    return .failure(.init("expected 3-digit milliseconds", at: i))
                }
                fraction = Double(v) / 1_000
            case .zone:
                guard i < b.count else {
                    return .failure(.init("ends before the UTC offset ('Z' or ±hh:mm)", at: i))
                }
                if b[i] == 0x5A || b[i] == 0x7A {
                    i += 1
                } else if b[i] == 0x2B || b[i] == 0x2D {
                    let negative = b[i] == 0x2D
                    i += 1
                    guard let oh = take(2), oh <= 23 else {
                        return .failure(.init("expected a 2-digit offset hour", at: i))
                    }
                    if i < b.count, b[i] == 0x3A { i += 1 }
                    guard let om = take(2), om <= 59 else {
                        return .failure(.init("expected a 2-digit offset minute", at: i))
                    }
                    offset = (oh * 3_600 + om * 60) * (negative ? -1 : 1)
                } else {
                    return .failure(.init("expected 'Z' or a ±hh:mm offset", at: i))
                }
            case .literal(let c):
                guard i < b.count, b[i] == c else {
                    return .failure(.init(
                        "expected '\(Character(UnicodeScalar(c)))'", at: i))
                }
                i += 1
            }
        }
        guard i == b.count else {
            return .failure(.init("unexpected trailing characters", at: i))
        }
        guard day <= daysIn(month: month, year: year) else {
            return .failure(.init(
                "day \(pad2(day)) is out of range for \(pad4(year))-\(pad2(month))", at: 0))
        }
        // A pattern with no Z field is read as UTC — deterministic on every platform,
        // where DateFormatter would have silently used the machine's local zone.
        return .success(epochSeconds(
            year: year, month: month, day: day, hour: hour, minute: minute,
            second: second, fraction: fraction, offsetSeconds: offset))
    }
}

// MARK: - Small formatting helpers (error messages only)

@usableFromInline
func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

@usableFromInline
func pad4(_ n: Int) -> String {
    if n >= 1000 { return "\(n)" }
    if n >= 100 { return "0\(n)" }
    if n >= 10 { return "00\(n)" }
    return "000\(n)"
}

extension DateFormat {
    /// The shared candidate list for a plain `var x: Date` with no `@DateFormat` — one
    /// global instead of a per-field static in every schema type.
    public static let defaultFormats: [DateFormat] = [.iso8601]
}

extension DateParser {
    /// Epoch seconds → `2026-08-06T12:30:00Z`, for error messages: a violation on a date
    /// field should read as a date, not as `1786363800.0`. Hinnant's `civil_from_days`,
    /// the exact inverse of the arithmetic in `epochDays`.
    public static func formatISO8601(_ seconds: Double) -> String {
        formatEpochISO(seconds)
    }
}

@usableFromInline
func formatEpochISO(_ seconds: Double) -> String {
    guard seconds.isFinite, abs(seconds) <= 9_007_199_254_740_992.0 else {
        return String(seconds)
    }
    let total = Int(seconds.rounded(.down))
    var days = total / 86_400
    var rem = total % 86_400
    if rem < 0 { rem += 86_400; days -= 1 }

    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097                                     // [0, 146096]
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)               // [0, 365]
    let mp = (5 * doy + 2) / 153                                    // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    let year = m <= 2 ? y + 1 : y

    let h = rem / 3_600, mi = (rem % 3_600) / 60, s = rem % 60
    return "\(pad4(year))-\(pad2(m))-\(pad2(d))T\(pad2(h)):\(pad2(mi)):\(pad2(s))Z"
}

// MARK: - The JSON reader primitive

extension AssayReader {

    /// Decode a date value: a string tried against each text-shaped format in order, or
    /// a bare number for `.unixSeconds`/`.unixMillis`. Returns EPOCH SECONDS — the
    /// generated code wraps them in `Date(timeIntervalSince1970:)`, which resolves in
    /// the user's module (see the header).
    ///
    /// A match on any format after the first adds a warning naming which one matched —
    /// the same contract as `@Key(_:or:)`, and for the same reason: silent tolerance is
    /// how a payload drifts formats without anyone noticing.
    @inlinable
    public mutating func decodeDate(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        _ formats: [DateFormat]
    ) -> Double? {
        beginValue()
        if currentByte == 0x22 {
            let start = cursor
            guard let text = scanString() else {
                failed(&sink, path, key, "date")
                return nil
            }
            return dateFromText(text, formats, &sink, path, key, valueStart: start)
        }
        let start = cursor
        if let v = scanDouble() {
            return dateFromNumber(v, formats, &sink, path, key, valueStart: start)
        }
        failed(&sink, path, key, "date")
        return nil
    }

    @inlinable
    public mutating func decodeDateOrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        _ formats: [DateFormat]
    ) -> Double?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = decodeDate(&sink, path, key, formats) { return .some(v) }
        return nil
    }

    @usableFromInline
    mutating func dateFromText(
        _ text: String, _ formats: [DateFormat], _ sink: inout IssueSink,
        _ path: [PathComponent], _ key: StaticString, valueStart: Int
    ) -> Double? {
        var primary: DateParseFailure? = nil
        for (i, format) in formats.enumerated() {
            switch DateParser.parse(text, as: format) {
            case .success(let seconds):
                if i > 0 {
                    warnDateFallback(&sink, path, key, matched: format, primary: formats[0])
                }
                return seconds
            case .failure(let failure):
                if primary == nil { primary = failure }
            }
        }
        // +1 skips the opening quote, so the caret lands on the failing byte INSIDE the
        // string — "day 31 is out of range" points at the 31.
        reportInvalidDate(
            &sink, path, key, formats, received: text,
            failure: primary ?? DateParseFailure("no formats to try", at: 0),
            caretAt: valueStart + 1 + (primary?.offset ?? 0))
        return nil
    }

    @usableFromInline
    mutating func dateFromNumber(
        _ value: Double, _ formats: [DateFormat], _ sink: inout IssueSink,
        _ path: [PathComponent], _ key: StaticString, valueStart: Int
    ) -> Double? {
        var primary: DateParseFailure? = nil
        for (i, format) in formats.enumerated() where format.acceptsNumber {
            switch DateParser.parse(seconds: value, as: format) {
            case .success(let seconds):
                if i > 0 {
                    warnDateFallback(&sink, path, key, matched: format, primary: formats[0])
                }
                return seconds
            case .failure(let failure):
                if primary == nil { primary = failure }
            }
        }
        reportInvalidDate(
            &sink, path, key, formats, received: shortDouble(value),
            failure: primary
                ?? DateParseFailure("value is a number; \(formats[0].displayName) is text", at: 0),
            caretAt: valueStart)
        return nil
    }

    @inline(never)
    @usableFromInline
    mutating func reportInvalidDate(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        _ formats: [DateFormat], received: String, failure: DateParseFailure, caretAt: Int
    ) {
        sink.add(Issue(
            code: .custom("invalid_date"),
            path: path + [.key(String(describing: key))],
            params: [
                "expected": .string(formats.map(\.displayName).joined(separator: ", or ")),
                "reason": .string(failure.reason),
                "offset": .int(failure.offset),
            ],
            received: received.count > 64 ? String(received.prefix(61)) + "..." : received,
            location: SourceSpan(lo: caretAt, len: 1)))
    }

    @inline(never)
    @usableFromInline
    mutating func warnDateFallback(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        matched: DateFormat, primary: DateFormat
    ) {
        sink.add(warning: Warning(
            code: .custom("date_format_fallback"),
            path: path + [.key(String(describing: key))],
            params: [
                "matched": .string(matched.displayName),
                "primary": .string(primary.displayName),
            ]))
    }
}

/// A short rendering of a numeric wire value for error text; `String(_: Double)` says
/// `1.691234567e9`, which is not what the payload said.
@usableFromInline
func shortDouble(_ d: Double) -> String {
    if d == d.rounded(), abs(d) < 1e15 {
        return String(Int64(d))
    }
    return String(d)
}

// MARK: - The RawValue path (YAML and XML)

extension RawValue {

    /// The format-neutral projection has already resolved scalars, so a YAML `1691234567`
    /// arrives as `.int` and an XML `<ts>1691234567</ts>` as `.string` — both must reach
    /// `.unixSeconds`, which is why the text parser accepts digit strings.
    @inlinable
    public func assayDate(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        _ formats: [DateFormat]
    ) -> Double? {
        switch self {
        case .string(let text):
            var primary: DateParseFailure? = nil
            for (i, format) in formats.enumerated() {
                switch DateParser.parse(text, as: format) {
                case .success(let seconds):
                    if i > 0 {
                        Self.warnDateFallback(&sink, path, key,
                                              matched: format, primary: formats[0])
                    }
                    return seconds
                case .failure(let failure):
                    if primary == nil { primary = failure }
                }
            }
            Self.reportInvalidDate(
                &sink, path, key, formats, received: text,
                failure: primary ?? DateParseFailure("no formats to try", at: 0))
            return nil

        case .int(let i):
            return numberDate(Double(i), formats, &sink, path, key, received: String(i))
        case .double(let d):
            return numberDate(d, formats, &sink, path, key, received: shortDouble(d))

        default:
            Self.mismatch(&sink, path, key, "date", self)
            return nil
        }
    }

    @usableFromInline
    func numberDate(
        _ value: Double, _ formats: [DateFormat], _ sink: inout IssueSink,
        _ path: [PathComponent], _ key: StaticString, received: String
    ) -> Double? {
        var primary: DateParseFailure? = nil
        for (i, format) in formats.enumerated() where format.acceptsNumber {
            switch DateParser.parse(seconds: value, as: format) {
            case .success(let seconds):
                if i > 0 {
                    Self.warnDateFallback(&sink, path, key,
                                          matched: format, primary: formats[0])
                }
                return seconds
            case .failure(let failure):
                if primary == nil { primary = failure }
            }
        }
        Self.reportInvalidDate(
            &sink, path, key, formats, received: received,
            failure: primary
                ?? DateParseFailure("value is a number; \(formats[0].displayName) is text", at: 0))
        return nil
    }

    /// No `location`: the node trees drop byte offsets when they are built. That is
    /// ROADMAP.md §12, not a decision made here.
    @inline(never)
    @usableFromInline
    static func reportInvalidDate(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        _ formats: [DateFormat], received: String, failure: DateParseFailure
    ) {
        sink.add(Issue(
            code: .custom("invalid_date"),
            path: path + [.key(String(describing: key))],
            params: [
                "expected": .string(formats.map(\.displayName).joined(separator: ", or ")),
                "reason": .string(failure.reason),
                "offset": .int(failure.offset),
            ],
            received: received.count > 64 ? String(received.prefix(61)) + "..." : received))
    }

    @inline(never)
    @usableFromInline
    static func warnDateFallback(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        matched: DateFormat, primary: DateFormat
    ) {
        sink.add(warning: Warning(
            code: .custom("date_format_fallback"),
            path: path + [.key(String(describing: key))],
            params: [
                "matched": .string(matched.displayName),
                "primary": .string(primary.displayName),
            ]))
    }
}
