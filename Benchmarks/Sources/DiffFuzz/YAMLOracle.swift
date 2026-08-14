// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// YAML differential oracles. Two of them, because they fail in different directions.
//
// This is the code that most needed an oracle and had none. YAML 1.2 is a large and
// genuinely difficult spec, Assay's parser implements a documented subset of it, and until
// now the only guarantee was that the fuzzer could not make it crash. Nothing checked that
// a document it accepted meant what it said. That is the worst failure mode a parser has:
// not a crash, which you find immediately, but a quiet mis-read that corrupts data and
// surfaces as a bug somewhere else entirely, months later.
//
//   ORACLE 1 — Yams (libyaml). An independent implementation of the same spec, in C, that
//   most of the YAML ecosystem is built on. This is the real oracle: it covers block style,
//   anchors and aliases, multi-document streams, block scalars, and all the corners a
//   subset parser is likely to get wrong. Where Assay and libyaml disagree about a document
//   both accept, one of them is wrong and it is overwhelmingly likely to be Assay.
//
//   ORACLE 2 — JSON. YAML 1.2 defines JSON as a strict subset: every valid JSON document
//   is a valid YAML document with the same meaning. So the existing 75-file JSON corpus is
//   also a YAML corpus, and JSONSerialization is a second independent oracle over it. This
//   costs nothing, needs no dependency, and covers flow style, quoting, escapes, numbers
//   and deep nesting at real scale.
//
// COMPARISON IS ON RESOLVED VALUES, not on nodes. Assay keeps scalars as unresolved text
// plus style — deliberately, so the Norway problem is the schema's decision rather than the
// parser's — while Yams resolves eagerly. Comparing resolved values is the only shared
// vocabulary, and it means this oracle checks STRUCTURE AND CONTENT, not tags or styles.
// Those are covered by Assay's own tests and are not independently verified here.
//===----------------------------------------------------------------------===//

import Foundation
import AssayCore
import AssayYAML
import Yams

/// The shared vocabulary: what both parsers agree a document means, once resolved.
indirect enum YValue: Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case sequence([YValue])
    /// Ordered, because YAML mappings are ordered and dropping that would hide a real
    /// class of disagreement.
    case mapping([(String, YValue)])

    static func == (a: YValue, b: YValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)):
            return x == y || (x.isNaN && y.isNaN)
        // A number that one side resolved as an integer and the other as a float is not a
        // disagreement worth failing on — 1 and 1.0 denote the same YAML scalar, and the
        // schema decides the Swift type. A difference in VALUE still fails.
        case (.int(let x), .double(let y)), (.double(let y), .int(let x)):
            return Double(x) == y
        case (.string(let x), .string(let y)): return x == y
        case (.sequence(let x), .sequence(let y)): return x == y
        case (.mapping(let x), .mapping(let y)):
            guard x.count == y.count else { return false }
            for (p, q) in zip(x, y) where p.0 != q.0 || p.1 != q.1 { return false }
            return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return "\(b)"
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return "\"\(s)\""
        case .sequence(let a): return "[\(a.map(\.description).joined(separator: ", "))]"
        case .mapping(let m):
            return "{\(m.map { "\($0.0): \($0.1)" }.joined(separator: ", "))}"
        }
    }
}

// MARK: - Assay's side

