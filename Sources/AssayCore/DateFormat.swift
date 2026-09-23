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
        case .iso8601: return "ISO-8601 date"
        case .unixSeconds: return "unix timestamp (seconds)"
        case .unixMillis: return "unix timestamp (milliseconds)"
        case .rfc9110: return "HTTP date (RFC 9110)"
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
