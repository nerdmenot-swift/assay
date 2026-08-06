// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// XML differential oracle: Assay's hand-written parser vs Foundation's XMLParser.
//
// Until this existed, the XML parser had exactly one guarantee — the fuzzer proved it did
// not crash — and nothing whatsoever checked that it parsed CORRECTLY. A parser that
// silently mis-reads valid input is worse than no parser, and "196 tests pass" says
// nothing about it when every one of those tests was written by the same person who wrote
// the parser and shares its blind spots.
//
// Foundation's XMLParser is a genuinely independent implementation (libxml2 on Linux,
// NSXMLParser on Darwin) written by other people from the same spec. Agreement between
// them is real evidence; agreement between a parser and its author's expectations is not.
//
// The comparison is on a FLATTENED EVENT STREAM rather than on trees, because that is the
// only shape both can produce. Four normalisations are applied, each for a stated reason,
// and each one is a place where a real disagreement could hide — so they are kept as
// narrow as possible:
//
//   1. ADJACENT TEXT IS MERGED. Foundation delivers character data in arbitrary chunks and
//      splits at entity boundaries; Assay produces one text node. Merging both sides makes
//      the comparison about content rather than chunking. This is the normalisation most
//      likely to hide a bug, so it merges only *directly adjacent* text.
//
//   2. TEXT THAT IS ENTIRELY WHITESPACE IS DROPPED, on both sides. Foundation reports
//      inter-element whitespace inconsistently depending on whether a DTD is present.
//      Losing it means this oracle cannot detect a whitespace-handling difference — stated
//      here rather than discovered later.
//
//   3. ATTRIBUTES ARE SORTED. Foundation hands back a Dictionary, which has no order, so
//      attribute ORDER IS NOT CHECKED BY THIS ORACLE. Assay preserves document order and
//      its own tests cover that.
//
// Namespace declarations need no normalisation at all: Assay consumes xmlns/xmlns:* into
// its scope stack exactly as Foundation does under shouldProcessNamespaces, so neither
// side reports them as attributes and the resolved URI is compared directly. That was
// worth checking rather than assuming — the first draft of this file normalised for a
// difference that does not exist.
//===----------------------------------------------------------------------===//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import AssayCore
import AssayXML

/// One step of a document, in the only vocabulary both parsers share.
enum XMLEvent: Equatable, CustomStringConvertible {
    case start(name: String, uri: String?, attributes: [String: String])
    case end(name: String, uri: String?)
    case text(String)
    case comment(String)
    case pi(target: String, data: String)

    var description: String {
        switch self {
        case .start(let n, let u, let a):
            let attrs = a.keys.sorted().map { "\($0)=\(a[$0]!)" }.joined(separator: " ")
            return "<\(n)\(u.map { "@\($0)" } ?? "")\(attrs.isEmpty ? "" : " " + attrs)>"
        case .end(let n, let u):   return "</\(n)\(u.map { "@\($0)" } ?? "")>"
        case .text(let t):         return "text(\(t))"
        case .comment(let c):      return "comment(\(c))"
        case .pi(let t, let d):    return "pi(\(t),\(d))"
        }
    }
}

// MARK: - Normalisation

/// On UNICODE SCALARS, not Characters: "\r\n" is a single Swift grapheme that equals
/// neither "\r" nor "\n", so a Character-wise check silently fails on CRLF input.
private func isBlank(_ t: String) -> Bool {
    t.unicodeScalars.allSatisfy { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
}

func normalise(_ events: [XMLEvent]) -> [XMLEvent] {
    var out: [XMLEvent] = []
    for e in events {
        if case .text(let t) = e {
            // Merge with a directly preceding text run, then drop if all whitespace.
            if case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + t)
            } else {
                out.append(.text(t))
            }
            continue
        }
        if case .text(let t)? = out.last, isBlank(t) {
            out.removeLast()
        }
        out.append(e)
    }
    if case .text(let t)? = out.last, isBlank(t) {
        out.removeLast()
    }
    return out
}

// MARK: - Assay's side

func assayEvents(_ bytes: [UInt8]) -> [XMLEvent]? {
    var sink = IssueSink(limits: .default)
    guard let doc = XML.decode(bytes, into: &sink, limits: .default), sink.isValid else {
        return nil
    }
    var out: [XMLEvent] = []
    // Foundation reports prolog comments and PIs (though not the XML declaration, which
    // Assay also excludes from `prolog`), so the comparison must include them.
    for node in doc.prolog {
        switch node {
        case .comment(let c):                      out.append(.comment(c))
        case .processingInstruction(let t, let d): out.append(.pi(target: t, data: d))
        default: break
        }
    }
    appendElement(doc.root, to: &out)
    return normalise(out)
}

/// Attributes are keyed `{uri}local` when namespaced, bare `local` when not — Clark
/// notation, so two attributes that differ only in namespace (n:k and k) cannot collide
/// in the dictionary. The Foundation side resolves its qName keys to the same form.
private func attributeKey(uri: String?, local: String) -> String {
    uri.map { "{\($0)}\(local)" } ?? local
}