/// Resolve an Assay node the way the YAML 1.2 core schema says to. Quoted scalars are
/// ALWAYS strings — `"123"` is the string, not the number — which is the rule that makes
/// JSON a subset of YAML at all.
func resolve(_ node: YAML.Node) -> YValue? {
    switch node {
    case .scalar(let s):
        switch s.style {
        case .singleQuoted, .doubleQuoted, .literal, .folded:
            return .string(s.content)
        case .plain:
            if let tag = s.tag {
                // An explicit tag overrides resolution: !!str 123 is a string.
                if tag == "!!str" || tag == "tag:yaml.org,2002:str" { return .string(s.content) }
            }
            return resolvePlain(s.content)
        }

    case .sequence(let items):
        var out: [YValue] = []
        out.reserveCapacity(items.count)
        for i in items {
            guard let v = resolve(i) else { return nil }
            out.append(v)
        }
        return .sequence(out)

    case .mapping(let pairs):
        var out: [(String, YValue)] = []
        out.reserveCapacity(pairs.count)
        for p in pairs {
            // Non-scalar keys are legal YAML and are outside this oracle's vocabulary.
            guard case .scalar(let k) = p.key else { return nil }
            guard let v = resolve(p.value) else { return nil }
            out.append((k.content, v))
        }
        return .mapping(out)
    }
}

/// The YAML 1.2 core schema's plain-scalar resolution.
func resolvePlain(_ text: String) -> YValue {
    switch text {
    case "", "~", "null", "Null", "NULL": return .null
    case "true", "True", "TRUE": return .bool(true)
    case "false", "False", "FALSE": return .bool(false)
    default: break
    }
    if let i = Int64(text) { return .int(i) }
    // 0x / 0o forms, which the core schema resolves as integers.
    if text.hasPrefix("0x"), let i = Int64(text.dropFirst(2), radix: 16) { return .int(i) }
    if text.hasPrefix("0o"), let i = Int64(text.dropFirst(2), radix: 8) { return .int(i) }
    switch text {
    case ".inf", ".Inf", ".INF", "+.inf": return .double(.infinity)
    case "-.inf", "-.Inf", "-.INF": return .double(-.infinity)
    case ".nan", ".NaN", ".NAN": return .double(.nan)
    default: break
    }
    if let d = Double(text), text.rangeOfCharacter(
        from: CharacterSet(charactersIn: "0123456789")) != nil {
        return .double(d)
    }
    return .string(text)
}

func assayYAML(_ text: String) -> [YValue]? {
    var sink = IssueSink(limits: .default)
    let docs = YAML.decodeAll(Array(text.utf8), into: &sink, limits: .default)
    guard sink.isValid else { return nil }
    var out: [YValue] = []
    for d in docs {
        guard let v = resolve(d) else { return nil }
        out.append(v)
    }
    return out
}

/// Why Assay rejected a document — a rejection count is a number, a rejection CAUSE is a
/// lead. Only called on the rejection path, so the re-parse costs nothing in the common case.
func assayRejectionReason(_ text: String) -> String {
    var sink = IssueSink(limits: .default)
    _ = YAML.decodeAll(Array(text.utf8), into: &sink, limits: .default)
    if let first = sink.issues.first {
        return "\(first.code)" + (first.received.map { ", received \($0)" } ?? "")
    }
    return "outside oracle vocabulary (non-scalar key)"
}

// MARK: - Yams's side

func yamsValue(_ node: Yams.Node) -> YValue? {
    switch node {
    case .scalar(let s):
        // Yams preserves the style, so the same quoted-is-a-string rule applies.
        switch s.style {
        case .singleQuoted, .doubleQuoted, .literal, .folded:
            return .string(s.string)
        default:
            if let tag = s.tag.description as String?, tag == "tag:yaml.org,2002:str" {
                return .string(s.string)
            }
            return resolvePlain(s.string)
        }
    case .sequence(let seq):
        var out: [YValue] = []
        for n in seq { guard let v = yamsValue(n) else { return nil }; out.append(v) }
        return .sequence(out)
    case .mapping(let map):
        // Yams's composer keeps `<<` as a literal key (merge is a constructor-level
        // feature there); Assay's parser expands it. Expand here, with the same
        // semantics Assay documents: an explicitly written pair always beats a merged
        // one, and merged pairs append after the explicit ones in source order.
        var out: [(String, YValue)] = []
        var mergeSources: [Yams.Node] = []
        for (k, v) in map {
            guard case .scalar(let ks) = k else { return nil }
            if ks.string == "<<", ks.style == .plain {
                mergeSources.append(v)
                continue
            }
            guard let vv = yamsValue(v) else { return nil }
            out.append((ks.string, vv))
        }
        for source in mergeSources {
            let mappings: [Yams.Node]
            if case .sequence(let seq) = source { mappings = Array(seq) }
            else { mappings = [source] }
            for m in mappings {
                guard case .mapping(let inner) = m else { return nil }
                for (k, v) in inner {
                    guard case .scalar(let ks) = k else { return nil }
                    guard !out.contains(where: { $0.0 == ks.string }) else { continue }
                    guard let vv = yamsValue(v) else { return nil }
                    out.append((ks.string, vv))
                }
            }
        }
        return .mapping(out)
    case .alias:
        // Yams's composer resolves aliases at parse time (loadAlias returns the anchored
        // node), so this case never appears in a composed tree — it exists for the
        // encoding side. Outside the oracle's vocabulary if it ever does.
        return nil
    }
}

