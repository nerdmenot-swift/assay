// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// TOML oracles. Three of them.
//
//   ORACLE 1 — TOMLKit (toml++). An independent C++ implementation with the most complete
//   conformance record, over the hand-written feature cases and the JSON corpus rendered
//   as TOML. Where the two accept a document and disagree, Assay is wrong until shown
//   otherwise.
//
//   ORACLE 2 — the official toml-test suite (github.com/toml-lang/toml-test), the
//   acceptance criterion for "TOML 1.0.0 compliant": every `valid/` document must parse
//   to exactly the tagged-JSON value beside it, every `invalid/` document must be
//   refused. Needs a checkout; `TOML_TEST_DIR` names it and CI clones one. Without it
//   the arm says so and passes nothing.
//
//   ORACLE 3 — the encoder: every document Assay writes, toml++ must read back to the
//   same value. The library's round-trip tests prove self-consistency and nothing more.
//
// COMPARISON IS ON VALUES with tables SORTED BY KEY: toml++ stores a table as a
// `std::map`, so document order is not in its vocabulary. Order is checked by the
// library's own tests and by toml-test's JSON (which is also unordered — so nothing here
// verifies order against an independent reader; `TOMLValueTests` pins it).
//
// DATE-TIMES are compared as canonical strings built from components on both sides:
// Assay's RFC 3339 text is parsed here, toml++'s struct fields are formatted here, and
// the two must meet exactly, fraction included (to nanoseconds, which is toml++'s
// resolution).
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore
import AssayTOML
import CorpusRender
import TOMLKit

// MARK: - Assay's side

func assayTOMLValue(_ node: TOML.Node) -> YValue {
    switch node {
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .dateTime(let dt): return .string(canonicalDateTime(dt))
    case .array(let items): return .sequence(items.map(assayTOMLValue))
    case .table(let members):
        return .mapping(members.map { .init($0.key, assayTOMLValue($0.value)) })
    }
}

func assayTOML(_ text: String) -> YValue? {
    guard let node = try? TOML.parse(text) else { return nil }
    return sortedMappings(assayTOMLValue(node))
}

func assayTOMLRejectionReason(_ text: String) -> String {
    var sink = IssueSink(limits: .default)
    _ = TOML.decode(Array(text.utf8), into: &sink, limits: .default)
    return sink.issues.first.map { "\($0.code.codeString)" } ?? "?"
}

/// `kind|YYYY-MM-DD|HH:MM:SS.nnnnnnnnn|±MMMM` — the shared spelling of a date-time.
func canonicalDateTime(_ dt: TOML.DateTime) -> String {
    switch dt {
    case .offsetDateTime(let s): return canonicalDateTime(text: s, kind: "odt")
    case .localDateTime(let s): return canonicalDateTime(text: s, kind: "ldt")
    case .localDate(let s): return canonicalDateTime(text: s, kind: "ld")
    case .localTime(let s): return canonicalDateTime(text: s, kind: "lt")
    }
}

/// Parse an RFC 3339 spelling into the canonical form. Accepts `T`, `t` or a space as the
/// separator and `Z`/`z` for UTC, so toml-test's expected strings go through it too.
func canonicalDateTime(text: String, kind: String) -> String {
    var s = Substring(text)
    var date = "", time = "", offset = ""
    func take(_ n: Int) -> String { let p = String(s.prefix(n)); s = s.dropFirst(n); return p }
    if kind != "lt" {
        date = take(10)
        if let sep = s.first, sep == "T" || sep == "t" || sep == " " { s = s.dropFirst() }
    }
    if kind != "ld" {
        time = take(8)
        var frac = ""
        if s.first == "." {
            s = s.dropFirst()
            while let c = s.first, c.isNumber { frac.append(c); s = s.dropFirst() }
        }
        time += "." + String((frac + String(repeating: "0", count: 9)).prefix(9))
    }
    if kind == "odt" {
        if let z = s.first, z == "Z" || z == "z" {
            offset = "+0000"
        } else {
            let sign = s.first == "-" ? -1 : 1
            s = s.dropFirst()
            let h = Int(take(2)) ?? 0
            s = s.dropFirst()
            let m = Int(take(2)) ?? 0
            let total = sign * (h * 60 + m)
            offset = (total < 0 ? "-" : "+") + String(format: "%04d", abs(total))
        }
    }
    return "\(kind)|\(date)|\(time)|\(offset)"
}

