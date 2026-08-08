// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Rendering a `RawValue` as block-style YAML. docs/ENCODING.md.
//
// Encoding runs the decode pipeline backwards: the schema builds a `RawValue`, and this
// file turns it into bytes. The macro never learns about YAML, which is why adding this
// format needed no macro change.
//
// THE ENTIRE DIFFICULTY IS QUOTING, and it is the Norway problem arriving from the other
// side. On the way in, Assay refuses to resolve `NO` as a boolean — a plain scalar keeps
// its text until someone asks a typed question, which is what sidesteps the bug instead
// of inheriting it. On the way OUT that guarantee has to be paid for: a `RawValue.string`
// holding "123", "true", "no", "~" or "" MUST be emitted quoted, because a bare `123` in
// the document is an integer to every YAML reader alive, including Assay's own.
//
// So the rule here is inverted from a pretty-printer's: plain style is used only when the
// text provably cannot be read as anything else, and everything uncertain is quoted. The
// round-trip law in docs/ENCODING.md §5 is what checks it, over the whole corpus.
//
// Block style, not flow, because the output is meant to be read by people — that is the
// only reason to choose YAML over JSON. Empty collections are the one exception: `{}` and
// `[]` have no block spelling.
//===----------------------------------------------------------------------===//

public import AssayCore

extension YAML {

    /// Render a `RawValue` as a YAML document, newline-terminated.
    public static func encode(_ value: RawValue) -> [UInt8] {
        var out = ""
        write(value, into: &out, indent: 0, atLineStart: true)
        if !out.hasSuffix("\n") { out += "\n" }
        return Array(out.utf8)
    }

    /// `atLineStart` distinguishes "this value begins its own line" (a document root, or
    /// a nested collection under a key) from "this value follows `key: ` on a line already
    /// in progress" — which is the whole of block-style layout.
    static func write(
        _ v: RawValue, into out: inout String, indent: Int, atLineStart: Bool
    ) {
        let pad = String(repeating: "  ", count: indent)
        switch v {
        case .null, .bool, .int, .double, .string:
            out += scalar(v)

        case .sequence(let items):
            if items.isEmpty { out += "[]"; return }
            for (i, item) in items.enumerated() {
                if i > 0 || !atLineStart { out += "\n" }
                out += "\(pad)- "
                writeNested(item, into: &out, indent: indent + 1)
            }

        case .mapping(let members):
            if members.isEmpty { out += "{}"; return }
            for (i, m) in members.enumerated() {
                if i > 0 || !atLineStart { out += "\n" }
                out += "\(pad)\(key(m.key)):"
                if isNonEmptyCollection(m.value) {
                    // A non-empty collection goes on its own lines, indented one level.
                    out += "\n"
                    write(m.value, into: &out, indent: indent + 1, atLineStart: true)
                } else {
                    out += " "
                    write(m.value, into: &out, indent: indent + 1, atLineStart: false)
                }
            }
        }
    }

    static func isNonEmptyCollection(_ v: RawValue) -> Bool {
        switch v {
        case .sequence(let xs): return !xs.isEmpty
        case .mapping(let ms):  return !ms.isEmpty
        default:                return false
        }
    }

    /// A sequence entry. A nested collection continues on the same line after `- `, with
    /// its own indentation measured from the dash — the compact block form.
    static func writeNested(_ v: RawValue, into out: inout String, indent: Int) {
        switch v {
        case .sequence(let xs) where xs.isEmpty: out += "[]"
        case .mapping(let ms) where ms.isEmpty:  out += "{}"
        case .sequence, .mapping:
            write(v, into: &out, indent: indent, atLineStart: false)
        default:
            out += scalar(v)
        }
    }

    // MARK: Scalars

