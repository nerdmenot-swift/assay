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
//
// EVERY ONE OF THEM GOES THROUGH `withBytes`, and none materialises an `Array`. That is not
// incidental tidiness. These run per value per record — `T.validate(rows)` over a million
// rows calls them a million times — and this file has now been wrong about performance in
// two different directions, both caught by measurement:
//
//   1. The first version ALLOCATED. `isEmail` built `Array(s.utf8)` then `Array(domain)`;
//      `isHostname` split into `[[UInt8]]`, one array per label plus reallocating appends;
//      `isTrimmed` built a `Set<UInt8>` per call. Roughly six heap allocations to check
//      fifteen bytes, and `.email` cost 179 ns against 9 ns for `.range`.
//
//   2. The obvious fix — walk `String.utf8` directly with indices — removed every
//      allocation and made `.uuid` SLOWER, 50 ns to 61. `String.UTF8View.Iterator` carries a
//      representation check per byte that `Array` iteration does not, and over 36 bytes that
//      outweighed the malloc it saved.
//
// So the shape here is neither: take the contiguous buffer ONCE with `withUTF8` and walk
// that. `withUTF8` allocates nothing for a small-form or native string — it makes storage
// contiguous only when it is not already — and gives the tight loop a plain pointer.
//
// The rule of this file, therefore: one `withBytes` at the entry point, everything below it
// over `Span<UInt8>`, and no `Array`, no per-call `Set`, and no sub-array per
// label anywhere.
//===----------------------------------------------------------------------===//

public enum FormatValidators {

    /// The contiguous UTF-8 bytes of `s` as a `Span`, without allocating.
    ///
    /// `withUTF8` is `mutating`, hence the local copy — which is a retain for a native
    /// string and nothing at all for a small one. It guarantees contiguity for every string
    /// representation, so nothing below this line has to care which one it got.
    ///
    /// The pointer becomes a `Span` HERE, at the single seam, which is hard constraint 11:
    /// unsafe code only below the seam, and the seam expressible in `Span` and values. Every
    /// validator below is ordinary safe Swift over an indexable buffer, and this function is
    /// the only `unsafe` in the file.
    @inline(__always)
    static func withBytes<R>(_ s: String, _ body: (Span<UInt8>) -> R) -> R {
        var copy = s
        return copy.withUTF8 { buffer in body(unsafe Span(_unsafeElements: buffer)) }
    }

    @inline(__always) static var dot: UInt8 { UInt8(ascii: ".") }
    @inline(__always) static var hyphen: UInt8 { UInt8(ascii: "-") }

    @inline(__always) static func isDigit(_ b: UInt8) -> Bool {
        b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
    }

    @inline(__always) static func isAlpha(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
    }

    // MARK: Email

    /// Local part ≤ 64 bytes with a sane charset, exactly one split at the LAST `@`,
    /// domain validated as a hostname, total ≤ 320 (the same bounds Vapor enforces
    /// around its regex — here without the regex).
    public static func isEmail(_ s: String) -> Bool {
        withBytes(s) { isEmail(bytes: $0) }
    }

