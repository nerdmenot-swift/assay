// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Hand-rolled format validators. cross-platform-audit.md §0 and §10 force every one:
//
//   * `.uuid`  — `UUID(uuidString:)` has TWO different C implementations selected by
//     platform; the non-Darwin one is sscanf-based with libc-dependent edge cases. A UUID
//     your Mac accepts can be rejected on Linux. ~15 lines here gets bit-identical
//     behaviour everywhere.
//   * `.email` — nothing in Foundation or the stdlib validates an email at all
//     (`grep -ril email` over swift-foundation: zero files). Split on the LAST `@`,
//     validate the local part, run the hostname validator on the domain. No regex engine,
//     which is what keeps `.email` working where `.regex` cannot.
//   * `.hostname` — the only host validation in Foundation is internal and unexported.
//   * `.url` — `URL(string:)` accepts `"hello"` and `"path space"` (its own test suite
//     asserts this); the strict initializer has a HIGHER availability floor than Regex.
//     This validator means "is a plausible absolute URL reference": a scheme, then
//     structure, no whitespace or controls. It is syntactic, and says so.
//
// All of these behave identically on every platform because they are implemented here,
// against bytes, with no locale, no ICU and no libc parsing.
//===----------------------------------------------------------------------===//

public enum FormatValidators {

    /// Local part ≤ 64 bytes with a sane charset, exactly one split at the LAST `@`,
    /// domain validated as a hostname, total ≤ 320 (the same bounds Vapor enforces
    /// around its regex — here without the regex).
    public static func isEmail(_ s: String) -> Bool {
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

    private static func isAtext(_ b: UInt8) -> Bool {
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
    public static func isHostname(_ s: String) -> Bool {
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
    public static func isUUID(_ s: String) -> Bool {
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
    public static func isURL(_ s: String) -> Bool {
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

    public static func isASCII(_ s: String) -> Bool {
        s.utf8.allSatisfy { $0 < 0x80 }
    }

    /// Leading/trailing ASCII whitespace check, locale-free.
    public static func isTrimmed(_ s: String) -> Bool {
        guard let f = s.utf8.first, let l = s.utf8.last else { return true }
        let ws: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        return !ws.contains(f) && !ws.contains(l)
    }
}

extension FormatValidators {
    /// Substring test over UTF-8 bytes. The stdlib's `String.contains(String)` comes from
    /// the StringProcessing overlay with a macOS 13 floor; this has none.
    public static func containsSubstring(_ haystack: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        let h = Array(haystack.utf8), n = Array(needle.utf8)
        guard n.count <= h.count else { return false }
        for start in 0...(h.count - n.count) {
            var i = 0
            while i < n.count, h[start + i] == n[i] { i += 1 }
            if i == n.count { return true }
        }
        return false
    }
}
