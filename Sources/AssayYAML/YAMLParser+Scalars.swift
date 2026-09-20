// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Scalars: plain (with continuation lines), single- and double-quoted (with escapes), and
// the `|` / `>` block scalars with their chomping indicators.
//===----------------------------------------------------------------------===//

import AssayCore

extension YAML.Parser {

    // MARK: Scalars

    /// A plain scalar in block context, INCLUDING its continuation lines.
    ///
    /// ```yaml
    /// description: this is a long
    ///   description that wraps
    /// ```
    ///
    /// YAML 1.2 §7.3.3. A plain scalar continues onto any following line indented more
    /// than the block it belongs to; a single line break folds to one space, and each
    /// additional blank line becomes a newline. Refusing this — which is what the
    /// parser did, with a `trailingContent` error — rejects ordinary hand-written
    /// config, and it is the sort of refusal that reads as a bug in the file rather
    /// than in the parser.
    ///
    /// A continuation stops at anything that opens a new construct. `indent` is the
    /// owning block's column, so a line at or left of it belongs to the parent; and a
    /// more-indented line that carries `: ` or opens with `- ` is a mapping or sequence
    /// rather than more text. YAML calls that last case an error outright; stopping
    /// here hands it to the caller, which reports against the real structure.
    mutating func parseFlowScalar(
        _ r: inout AssayReader, _ sink: inout IssueSink, indent: Int = Int.max
    ) -> B.Value? {
        if let q = r.currentByte, q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
            return parseQuoted(&r, &sink)
        }
        let start = r.byteOffset
        var end = start
        scanPlainLine(&r, end: &end)
        var content = r.string(from: start, to: end)

