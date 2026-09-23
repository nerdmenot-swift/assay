// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Values: the four string forms, integers in four bases, floats, the four date-time
// kinds, booleans, arrays and inline tables.
//
// The first byte decides the kind; nothing here backtracks. A leading digit is the one
// ambiguous case — `1979-05-27`, `07:32:00` and `1979` all start the same way — and it is
// settled by looking four bytes ahead for `-` (a date) or two for `:` (a time) before
// the number scanner is entered.
//===----------------------------------------------------------------------===//

import AssayCore

extension TOML.Parser {

    mutating func parseValue(_ r: inout AssayReader, _ sink: inout IssueSink) -> TOML.Node? {
        guard let c = r.currentByte else {
            r.report(&sink, .tomlExpectedValue)
            return nil
        }
        switch c {
        case UInt8(ascii: "\""):
            let multiline =
                r.byte(at: 1) == UInt8(ascii: "\"") && r.byte(at: 2) == UInt8(ascii: "\"")
            return scanBasicString(&r, &sink, multiline: multiline).map { .string($0) }
        case UInt8(ascii: "'"):
            let multiline = r.byte(at: 1) == UInt8(ascii: "'") && r.byte(at: 2) == UInt8(ascii: "'")
            return scanLiteralString(&r, &sink, multiline: multiline).map { .string($0) }
        case UInt8(ascii: "["):
            return parseArray(&r, &sink)
        case UInt8(ascii: "{"):
            return parseInlineTable(&r, &sink)
        case UInt8(ascii: "t"):
            if r.consume("true") { return .bool(true) }
        case UInt8(ascii: "f"):
            if r.consume("false") { return .bool(false) }
        case UInt8(ascii: "i"), UInt8(ascii: "n"), UInt8(ascii: "+"), UInt8(ascii: "-"):
            return scanNumber(&r, &sink)
        case 0x30...0x39:
            // `1979-05-27` or `07:32:00` before `1979`.
            if isDigit(r.byte(at: 1)), isDigit(r.byte(at: 2)), isDigit(r.byte(at: 3)),
                r.byte(at: 4) == UInt8(ascii: "-")
            {
                return scanDateTime(&r, &sink)
            }
            if isDigit(r.byte(at: 1)), r.byte(at: 2) == UInt8(ascii: ":") {
                return scanLocalTime(&r, &sink)
            }
            return scanNumber(&r, &sink)
        default:
            break
        }
        r.report(&sink, .tomlExpectedValue)
        return nil
    }

    func isDigit(_ b: UInt8?) -> Bool { b.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }

    // MARK: Arrays and inline tables

    /// `[ 1, 2, 3 ]` — values may be of mixed type, span lines, carry comments, and end
    /// with a trailing comma.
    mutating func parseArray(_ r: inout AssayReader, _ sink: inout IssueSink) -> TOML.Node? {
        guard r.enterContainer(&sink) else { return nil }
        defer { r.leaveContainer() }
        r.advance(by: 1)
        var items: [TOML.Node] = []
        while true {
            guard skipBlankLines(&r, &sink) else { return nil }
            guard let c = r.currentByte else {
                r.report(&sink, .tomlUnterminatedArray)
                return nil
            }
            if c == UInt8(ascii: "]") { r.advance(by: 1); return .array(items) }
            guard let value = parseValue(&r, &sink) else { return nil }
            items.append(value)
            guard skipBlankLines(&r, &sink) else { return nil }
            if r.currentByte == UInt8(ascii: ",") { r.advance(by: 1); continue }
            if r.currentByte == UInt8(ascii: "]") { r.advance(by: 1); return .array(items) }
            r.report(&sink, .tomlUnterminatedArray)
            return nil
        }
    }

