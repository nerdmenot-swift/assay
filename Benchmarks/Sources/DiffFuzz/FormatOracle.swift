// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The format validators, against a naive oracle. Sources/AssayCore/FormatValidators.swift.
//
// This oracle is the SHIPPED IMPLEMENTATION AS IT WAS BEFORE it was made allocation-free —
// verbatim, `Array(s.utf8)` and `[[UInt8]]` and all. It is kept because that version was
// obviously correct and obviously slow: it split the domain into an array per label and
// checked each one on its own, which is the way you would write it if you were only trying
// to be right. The fast one walks the UTF-8 view in a single pass with the label state in
// local variables, and single-pass rewrites of a multi-pass check are exactly where an
// edge case goes missing — an empty label, a trailing hyphen at the very end, a bare dot.
//
// So the two are run against the same inputs and required to agree, on every generated
// string and on a table of the cases that make these functions hard. `.email` went from
// 179 ns to the numbers in RESULTS.md by this change; the oracle is what makes that a
// speedup rather than a behaviour change nobody noticed.
//===----------------------------------------------------------------------===//

import AssayCore

enum NaiveFormats {

    /// Local part ≤ 64 bytes with a sane charset, exactly one split at the LAST `@`,
    /// domain validated as a hostname, total ≤ 320 (the same bounds Vapor enforces
    /// around its regex — here without the regex).
    static func isEmail(_ s: String) -> Bool {
        let utf8 = Array(s.utf8)
        guard utf8.count <= 320, let at = utf8.lastIndex(of: UInt8(ascii: "@")) else {
            return false
        }
        let local = utf8[..<at]
        let domain = utf8[utf8.index(after: at)...]
        guard local.count >= 1, local.count <= 64 else { return false }

        // RFC 5322 atext plus dot; dots must not lead, trail or double.
        var previousWasDot = true                     // leading dot rejected
        for b in local {
            if b == UInt8(ascii: ".") {
                if previousWasDot { return false }
                previousWasDot = true
                continue
            }
            previousWasDot = false
            guard isAtext(b) else { return false }
        }
        if previousWasDot { return false }            // trailing dot

        return isHostname(bytes: Array(domain), requireMultipleLabels: true)
    }

    static func isAtext(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"),
             UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: "-"), UInt8(ascii: "/"), UInt8(ascii: "="), UInt8(ascii: "?"),
             UInt8(ascii: "^"), UInt8(ascii: "_"), UInt8(ascii: "`"), UInt8(ascii: "{"),
             UInt8(ascii: "|"), UInt8(ascii: "}"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    /// RFC 1123 shape: ≤ 253 bytes total, labels 1–63 of `[A-Za-z0-9-]` with no leading
    /// or trailing hyphen, optional trailing dot, and a TLD that is not all-numeric.
    static func isHostname(_ s: String) -> Bool {
        isHostname(bytes: Array(s.utf8), requireMultipleLabels: false)
    }

    static func isHostname(bytes input: [UInt8], requireMultipleLabels: Bool) -> Bool {
        var bytes = input
        if bytes.last == UInt8(ascii: ".") { bytes.removeLast() }   // trailing dot is legal
        guard bytes.count >= 1, bytes.count <= 253 else { return false }

        var labels: [[UInt8]] = []
        var current: [UInt8] = []
        for b in bytes {
            if b == UInt8(ascii: ".") {
                labels.append(current)
                current = []
            } else {
                current.append(b)
            }
        }
        labels.append(current)

        if requireMultipleLabels && labels.count < 2 { return false }

        for label in labels {
            guard label.count >= 1, label.count <= 63 else { return false }
            guard label.first != UInt8(ascii: "-"), label.last != UInt8(ascii: "-") else {
                return false
            }
            for b in label {
                let ok = (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                    || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                    || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                    || b == UInt8(ascii: "-")
                guard ok else { return false }
            }
        }

        // An all-numeric TLD means "1.2.3.4" would pass as a hostname.
        if let tld = labels.last,
           tld.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            return false
        }
        return true
    }

    /// Exactly 8-4-4-4-12 hex with hyphens. No braces, no urn:uuid:, no bare 32-hex —
    /// the canonical text form and nothing else, identically on every platform.
    static func isUUID(_ s: String) -> Bool {
        let utf8 = Array(s.utf8)
        guard utf8.count == 36 else { return false }
        for (i, b) in utf8.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                guard b == UInt8(ascii: "-") else { return false }
            } else {
                let isHex = (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                    || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f"))
                    || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"))
                guard isHex else { return false }
            }
        }
        return true
    }

