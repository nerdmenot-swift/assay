// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Encoder differential: everything Assay writes, Foundation must accept.
//
// The round-trip law in docs/ENCODING.md is tested against Assay's OWN parser, which
// proves self-consistency and nothing more — a writer and reader that share a bug agree
// perfectly. This arm closes that: every document the encoder produces is handed to
// `JSONSerialization`, and the values it reads back are compared against the values
// Assay put in.
//
// The corpus is the JSON corpus, re-encoded: parse each file to `JSON.Value`, wrap it in
// an encodable schema, write it, and check Foundation reads the same thing.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore

@Schema(encodes: true)
struct EncodedEnvelope {
    var payload: RawValue
}

func runEncodeDifferential(corpus: URL) -> Int {
    var checked = 0
    guard let all = try? FileManager.default.contentsOfDirectory(
        at: corpus, includingPropertiesForKeys: nil) else { return 0 }

    for url in all.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("neg-") {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSON.Value.parse([UInt8](data)) else { continue }
        let name = url.lastPathComponent

        let envelope = EncodedEnvelope(payload: RawValue(value))
        let d = envelope.diagnoseEncode()
        guard d.isValid else {
            fail("encode: \(name) produced issues: \(d.issues.map(\.code.codeString))")
            continue
        }

        // 1. Foundation must accept the bytes at all. This is the check Assay's own
        //    parser cannot make — it is lenient in exactly the places Assay is.
        guard let theirs = try? JSONSerialization.jsonObject(
                with: Data(d.bytes), options: [.fragmentsAllowed]) as? [String: Any],
              let theirPayload = theirs["payload"] else {
            fail("encode: Foundation rejected Assay's own output for \(name)")
            continue
        }

        // 2. And must read back the same values.
        guard let mine = try? EncodedEnvelope.parse(json: d.bytes) else {
            fail("encode: Assay could not re-parse its own output for \(name)")
            continue
        }
        if !equivalentRaw(mine.payload, theirPayload) {
            fail("encode: \(name) round-tripped to a different value")
        }
        checked += 1
    }
    return checked
}

/// `RawValue` against Foundation's `Any` tree.
private func equivalentRaw(_ mine: RawValue, _ theirs: Any) -> Bool {
    switch mine {
    case .null:
        return theirs is NSNull
    case .bool(let b):
        guard let n = theirs as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            return false
        }
        return n.boolValue == b
    case .int(let i):
        guard let n = theirs as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            return false
        }
        return n.int64Value == i || n.doubleValue == Double(i)
    case .double(let d):
        guard let n = theirs as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            return false
        }
        return n.doubleValue == d
    case .string(let s):
        return (theirs as? String) == s
    case .sequence(let xs):
        guard let a = theirs as? [Any], a.count == xs.count else { return false }
        for (x, y) in zip(xs, a) where !equivalentRaw(x, y) { return false }
        return true
    case .mapping(let ms):
        guard let o = theirs as? [String: Any], o.count == ms.count else { return false }
        for m in ms {
            guard let v = o[m.key], equivalentRaw(m.value, v) else { return false }
        }
        return true
    }
}
