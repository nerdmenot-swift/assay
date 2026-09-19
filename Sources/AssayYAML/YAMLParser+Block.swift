// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Block collections: `- item` sequences and `key: value` mappings, indentation-scoped,
// including the merge key (`<<`). Split out of YAMLParser.swift on 2026-09-10; the parser
// is one recursive-descent struct and these are its extensions by concern.
//===----------------------------------------------------------------------===//

import AssayCore

extension YAML.Parser {

    // MARK: Block collections

    mutating func parseBlockSequence(
        _ r: inout AssayReader,
        _ sink: inout IssueSink,
        indent: Int,
        depth: Int
    ) -> YAML.Node? {
        var items: [YAML.Node] = []
        items.reserveCapacity(hints.items(at: depth))
        while true {
            skipBlanksAndComments(&r)
            if r.atEnd { break }
            let column = currentColumn(&r)
            if column < indent { break }
            if column > indent { break }
            guard r.currentByte == UInt8(ascii: "-"),
                  let next = r.byte(at: 1),
                  next == 0x20 || next == 0x0A || next == 0x0D else { break }

            r.advanceBy(1)
            skipInlineSpace(&r)

            // "-" alone on a line. The entry's value may still be a nested block
            // node on the following lines, indented past the dash (YAML 1.2 §8.2.1:
            // `-` is a block-sequence indicator, not a scalar terminator). Only when
            // the next content line is not more indented is the entry empty.
            if r.currentByte == 0x0A || r.currentByte == 0x0D || r.atEnd {
                skipBlanksAndComments(&r)
                if !r.atEnd, currentColumn(&r) > column {
                    let itemColumn = currentColumn(&r)
                    guard let item = parseNode(&r, &sink, indent: itemColumn - 1,
                                               depth: depth + 1) else { return nil }
                    items.append(item)
                } else {
                    items.append(.scalar(YAML.Scalar(content: "")))
                }
                continue
            }
            let itemColumn = currentColumn(&r)
            guard let item = parseNode(&r, &sink, indent: itemColumn - 1,
                                       depth: depth + 1) else { return nil }
            items.append(item)
        }
        hints.setItems(items.count, at: depth); return .sequence(items)
    }

    /// `- ` (or `-` at end of line): a block-sequence entry indicator. `---` is not one.
    mutating func isSequenceEntry(_ r: inout AssayReader) -> Bool {
        guard r.currentByte == UInt8(ascii: "-"), let next = r.byte(at: 1) else { return false }
        return next == 0x20 || next == 0x0A || next == 0x0D
    }

    mutating func parseBlockMapping(
        _ r: inout AssayReader,
        _ sink: inout IssueSink,
        indent: Int,
        depth: Int
    ) -> YAML.Node? {
        var pairs: [YAML.Pair] = []
        pairs.reserveCapacity(hints.members(at: depth))
        // Merge sources are collected and applied AFTER the mapping is complete.
        // Applying them inline would let `<<:` win over an explicit key that appears
        // later in the document, and YAML says the explicit key always wins
        // regardless of position.
        var mergeSources: [YAML.Node] = []
        while true {
            skipBlanksAndComments(&r)
            if r.atEnd { break }
            if atLineStart(&r), r.matches("---") || r.matches("...") { break }
            let column = currentColumn(&r)
            if column != indent { break }

            // Explicit key: "? key" then "\n: value"
            var key: YAML.Node
            if r.currentByte == UInt8(ascii: "?"),
               let n = r.byte(at: 1), n == 0x20 || n == 0x0A {
                r.advanceBy(1)
                skipInlineSpace(&r)
                guard let k = parseNode(&r, &sink, indent: column,
                                        depth: depth + 1) else { return nil }
                key = k
                skipBlanksAndComments(&r)
                guard r.currentByte == UInt8(ascii: ":") else {
                    r.report(&sink, .yamlExpectedValueIndicator)
                    return nil
                }
                r.advanceBy(1)
            } else {
                guard let k = parseKeyScalar(&r, &sink, depth: depth) else { return nil }
                key = k
                guard r.currentByte == UInt8(ascii: ":") else {
                    r.report(&sink, .yamlExpectedColon)
                    return nil
                }
                r.advanceBy(1)
            }

            skipInlineSpace(&r)

            // Value on the same line, or a nested block on following lines.
            //
            // The span is captured around the value parse and then trimmed, because
            // `parseNode` leaves the cursor past the value's trailing newline and any
            // blanks or comments after it. An untrimmed span would underline the rest
            // of the file, which is worse than no caret at all.
            let valueStart = r.byteOffset
            var value: YAML.Node
            if r.currentByte == nil || r.currentByte == 0x0A || r.currentByte == 0x0D
                || r.currentByte == UInt8(ascii: "#") {
                skipBlanksAndComments(&r)
                let nextColumn = currentColumn(&r)
                // A nested value is indented past the key — or is a block SEQUENCE at the
                // key's own column. YAML 1.2 §8.2.1 lets a mapping value's sequence sit at
                // the key's indentation ("indentless"), and it is how Kubernetes, GitHub
                // Actions and compose files are written. Only a sequence: a mapping at that
                // column is the next sibling key.
                //
                // Until 2026-09-19 this was `nextColumn <= indent` → empty, and the dash line
                // then went back to this loop as a KEY: `items:\n- a` was refused, and
                // `items:\n- name: x` parsed as `{items: "", "- name": "x"}`, which is not
                // YAML at all — a plain scalar cannot begin with "- ".
                if r.atEnd || nextColumn < indent
                    || (nextColumn == indent && !isSequenceEntry(&r)) {
                    value = .scalar(YAML.Scalar(content: ""))
                } else {
                    guard let v = parseNode(&r, &sink, indent: indent, depth: depth + 1,
                                            indentlessSequence: true) else { return nil }
                    value = v
                }
            } else {
                // Same line — which may still be only properties (`key: &a` or `key: !!seq`)
                // with the sequence itself indentless on the lines below.
                guard let v = parseNode(&r, &sink, indent: indent, depth: depth + 1,
                                        indentlessSequence: true) else { return nil }
                value = v
            }

            // Merge key. Applied, not preserved — YAML 1.1's `<<` is a directive to the
            // parser, and a consumer seeing a literal "<<" key would be wrong.
            if case .scalar(let ks) = key, ks.content == "<<", ks.tag == nil {
                mergeSources.append(value)
            } else {
                pairs.append(YAML.Pair(key: key, value: value,
                                  valueSpan: trimmedSpan(&r, from: valueStart)))
            }
        }
        for source in mergeSources { mergeInto(&pairs, from: source) }
        hints.setMembers(pairs.count, at: depth); return .mapping(pairs)
    }

