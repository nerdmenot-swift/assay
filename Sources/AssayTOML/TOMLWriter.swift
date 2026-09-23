// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Rendering a `RawValue` as TOML. docs/ENCODING.md.
//
// The layout is the one every TOML serialiser converges on, because it is what the
// format's readers expect: a table's scalar members first as `key = value` lines, then
// each sub-table as its own `[a.b]` section, then each array of tables as `[[a.b]]`
// sections. An array that holds anything other than tables is written inline, with any
// tables inside it as inline tables, since `[[…]]` cannot spell a mixed array.
//
// TOML HAS NO NULL, and that is the one place encoding can fail. A nil member of a table
// is omitted — the reader sees an absent key, which is what an optional field decodes nil
// from, so the round trip holds. A nil anywhere else (an array element, the document
// root) has no spelling that reads back as nil, and is reported rather than substituted.
//
// Strings are always basic (`"…"`) single-line strings with escapes. Literal and
// multi-line forms are prettier for some inputs and correct for none the basic form is
// not; a writer that picks between them has four code paths where one will do.
//===----------------------------------------------------------------------===//

public import AssayCore

extension TOML {

    /// Render a `RawValue` as a TOML document. The value must be a mapping — a TOML
    /// document is a table — and may not contain a null outside a table member; both are
    /// reported to the sink, and the bytes returned are what could be written.
    public static func encode(
        _ value: RawValue, into sink: inout IssueSink
    ) -> EncodedBytes {
        guard case .mapping(let members) = value else {
            sink.add(Issue(code: .tomlRootNotATable, path: []))
            return EncodedBytes()
        }
        var out = ""
        writeTable(members, path: [], into: &out, sink: &sink)
        return EncodedBytes(text: out)
    }

    /// `[a.b]`-style sections for a table's members, recursively. `path` is the header
    /// prefix (empty at the root, whose scalars need no header).
    static func writeTable(
        _ members: [RawValue.Member], path: [String], into out: inout String, sink: inout IssueSink
    ) {
        var tables: [RawValue.Member] = []
        var arraysOfTables: [RawValue.Member] = []
        var lines = ""
        for m in members {
            switch m.value {
            case .null:
                continue
            case .mapping:
                tables.append(m)
            case .sequence(let items) where !items.isEmpty && items.allSatisfy(isMapping):
                arraysOfTables.append(m)
            default:
                lines += key(m.key) + " = "
                writeInline(m.value, path: path + [m.key], into: &lines, sink: &sink)
                lines += "\n"
            }
        }
        out += lines
        for m in tables {
            guard case .mapping(let sub) = m.value else { continue }
            let subPath = path + [m.key]
            if !out.isEmpty { out += "\n" }
            out += "[" + header(subPath) + "]\n"
            writeTable(sub, path: subPath, into: &out, sink: &sink)
        }
        for m in arraysOfTables {
            guard case .sequence(let items) = m.value else { continue }
            let subPath = path + [m.key]
            for item in items {
                guard case .mapping(let sub) = item else { continue }
                if !out.isEmpty { out += "\n" }
                out += "[[" + header(subPath) + "]]\n"
                writeTable(sub, path: subPath, into: &out, sink: &sink)
            }
        }
    }

    /// A value on the right of `=`, or inside an array or inline table.
    static func writeInline(
        _ v: RawValue, path: [String], into out: inout String, sink: inout IssueSink
    ) {
        switch v {
        case .null:
            sink.add(Issue(code: .tomlNoNull, path: path.map { .key($0) }))
            out += "\"\""
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            out += float(d)
        case .string(let s):
            out += quoted(s)
        case .sequence(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += ", " }
                if case .null = item {
                    sink.add(Issue(code: .tomlNoNull, path: path.map { .key($0) } + [.index(i)]))
                    out += "\"\""
                    continue
                }
                writeInline(item, path: path, into: &out, sink: &sink)
            }
            out += "]"
        case .mapping(let members):
            out += "{"
            var first = true
            for m in members {
                if case .null = m.value { continue }
                if !first { out += ", " }
                first = false
                out += key(m.key) + " = "
                writeInline(m.value, path: path + [m.key], into: &out, sink: &sink)
            }
            out += "}"
        }
    }

    static func isMapping(_ v: RawValue) -> Bool {
        if case .mapping = v { return true }
        return false
    }

    static func header(_ path: [String]) -> String {
        path.map(key).joined(separator: ".")
    }

    /// Bare if it can be, quoted otherwise. The empty key must be quoted.
    static func key(_ k: String) -> String {
        let bare =
            !k.isEmpty
            && k.utf8.allSatisfy {
                ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A)
                    || ($0 >= 0x30 && $0 <= 0x39)
                    || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
            }
        return bare ? k : quoted(k)
    }

    /// `inf`, `nan`, or the shortest round-tripping decimal — which always carries a `.`
    /// or an `e`, so it reads back as a float and not an integer.
    static func float(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        return String(d)
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    let hex = String(u.value, radix: 16, uppercase: true)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}