        // `Int.max` is the flow-context caller, where multi-line plain scalars are out
        // of scope (see this file's header) — no line can be indented past it.
        var pendingBreaks = 0
        while indent != Int.max, let more = plainContinuation(&r, indent: indent,
                                                             breaks: &pendingBreaks) {
            content += pendingBreaks > 0
                ? String(repeating: "\n", count: pendingBreaks)
                : " "
            content += more
            pendingBreaks = 0
        }
        return B.scalar(content, style: .plain, tag: nil)
    }

    /// One line of a plain scalar, stopping at the newline or an unquoted `#` comment.
    /// `end` is left at the last non-blank byte, so trailing spaces are not content.
    mutating func scanPlainLine(_ r: inout AssayReader, end: inout Int) {
        while let c = r.currentByte {
            if c == 0x0A || c == 0x0D { break }
            if c == UInt8(ascii: "#"), let p = r.byte(at: -1), p == 0x20 || p == 0x09 {
                break
            }
            r.advanceBy(1)
            if c != 0x20 && c != 0x09 { end = r.byteOffset }
        }
    }

    /// The next continuation line's text, or nil if the scalar ends here.
    ///
    /// Restores the cursor exactly when it returns nil, so a caller that stops mid-scan
    /// leaves the following construct untouched for whoever parses it next.
    mutating func plainContinuation(
        _ r: inout AssayReader, indent: Int, breaks: inout Int
    ) -> String? {
        let mark = r.byteOffset
        var blankLines = 0

        while true {
            guard let c = r.currentByte, c == 0x0A || c == 0x0D else {
                r.seek(to: mark); return nil
            }
            r.advanceBy(1)
            if c == 0x0D, r.currentByte == 0x0A { r.advanceBy(1) }

            let lineStart = r.byteOffset
            var column = 0
            while let b = r.currentByte, b == 0x20 || b == 0x09 {
                r.advanceBy(1); column += 1
            }
            guard let first = r.currentByte else { r.seek(to: mark); return nil }

            // A blank line does not end the scalar; it becomes a fold break.
            if first == 0x0A || first == 0x0D { blankLines += 1; continue }

            // Anything at or left of the owning block belongs to the parent.
            if column <= indent { r.seek(to: mark); return nil }
            if first == UInt8(ascii: "#") { r.seek(to: mark); return nil }

            // `-` is NOT a stopper here, which is the counter-intuitive part. YAML 1.2
            // §7.3.3 builds a continuation line from `ns-plain-char`, not from
            // `ns-plain-first`, so the indicator restrictions that apply to a scalar's
            // FIRST character do not apply to its later lines. libyaml agrees:
            // `a: one\n  - x` is the single scalar "one - x", not a nested sequence.
            // Guarding against `-` here produced a rejection libyaml does not make,
            // which the differential caught.
            if first == UInt8(ascii: "?") || first == UInt8(ascii: "&")
                || first == UInt8(ascii: "*") {
                r.seek(to: mark); return nil
            }

            var end = r.byteOffset
            let textStart = r.byteOffset
            scanPlainLine(&r, end: &end)

            // A `: ` on the line makes it a mapping entry, and YAML forbids that
            // inside a plain scalar. Stopping hands the line back to the caller, which
            // reports it against the real structure — libyaml instead yields a document
            // stream with nothing in it, which is a worse answer to give a user.
            var i = textStart
            while i < end {
                if r.byte(absolute: i) == UInt8(ascii: ":"),
                   i + 1 >= end || r.byte(absolute: i + 1) == 0x20 {
                    r.seek(to: mark); return nil
                }
                i += 1
            }
            guard end > textStart else { r.seek(to: mark); return nil }

            _ = lineStart
            breaks = blankLines
            return r.string(from: textStart, to: end)
        }
    }

    mutating func parseQuoted(
        _ r: inout AssayReader, _ sink: inout IssueSink
    ) -> B.Value? {
        let quote = r.currentByte!
        let double = quote == UInt8(ascii: "\"")
        r.advanceBy(1)

        let start = r.byteOffset
        var needsUnescape = false
        while let c = r.currentByte {
            if c == quote {
                if !double, r.byte(at: 1) == quote {          // '' is a literal '
                    needsUnescape = true
                    r.advanceBy(2)
                    continue
                }
                break
            }
            if double, c == UInt8(ascii: "\\") {
                needsUnescape = true
                r.advanceBy(2)
                continue
            }
            r.advanceBy(1)
        }
        guard r.currentByte == quote else {
            r.report(&sink, .yamlUnterminatedQuotedScalar)
            return nil
        }
        let raw = r.string(from: start, to: r.byteOffset)
        r.advanceBy(1)

        let content: String
        if !needsUnescape {
            content = raw                                    // fast path: one copy
        } else if double {
            guard let u = unescapeDouble(raw, &r, &sink) else { return nil }
            content = u
        } else {
            content = raw.replacingOccurrencesOfDoubledQuote()
        }
        return B.scalar(content, style: double ? .doubleQuoted : .singleQuoted, tag: nil)
    }

    func unescapeDouble(
        _ raw: String, _ r: inout AssayReader, _ sink: inout IssueSink
    ) -> String? {
        var out = ""
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c != "\\" { out.append(c); i = raw.index(after: i); continue }
            i = raw.index(after: i)
            guard i < raw.endIndex else { break }
            let e = raw[i]
            i = raw.index(after: i)
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            case "e": out.append("\u{1B}")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "/": out.append("/")
            case " ": out.append(" ")
            case "x", "u", "U":
                let width = e == "x" ? 2 : (e == "u" ? 4 : 8)
                var hex = ""
                var n = 0
                while n < width, i < raw.endIndex {
                    hex.append(raw[i]); i = raw.index(after: i); n += 1
                }
                guard let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) else {
                    r.report(&sink, .yamlBadEscape)
                    return nil
                }
                out.unicodeScalars.append(s)
            default:
                r.report(&sink, .yamlBadEscape)
                return nil
            }
        }
        return out
    }

    /// Literal `|` and folded `>` block scalars, with chomping (`-` strip, `+` keep)
    /// and an optional explicit indentation indicator.
    mutating func parseBlockScalar(
        _ r: inout AssayReader, _ sink: inout IssueSink, indent: Int
    ) -> B.Value? {
        let folded = r.currentByte == UInt8(ascii: ">")
        r.advanceBy(1)

        var chomp: Character = "c"                    // c=clip, s=strip, k=keep
        var explicitIndent = 0
        while let c = r.currentByte, c != 0x0A, c != 0x0D {
            if c == UInt8(ascii: "-") { chomp = "s" }
            else if c == UInt8(ascii: "+") { chomp = "k" }
            else if c >= 0x31 && c <= 0x39 { explicitIndent = Int(c - 0x30) }
            r.advanceBy(1)
        }
        skipLine(&r)

        var lines: [String] = []
        var blockIndent = explicitIndent > 0 ? indent + explicitIndent : -1

        while !r.atEnd {
            let lineStart = r.byteOffset
            var column = 0
            while let c = r.currentByte, c == 0x20 { r.advanceBy(1); column += 1 }

            // A blank line belongs to the block regardless of its indentation.
            if r.currentByte == 0x0A || r.currentByte == nil {
                lines.append("")
                skipLine(&r)
                continue
            }
            if blockIndent < 0 { blockIndent = column }
            if column < blockIndent {
                r.seek(to: lineStart)
                break
            }
            r.seek(to: lineStart + blockIndent)
            let textStart = r.byteOffset
            while let c = r.currentByte, c != 0x0A, c != 0x0D { r.advanceBy(1) }
            lines.append(r.string(from: textStart, to: r.byteOffset))
            skipLine(&r)
        }

        // Chomping applies to the trailing newlines only.
        while let last = lines.last, last.isEmpty { lines.removeLast() }

        var content: String
        if folded {
            // Folded: a single newline between non-empty lines becomes a space; a
            // blank line becomes a newline; a more-indented line keeps its break.
            var parts: [String] = []
            var current = ""
            for line in lines {
                if line.isEmpty {
                    parts.append(current); current = ""
                } else if line.first == " " || line.first == "\t" {
                    if !current.isEmpty { parts.append(current); current = "" }
                    parts.append(line)
                } else if current.isEmpty {
                    current = line
                } else {
                    current += " " + line
                }
            }
            if !current.isEmpty { parts.append(current) }
            content = parts.joined(separator: "\n")
        } else {
            content = lines.joined(separator: "\n")
        }

        switch chomp {
        case "s": break                                    // strip: no trailing newline
        case "k": content += "\n\n"                         // keep (approximate)
        default: if !content.isEmpty { content += "\n" }    // clip: exactly one
        }

        return B.scalar(content, style: folded ? .folded : .literal, tag: nil)
    }
}

extension String {
    /// `''` inside a single-quoted scalar is a literal `'`.
    func replacingOccurrencesOfDoubledQuote() -> String {
        var out = ""
        out.reserveCapacity(count)
        var i = startIndex
        while i < endIndex {
            let c = self[i]
            out.append(c)
            i = index(after: i)
            if c == "'", i < endIndex, self[i] == "'" { i = index(after: i) }
        }
        return out
    }
}