    /// `{ a = 1, b.c = 2 }` — one line, no trailing comma (TOML 1.0). Closed on return:
    /// nothing later in the document can add to it.
    mutating func parseInlineTable(_ r: inout AssayReader, _ sink: inout IssueSink) -> TOML.Node? {
        guard r.enterContainer(&sink) else { return nil }
        defer { r.leaveContainer() }
        r.advance(by: 1)
        let table = newTable(.header)
        skipSpace(&r)
        if r.currentByte == UInt8(ascii: "}") { r.advance(by: 1); return .table([]) }
        while true {
            skipSpace(&r)
            guard parseKeyValue(&r, &sink, into: table) else { return nil }
            skipSpace(&r)
            if r.currentByte == UInt8(ascii: ",") { r.advance(by: 1); continue }
            if r.currentByte == UInt8(ascii: "}") { r.advance(by: 1); return finish(table) }
            r.report(&sink, .tomlUnterminatedInlineTable)
            return nil
        }
    }

    // MARK: Strings

    /// `"…"` or `"""…"""`. The cursor is on the opening quote.
    mutating func scanBasicString(
        _ r: inout AssayReader, _ sink: inout IssueSink, multiline: Bool
    ) -> String? {
        r.advance(by: multiline ? 3 : 1)
        if multiline { _ = consumeNewline(&r) }

        // THE WHOLE-LITERAL FAST PATH, for a single-line basic string with no escape in it
        // — which is very nearly every basic string anyone writes. It reaches the closing
        // quote without building the `[UInt8]` at all: one sized `String` copy out of the
        // source, the same shape `AssayReader.scanString` uses for JSON. The loop below
        // appended one byte at a time and then copied the accumulator into a `String`, so
        // this replaces two passes and an intermediate allocation with one pass.
        if !multiline {
            let start = r.byteOffset
            var k = 0
            while let b = r.byte(at: k) {
                if b == 0x22 {
                    let text = r.string(from: start, to: start + k)
                    r.advance(by: k + 1)
                    return text
                }
                // Anything that needs transforming or rejecting ends the fast path and
                // hands the whole literal back to the general loop, which starts over from
                // `start`. Re-scanning a literal that has an escape in it is cheaper than
                // carrying a partial accumulator across the two paths.
                if b == 0x5C || b == 0x0A || b == 0x0D || b == 0x7F
                    || (b < 0x20 && b != 0x09)
                {
                    break
                }
                k += 1
            }
        }

        var out: [UInt8] = []
        while true {
            guard let c = r.currentByte else {
                r.report(&sink, .tomlUnterminatedString)
                return nil
            }
            if c == UInt8(ascii: "\"") {
                if !multiline { r.advance(by: 1); return String(decoding: out, as: UTF8.self) }
                var n = 0
                while r.byte(at: n) == UInt8(ascii: "\"") { n += 1 }
                if n >= 3 {
                    // One or two quotes may sit just inside the closing delimiter.
                    guard n <= 5 else {
                        r.advance(by: n)
                        r.report(&sink, .tomlExpectedNewline)
                        return nil
                    }
                    for _ in 0..<(n - 3) { out.append(UInt8(ascii: "\"")) }
                    r.advance(by: n)
                    return String(decoding: out, as: UTF8.self)
                }
                for _ in 0..<n { out.append(UInt8(ascii: "\"")) }
                r.advance(by: n)
                continue
            }
            if c == UInt8(ascii: "\\") {
                guard scanEscape(&r, &sink, into: &out, multiline: multiline) else { return nil }
                continue
            }
            if c == 0x0A || c == 0x0D {
                guard multiline else {
                    r.report(&sink, .tomlUnterminatedString)
                    return nil
                }
                // CRLF becomes LF: the specification lets a parser normalise newlines
                // and toml++ and BurntSushi/toml both do, so a file edited on Windows
                // yields the same strings everywhere. A bare CR is not a newline.
                if c == 0x0D {
                    guard r.byte(at: 1) == 0x0A else {
                        r.report(&sink, .tomlControlCharacter)
                        return nil
                    }
                    r.advance(by: 1)
                }
                out.append(0x0A)
                r.advance(by: 1)
                continue
            }
            if c < 0x20 && c != 0x09 || c == 0x7F {
                r.report(&sink, .tomlControlCharacter)
                return nil
            }
            // A RUN of ordinary bytes in one copy rather than one append per byte. `c` is
            // already known ordinary here — every other case returned or continued above —
            // so this consumes at least one byte and cannot spin.
            let runStart = r.byteOffset
            var k = 0
            while let b = r.byte(at: k), b != 0x22, b != 0x5C, b != 0x0A, b != 0x0D,
                b != 0x7F, !(b < 0x20 && b != 0x09)
            { k += 1 }
            r.advance(by: k)
            r.appendBytes(from: runStart, to: r.byteOffset, into: &out)
        }
    }