    static func isEmail(bytes: Span<UInt8>) -> Bool {
        let n = bytes.count
        guard n <= 320 else { return false }

        var at = -1
        var i = n - 1
        while i >= 0 {
            if bytes[i] == UInt8(ascii: "@") { at = i; break }
            i -= 1
        }
        guard at >= 1, at <= 64 else { return false }     // local part 1...64 bytes

        // RFC 5322 atext plus dot; dots must not lead, trail or double.
        var previousWasDot = true                         // leading dot rejected
        for j in 0..<at {
            let b = bytes[j]
            if b == dot {
                if previousWasDot { return false }
                previousWasDot = true
                continue
            }
            previousWasDot = false
            guard isAtext(b) else { return false }
        }
        if previousWasDot { return false }                // trailing dot

        return hostname(bytes: bytes, from: at + 1, to: n,
                               requireMultipleLabels: true)
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

    // MARK: Hostname

    /// RFC 1123 shape: ≤ 253 bytes total, labels 1–63 of `[A-Za-z0-9-]` with no leading
    /// or trailing hyphen, optional trailing dot, and a TLD that is not all-numeric.
    public static func isHostname(_ s: String) -> Bool {
        withBytes(s) {
            hostname(bytes: $0, from: 0, to: $0.count, requireMultipleLabels: false)
        }
    }

    /// One pass over `bytes[from..<to]`, tracking the current label's length and shape in
    /// local variables. The version this replaced split into `[[UInt8]]` first, which is the
    /// same walk plus one heap allocation per label.
    ///
    /// A trailing dot is legal and is dropped by narrowing the range — not by copying the
    /// bytes somewhere one can be removed from the end.
    static func hostname(
        bytes: Span<UInt8>, from: Int, to: Int, requireMultipleLabels: Bool
    ) -> Bool {
        var end = to
        if end > from, bytes[end - 1] == dot { end -= 1 }
        guard end - from <= 253 else { return false }

        var labelLength = 0
        var closedLabels = 0
        var previous: UInt8 = 0
        // Whether the label currently being read is all digits. Checked at the end against
        // the LAST label, so "1.2.3.4" does not pass as a hostname.
        var labelAllNumeric = true

        for i in from..<end {
            let b = bytes[i]
            if b == dot {
                guard labelLength >= 1, previous != hyphen else { return false }
                closedLabels += 1
                labelLength = 0
                labelAllNumeric = true
                previous = b
                continue
            }
            if labelLength == 0, b == hyphen { return false }
            labelLength += 1
            if labelLength > 63 { return false }
            guard isAlpha(b) || isDigit(b) || b == hyphen else { return false }
            if !isDigit(b) { labelAllNumeric = false }
            previous = b
        }

        // The final label, which no dot closed. An empty one means the range was empty, or
        // was a bare "." or ended in a doubled dot.
        guard labelLength >= 1, previous != hyphen else { return false }
        if requireMultipleLabels, closedLabels < 1 { return false }
        return !labelAllNumeric
    }

    // MARK: UUID

    /// Exactly 8-4-4-4-12 hex with hyphens. No braces, no urn:uuid:, no bare 32-hex —
    /// the canonical text form and nothing else, identically on every platform.
    public static func isUUID(_ s: String) -> Bool {
        withBytes(s) { isUUID(bytes: $0) }
    }

    static func isUUID(bytes: Span<UInt8>) -> Bool {
        guard bytes.count == 36 else { return false }
        for i in 0..<36 {
            let b = bytes[i]
            if i == 8 || i == 13 || i == 18 || i == 23 {
                guard b == hyphen else { return false }
            } else {
                let isHex = isDigit(b)
                    || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f"))
                    || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"))
                guard isHex else { return false }
            }
        }
        return true
    }

    // MARK: URL

    /// A plausible absolute URL reference: `scheme ":" rest`, scheme per RFC 3986
    /// (ALPHA *(ALPHA / DIGIT / "+" / "-" / ".")), a non-empty rest, and no whitespace or
    /// control bytes anywhere. Syntactic on purpose — resolving hosts or IDNA differs by
    /// platform, which is the exact failure mode this library refuses.
    public static func isURL(_ s: String) -> Bool {
        withBytes(s) { isURL(bytes: $0) }
    }

    static func isURL(bytes: Span<UInt8>) -> Bool {
        let n = bytes.count
        var colon = -1
        for i in 0..<n {
            let b = bytes[i]
            if b <= 0x20 || b == 0x7F { return false }    // space, controls, anywhere
            if colon >= 0 { continue }
            if b == UInt8(ascii: ":") { colon = i; continue }
            if i == 0 {
                guard isAlpha(b) else { return false }    // a scheme starts with a letter
            } else {
                let ok = isAlpha(b) || isDigit(b)
                    || b == UInt8(ascii: "+") || b == hyphen || b == dot
                guard ok else { return false }
            }
        }
        return colon >= 1 && colon + 1 < n
    }

    // MARK: Counting and trimming

    /// The number of Characters in `s` — grapheme clusters, which is what a rule whose
    /// message says "characters" has to mean, and what `String.count` returns.
    ///
    /// `String.count` runs the full Unicode segmentation algorithm and cost ~22 ns on a
    /// 15-byte string, which made `.min`/`.max` — the two most common rules in any schema —
    /// as expensive as `.url`. The shortcut: if every byte is ASCII **and none is CR**, each
    /// byte is its own grapheme cluster, so the count is the byte count.
    ///
    /// CR is the exception and it is the ONLY one, which is why this cannot simply be "is it
    /// ASCII": "\r\n" is a SINGLE grapheme cluster spanning two ASCII bytes, so a pure-ASCII
    /// string containing CR has fewer Characters than bytes. No other ASCII scalar combines
    /// with a neighbour. Anything else — any high bit set, any CR — falls back to
    /// `String.count`, which is exactly right and merely slower. The differential in DiffFuzz
    /// checks this against `s.count` itself over generated strings, because the argument
    /// above is the kind that is convincing and wrong.
    public static func characterCount(_ s: String) -> Int {
        let fast: Int? = withBytes(s) { bytes in
            let n = bytes.count
            for i in 0..<n {
                let b = bytes[i]
                if b >= 0x80 || b == 0x0D { return nil }
            }
            return n
        }
        return fast ?? s.count
    }

    public static func isASCII(_ s: String) -> Bool {
        withBytes(s) { bytes in
            let n = bytes.count
            for i in 0..<n where bytes[i] >= 0x80 { return false }
            return true
        }
    }

    /// Leading/trailing ASCII whitespace check, locale-free. Four comparisons rather than
    /// a `Set<UInt8>` built per call — this runs per value, and the set was an allocation.
    public static func isTrimmed(_ s: String) -> Bool {
        withBytes(s) { bytes in
            let n = bytes.count
            guard n > 0 else { return true }
            @inline(__always) func isSpace(_ b: UInt8) -> Bool {
                b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
            }
            return !isSpace(bytes[0]) && !isSpace(bytes[n - 1])
        }
    }
}

extension FormatValidators {
    /// Substring test over UTF-8 bytes. The stdlib's `String.contains(String)` comes from
    /// the StringProcessing overlay with a macOS 13 floor; this has none.
    public static func containsSubstring(_ haystack: String, _ needle: String) -> Bool {
        withBytes(haystack) { h in
            withBytes(needle) { n in
                let hc = h.count, nc = n.count
                if nc == 0 { return true }
                guard nc <= hc else { return false }
                // Naive search, as it was before, but over two pointers rather than over two
                // freshly allocated arrays.
                for start in 0...(hc - nc) {
                    var i = 0
                    while i < nc, h[start + i] == n[i] { i += 1 }
                    if i == nc { return true }
                }
                return false
            }
        }
    }
}