// MARK: - toml++'s side

func tomlKitValue(_ v: TOMLValueConvertible) -> YValue? {
    switch v.type {
    case .bool: return v.bool.map { .bool($0) }
    case .int: return v.int.map { .int(Int64($0)) }
    case .double: return v.double.map { .double($0) }
    case .string: return v.string.map { .string($0) }
    case .date:
        guard let d = v.date else { return nil }
        return .string("ld|\(tomlKitDate(d))||")
    case .time:
        guard let t = v.time else { return nil }
        return .string("lt||\(tomlKitTime(t))|")
    case .dateTime:
        guard let dt = v.dateTime else { return nil }
        if let o = dt.offset {
            let total = o.offset
            let off = (total < 0 ? "-" : "+") + String(format: "%04d", abs(total))
            return .string("odt|\(tomlKitDate(dt.date))|\(tomlKitTime(dt.time))|\(off)")
        }
        return .string("ldt|\(tomlKitDate(dt.date))|\(tomlKitTime(dt.time))|")
    case .array:
        guard let a = v.array else { return nil }
        var out: [YValue] = []
        for item in a { guard let x = tomlKitValue(item) else { return nil }; out.append(x) }
        return .sequence(out)
    case .table:
        guard let t = v.table else { return nil }
        var out: [YValue.Member] = []
        for (k, item) in t { guard let x = tomlKitValue(item) else { return nil }; out.append(.init(k, x)) }
        return .mapping(out)
    }
}

func tomlKitDate(_ d: TOMLDate) -> String { String(format: "%04d-%02d-%02d", d.year, d.month, d.day) }
func tomlKitTime(_ t: TOMLTime) -> String {
    String(format: "%02d:%02d:%02d.%09d", t.hour, t.minute, t.second, t.nanoSecond)
}

func tomlKit(_ text: String) -> YValue? {
    guard let table = try? TOMLTable(string: text), let v = tomlKitValue(table) else { return nil }
    return sortedMappings(v)
}

// MARK: - Oracle 1: the differential

func runTOMLDifferential(_ documents: [(name: String, text: String)]) -> YAMLOracleResult {
    var r = YAMLOracleResult()
    for (name, text) in documents {
        let mine = assayTOML(text)
        let theirs = tomlKit(text)
        switch (mine, theirs) {
        case (nil, nil): r.bothRejected += 1
        case (nil, .some):
            r.assayOnlyRejected.append("\(name) [\(assayTOMLRejectionReason(text))]")
            if ProcessInfo.processInfo.environment["SHOW_ORACLE"] != nil {
                print("      oracle for \(name): \(String(describing: theirs))")
            }
        case (.some, nil): r.oracleOnlyRejected.append(name)
        case (.some(let a), .some(let b)):
            if a == b { r.agreed += 1 } else { r.disagreed.append((name, describeDifference([a], [b], "toml++"))) }
        }
    }
    return r
}

// MARK: - Oracle 2: toml-test

/// Runs the suite at `dir` (a checkout of toml-lang/toml-test). Returns (valid passed,
/// valid total, invalid passed, invalid total). Every miss is reported through `fail`.
func runTOMLTestSuite(dir: URL) -> (validOK: Int, valid: Int, invalidOK: Int, invalid: Int) {
    let tests = dir.appendingPathComponent("tests")
    // The 1.0.0 file list is authoritative; the suite also carries 1.1 cases.
    guard let list = try? String(contentsOf: tests.appendingPathComponent("files-toml-1.0.0"), encoding: .utf8) else {
        fail("toml-test: \(tests.path)/files-toml-1.0.0 not found — is TOML_TEST_DIR a toml-test checkout?")
        return (0, 0, 0, 0)
    }
    var validOK = 0, valid = 0, invalidOK = 0, invalid = 0
    for line in list.split(separator: "\n") where line.hasSuffix(".toml") {
        let rel = String(line)
        let url = tests.appendingPathComponent(rel)
        guard let bytes = try? Data(contentsOf: url) else { fail("toml-test: cannot read \(rel)"); continue }
        if rel.hasPrefix("invalid/") {
            invalid += 1
            var sink = IssueSink(limits: .default)
            if TOML.decode([UInt8](bytes), into: &sink, limits: .default) != nil, sink.isValid {
                fail("toml-test: ACCEPTED invalid \(rel)")
            } else {
                invalidOK += 1
            }
            continue
        }
        valid += 1
        guard let node = try? TOML.parse([UInt8](bytes)) else {
            fail("toml-test: REJECTED valid \(rel) [\(assayTOMLRejectionReason(String(decoding: bytes, as: UTF8.self)))]")
            continue
        }
        let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
        guard let jsonData = try? Data(contentsOf: jsonURL),
              let any = try? JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed]),
              let expected = taggedJSON(any) else {
            fail("toml-test: cannot read expected \(jsonURL.lastPathComponent)")
            continue
        }
        let got = sortedMappings(assayTOMLValue(node))
        if got == expected {
            validOK += 1
        } else {
            fail("toml-test: \(rel) — \(firstPathDifference(got, expected) ?? "\(got) vs \(expected)")")
        }
    }
    return (validOK, valid, invalidOK, invalid)
}

