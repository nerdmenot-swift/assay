// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// YAML and XML timing. Until this existed every published Assay number was JSON, and the
// honest sentence was "the YAML and XML parsers are verified correct and nothing is known
// about their speed".
//
// THE JSON THESIS DOES NOT TRANSFER, and these numbers must not be read through it. The
// 5-9x JSON ratios come from deleting the Codable container boundary at compile time.
// The YAML and XML paths build a node tree first and decode structs from `RawValue` — a
// tree walk, not a fused decode — so there is no boundary being deleted and no
// architectural reason to expect JSON-sized margins. These rows exist to catch
// pathologies and to place Assay against what a Swift project would otherwise use:
//
//   YAML baseline: Yams — the ecosystem's YAML library, wrapping libyaml (C). Two rows:
//     * node parse:    YAML.parse vs Yams.compose      (tree vs tree, neither resolves)
//     * struct decode: T.parse(yaml:) vs YAMLDecoder   (macro+RawValue vs Codable)
//   XML baseline: Foundation's XMLParser, with a counting delegate. Assay builds a full
//     tree with attributes and namespace resolution; the Foundation side only counts
//     events and sums text bytes, WHICH FAVOURS FOUNDATION — it does strictly less work
//     than any consumer that keeps the document. Stated here rather than discovered in a
//     footnote. shouldProcessNamespaces is left false (cheaper for Foundation; the
//     rendered corpus has no namespaces). There is no XML struct-decode row because
//     Foundation has no Codable XML decoder to compare against.
//
// The corpus is the apimodel JSON ladder re-rendered by CorpusRender — the same bytes
// DiffFuzz verifies against libyaml and Foundation before this file ever times them.
// Correctness first: every row is gated on both sides producing the same shape.
//===----------------------------------------------------------------------===//

import Foundation
// Foundation's XMLParser lives in a separate module off Darwin. Importing it conditionally
// is what lets this file — and therefore every published YAML/XML ratio — run on Linux.
#if canImport(FoundationXML)
import FoundationXML
#endif
import Assay
import AssayYAML
import AssayXML
import CorpusRender
import Yams

// The same shape as `Payload`/`Item`, with the RawValue decode path emitted. A separate
// declaration so the JSON arm keeps measuring exactly what `formats: .json` emits.
@Schema(keys: .snakeCase, formats: .all)
struct RawItem {
    var id: String
    var sequence: Int
    var name: String
    var description: String
    var createdAt: String
    var updatedAt: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    var ownerId: String
}

@Schema(keys: .snakeCase, formats: .all)
struct RawPayload {
    var requestId: String
    var generatedAt: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [RawItem]
}

private final class CountingXMLDelegate: NSObject, XMLParserDelegate {
    var starts = 0
    var attributes = 0
    var textBytes = 0
    func parser(_ p: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String] = [:]) {
        starts += 1
        attributes += attrs.count
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { textBytes += s.utf8.count }
}

private func elementCount(_ e: XML.Element) -> Int {
    1 + e.children.reduce(0) {
        if case .element(let sub) = $1 { return $0 + elementCount(sub) }
        return $0
    }
}

func runFormatBenchmarks(corpusDir: URL, sizes: [String]) {
    struct Doc {
        let size: String
        let yamlText: String
        let yamlBytes: [UInt8]
        let xmlText: String
        let xmlBytes: [UInt8]
    }
    var docs: [Doc] = []
    for size in sizes {
        let url = corpusDir.appendingPathComponent("apimodel-\(size).json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSON.Value.parse([UInt8](data)) else { continue }
        let raw = RawValue(value)
        var yaml = renderYAML(raw)
        if yaml.hasPrefix("\n") { yaml.removeFirst() }
        let xml = renderXML(raw)
        docs.append(Doc(size: size, yamlText: yaml, yamlBytes: Array(yaml.utf8),
                        xmlText: xml, xmlBytes: Array(xml.utf8)))
    }
    guard !docs.isEmpty else {
        print("format bench: no corpus — run: swift run -c release CorpusGen")
        return
    }

    func table(_ title: String, _ note: String, baseline: String,
               rows: (Doc) -> (bytes: Int, theirs: Double, mine: Double)?) {
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
            print(pad(doc.size, 10, right: true) + pad("\(r.bytes)", 10)
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
    print("YAML and XML — the tree-decode paths. READ THE HEADER OF Formats.swift:")
    print("no Codable boundary is deleted here, so the JSON thesis does not apply and")
    print("JSON-sized ratios should not be expected. Correctness of both parsers against")
    print("these exact documents is DiffFuzz's job and runs in the same CI.")

    table("YAML node parse — YAML.parse vs Yams.compose",
          "Tree vs tree; neither side resolves scalars. Yams crosses into libyaml (C).",
          baseline: "Yams") { doc in
        guard (try? YAML.parse(doc.yamlBytes)) != nil,
              (try? Yams.compose(yaml: doc.yamlText)) != nil else { return nil }
        let iters = max(200, iterationCount(forBytes: doc.yamlBytes.count) / 5)
        let theirs = measure(iterations: iters) { _ = try? Yams.compose(yaml: doc.yamlText) }
        let mine = measure(iterations: iters) { _ = try? YAML.parse(doc.yamlBytes) }
        return (doc.yamlBytes.count, theirs, mine)
    }

    table("YAML struct decode — T.parse(yaml:) vs Yams' YAMLDecoder (Codable)",
          "The comparison a migrating project would actually make.",
          baseline: "YAMLDecoder") { doc in
        let decoder = YAMLDecoder()
        // Gate: same items, same fields, or the row is a lie.
        guard let mine = try? RawPayload.parse(yaml: doc.yamlBytes),
              let theirs = try? decoder.decode(CodablePayload.self, from: doc.yamlText),
              mine.items.count == theirs.items.count,
              mine.requestId == theirs.request_id,
              mine.items.first?.id == theirs.items.first?.id else { return nil }
        let iters = max(200, iterationCount(forBytes: doc.yamlBytes.count) / 5)
        let t = measure(iterations: iters) {
            _ = try? decoder.decode(CodablePayload.self, from: doc.yamlText)
        }
        let m = measure(iterations: iters) { _ = try? RawPayload.parse(yaml: doc.yamlBytes) }
        return (doc.yamlBytes.count, t, m)
    }

    table("XML tree parse — XML.parse vs Foundation XMLParser (counting delegate)",
          "ASYMMETRIC in Foundation's favour: Assay builds and keeps the whole tree;"
          + "\nFoundation only counts events. A parser instance per iteration is Foundation's"
          + "\nown requirement, not a handicap added here.",
          baseline: "Foundation") { doc in
        // Gate: Foundation must see exactly as many element starts as Assay's tree holds.
        guard let mine = try? XML.parse(doc.xmlBytes) else { return nil }
        let counter = CountingXMLDelegate()
        let gate = XMLParser(data: Data(doc.xmlBytes))
        gate.delegate = counter
        guard gate.parse(), counter.starts == elementCount(mine.root) else { return nil }
        let data = Data(doc.xmlBytes)
        let iters = max(200, iterationCount(forBytes: doc.xmlBytes.count) / 5)
        let t = measure(iterations: iters) {
            let d = CountingXMLDelegate()
            let p = XMLParser(data: data)
            p.delegate = d
            _ = p.parse()
        }
        let m = measure(iterations: iters) { _ = try? XML.parse(doc.xmlBytes) }
        return (doc.xmlBytes.count, t, m)
    }
}
