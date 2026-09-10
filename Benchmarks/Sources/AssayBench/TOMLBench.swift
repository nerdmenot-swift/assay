// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// TOML timing, against toml++ through TOMLKit — the library a Swift project would
// otherwise use, and a C++ parser underneath. Same caveat as Formats.swift: this is a
// tree decoder, no Codable boundary is deleted, and the JSON thesis does not apply.
//
//   node parse:    TOML.parse vs TOMLTable(string:)       (tree vs tree)
//   struct decode: T.parse(toml:) vs TOMLDecoder (Codable) (macro+RawValue vs Codable)
//
// The corpus is the apimodel ladder rendered with `[[items]]` sections — the shape a
// real document has — and DiffFuzz verifies both parsers agree on these exact bytes
// before they are timed.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayTOML
import CorpusRender
import TOMLKit

func runTOMLBenchmarks(corpusDir: URL, sizes: [String]) {
    struct Doc {
        let size: String
        let text: String
        let bytes: [UInt8]
    }
    var docs: [Doc] = []
    for size in sizes {
        let url = corpusDir.appendingPathComponent("apimodel-\(size).json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSON.Value.parse([UInt8](data)),
              let text = renderTOML(RawValue(value), sections: true) else { continue }
        docs.append(Doc(size: size, text: text, bytes: Array(text.utf8)))
    }
    guard !docs.isEmpty else {
        print("toml bench: no corpus — run: swift run -c release CorpusGen")
        return
    }

    func table(_ title: String, _ note: String, baseline: String,
               rows: (Doc) -> (theirs: Double, mine: Double)?) {
        print("")
        print(title)
        print(note)
        print(pad("size", 10, right: true) + pad("bytes", 10) + pad("\(baseline) ns", 15)
              + pad("Assay ns", 13) + pad("ratio", 10))
        print(String(repeating: "-", count: 62))
        var ratios: [Double] = []
        for doc in docs {
            guard let r = rows(doc) else { continue }
            let ratio = r.theirs / r.mine
            ratios.append(ratio)
            print(pad(doc.size, 10, right: true) + pad("\(doc.bytes.count)", 10)
                  + pad(String(format: "%.0f", r.theirs), 15)
                  + pad(String(format: "%.0f", r.mine), 13)
                  + pad(String(format: "%.2fx", ratio), 10))
        }
        if !ratios.isEmpty {
            print(String(format: "mean %.2fx over %d sizes",
                         ratios.reduce(0, +) / Double(ratios.count), ratios.count))
        }
    }

    print("")
    print("TOML — a tree-decode path; see the header of TOMLBench.swift. toml++ is C++")
    print("reached through TOMLKit's wrapper, so its node-parse row includes that crossing.")

    table("TOML node parse — TOML.parse vs TOMLTable(string:) (toml++)",
          "Tree vs tree.", baseline: "toml++") { doc in
        guard let mine = try? TOML.parse(doc.bytes),
              let theirs = try? TOMLTable(string: doc.text),
              mine["items"]?.array?.count == theirs["items"]?.array?.count else { return nil }
        let iters = max(200, iterationCount(forBytes: doc.bytes.count) / 5)
        let t = measure(iterations: iters) { _ = try? TOMLTable(string: doc.text) }
        let m = measure(iterations: iters) { _ = try? TOML.parse(doc.bytes) }
        return (t, m)
    }

    table("TOML struct decode — T.parse(toml:) vs TOMLKit's TOMLDecoder (Codable)",
          "The comparison a migrating project would actually make.",
          baseline: "TOMLDecoder") { doc in
        let decoder = TOMLDecoder()
        guard let mine = try? RawPayload.parse(toml: doc.bytes),
              let theirs = try? decoder.decode(CodablePayload.self, from: doc.text),
              mine.items.count == theirs.items.count,
              mine.requestId == theirs.request_id,
              mine.items.first?.id == theirs.items.first?.id else { return nil }
        let iters = max(200, iterationCount(forBytes: doc.bytes.count) / 5)
        let t = measure(iterations: iters) {
            _ = try? decoder.decode(CodablePayload.self, from: doc.text)
        }
        let m = measure(iterations: iters) { _ = try? RawPayload.parse(toml: doc.bytes) }
        return (t, m)
    }
}