/// toml-test's tagged JSON: a value is `{"type": "integer", "value": "42"}`; a table is
/// a plain object and an array a plain array.
func taggedJSON(_ any: Any) -> YValue? {
    if let a = any as? [Any] {
        var out: [YValue] = []
        for x in a { guard let v = taggedJSON(x) else { return nil }; out.append(v) }
        return .sequence(out)
    }
    guard let d = any as? [String: Any] else { return nil }
    if d.count == 2, let type = d["type"] as? String, let value = d["value"] as? String {
        switch type {
        case "string": return .string(value)
        case "integer": return Int64(value).map { .int($0) }
        case "float":
            switch value {
            case "inf", "+inf": return .double(.infinity)
            case "-inf": return .double(-.infinity)
            case "nan", "+nan", "-nan": return .double(.nan)
            default: return Double(value).map { .double($0) }
            }
        case "bool": return .bool(value == "true")
        case "datetime": return .string(canonicalDateTime(text: value, kind: "odt"))
        case "datetime-local": return .string(canonicalDateTime(text: value, kind: "ldt"))
        case "date-local": return .string(canonicalDateTime(text: value, kind: "ld"))
        case "time-local": return .string(canonicalDateTime(text: value, kind: "lt"))
        default: return nil
        }
    }
    var out: [YValue.Member] = []
    for k in d.keys.sorted() {
        guard let v = taggedJSON(d[k]!) else { return nil }
        out.append(.init(k, v))
    }
    return .mapping(out)
}

// MARK: - Oracle 3: the encoder

@Schema(formats: .all, encodes: true)
struct TOMLEnvelope {
    var payload: RawValue
}

/// Every null-free corpus document, written by Assay and read back by toml++.
func runTOMLEncodeDifferential(corpus: URL) -> Int {
    var checked = 0
    guard let all = try? FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil) else { return 0 }
    for url in all.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("neg-") {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSON.Value.parse([UInt8](data)) else { continue }
        let raw = RawValue(value)
        // Nulls have no TOML spelling; the writer reports them, and that is tested in
        // the library. This oracle is about what it CAN write.
        guard renderTOML(.mapping([.init(key: "payload", value: raw)])) != nil else { continue }
        let name = url.lastPathComponent
        let d = TOMLEnvelope(payload: raw).diagnoseEncodeTOML()
        guard d.isValid else {
            fail("toml-encode: \(name) produced issues: \(d.issues.map(\.code.codeString))")
            continue
        }
        let text = String(decoding: d.bytes, as: UTF8.self)
        guard let theirs = tomlKit(text) else {
            fail("toml-encode: toml++ rejected Assay's own TOML for \(name)")
            continue
        }
        guard case .mapping(let top) = theirs, let payload = top.first(where: { $0.key == "payload" })?.value else {
            fail("toml-encode: \(name) is outside the oracle's vocabulary")
            continue
        }
        let mine = sortedMappings(rawAsY(raw))
        if mine != payload {
            fail("toml-encode: \(name) round-tripped through toml++ to a different value: \(firstPathDifference(mine, payload) ?? "")")
        }
        checked += 1
    }
    return checked
}

private func rawAsY(_ v: RawValue) -> YValue {
    switch v {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .sequence(let a): return .sequence(a.map(rawAsY))
    case .mapping(let m): return .mapping(m.map { .init($0.key, rawAsY($0.value)) })
    }
}
