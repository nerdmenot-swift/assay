// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Where the time actually goes — the measurement that gates phases 4 and 5.
//
// `docs/PERFORMANCE.md` §14 makes SIMD (phase 4) and C (phase 5) conditional on numbers,
// and this is the number they are conditional on. Amdahl, applied honestly: the most a
// vectorised UTF-8 validator can win is the share of decode time that validator occupies,
// so measuring that share bounds the entire SIMD/C opportunity before a line of it is
// written.
//
// Three timings over the same bytes:
//
//   validate  — UTF8Validation.firstInvalid alone, the one whole-buffer pass. THIS is
//               the part a SIMD kernel replaces; simdjson's stage 1 is essentially this
//               plus structural indexing.
//   scan      — JSON.Value.parse: validation + the byte scanner + a tree, but no macro
//               and no Codable boundary.
//   decode    — the full @Schema decode, which is what a user actually pays.
//
// Reported as shares of `decode`, because a ratio against Foundation says nothing about
// where Assay's own remaining time sits.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore

func runDecompositionBenchmarks(corpusDir: URL, sizes: [String]) {
    print("")
    print("Where decode time goes — the measurement that gates SIMD (phase 4) and C (5)")
    print("Amdahl: a vectorised validator cannot win more than the validate share below.")
    print(pad("shape", 18, right: true) + pad("size", 7) + pad("decode ns", 12)
          + pad("validate", 11) + pad("val %", 8) + pad("scan ns", 11) + pad("scan %", 8))
    print(String(repeating: "-", count: 76))

    var validateShares: [Double] = []

    // apimodel is the API-shaped arm the falsification condition used; short-strings and
    // long-strings bracket the String-construction axis, which is where the profile says
    // Assay's own time concentrates.
    for shape in ["apimodel", "short-strings", "long-strings", "floats-dense"] {
        for size in ["8k", "64k"] {
            let url = corpusDir.appendingPathComponent("\(shape)-\(size).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let bytes = [UInt8](data)
            let iters = max(400, iterationCount(forBytes: bytes.count))

            // Validation alone. Held live through a checksum so it cannot be optimised out.
            var sink = 0
            let vNs = measure(iterations: iters) {
                bytes.withUnsafeBufferPointer { buf in
                    if let b = buf.baseAddress {
                        sink &+= unsafe UTF8Validation.firstInvalid(b, buf.count) ?? 1
                    }
                }
            }
            precondition(sink >= 0)

            let sNs = measure(iterations: iters) { _ = try? JSON.Value.parse(bytes) }

            // The full decode, on whichever schema this shape fits.
            let dNs: Double
            switch shape {
            case "apimodel":
                guard Payload.diagnose(json: bytes).value != nil else { continue }
                dNs = measure(iterations: iters) { _ = Payload.diagnose(json: bytes).value }
            case "floats-dense":
                guard Polygon.diagnose(json: bytes).value != nil else { continue }
                dNs = measure(iterations: iters) { _ = Polygon.diagnose(json: bytes).value }
            default:
                guard StringPrefix.diagnose(json: bytes).value != nil else { continue }
                dNs = measure(iterations: iters) { _ = StringPrefix.diagnose(json: bytes).value }
            }

            let vPct = vNs / dNs * 100
            let sPct = sNs / dNs * 100
            validateShares.append(vPct)
            print(pad(shape, 18, right: true) + pad(size, 7)
                  + pad(String(format: "%.0f", dNs), 12)
                  + pad(String(format: "%.0f", vNs), 11)
                  + pad(String(format: "%.1f%%", vPct), 8)
                  + pad(String(format: "%.0f", sNs), 11)
                  + pad(String(format: "%.0f%%", sPct), 8))
        }
    }

    guard !validateShares.isEmpty else { return }
    let mean = validateShares.reduce(0, +) / Double(validateShares.count)
    let hi = validateShares.max()!
    print(String(format: "UTF-8 validation is %.1f%% of decode on average, %.1f%% at worst.",
                 mean, hi))
    print("")
    print("Reading this as a gate: a PERFECT vectorised validator — zero cost, not merely")
    print(String(format: "faster — would improve end-to-end decode by at most %.1f%%. A realistic", hi))
    print(String(format: "4x validator wins about %.1f%%. That is the ceiling on phase 4's", hi * 0.75))
    print("headline win for schema decoding, measured rather than assumed.")
    print("The prefix/skip and value-model paths spend a larger share here and would")
    print("benefit more; the struct path, which is the product, would not.")
}