/// Whether `text` carries anything a YAML parser should turn into a node — that is, any
/// line with something on it once a `#` comment and surrounding whitespace are removed.
func yamlHasContent(_ text: String) -> Bool {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var code = line
        if let hash = code.firstIndex(of: "#") { code = code[code.startIndex..<hash] }
        if code.contains(where: { !$0.isWhitespace }) { return true }
    }
    return false
}

func yamsYAML(_ text: String) -> [YValue]? {
    do {
        let nodes = try Yams.compose_all(yaml: text)
        // ZERO documents from input that HAS content is a REFUSAL, not an acceptance, and
        // libyaml expresses it that way rather than by throwing. `a: one\n  two: 3` — a
        // plain scalar followed by a more-indented mapping key — comes back as an empty
        // stream. Counting that as "the oracle accepted it" made Assay's explicit error look
        // like a disagreement when the two in fact agree the document is bad.
        //
        // "Has content" must ignore comments as well as whitespace: a file of nothing but
        // `# notes` legitimately parses to no documents, and a first version of this check
        // that only skipped whitespace turned that into a false failure.
        var out: [YValue] = []
        for n in nodes { guard let v = yamsValue(n) else { return nil }; out.append(v) }
        if out.isEmpty, yamlHasContent(text) { return nil }
        return out
    } catch {
        return nil
    }
}

// MARK: - JSON as YAML

func jsonAsYValue(_ any: Any) -> YValue? {
    if any is NSNull { return .null }
    if let n = any as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        let d = n.doubleValue
        if d == d.rounded(), abs(d) < 9.2e18 { return .int(n.int64Value) }
        return .double(d)
    }
    if let s = any as? String { return .string(s) }
    if let a = any as? [Any] {
        var out: [YValue] = []
        for x in a { guard let v = jsonAsYValue(x) else { return nil }; out.append(v) }
        return .sequence(out)
    }
    if let d = any as? [String: Any] {
        // JSONSerialization returns an unordered dictionary, so this comparison sorts both
        // sides by key. Mapping ORDER is therefore not checked by the JSON oracle — the
        // Yams oracle checks it, on ordered input.
        var out: [(String, YValue)] = []
        for k in d.keys.sorted() {
            guard let v = jsonAsYValue(d[k]!) else { return nil }
            out.append((k, v))
        }
        return .mapping(out)
    }
    return nil
}

func sortedMappings(_ v: YValue) -> YValue {
    switch v {
    case .sequence(let a): return .sequence(a.map(sortedMappings))
    case .mapping(let m):
        return .mapping(m.map { ($0.0, sortedMappings($0.1)) }.sorted { $0.0 < $1.0 })
    default: return v
    }
}

// MARK: - Results

struct YAMLOracleResult {
    var agreed = 0
    var bothRejected = 0
    var assayOnlyRejected: [String] = []
    var oracleOnlyRejected: [String] = []
    var disagreed: [(name: String, detail: String)] = []
}