    /// How many pairs a merge source would contribute, without merging it.
    static func mergedPairCount(_ value: YAML.Node) -> Int {
        switch value {
        case .mapping(let p): return p.count
        case .sequence(let xs):
            var n = 0
            for x in xs { if case .mapping(let p) = x { n += p.count } }
            return n
        default: return 0
        }
    }

    /// Where the merge stops scanning and starts hashing. See `mergeInto`.
    static var mergeSetThreshold: Int { 24 }

    /// `<<: *base` and `<<: [*a, *b]`. Earlier sources win, and an explicit key in the
    /// mapping always beats a merged one — which the set preserves, because a key is
    /// inserted the first time it is seen and every later duplicate is skipped.
    ///
    /// THE SET IS NOT AN OPTIMISATION, IT IS THE DIFFERENCE BETWEEN LINEAR AND QUADRATIC.
    /// This was `pairs.contains(where: { $0.key == p.key })` — a scan of every accumulated
    /// pair for every merged pair, so a mapping with n of its own keys merging n more cost
    /// O(n²) `YAML.Node` comparisons. Measured 2026-09-13: a 1 MB document with one `<<:`
    /// took **3.5 s**, against 5 ms for the same document with the merge line removed, and
    /// the time quadrupled for every doubling. Nothing saw it: the node count stays small,
    /// so neither the alias-expansion budget nor `maxDepth` fires, and the amplification
    /// tests cover alias bombs rather than merge width.
    ///
    /// `YAML.Node` is `Hashable`, and the set uses the same `==` the scan did, so this is
    /// the identical predicate rather than an approximation of it. Keys are almost always
    /// scalars; the hashing cost is the string hash the comparison would have done anyway.
    func mergeInto(_ pairs: inout [YAML.Pair], from value: YAML.Node) {
        // THRESHOLDED, because the first version of this fix was not and that was the same
        // mistake in the other direction. A config file's mapping has a handful of keys,
        // and building a `Set` for it is a heap allocation and a hash per key to replace
        // three or four pointer comparisons — exactly what `XMLParser`'s attribute comment
        // warns against. Trading the common case to fix the adversarial one is not a fix.
        //
        // Below the threshold: the original scan, allocation-free, byte-for-byte.
        // Above it: the set, and the quadratic goes away.
        let total = pairs.count + Self.mergedPairCount(value)
        guard total > Self.mergeSetThreshold else {
            func mergeSmall(_ node: YAML.Node) {
                guard case .mapping(let source) = node else { return }
                for p in source where !pairs.contains(where: { $0.key == p.key }) {
                    pairs.append(p)
                }
            }
            if case .sequence(let sources) = value {
                for s in sources { mergeSmall(s) }
            } else {
                mergeSmall(value)
            }
            return
        }

        var present = Set<YAML.Node>(minimumCapacity: total)
        for p in pairs { present.insert(p.key) }

        func merge(_ node: YAML.Node) {
            guard case .mapping(let source) = node else { return }
            for p in source where present.insert(p.key).inserted {
                pairs.append(p)
            }
        }
        if case .sequence(let sources) = value {
            for s in sources { merge(s) }
        } else {
            merge(value)
        }
    }

    /// A mapping key: quoted, flow collection, or a plain scalar up to the `:`.
    mutating func parseKeyScalar(
        _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
    ) -> YAML.Node? {
        if r.currentByte == UInt8(ascii: "[") {
            return parseFlowSequence(&r, &sink, depth: depth)
        }
        if r.currentByte == UInt8(ascii: "{") {
            return parseFlowMapping(&r, &sink, depth: depth)
        }
        if let q = r.currentByte, q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
            return parseQuoted(&r, &sink)
        }
        let start = r.byteOffset
        var end = start
        while let c = r.currentByte {
            if c == 0x0A { break }
            if c == UInt8(ascii: ":") {
                let n = r.byte(at: 1)
                if n == nil || n == 0x20 || n == 0x0A || n == 0x0D { break }
            }
            r.advanceBy(1)
            if c != 0x20 && c != 0x09 { end = r.byteOffset }
        }
        return .scalar(YAML.Scalar(content: r.string(from: start, to: end)))
    }
}
