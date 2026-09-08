// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The XML property list flavour, projected onto `RawValue`.
//
// This one IS mostly a projection, which is why it is a fifth the size of `BinaryPlist.swift`
// — and the contrast is the point `ROADMAP.md` §10 missed when it called plists "mechanically
// the smallest item on this list". One of the two flavours is; the other is a random-access
// object graph with two amplification attacks.
//
// IT REUSES `AssayXML`'s PARSER rather than shipping a second one. That parser already
// refuses XXE by construction — no external entity resolution, no DTD subset processing — and
// an XML plist carries a `<!DOCTYPE ... SYSTEM "http://www.apple.com/DTDs/PropertyList-1.0.dtd">`
// on essentially every document ever written. A plist reader that fetched that URL would be
// the textbook XXE, and the refusal is inherited rather than reimplemented.
//
// THE TYPE MAPPING, which differs from the generic XML projection and has to. `AssayXML`'s
// `RawValue(XML.Document)` maps elements to keys; a plist's elements are TYPE TAGS and its
// keys live in `<key>` siblings, so the generic projection would produce `{"key": ..., "string":
// ...}` — structurally valid and semantically nothing. The two mappings cannot be shared.
//
//   <true/> <false/>   -> .bool
//   <integer>          -> .int      (refuses what does not fit Int64, rather than saturating)
//   <real>             -> .double
//   <string>           -> .string
//   <data>             -> .string, base64 — the SAME spelling the binary flavour produces,
//                         so a document round-tripped between flavours decodes identically
//   <date>             -> .string, the ISO-8601 text as written. NOT the binary flavour's
//                         seconds-since-2001 double, and that asymmetry is deliberate: each
//                         flavour yields what it actually stores. Converting either one would
//                         mean picking an epoch in a Foundation-free core. `docs/PLIST.md`.
//   <array> <dict>     -> .sequence, .mapping
//
// `<dict>` is `<key>` and value strictly alternating. A `<key>` with no value, or a value with
// no `<key>`, is a malformed document and says so — Foundation's own reader is lenient here,
// and being lenient about which value belongs to which key is not a leniency worth having.
//===----------------------------------------------------------------------===//

public import Assay
public import AssayCore
public import AssayXML

enum XMLPlist {

    static func decode(
        _ bytes: [UInt8], into sink: inout IssueSink, limits: Limits
    ) -> RawValue? {
        guard let doc = XML.decode(bytes, into: &sink, limits: limits), sink.isValid else {
            return nil
        }
        let root = doc.root
        // `<plist version="1.0">` wraps exactly one value. A bare `<dict>` root also occurs
        // in the wild (Apple's own tooling emits it in places), so both are accepted.
        let top: XML.Element
        if root.name.local == "plist" {
            let children = root.children.compactMap { child -> XML.Element? in
                if case .element(let e) = child { return e }
                return nil
            }
            guard children.count == 1 else {
                sink.add(Issue(code: .custom("plist_bad_root"), params: ["reason": .string(
                    "<plist> must contain exactly one value, found \(children.count)")]))
                return nil
            }
            top = children[0]
        } else {
            top = root
        }
        return value(top, depth: 0, into: &sink, limits: limits)
    }

    private static func value(
        _ e: XML.Element, depth: Int, into sink: inout IssueSink, limits: Limits
    ) -> RawValue? {
        guard depth <= limits.maxDepth else {
            sink.add(Issue(code: .custom("plist_too_deep"),
                           params: ["maxDepth": .int(limits.maxDepth)]))
            return nil
        }

        func bad(_ reason: String, _ code: String = "plist_bad_value") -> RawValue? {
            sink.add(Issue(code: .custom(code), params: ["reason": .string(reason)]))
            return nil
        }

        switch e.name.local {
        case "true":    return .bool(true)
        case "false":   return .bool(false)
        case "string":  return .string(text(e))
        case "key":     return .string(text(e))

        case "integer":
            let t = text(e).trimmedPlistText
            guard let n = Int64(t) else {
                // Not saturated, not truncated. A number read as a different number is the
                // one failure a decoder must never have.
                return bad("'\(t)' is not an integer this decoder can represent",
                           "plist_int_out_of_range")
            }
            return .int(n)

        case "real":
            let t = text(e).trimmedPlistText
            guard let d = Double(t) else { return bad("'\(t)' is not a real number") }
            return .double(d)

        case "data":
            // Validated rather than passed through: `<data>` whose contents are not base64
            // is a malformed document, and handing the caller a string that looks like data
            // and is not would move the failure somewhere it cannot be explained.
            let t = text(e)
            guard Base64.decode(t) != nil else { return bad("<data> is not valid base64") }
            var packed = ""
            packed.reserveCapacity(t.utf8.count)
            for ch in t where !ch.isWhitespace { packed.append(ch) }
            return .string(packed)

        case "date":
            return .string(text(e).trimmedPlistText)

        case "array":
            var out: [RawValue] = []
            for child in e.children {
                guard case .element(let c) = child else { continue }
                guard let v = value(c, depth: depth + 1, into: &sink, limits: limits) else {
                    return nil
                }
                out.append(v)
            }
            return .sequence(out)

        case "dict":
            var members: [RawValue.Member] = []
            var pendingKey: String?
            for child in e.children {
                guard case .element(let c) = child else { continue }
                if c.name.local == "key" {
                    guard pendingKey == nil else {
                        return bad("two <key> elements in a row inside <dict>",
                                   "plist_unpaired_key")
                    }
                    pendingKey = text(c)
                    continue
                }
                guard let k = pendingKey else {
                    return bad("<\(c.name.local)> inside <dict> with no <key> before it",
                               "plist_unpaired_key")
                }
                pendingKey = nil
                guard let v = value(c, depth: depth + 1, into: &sink, limits: limits) else {
                    return nil
                }
                members.append(.init(key: k, value: v))
            }
            guard pendingKey == nil else {
                return bad("a trailing <key> with no value", "plist_unpaired_key")
            }
            return .mapping(members)

        default:
            return bad("<\(e.name.local)> is not a property-list type", "plist_bad_marker")
        }
    }

    /// Concatenated character data, ignoring comments and nested elements. A plist leaf holds
    /// text and nothing else, so anything else in one is already a malformed document — and
    /// the enclosing switch has better context to say so than this does.
    private static func text(_ e: XML.Element) -> String {
        var out = ""
        for child in e.children {
            if case .text(let t) = child { out += t }
        }
        return out
    }
}

extension String {
    /// Leading and trailing whitespace, dropped. `<integer> 42 </integer>` is common enough in
    /// hand-edited files to be worth accepting; no Foundation here, so it is written out.
    var trimmedPlistText: String {
        var s = Substring(self)
        while let f = s.first, f.isWhitespace { s = s.dropFirst() }
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