    /// A plausible absolute URL reference: `scheme ":" rest`, scheme per RFC 3986
    /// (ALPHA *(ALPHA / DIGIT / "+" / "-" / ".")), a non-empty rest, and no whitespace or
    /// control bytes anywhere. Syntactic on purpose — resolving hosts or IDNA differs by
    /// platform, which is the exact failure mode this library refuses.
    static func isURL(_ s: String) -> Bool {
        let utf8 = Array(s.utf8)
        guard let colon = utf8.firstIndex(of: UInt8(ascii: ":")), colon > 0 else {
            return false
        }
        let first = utf8[0]
        guard (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z"))
            || (first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z")) else {
            return false
        }
        for b in utf8[1..<colon] {
            let ok = (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                || b == UInt8(ascii: "+") || b == UInt8(ascii: "-") || b == UInt8(ascii: ".")
            guard ok else { return false }
        }
        guard colon + 1 < utf8.count else { return false }
        for b in utf8 {
            if b <= 0x20 || b == 0x7F { return false }    // space, controls
        }
        return true
    }

    static func isASCII(_ s: String) -> Bool {
        s.utf8.allSatisfy { $0 < 0x80 }
    }

    /// Leading/trailing ASCII whitespace check, locale-free.
    static func isTrimmed(_ s: String) -> Bool {
        guard let f = s.utf8.first, let l = s.utf8.last else { return true }
        let ws: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        return !ws.contains(f) && !ws.contains(l)
    }
}

// MARK: - The differential

func runFormatDifferential() -> Bool {
    // The cases that make these functions hard, written down rather than hoped for from a
    // generator: empty labels, hyphens at the boundaries, the legal trailing dot, an
    // all-numeric TLD, the length limits, and the local part's dot rules.
    let corners = [
        "", ".", "..", "a", "a.b", "a..b", ".a", "a.", "a.b.", "-a.b", "a-.b", "a.-b",
        "a.b-", "1.2.3.4", "a.1", "1.a", "a.b.c.d", "localhost", "example.com",
        "EXAMPLE.COM", "xn--bcher-kva.example", "a-b.c-d.ef",
        String(repeating: "a", count: 63) + ".com",
        String(repeating: "a", count: 64) + ".com",
        String(repeating: "a.", count: 130) + "com",
        "ada@example.com", "ada@", "@example.com", "a@b@c.com", "a.b@c.com",
        ".a@b.com", "a.@b.com", "a..b@c.com", "a@b", "a@1.2", "a b@c.com",
        "\u{00E9}@example.com", "a@example..com", "a@-example.com", "a@example-.com",
        String(repeating: "a", count: 65) + "@example.com",
        String(repeating: "a", count: 300) + "@example.com",
        "http://example.com", "https://a", "mailto:a@b.com", "hello", "path space",
        ":", "a:", ":a", "1http://x", "h+t-t.p://x", "ftp://x/y?z#w",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf6", "f81d4fae7dec11d0a76500a0c91e6bf6",
        "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6", "f81d4fae-7dec-11d0-a765-00a0c91e6bfg",
        " a", "a ", " ", "\ta\t", "abc",
    ]

    var seed: UInt64 = 0xF011_A75E_ED00_0001
    func next() -> UInt64 {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return seed
    }
    // Bytes drawn from the alphabet these validators actually branch on, so a generated
    // string is far more likely to reach an interesting arm than a uniform one would be.
    let alphabet = Array("ab9.-@:/ \t\r\n\u{7F}+_%!#\u{00E9}\u{0301}".utf8)
    var generated: [String] = []
    for _ in 0..<40_000 {
        let n = Int(next() % 40)
        var bytes: [UInt8] = []
        for _ in 0..<n { bytes.append(alphabet[Int(next() % UInt64(alphabet.count))]) }
        generated.append(String(decoding: bytes, as: UTF8.self))
    }

    var mismatches = 0
    for s in corners + generated {
        let checks: [(String, Bool, Bool)] = [
            ("isEmail", FormatValidators.isEmail(s), NaiveFormats.isEmail(s)),
            ("isHostname", FormatValidators.isHostname(s), NaiveFormats.isHostname(s)),
            ("isUUID", FormatValidators.isUUID(s), NaiveFormats.isUUID(s)),
            ("isURL", FormatValidators.isURL(s), NaiveFormats.isURL(s)),
            ("isTrimmed", FormatValidators.isTrimmed(s), NaiveFormats.isTrimmed(s)),
            // Not a rewrite of an old implementation but a shortcut around `String.count`,
            // and the oracle for it is `String.count` itself. The interesting inputs are
            // CR (where two ASCII bytes are ONE grapheme cluster) and anything non-ASCII.
            ("characterCount",
             FormatValidators.characterCount(s) == s.count, true),
        ]
        for (name, fast, naive) in checks where fast != naive {
            mismatches += 1
            if mismatches <= 10 {
                print("  MISMATCH \(name)(\(s.debugDescription)): fast=\(fast) naive=\(naive)")
            }
        }
    }

    let total = corners.count + generated.count
    if mismatches == 0 {
        print("format differential: \(total) strings x 6 checks agree with the naive oracle")
        return true
    }
    print("format differential: \(mismatches) MISMATCHES over \(total) strings")
    return false
}
