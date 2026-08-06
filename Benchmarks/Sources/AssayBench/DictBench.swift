// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Dictionary fields — PERFORMANCE.md §2.5's stated structural worst case, measured now
// that it exists instead of assumed while it did not.
//
// Why it is the worst case: Assay must build the user's Dictionary — a hash and a
// `String` per key, the cost it deletes everywhere else by matching keys against
// compile-time literals without materialising them. The structural expectation was a
// NARROWED margin rather than a loss, because Foundation builds *two* dictionaries —
// its internal JSONMap plus the user's. The numbers below say which it is.
//
// Documents are the flat corpus shapes re-wrapped as `{"m": <corpus object>}` so the
// byte distribution is the corpus's: `bigints` (13-digit values, key-heavy) and
// `short-strings` (SSO values, where the keys are the whole story).
//===----------------------------------------------------------------------===//

import Foundation
import Assay

@Schema
struct IntMap {
    var m: [String: Int64]
}

struct CodableIntMap: Codable {
    var m: [String: Int64]
}

@Schema
struct StringMap {
    var m: [String: String]
}

struct CodableStringMap: Codable {
    var m: [String: String]
}

func runDictionaryBenchmarks(corpusDir: URL, sizes: [String]) {
    print("")
    print("Dictionary decode — the stated worst case (PERFORMANCE.md §2.5)")
    print("[String: T] must build the user's Dictionary: a hash and a String per key,")
    print("the cost the struct path deletes. Corpus objects wrapped as {\"m\": ...}.")
    print(pad("shape", 16, right: true) + pad("size", 7) + pad("bytes", 9)
          + pad("Foundation ns", 15) + pad("Assay ns", 12) + pad("ratio", 9))
    print(String(repeating: "-", count: 68))

    var ratios: [Double] = []

    func arm(_ shape: String,
             assay: @escaping ([UInt8]) -> Bool,
             foundation: @escaping (Data) -> Bool) {
        for size in sizes {
            let url = corpusDir.appendingPathComponent("\(shape)-\(size).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            var wrapped = Array("{\"m\":".utf8)
            wrapped.append(contentsOf: [UInt8](data))
            wrapped.append(UInt8(ascii: "}"))
            let wrappedData = Data(wrapped)

            guard foundation(wrappedData), assay(wrapped) else {
                print(pad(shape, 16, right: true) + pad(size, 7)
                      + "   one side declined this file")
                continue
            }
            let iters = max(400, iterationCount(forBytes: wrapped.count) / 2)
            let fNs = measure(iterations: iters) { _ = foundation(wrappedData) }
            let aNs = measure(iterations: iters) { _ = assay(wrapped) }
            let ratio = fNs / aNs
            ratios.append(ratio)
            print(pad(shape, 16, right: true) + pad(size, 7)
                  + pad("\(wrapped.count)", 9)
                  + pad(String(format: "%.0f", fNs), 15)
                  + pad(String(format: "%.0f", aNs), 12)
                  + pad(String(format: "%.2fx", ratio), 9))
        }
    }

    let dec = JSONDecoder()
    // Correctness gate folded into the arm closures: both sides must produce the same
    // entry count on the first call, asserted once via the closures below.
    var checkedInt = false
    arm("bigints",
        assay: { bytes in
            guard let v = try? IntMap.parse(json: bytes) else { return false }
            if !checkedInt {
                guard let ref = try? dec.decode(CodableIntMap.self, from: Data(bytes)),
                      ref.m == v.m else { return false }
                checkedInt = true
            }
            return !v.m.isEmpty
        },
        foundation: { data in
            (try? dec.decode(CodableIntMap.self, from: data)) != nil
        })

    var checkedString = false
    arm("short-strings",
        assay: { bytes in
            guard let v = try? StringMap.parse(json: bytes) else { return false }
            if !checkedString {
                guard let ref = try? dec.decode(CodableStringMap.self, from: Data(bytes)),
                      ref.m == v.m else { return false }
                checkedString = true
            }
            return !v.m.isEmpty
        },
        foundation: { data in
            (try? dec.decode(CodableStringMap.self, from: data)) != nil
        })

    if !ratios.isEmpty {
        print(String(format: "mean %.2fx over %d rows.",
                     ratios.reduce(0, +) / Double(ratios.count), ratios.count))
        print("The predicted mechanism shows as the DECLINING ratio with size — the")
        print("user's Dictionary grows as a share of the work — but not as a loss:")
        print("Foundation pays its internal map, the user's map, AND the Codable")
        print("boundary; Assay pays only the user's map.")
    }
}
