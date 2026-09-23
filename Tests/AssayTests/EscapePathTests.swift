// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay

//===----------------------------------------------------------------------===//
// The string escape path, on both sides of its stack/heap boundary.
//
// Since 2026-09-19 `scanStringSlow` sizes its buffer by the string (the distance to the
// closing quote, an exact upper bound because every escape shrinks) instead of reserving the
// rest of the document. At or under 1,024 source bytes it unescapes on the stack; above, it
// writes straight into the String's storage. Two paths means two places to be wrong, so
// every case runs at lengths straddling the boundary, with output of every UTF-8 width.
//===----------------------------------------------------------------------===//

@Schema struct EscapedValue: Equatable { var s: String }

@Suite("String escapes — stack and heap paths")
struct EscapePathTests {

    /// JSON-escape `s` the long way: every quote, backslash and control character escaped,
    /// and every non-ASCII scalar as `\uXXXX`, with a surrogate pair above U+FFFF, so the
    /// decoder has to rebuild 2-, 3- and 4-byte UTF-8 from 6- and 12-byte escapes.
    static func escaped(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if u.value < 0x80 { out.unicodeScalars.append(u); continue }
                func hex(_ v: UInt32) -> String {
                    let h = String(v, radix: 16)
                    return "\\u" + String(repeating: "0", count: 4 - h.count) + h
                }
                if u.value > 0xFFFF {
                    let v = u.value - 0x10000
                    out += hex(0xD800 + (v >> 10)) + hex(0xDC00 + (v & 0x3FF))
                } else {
                    out += hex(u.value)
                }
            }
        }
        return out
    }

    /// A string whose ESCAPED form is about `sourceLength` bytes, cycling through every
    /// escape kind and UTF-8 width.
    static func sample(sourceLength: Int) -> String {
        let pieces = ["a", "\n", "\"", "\\", "\t", "é", "€", "😀", "plain"]
        var s = "", i = 0, n = 0
        while n < sourceLength {
            let p = pieces[i % pieces.count]
            s += p; n += escaped(p).utf8.count; i += 1
        }
        return s
    }

    @Test(
        "round trip at lengths straddling the 1,024-byte boundary",
        arguments: [1, 15, 16, 200, 1_000, 1_020, 1_024, 1_025, 1_030, 3_000, 70_000])
    func roundTrip(_ length: Int) throws {
        let original = Self.sample(sourceLength: length)
        let json = "{\"s\":\"" + Self.escaped(original) + "\"}"
        #expect(try EscapedValue.parse(json: json).s == original)
    }

    @Test(
        "an invalid escape is reported on the heap path as on the stack path",
        arguments: [10, 3_000])
    func invalidEscape(_ padding: Int) {
        let pad = String(repeating: "x", count: padding)
        for bad in ["\\q", "\\ud800", "\\u12"] {
            let d = EscapedValue.diagnose(json: "{\"s\":\"\\n" + pad + bad + pad + "\"}")
            #expect(d.value == nil)
            #expect(
                d.issues.map(\.code.codeString).contains("invalid_escape"),
                "\(bad) at padding \(padding): \(d.issues.map(\.code.codeString))")
        }
    }

    @Test(
        "an unterminated escaped string fails, whichever path it would have taken",
        arguments: [10, 3_000])
    func unterminated(_ padding: Int) {
        let d = EscapedValue.diagnose(json: "{\"s\":\"\\n" + String(repeating: "x", count: padding))
        #expect(d.value == nil)
        #expect(!d.issues.isEmpty)
    }
}
