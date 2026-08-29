// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// YAML encoder differential: everything Assay writes, libyaml must read back.
//
// The round-trip tests in the library check Assay's writer against Assay's own reader,
// which proves self-consistency and nothing more — a writer and reader that share a
// quoting bug agree perfectly, and quoting is the entire difficulty in YAML output.
//
// This hands every encoded document to Yams/libyaml instead. It is the check that
// actually asks "is this YAML?" rather than "is this the YAML we happen to parse?", and
// it is where a plain scalar that should have been quoted gets caught: libyaml resolves
// `123` to an integer whatever Assay's reader would have done with it.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore
import AssayYAML
import Yams

@Schema(formats: .all, encodes: true)
struct YamlEnvelope {
    var payload: RawValue
}

func runYAMLEncodeDifferential(corpus: URL) -> Int {
    var checked = 0
    guard let all = try? FileManager.default.contentsOfDirectory(
        at: corpus, includingPropertiesForKeys: nil) else { return 0 }

    for url in all.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("neg-") {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSON.Value.parse([UInt8](data)) else { continue }
        let name = url.lastPathComponent

        let envelope = YamlEnvelope(payload: RawValue(value))
        let d = envelope.diagnoseEncodeYAML()
        guard d.isValid else {
            fail("yaml-encode: \(name) produced issues: \(d.issues.map(\.code.codeString))")
            continue
        }
        let text = String(decoding: d.bytes, as: UTF8.self)

        // 1. libyaml must accept it at all.
        guard let composed = try? Yams.compose(yaml: text) else {
            fail("yaml-encode: libyaml rejected Assay's own YAML for \(name)")
            continue
        }
        // 2. And must read back the same values — this is where an unquoted "123" dies.
        // libyaml sees the whole document, including the `payload:` wrapper; compare
        // its contents against the field, not the envelope against the field.
        guard let whole = yamsValue(composed),
              case .mapping(let topLevel) = whole,
              let theirs = topLevel.first(where: { $0.key == "payload" })?.value else {
            fail("yaml-encode: \(name) is outside the oracle's vocabulary")
            continue
        }
        guard let mine = try? YamlEnvelope.parse(yaml: d.bytes) else {
            fail("yaml-encode: Assay could not re-parse its own YAML for \(name)")
            continue
        }
        if !rawMatchesY(mine.payload, theirs) {
            fail("yaml-encode: \(name) round-tripped through libyaml to a different value")
        }
        checked += 1
    }
    return checked
}

/// `RawValue` against the oracle's resolved `YValue`, reusing the YAML oracle's own
/// vocabulary so the two differentials agree on what "equal" means.
private func rawMatchesY(_ mine: RawValue, _ theirs: YValue) -> Bool {
    switch (mine, theirs) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.int(let a), .double(let b)): return Double(a) == b
    case (.double(let a), .double(let b)): return a == b || (a.isNaN && b.isNaN)
    case (.double(let a), .int(let b)): return a == Double(b)
    case (.string(let a), .string(let b)): return a == b
    case (.sequence(let a), .sequence(let b)):
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where !rawMatchesY(x, y) { return false }
        return true
    case (.mapping(let a), .mapping(let b)):
        guard a.count == b.count else { return false }
        for (m, pair) in zip(a, b) {
            guard m.key == pair.key, rawMatchesY(m.value, pair.value) else { return false }
        }
        return true
    default: return false
    }
}
