// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// XML encoder differential: everything Assay writes, Foundation must accept.
//
// The library's round-trip tests check Assay's writer against Assay's own reader, which
// proves self-consistency and nothing more. This asks the question only an independent
// parser can answer: **is this well-formed XML?** Escaping, attribute-value
// normalisation, empty-element form and name validity are all places where a writer and
// reader that share an assumption agree perfectly and both are wrong.
//
// Scope, stated rather than implied: this checks WELL-FORMEDNESS and element structure,
// not value equality. XML has no type system, so a JSON-derived value cannot round-trip
// through XML exactly — arrays become repeated siblings that re-project as repeated keys,
// and every scalar becomes text. Claiming value equality here would be claiming something
// the format cannot deliver.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore
import AssayXML

@Schema(coerceScalars: true, formats: .all, encodes: true)
struct XmlEnvelope {
    var payload: RawValue
}

private final class CountingDelegate: NSObject, XMLParserDelegate {
    var elements = 0
    var failed: String?
    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        elements += 1
    }
    func parser(_ p: XMLParser, parseErrorOccurred e: any Error) {
        if failed == nil { failed = String(describing: e) }
    }
}

func runXMLEncodeDifferential(corpus: URL) -> Int {
    var checked = 0
    guard let all = try? FileManager.default.contentsOfDirectory(
        at: corpus, includingPropertiesForKeys: nil) else { return 0 }

    for url in all.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("neg-") {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSON.Value.parse([UInt8](data)) else { continue }
        let name = url.lastPathComponent

        let envelope = XmlEnvelope(payload: RawValue(value))
        let d = envelope.diagnoseEncodeXML()
        guard d.isValid else {
            fail("xml-encode: \(name) produced issues: \(d.issues.map(\.code.codeString))")
            continue
        }

        // 1. Foundation must accept it — the check Assay's own parser cannot make.
        let delegate = CountingDelegate()
        let parser = XMLParser(data: Data(d.bytes))
        parser.delegate = delegate
        guard parser.parse(), delegate.failed == nil else {
            fail("xml-encode: Foundation rejected Assay's own XML for \(name): "
                 + (delegate.failed ?? "unknown"))
            continue
        }

        // 2. Assay must read its own output back, and see the same element count
        //    Foundation did — structure preserved, whatever the types became.
        guard let reparsed = try? XML.parse(d.bytes) else {
            fail("xml-encode: Assay could not re-parse its own XML for \(name)")
            continue
        }
        let mine = countElements(reparsed.root)
        if mine != delegate.elements {
            fail("xml-encode: \(name) — Assay sees \(mine) elements, Foundation \(delegate.elements)")
        }
        checked += 1
    }
    return checked
}

private func countElements(_ e: XML.Element) -> Int {
    1 + e.children.reduce(0) { acc, c in
        if case .element(let sub) = c { return acc + countElements(sub) }
        return acc
    }
}