    static func scalar(_ v: RawValue) -> String {
        switch v {
        case .null:          return "null"
        case .bool(let b):   return b ? "true" : "false"
        case .int(let i):    return String(i)
        case .double(let d):
            // YAML can express what JSON cannot, so these are values rather than issues —
            // the one place the YAML encoder is strictly more capable than the JSON one.
            if d.isNaN { return ".nan" }
            if d.isInfinite { return d > 0 ? ".inf" : "-.inf" }
            return String(d)
        case .string(let s): return quotedIfNeeded(s)
        case .sequence(let xs): return xs.isEmpty ? "[]" : ""
        case .mapping(let ms):  return ms.isEmpty ? "{}" : ""
        }
    }

    static func key(_ k: String) -> String { quotedIfNeeded(k) }

    /// Plain style only when the text provably reads back as the same string.
    static func quotedIfNeeded(_ s: String) -> String {
        needsQuoting(s) ? doubleQuoted(s) : s
    }

    /// Deliberately conservative: every case where a bare scalar could resolve as some
    /// other type, or could be read as structure, is quoted. A false positive costs two
    /// characters; a false negative silently changes the value's type on the way back in.
    static func needsQuoting(_ s: String) -> Bool {
        if s.isEmpty { return true }

        // Anything the core schema would resolve as a non-string. `resolvePlain` is the
        // decoder's own rule, so this asks the exact question the reader will ask.
        if resolvesAsNonString(s) { return true }

        let bytes = Array(s.utf8)

        // Leading or trailing whitespace does not survive a plain scalar.
        if bytes.first == 0x20 || bytes.first == 0x09 { return true }
        if bytes.last == 0x20 || bytes.last == 0x09 { return true }

        // Control characters, newlines and tabs.
        for b in bytes where b < 0x20 || b == 0x7F { return true }

        // A leading indicator character changes how the line parses.
        switch bytes[0] {
        case UInt8(ascii: "-"), UInt8(ascii: "?"), UInt8(ascii: ":"), UInt8(ascii: ","),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "#"), UInt8(ascii: "&"), UInt8(ascii: "*"), UInt8(ascii: "!"),
             UInt8(ascii: "|"), UInt8(ascii: ">"), UInt8(ascii: "'"), UInt8(ascii: "\""),
             UInt8(ascii: "%"), UInt8(ascii: "@"), UInt8(ascii: "`"):
            return true
        default: break
        }

        // `: ` ends a key and ` #` starts a comment, anywhere in the run.
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == UInt8(ascii: ":"), bytes[i + 1] == 0x20 { return true }
            if bytes[i] == 0x20, bytes[i + 1] == UInt8(ascii: "#") { return true }
            i += 1
        }
        // A trailing colon would read as an empty-valued key.
        if bytes.last == UInt8(ascii: ":") { return true }

        // Document markers.
        if s == "---" || s == "..." { return true }
        return false
    }

    /// Whether the YAML 1.2 core schema reads this text as something other than a string.
    /// Mirrors `RawValue`'s own resolution so the question matches the answer.
    static func resolvesAsNonString(_ s: String) -> Bool {
        switch s {
        case "", "~", "null", "Null", "NULL",
             "true", "True", "TRUE", "false", "False", "FALSE",
             ".inf", ".Inf", ".INF", "-.inf", "-.Inf", "-.INF",
             ".nan", ".NaN", ".NAN", "+.inf":
            return true
        default: break
        }
        if Int64(s) != nil { return true }
        if s.hasPrefix("0x"), Int64(s.dropFirst(2), radix: 16) != nil { return true }
        if s.hasPrefix("0o"), Int64(s.dropFirst(2), radix: 8) != nil { return true }
        // A float only if it also contains a digit — `Double("infinity")` succeeds, and
        // "infinity" is an ordinary string in the core schema.
        if Double(s) != nil, s.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) {
            return true
        }
        return false
    }

    static func doubleQuoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\\x" + hex2(UInt8(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func hex2(_ b: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(b >> 4)], digits[Int(b & 0x0F)]])
    }
}