    /// One escape, cursor on the backslash. Appends the bytes it denotes.
    func scanEscape(
        _ r: inout AssayReader, _ sink: inout IssueSink, into out: inout [UInt8], multiline: Bool
    ) -> Bool {
        let at = r.byteOffset
        r.advance(by: 1)
        guard let e = r.currentByte else {
            r.report(&sink, .tomlUnterminatedString)
            return false
        }
        switch e {
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "\""): out.append(0x22)
        case UInt8(ascii: "\\"): out.append(0x5C)
        case UInt8(ascii: "u"), UInt8(ascii: "U"):
            let digits = e == UInt8(ascii: "u") ? 4 : 8
            r.advance(by: 1)
            var value: UInt32 = 0
            for _ in 0..<digits {
                guard let h = r.currentByte, let d = hexValue(h) else {
                    r.report(
                        &sink, .tomlBadEscape, span: SourceSpan(lo: at, len: r.byteOffset - at))
                    return false
                }
                value = value &* 16 &+ UInt32(d)
                r.advance(by: 1)
            }
            // Surrogates and values past U+10FFFF are not scalars; `Unicode.Scalar` is
            // the arbiter.
            guard let scalar = Unicode.Scalar(value) else {
                r.report(&sink, .tomlBadEscape, span: SourceSpan(lo: at, len: r.byteOffset - at))
                return false
            }
            out.append(contentsOf: Array(String(scalar).utf8))
            return true
        case 0x20, 0x09, 0x0A, 0x0D:
            // A line-ending backslash: trims all whitespace and newlines that follow.
            // Only whitespace may sit between the backslash and the newline, and only
            // a multi-line string has one.
            guard multiline else {
                r.report(&sink, .tomlBadEscape, span: SourceSpan(lo: at, len: 2))
                return false
            }
            var i = 0
            while r.byte(at: i) == 0x20 || r.byte(at: i) == 0x09 { i += 1 }
            guard r.byte(at: i) == 0x0A || (r.byte(at: i) == 0x0D && r.byte(at: i + 1) == 0x0A)
            else {
                r.report(&sink, .tomlBadEscape, span: SourceSpan(lo: at, len: 2))
                return false
            }
            r.advance(by: i)
            while let c = r.currentByte, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                if c == 0x0D, r.byte(at: 1) != 0x0A { break }
                r.advance(by: 1)
            }
            return true
        default:
            r.report(&sink, .tomlBadEscape, span: SourceSpan(lo: at, len: 2))
            return false
        }
        r.advance(by: 1)
        return true
    }

    func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    /// `'…'` or `'''…'''`. No escapes; what you see is what you get.
    mutating func scanLiteralString(
        _ r: inout AssayReader, _ sink: inout IssueSink, multiline: Bool
    ) -> String? {
        r.advance(by: multiline ? 3 : 1)
        if multiline { _ = consumeNewline(&r) }
        let start = r.byteOffset
        var out: [UInt8] = []
        while true {
            guard let c = r.currentByte else {
                r.report(&sink, .tomlUnterminatedString)
                return nil
            }
            if c == UInt8(ascii: "'") {
                if !multiline {
                    // One copy: the single-line form has nothing to normalise.
                    let s = r.string(from: start, to: r.byteOffset)
                    r.advance(by: 1)
                    return s
                }
                var n = 0
                while r.byte(at: n) == UInt8(ascii: "'") { n += 1 }
                if n >= 3 {
                    guard n <= 5 else {
                        r.advance(by: n)
                        r.report(&sink, .tomlExpectedNewline)
                        return nil
                    }
                    for _ in 0..<(n - 3) { out.append(UInt8(ascii: "'")) }
                    r.advance(by: n)
                    return String(decoding: out, as: UTF8.self)
                }
                for _ in 0..<n { out.append(UInt8(ascii: "'")) }
                r.advance(by: n)
                continue
            }
            if c == 0x0A || c == 0x0D {
                guard multiline else {
                    r.report(&sink, .tomlUnterminatedString)
                    return nil
                }
                // CRLF → LF, as in the basic form above.
                if c == 0x0D {
                    guard r.byte(at: 1) == 0x0A else {
                        r.report(&sink, .tomlControlCharacter)
                        return nil
                    }
                    r.advance(by: 1)
                }
                out.append(0x0A)
                r.advance(by: 1)
                continue
            }
            if c < 0x20 && c != 0x09 || c == 0x7F {
                r.report(&sink, .tomlControlCharacter)
                return nil
            }
            out.append(c)
            r.advance(by: 1)
        }
    }

    // MARK: Numbers

    /// An integer or a float, with the sign, `inf`/`nan`, prefixed bases and underscores.
    mutating func scanNumber(_ r: inout AssayReader, _ sink: inout IssueSink) -> TOML.Node? {
        let start = r.byteOffset
        guard let node = scanNumberBody(&r, &sink, start: start) else { return nil }
        // `+0x1`, `1x`, `infinity`: a number followed by more word is a bad number, not a
        // good number with something after it.
        if let c = r.currentByte, isBareKeyByte(c) {
            r.report(
                &sink, .tomlBadNumber, span: SourceSpan(lo: start, len: r.byteOffset - start + 1))
            return nil
        }
        return node
    }

    mutating func scanNumberBody(
        _ r: inout AssayReader, _ sink: inout IssueSink, start: Int
    ) -> TOML.Node? {
        var negative = false
        var signed = false
        if let c = r.currentByte, c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
            signed = true
            negative = c == UInt8(ascii: "-")
            r.advance(by: 1)
        }
        if r.consume("inf") { return .double(negative ? -.infinity : .infinity) }
        if r.consume("nan") { return .double(.nan) }

        if !signed, r.currentByte == UInt8(ascii: "0"), let p = r.byte(at: 1),
            p == UInt8(ascii: "x") || p == UInt8(ascii: "o") || p == UInt8(ascii: "b")
        {
            r.advance(by: 2)
            let radix: Int64 = p == UInt8(ascii: "x") ? 16 : (p == UInt8(ascii: "o") ? 8 : 2)
            return scanPrefixedInteger(&r, &sink, radix: radix, start: start)
        }

        // Decimal. THE FAST PATH FIRST: a literal with no `_` in it needs no accumulator at
        // all, and that is very nearly every number anyone writes.
        //
        // THE SAFETY PROPERTY, which is what makes this worth doing at all: the fast path
        // may only ever DECLINE, never accept something the general path would reject. It
        // reports nothing into the sink and returns nil on anything it is not certain of —
        // an underscore, an overflow, a leading zero, a missing digit — and the general
        // path below then re-derives the same input and produces the same diagnostic. So
        // the two paths cannot disagree about what is valid; the worst a mistake here can
        // cost is a rewind.
        let digitsStart = r.byteOffset
        if let fast = scanDecimalFast(&r, tokenStart: start, negative: negative) {
            return fast
        }
        r.seek(to: digitsStart)

        // The general path, unchanged: it owns every diagnostic and every `_`.
        var text: [UInt8] = []
        if negative { text.append(UInt8(ascii: "-")) }
        let intStart = text.count
        guard scanDigits(&r, &sink, into: &text, radix: 10, start: start) else { return nil }
        if text.count - intStart > 1, text[intStart] == UInt8(ascii: "0") {
            r.report(&sink, .tomlBadNumber, span: SourceSpan(lo: start, len: r.byteOffset - start))
            return nil
        }
        var isFloat = false
        if r.currentByte == UInt8(ascii: ".") {
            isFloat = true
            text.append(UInt8(ascii: "."))
            r.advance(by: 1)
            guard scanDigits(&r, &sink, into: &text, radix: 10, start: start) else { return nil }
        }
        if let e = r.currentByte, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            isFloat = true
            text.append(UInt8(ascii: "e"))
            r.advance(by: 1)
            if let s = r.currentByte, s == UInt8(ascii: "+") || s == UInt8(ascii: "-") {
                text.append(s)
                r.advance(by: 1)
            }
            guard scanDigits(&r, &sink, into: &text, radix: 10, start: start) else { return nil }
        }
        if isFloat {
            // The grammar has been checked above; the stdlib's conversion is correctly
            // rounded, which is more than a hand-rolled one would be.
            guard let d = Double(String(decoding: text, as: UTF8.self)) else {
                r.report(
                    &sink, .tomlBadNumber, span: SourceSpan(lo: start, len: r.byteOffset - start))
                return nil
            }
            // OUT OF RANGE IS NOT A VALUE — the same verdict the JSON path reaches in
            // `slowDouble`, and reached here for the same reason: a struct must not mean
            // different things depending on which format its bytes came from. `1e309` is
            // `+infinity` and `1e-400` is zero, and neither is what the file says.
            // toml++ rejects both; so does Foundation's JSONDecoder.
            //
            // Underflow is only underflow when the significand was non-zero: `0.0e-400` is
            // zero because it is zero.
            // The significand ONLY. `text` holds the exponent too — the general path
            // appends a lower-case `e` and the exponent digits — so scanning all of it made
            // `0.0e-400` look significant because of the `4`, and rejected a literal that
            // is honestly zero.
            let significandEnd = text.firstIndex(of: UInt8(ascii: "e")) ?? text.endIndex
            let underflowed =
                d == 0
                && text[..<significandEnd].contains { $0 >= 0x31 && $0 <= 0x39 }
            if !d.isFinite || underflowed {
                r.report(
                    &sink, .numberOverflow,
                    span: SourceSpan(lo: start, len: r.byteOffset - start))
                return nil
            }
            return .double(d)
        }
        var value: Int64 = 0
        for b in text[intStart...] {
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let digit = Int64(b - 0x30)
            let (a, o2) =
                negative ? m.subtractingReportingOverflow(digit) : m.addingReportingOverflow(digit)
            guard !o1, !o2 else {
                r.report(
                    &sink, .numberOverflow, span: SourceSpan(lo: start, len: r.byteOffset - start))
                return nil
            }
            value = a
        }
        return .int(value)
    }

    /// A decimal literal with no digit separator, decided and returned without building an
    /// accumulator. Returns nil to DECLINE — see `scanNumberBody` for why declining is the
    /// only failure mode this function has.
    ///
    /// The cursor is left wherever it got to; the caller rewinds on nil.
    ///
    /// Integers accumulate straight into `Int64` as the digits are read. Floats are handed
    /// to the stdlib as the source text itself — `r.string(from:to:)` over the literal,
    /// which is exactly the bytes the general path would have copied one at a time into
    /// `text`, including a leading `+` and an upper-case `E`, both of which `Double.init`
    /// accepts. Correct rounding stays the stdlib's job on either path.
    mutating func scanDecimalFast(
        _ r: inout AssayReader, tokenStart: Int, negative: Bool
    ) -> TOML.Node? {
        // Integer part.
        var value: Int64 = 0
        var digits = 0
        while let c = r.currentByte, c >= 0x30, c <= 0x39 {
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let d = Int64(c - 0x30)
            let (a, o2) =
                negative
                ? m.subtractingReportingOverflow(d)
                : m.addingReportingOverflow(d)
            guard !o1, !o2 else { return nil }  // overflow: the general path reports
            value = a
            digits += 1
            r.advance(by: 1)
        }
        guard digits > 0 else { return nil }  // no digits, or a `_` led
        // `01` is not a TOML integer; `0` alone is. Same test the general path makes.
        if digits > 1, r.byte(at: -digits) == UInt8(ascii: "0") { return nil }
        // A separator anywhere means the accumulated value is not the literal's value.
        if r.currentByte == UInt8(ascii: "_") { return nil }

        var isFloat = false
        if r.currentByte == UInt8(ascii: ".") {
            isFloat = true
            r.advance(by: 1)
            var frac = 0
            while let c = r.currentByte, c >= 0x30, c <= 0x39 { frac += 1; r.advance(by: 1) }
            guard frac > 0 else { return nil }
            if r.currentByte == UInt8(ascii: "_") { return nil }
        }
        if let e = r.currentByte, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            isFloat = true
            r.advance(by: 1)
            if let sgn = r.currentByte, sgn == UInt8(ascii: "+") || sgn == UInt8(ascii: "-") {
                r.advance(by: 1)
            }
            var exp = 0
            while let c = r.currentByte, c >= 0x30, c <= 0x39 { exp += 1; r.advance(by: 1) }
            guard exp > 0 else { return nil }
            if r.currentByte == UInt8(ascii: "_") { return nil }
        }

        if isFloat {
            // FROM `tokenStart`, NOT FROM THE FIRST DIGIT: the sign was consumed before
            // this was called, and slicing after it turns `-1.5` into `1.5`. The integer
            // arm does not care — it applies `negative` as it accumulates — which is
            // exactly the sort of asymmetry that makes a fast path wrong in one arm only.
            // DECLINE ON ZERO AS WELL AS ON NON-FINITE. A zero result is either a literal
            // that is genuinely zero or one that underflowed, and telling those apart means
            // inspecting the significand — which the general path already does. Handing it
            // over keeps the "may only decline" property intact and costs a rewind on a
            // float literal that is exactly zero, which is rare.
            guard let d = Double(r.string(from: tokenStart, to: r.byteOffset)),
                d.isFinite, d != 0
            else { return nil }
            return .double(d)
        }
        return .int(value)
    }

    /// `0xDEAD_BEEF`, `0o755`, `0b1101` — after the prefix.
    func scanPrefixedInteger(
        _ r: inout AssayReader, _ sink: inout IssueSink, radix: Int64, start: Int
    ) -> TOML.Node? {
        var text: [UInt8] = []
        guard scanDigits(&r, &sink, into: &text, radix: Int(radix), start: start) else {
            return nil
        }
        var value: Int64 = 0
        for b in text {
            let digit = Int64(hexValue(b) ?? 0)
            let (m, o1) = value.multipliedReportingOverflow(by: radix)
            let (a, o2) = m.addingReportingOverflow(digit)
            guard !o1, !o2 else {
                r.report(
                    &sink, .numberOverflow, span: SourceSpan(lo: start, len: r.byteOffset - start))
                return nil
            }
            value = a
        }
        return .int(value)
    }

    /// One or more digits of `radix`, with underscores allowed only between two digits.
    func scanDigits(
        _ r: inout AssayReader, _ sink: inout IssueSink, into out: inout [UInt8], radix: Int,
        start: Int
    ) -> Bool {
        var count = 0
        while let c = r.currentByte {
            if let d = hexValue(c), Int(d) < radix {
                out.append(c)
                count += 1
                r.advance(by: 1)
            } else if c == UInt8(ascii: "_") {
                // Only between two digits: `1_000` yes, `1_`, `_1` and `1__0` no.
                guard count > 0, let n = r.byte(at: 1), let d = hexValue(n), Int(d) < radix else {
                    r.report(
                        &sink, .tomlBadNumber,
                        span: SourceSpan(lo: start, len: max(1, r.byteOffset - start + 1)))
                    return false
                }
                r.advance(by: 1)
            } else {
                break
            }
        }
        guard count > 0 else {
            r.report(
                &sink, .tomlBadNumber,
                span: SourceSpan(lo: start, len: max(1, r.byteOffset - start)))
            return false
        }
        return true
    }

    // MARK: Date-times

    /// A date, and if a time follows it, a local or offset date-time. Cursor on the first
    /// digit; the caller has seen `DDDD-`.
    mutating func scanDateTime(_ r: inout AssayReader, _ sink: inout IssueSink) -> TOML.Node? {
        let start = r.byteOffset
        func fail() -> TOML.Node? {
            r.report(
                &sink, .tomlBadDateTime,
                span: SourceSpan(lo: start, len: max(1, r.byteOffset - start)))
            return nil
        }
        guard let year = fixedDigits(&r, 4), r.currentByte == UInt8(ascii: "-") else {
            return fail()
        }
        r.advance(by: 1)
        guard let month = fixedDigits(&r, 2), r.currentByte == UInt8(ascii: "-") else {
            return fail()
        }
        r.advance(by: 1)
        guard let day = fixedDigits(&r, 2) else { return fail() }
        guard month >= 1, month <= 12, day >= 1, day <= daysIn(month: month, year: year) else {
            return fail()
        }
        var text = r.string(from: start, to: r.byteOffset)

        // `T`, `t`, or a space that is followed by a digit, introduces the time.
        let sep = r.currentByte
        let hasTime =
            sep == UInt8(ascii: "T") || sep == UInt8(ascii: "t")
            || (sep == 0x20 && isDigit(r.byte(at: 1)))
        guard hasTime else { return .dateTime(.localDate(text)) }
        r.advance(by: 1)
        guard let time = scanTime(&r) else { return fail() }
        text += "T" + time

        if let z = r.currentByte, z == UInt8(ascii: "Z") || z == UInt8(ascii: "z") {
            r.advance(by: 1)
            return .dateTime(.offsetDateTime(text + "Z"))
        }
        if let s = r.currentByte, s == UInt8(ascii: "+") || s == UInt8(ascii: "-") {
            let offsetStart = r.byteOffset
            r.advance(by: 1)
            guard let oh = fixedDigits(&r, 2), r.currentByte == UInt8(ascii: ":") else {
                return fail()
            }
            r.advance(by: 1)
            guard let om = fixedDigits(&r, 2), oh <= 23, om <= 59 else { return fail() }
            text += r.string(from: offsetStart, to: r.byteOffset)
            return .dateTime(.offsetDateTime(text))
        }
        return .dateTime(.localDateTime(text))
    }

    /// `07:32:00`, `00:32:00.999999`. Cursor on the first digit.
    mutating func scanLocalTime(_ r: inout AssayReader, _ sink: inout IssueSink) -> TOML.Node? {
        let start = r.byteOffset
        guard let time = scanTime(&r) else {
            r.report(
                &sink, .tomlBadDateTime,
                span: SourceSpan(lo: start, len: max(1, r.byteOffset - start)))
            return nil
        }
        return .dateTime(.localTime(time))
    }

    /// `HH:MM:SS` with an optional fraction, range-checked. Seconds are required in TOML
    /// 1.0; a leap second (`:60`) is allowed, as RFC 3339 allows it.
    func scanTime(_ r: inout AssayReader) -> String? {
        let start = r.byteOffset
        guard let h = fixedDigits(&r, 2), r.currentByte == UInt8(ascii: ":") else { return nil }
        r.advance(by: 1)
        guard let m = fixedDigits(&r, 2), r.currentByte == UInt8(ascii: ":") else { return nil }
        r.advance(by: 1)
        guard let s = fixedDigits(&r, 2) else { return nil }
        guard h <= 23, m <= 59, s <= 60 else { return nil }
        if r.currentByte == UInt8(ascii: ".") {
            r.advance(by: 1)
            var n = 0
            while isDigit(r.currentByte) { r.advance(by: 1); n += 1 }
            guard n > 0 else { return nil }
        }
        return r.string(from: start, to: r.byteOffset)
    }

    /// Exactly `n` ASCII digits, as an integer.
    func fixedDigits(_ r: inout AssayReader, _ n: Int) -> Int? {
        var v = 0
        for _ in 0..<n {
            guard let c = r.currentByte, c >= 0x30, c <= 0x39 else { return nil }
            v = v * 10 + Int(c - 0x30)
            r.advance(by: 1)
        }
        return v
    }

    func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