func runYAMLDifferential(
    _ documents: [(name: String, text: String)],
    oracleName: String
) -> YAMLOracleResult {
    var r = YAMLOracleResult()
    for (name, text) in documents {
        let mine = assayYAML(text)
        let theirs = yamsYAML(text)
        switch (mine, theirs) {
        case (nil, nil): r.bothRejected += 1
        case (nil, .some):
            r.assayOnlyRejected.append("\(name) [\(assayRejectionReason(text))]")
            // `SHOW_ORACLE=1` prints what the oracle produced for a disagreement. Reading
            // the oracle's actual answer is what settles these: it is how `a: one\n  - x`
            // turned out to be the scalar "one - x" rather than a parser bug on either side.
            if ProcessInfo.processInfo.environment["SHOW_ORACLE"] != nil {
                print("      oracle for \(name): \(String(describing: theirs))")
            }
        case (.some, nil): r.oracleOnlyRejected.append(name)
        case (.some(let a), .some(let b)):
            if a == b {
                r.agreed += 1
            } else {
                r.disagreed.append((name, describeDifference(a, b, oracleName)))
            }
        }
    }
    return r
}

func runJSONAsYAML(_ files: [(name: String, data: Data)]) -> YAMLOracleResult {
    var r = YAMLOracleResult()
    for (name, data) in files {
        let text = String(decoding: data, as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]),
              let expected = jsonAsYValue(object) else { continue }

        guard let mine = assayYAML(text), mine.count == 1 else {
            r.assayOnlyRejected.append(name); continue
        }
        let got = sortedMappings(mine[0])
        if got == expected {
            r.agreed += 1
        } else {
            r.disagreed.append((name, describeDifference([got], [expected], "JSON")))
        }
    }
    return r
}

func describeDifference(_ a: [YValue], _ b: [YValue], _ oracleName: String) -> String {
    if a.count != b.count {
        return "document count: Assay \(a.count) vs \(oracleName) \(b.count)"
    }
    for (i, (x, y)) in zip(a, b).enumerated() where x != y {
        if let path = firstPathDifference(x, y) { return "doc \(i) \(path)" }
        return "doc \(i): \(x) vs \(y)"
    }
    return "values compared unequal but no difference located"
}

/// Walk both values together and name the first place they diverge. On a 2,000-key
/// document, "they differ" is useless and "at items[3].name Assay says X" is the bug.
func firstPathDifference(_ a: YValue, _ b: YValue, path: String = "") -> String? {
    if a == b { return nil }
    switch (a, b) {
    case (.sequence(let x), .sequence(let y)):
        if x.count != y.count {
            return "at \(path.isEmpty ? "<root>" : path): length \(x.count) vs \(y.count)"
        }
        for (i, (p, q)) in zip(x, y).enumerated() {
            if let d = firstPathDifference(p, q, path: "\(path)[\(i)]") { return d }
        }
    case (.mapping(let x), .mapping(let y)):
        if x.count != y.count {
            let mine = Set(x.map(\.0)), theirs = Set(y.map(\.0))
            let extra = mine.subtracting(theirs), missing = theirs.subtracting(mine)
            return "at \(path.isEmpty ? "<root>" : path): key counts differ"
                + (extra.isEmpty ? "" : "; only Assay has \(extra.sorted())")
                + (missing.isEmpty ? "" : "; only the oracle has \(missing.sorted())")
        }
        for (p, q) in zip(x, y) {
            if p.0 != q.0 {
                return "at \(path).\(p.0): key order or name differs (oracle says \(q.0))"
            }
            if let d = firstPathDifference(p.1, q.1, path: "\(path).\(p.0)") { return d }
        }
    default:
        return "at \(path.isEmpty ? "<root>" : path): Assay \(a) vs oracle \(b)"
    }
    return "at \(path.isEmpty ? "<root>" : path): Assay \(a) vs oracle \(b)"
}
