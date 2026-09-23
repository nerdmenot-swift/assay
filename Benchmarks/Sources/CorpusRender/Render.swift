// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Re-render the JSON corpus as YAML and XML. Shared by DiffFuzz (which feeds the
// documents to two parsers and compares) and AssayBench (which times them).
//
// The renderer only has to emit VALID documents, not semantically intended ones: the
// differential oracles compare Assay against libyaml and Foundation on whatever the text
// actually says, so a renderer bug produces a document both sides read the same way and
// the comparison stays honest. That is what makes generating input this cheaply sound.
//===----------------------------------------------------------------------===//

import Foundation
import AssayCore

/// Render a `RawValue` as block-style YAML. Only needs to be valid, not canonical: the
/// oracles compare two parsers on the text, whatever it says.
public func renderYAML(_ v: RawValue, indent: Int = 0) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d):
        return d.isFinite ? String(d) : (d.isNaN ? ".nan" : (d > 0 ? ".inf" : "-.inf"))
    case .string(let s): return quoteYAML(s)
    case .sequence(let items):
        if items.isEmpty { return "[]" }
        return "\n"
            + items.map { item in
                let rendered = renderYAML(item, indent: indent + 1)
                if rendered.hasPrefix("\n") {
                    return "\(pad)-\(rendered.replacingOccurrences(of: "\n", with: "\n "))"
                }
                return "\(pad)- \(rendered)"
            }.joined(separator: "\n")
    case .mapping(let members):
        if members.isEmpty { return "{}" }
        return "\n"
            + members.map { m in
                "\(pad)\(quoteYAML(m.key)): \(renderYAML(m.value, indent: indent + 1))"
            }.joined(separator: "\n")
    }
}

/// Always double-quote. Ambiguity between a plain scalar and a number, a boolean or a
/// Norway is exactly what the hand-written cases are for; the generated corpus is about
/// structure at volume and should not accidentally test resolution.
public func quoteYAML(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04X", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out + "\""
}

/// Render a `RawValue` as XML. Arrays become repeated `<item>` elements; scalars become
/// text. Keys that are not valid XML names are skipped rather than mangled.
public func renderXML(_ v: RawValue, tag: String = "root") -> String {
    switch v {
    case .null: return "<\(tag)/>"
    case .bool(let b): return "<\(tag)>\(b)</\(tag)>"
    case .int(let i): return "<\(tag)>\(i)</\(tag)>"
    case .double(let d): return "<\(tag)>\(d)</\(tag)>"
    case .string(let s): return "<\(tag)>\(escapeXML(s))</\(tag)>"
    case .sequence(let items):
        return "<\(tag)>" + items.map { renderXML($0, tag: "item") }.joined() + "</\(tag)>"
    case .mapping(let members):
        let inner = members.compactMap { m -> String? in
            guard isXMLName(m.key) else { return nil }
            return renderXML(m.value, tag: m.key)
        }.joined()
        return "<\(tag)>\(inner)</\(tag)>"
    }
}

public func escapeXML(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "&": out += "&amp;"
        default:
            // XML 1.0 forbids most control characters outright — not even as character
            // references. Dropping them keeps the generated corpus well-formed.
            if ch.value < 0x20 && ch != "\n" && ch != "\t" && ch != "\r" { continue }
            out.unicodeScalars.append(ch)
        }
    }
    return out
}

public func isXMLName(_ s: String) -> Bool {
    guard let first = s.unicodeScalars.first else { return false }
    guard CharacterSet.letters.contains(first) || first == "_" else { return false }
    return s.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
    }
}

// MARK: - TOML

/// Render a `RawValue` as TOML, or nil when TOML cannot spell it: a root that is not a
/// mapping, or a null anywhere. Nested mappings become `[a.b]` sections; arrays are
/// always inline, with inline tables inside them — deliberately a different layout from
/// `AssayTOML`'s writer, so the oracle documents are not that writer's output.
public func renderTOML(_ v: RawValue, sections: Bool = false) -> String? {
    guard case .mapping(let members) = v, !containsNull(v) else { return nil }
    var out = ""
    renderTOMLTable(members, path: [], sections: sections, into: &out)
    return out
}

private func containsNull(_ v: RawValue) -> Bool {
    switch v {
    case .null: return true
    case .sequence(let items): return items.contains(where: containsNull)
    case .mapping(let members): return members.contains { containsNull($0.value) }
    default: return false
    }
}

/// `sections: true` writes an array whose elements are all mappings as `[[a.b]]`
/// sections — the shape a real document has — instead of one inline array.
private func renderTOMLTable(
    _ members: [RawValue.Member], path: [String], sections: Bool, into out: inout String
) {
    var tables: [RawValue.Member] = []
    var arrays: [RawValue.Member] = []
    for m in members {
        if case .mapping = m.value { tables.append(m); continue }
        if sections, case .sequence(let items) = m.value, !items.isEmpty,
            items.allSatisfy({ if case .mapping = $0 { return true } else { return false } })
        {
            arrays.append(m)
            continue
        }
        out += tomlKey(m.key) + " = " + renderTOMLInline(m.value) + "\n"
    }
    for m in tables {
        guard case .mapping(let sub) = m.value else { continue }
        let subPath = path + [m.key]
        out += "\n[" + subPath.map(tomlKey).joined(separator: ".") + "]\n"
        renderTOMLTable(sub, path: subPath, sections: sections, into: &out)
    }
    for m in arrays {
        guard case .sequence(let items) = m.value else { continue }
        let subPath = path + [m.key]
        for item in items {
            guard case .mapping(let sub) = item else { continue }
            out += "\n[[" + subPath.map(tomlKey).joined(separator: ".") + "]]\n"
            renderTOMLTable(sub, path: subPath, sections: sections, into: &out)
        }
    }
}

private func renderTOMLInline(_ v: RawValue) -> String {
    switch v {
    case .null: return "\"\""
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d):
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        return String(d)
    case .string(let s): return quoteTOML(s)
    case .sequence(let items):
        return "[" + items.map(renderTOMLInline).joined(separator: ", ") + "]"
    case .mapping(let members):
        return "{"
            + members.map { tomlKey($0.key) + " = " + renderTOMLInline($0.value) }.joined(
                separator: ", ") + "}"
    }
}

private func tomlKey(_ k: String) -> String {
    let bare =
        !k.isEmpty
        && k.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39)
                || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
        }
    return bare ? k : quoteTOML(k)
}

/// A basic string; the escape set is TOML's, which is JSON's without `\/`.
public func quoteTOML(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if ch.value < 0x20 || ch.value == 0x7F {
                out += String(format: "\\u%04X", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out + "\""
}