private func appendElement(_ e: XML.Element, to out: inout [XMLEvent]) {
    var attrs: [String: String] = [:]
    for a in e.attributes {
        attrs[attributeKey(uri: a.name.namespaceURI, local: a.name.local)] = a.value
    }
    out.append(.start(name: e.name.local, uri: e.name.namespaceURI, attributes: attrs))
    for child in e.children {
        switch child {
        case .element(let sub):                appendElement(sub, to: &out)
        case .text(let t):                     out.append(.text(t))
        // Foundation reports CDATA as character data; the adjacent-text merge in
        // normalise() makes <r>a<![CDATA[b]]></r> compare equal on both sides.
        case .cdata(let t):                    out.append(.text(t))
        case .comment(let c):                  out.append(.comment(c))
        case .processingInstruction(let t, let d): out.append(.pi(target: t, data: d))
        }
    }
    out.append(.end(name: e.name.local, uri: e.name.namespaceURI))
}

// MARK: - Foundation's side

final class FoundationXMLCollector: NSObject, XMLParserDelegate {
    var events: [XMLEvent] = []
    var failed = false
    private var openURIs: [String?] = []
    /// prefix → stack of URIs, innermost last. Foundation resolves ELEMENT names itself
    /// under shouldProcessNamespaces, but hands attributes back keyed by qName — so
    /// attribute namespaces must be resolved here, from the mapping-prefix callbacks
    /// (which arrive before didStartElement and after didEndElement, bracketing exactly
    /// the region where the mapping is in scope).
    private var prefixScopes: [String: [String]] = [:]

    func parser(_ p: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
        prefixScopes[prefix, default: []].append(uri)
    }

    func parser(_ p: XMLParser, didEndMappingPrefix prefix: String) {
        _ = prefixScopes[prefix]?.popLast()
    }

    private func resolveAttribute(_ qName: String) -> String {
        guard let colon = qName.firstIndex(of: ":") else { return qName }
        let prefix = String(qName[..<colon])
        let local = String(qName[qName.index(after: colon)...])
        if prefix == "xml" { return "{http://www.w3.org/XML/1998/namespace}\(local)" }
        guard let uri = prefixScopes[prefix]?.last else { return qName }
        return "{\(uri)}\(local)"
    }

    func parser(_ p: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        // Foundation reports "" for no namespace in some configurations; normalise to nil.
        let uri = (namespaceURI?.isEmpty ?? true) ? nil : namespaceURI
        openURIs.append(uri)
        var attrs: [String: String] = [:]
        for (qName, value) in attributes { attrs[resolveAttribute(qName)] = value }
        events.append(.start(name: name, uri: uri, attributes: attrs))
    }

    func parser(_ p: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let uri = openURIs.popLast() ?? nil
        events.append(.end(name: name, uri: uri))
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        events.append(.text(s))
    }

    func parser(_ p: XMLParser, foundComment c: String) {
        events.append(.comment(c))
    }

    func parser(_ p: XMLParser, foundProcessingInstructionWithTarget t: String, data: String?) {
        events.append(.pi(target: t, data: data ?? ""))
    }

    func parser(_ p: XMLParser, foundCDATA block: Data) {
        events.append(.text(String(decoding: block, as: UTF8.self)))
    }

    func parser(_ p: XMLParser, parseErrorOccurred: any Error) { failed = true }
}

func foundationEvents(_ data: Data) -> [XMLEvent]? {
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    // True so the mapping-prefix callbacks fire — the collector needs them to resolve
    // attribute qNames, which Foundation does not resolve itself.
    parser.shouldReportNamespacePrefixes = true
    // Assay refuses external entities by construction; Foundation must be told to, or the
    // two would differ on documents that reach out to the network — and the oracle would
    // be reporting an XXE as a parser disagreement.
    parser.shouldResolveExternalEntities = false

    let collector = FoundationXMLCollector()
    parser.delegate = collector
    guard parser.parse(), !collector.failed else { return nil }
    return normalise(collector.events)
}

// MARK: - The comparison

struct XMLOracleResult {
    var agreed = 0
    var bothRejected = 0
    var assayOnlyRejected: [String] = []
    var foundationOnlyRejected: [String] = []
    var disagreed: [(name: String, detail: String)] = []
}

func runXMLDifferential(_ documents: [(name: String, text: String)]) -> XMLOracleResult {
    var r = XMLOracleResult()

    for (name, text) in documents {
        let data = Data(text.utf8)
        let mine = assayEvents([UInt8](text.utf8))
        let theirs = foundationEvents(data)

        switch (mine, theirs) {
        case (nil, nil):
            r.bothRejected += 1

        case (nil, .some):
            // Assay is stricter. Sometimes correct (it refuses XXE by construction), often
            // a gap. Reported separately rather than counted as agreement.
            r.assayOnlyRejected.append(name)

        case (.some, nil):
            // Assay accepted something Foundation rejected. This direction is the
            // dangerous one: it means Assay may be inventing structure for malformed input.
            r.foundationOnlyRejected.append(name)

        case (.some(let a), .some(let b)):
            if a == b {
                r.agreed += 1
            } else {
                r.disagreed.append((name, firstDifference(a, b)))
            }
        }
    }
    return r
}

/// The first differing event, with context. A diff of two 400-event streams is unreadable;
/// the first divergence is almost always the whole story.
func firstDifference(_ a: [XMLEvent], _ b: [XMLEvent]) -> String {
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : nil
        let y = i < b.count ? b[i] : nil
        if x != y {
            let context = i > 0 ? "after \(a[i - 1].description)" : "at the start"
            return "event \(i) \(context): Assay \(x?.description ?? "<end>")"
                + " vs Foundation \(y?.description ?? "<end>")"
        }
    }
    return "streams are equal but compared unequal"
}
