// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Date differential: Assay's civil arithmetic vs Foundation's calendar machinery.
//
// This lives here and not in Tests/ because importing Foundation into the library's test
// target pulls swift-testing's _Testing_Foundation overlay and its macOS 13 floor.
//
// Every agreement is EXACT (Double equality, no tolerance): both sides are integer
// arithmetic over the same civil fields, and "close" would mean one of them is wrong.
// Deliberate divergences are named in Sources/AssayCore/Dates.swift's header and are
// not exercised here: leap seconds (`:60` — Assay accepts, Foundation rejects) and the
// RFC 850 two-digit-year pivot (Assay uses the fixed POSIX pivot, Foundation asks a
// clock).
//===----------------------------------------------------------------------===//

import Foundation
import AssayCore

func runDateDifferential() -> Int {
    var checked = 0

    // 1. Foundation formats, Assay reparses. Prime step so instants never align with
    //    month or week boundaries; range covers 1902...2038 including negatives.
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone(identifier: "UTC")!
    var t = -2_147_000_000.0
    while t < 2_147_000_000.0 {
        let text = iso.string(from: Date(timeIntervalSince1970: t))
        switch DateParser.parse(text, as: .iso8601) {
        case .success(let mine):
            if mine != t {
                fail("date: \(text) — Assay \(mine) vs Foundation \(t)")
            }
        case .failure(let f):
            fail("date: Assay rejected Foundation's own output \(text): \(f.reason)")
        }
        t += 3_456_789
        checked += 1
    }

    // 2. Assay parses arbitrary valid civil fields, Foundation must agree.
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
    func pad(_ n: Int, _ w: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, w - s.count)) + s
    }
    for _ in 0..<1_000 {
        let year = 1583 + next(2500 - 1583)
        let month = 1 + next(12)
        let dim = [31, (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28,
                   31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        let day = 1 + next(dim)
        let h = next(24), m = next(60), s = next(60)
        let text = "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
            + "T\(pad(h, 2)):\(pad(m, 2)):\(pad(s, 2))Z"
        guard let theirs = iso.date(from: text) else {
            fail("date: Foundation rejected valid \(text)")
            continue
        }
        switch DateParser.parse(text, as: .iso8601) {
        case .success(let mine):
            if mine != theirs.timeIntervalSince1970 {
                fail("date: \(text) — Assay \(mine) vs Foundation \(theirs.timeIntervalSince1970)")
            }
        case .failure(let f):
            fail("date: Assay rejected \(text): \(f.reason)")
        }
        checked += 1
    }

    // 3. HTTP dates against a POSIX-locale DateFormatter emitting IMF-fixdate.
    let http = DateFormatter()
    http.locale = Locale(identifier: "en_US_POSIX")
    http.timeZone = TimeZone(identifier: "GMT")!
    http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    t = 0
    while t < 2_000_000_000.0 {
        let text = http.string(from: Date(timeIntervalSince1970: t))
        switch DateParser.parse(text, as: .rfc9110) {
        case .success(let mine):
            if mine != t { fail("http-date: \(text) — Assay \(mine) vs \(t)") }
        case .failure(let f):
            fail("http-date: Assay rejected \(text): \(f.reason)")
        }
        t += 73_456_789
        checked += 1
    }

    // 4. Rejection agreement on a fixed adversarial list — cases where both sides
    //    should refuse.
    let invalid = [
        "2026-13-01T00:00:00Z", "2026-08-06T12:60:00Z", "not a date",
        "2026-08-06", "2026-08-06T12:00Z",
    ]
    for text in invalid {
        let theirs = iso.date(from: text)
        let mine = try? DateParser.parse(text, as: .iso8601).get()
        if theirs != nil && mine == nil {
            fail("date: Foundation accepts \(text), Assay rejects it")
        }
        if theirs == nil && mine != nil {
            fail("date: Assay accepts \(text), Foundation rejects it")
        }
        checked += 1
    }

    // 5. A deliberate divergence, pinned so it stays deliberate: Foundation ROLLS OVER
    //    impossible civil dates — Feb 29 of a common year becomes Mar 1, Apr 31 becomes
    //    May 1, hour 24 becomes the next midnight — which is precisely the quiet
    //    mis-read a validating decoder exists to refuse. Assay rejects all three with
    //    the field named. If Foundation ever becomes strict, this section fails and the
    //    cases move up into the agreement list.
    for text in ["2026-02-29T00:00:00Z", "2026-04-31T00:00:00Z", "2026-08-06T24:00:00Z"] {
        if (try? DateParser.parse(text, as: .iso8601).get()) != nil {
            fail("date: Assay accepted the impossible date \(text)")
        }
        if iso.date(from: text) == nil {
            fail("date: Foundation now rejects \(text) — move it to the agreement list")
        }
        checked += 1
    }

    return checked
}
