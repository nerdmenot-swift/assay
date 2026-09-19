// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Flow collections: `[a, b]` and `{k: v}`, with the alias budget charged the same way the
// block forms charge it (an alias bomb is an alias bomb in either style).
//===----------------------------------------------------------------------===//

import AssayCore

extension YAML.Parser {

    // MARK: Flow collections

    mutating func parseFlowSequence(
        _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
    ) -> YAML.Node? {
        guard depth < limits.maxDepth else {
            r.report(&sink, .depthExceeded); return nil
        }
        r.advanceBy(1)                                   // [
        var items: [YAML.Node] = []
        items.reserveCapacity(hints.items(at: depth))
        while true {
            skipBlanksAndComments(&r)
            guard let c = r.currentByte else {
                r.report(&sink, .yamlUnterminatedFlowSequence)
                return nil
            }
            if c == UInt8(ascii: "]") { r.advanceBy(1); break }

            // Zero-progress guard. A plain flow scalar terminates on , ] } and
            // newline WITHOUT consuming the terminator, so a stray "}" here yields an
            // empty scalar and no advance — and the loop spins forever appending
            // nothing. `[}]` used to hang the parser until the OOM killer arrived.
            // Found by the fuzzer; this is exactly the class it exists to catch.
            let before = r.byteOffset
            guard let item = parseFlowNode(&r, &sink, depth: depth + 1) else { return nil }
            guard r.byteOffset > before else {
                r.report(&sink, .yamlUnexpectedInFlow)
                return nil
            }
            items.append(item)

            skipBlanksAndComments(&r)
            // The separator is not optional: after an item only "," or "]" is legal.
            // Falling through on anything else was the other half of the hang.
            switch r.currentByte {
            case UInt8(ascii: ","): r.advanceBy(1)
            case UInt8(ascii: "]"): r.advanceBy(1); hints.setItems(items.count, at: depth); return .sequence(items)
            case nil:
                r.report(&sink, .yamlUnterminatedFlowSequence)
                return nil
            default:
                r.report(&sink, .yamlUnexpectedInFlow)
                return nil
            }
        }
        hints.setItems(items.count, at: depth); return .sequence(items)
    }

    mutating func parseFlowMapping(
        _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
    ) -> YAML.Node? {
        guard depth < limits.maxDepth else {
            r.report(&sink, .depthExceeded); return nil
        }
        r.advanceBy(1)                                   // {
        var pairs: [YAML.Pair] = []
        pairs.reserveCapacity(hints.members(at: depth))
        var mergeSources: [YAML.Node] = []
        while true {
            skipBlanksAndComments(&r)
            guard let c = r.currentByte else {
                r.report(&sink, .yamlUnterminatedFlowMapping)
                return nil
            }
            if c == UInt8(ascii: "}") { r.advanceBy(1); break }

            let keyStart = r.byteOffset
            guard let key = parseFlowNode(&r, &sink, depth: depth + 1) else { return nil }
            guard r.byteOffset > keyStart else {
                r.report(&sink, .yamlUnexpectedInFlow)
                return nil
            }
            skipBlanksAndComments(&r)
            guard r.currentByte == UInt8(ascii: ":") else {
                r.report(&sink, .yamlExpectedColon)
                return nil
            }
            r.advanceBy(1)
            skipBlanksAndComments(&r)
            let valueStart = r.byteOffset
            guard let value = parseFlowNode(&r, &sink, depth: depth + 1) else { return nil }

            if case .scalar(let ks) = key, ks.content == "<<" {
                mergeSources.append(value)
            } else {
                pairs.append(YAML.Pair(key: key, value: value,
                                  valueSpan: trimmedSpan(&r, from: valueStart)))
            }

            skipBlanksAndComments(&r)
            switch r.currentByte {
            case UInt8(ascii: ","): r.advanceBy(1)
            case UInt8(ascii: "}"):
                r.advanceBy(1)
                for source in mergeSources { mergeInto(&pairs, from: source) }
                hints.setMembers(pairs.count, at: depth); return .mapping(pairs)
            case nil:
                r.report(&sink, .yamlUnterminatedFlowMapping)
                return nil
            default:
                r.report(&sink, .yamlUnexpectedInFlow)
                return nil
            }
        }
        for source in mergeSources { mergeInto(&pairs, from: source) }
        hints.setMembers(pairs.count, at: depth); return .mapping(pairs)
    }

    mutating func parseFlowNode(
        _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
    ) -> YAML.Node? {
        skipBlanksAndComments(&r)
        // Captured BEFORE the charge, exactly as `parseNode` does, so an anchored flow
        // node's recorded cost is everything its subtree consumed. Getting this wrong is
        // not a style matter: `anchorCost` is what an alias is charged, so a
        // flow-defined anchor recorded at cost 1 would let `[&a [x,x,x,x], *a, *a, *a]`
        // expand for free. That is FINDING 1 in AuditRegressionTests, in a new location.
        let budgetAtEntry = nodeBudget
        // Flow nodes are charged too: this path does not go through parseNode, so
        // without it a flow-heavy document is unbounded and — worse — the alias arm
        // below was free.
        guard chargeNode(1, r: &r, sink: &sink) else { return nil }

        // Anchor properties. Absent until 2026-09-08, which is why `[&a x, *a]` did not
        // resolve: `&` is not a flow terminator, so the anchor fell through to the plain
        // scalar arm and became part of the content, and the alias then found nothing.
        // Block style was unaffected because it goes through `parseNode`, which has had
        // this loop all along — the gap was flow-INTERNAL only.
        //
        // Tags (`[!!str 1]`) are the same shape and are still not handled here. Left
        // deliberately: consuming them changes how documents that currently parse
        // `!!str x` as a plain scalar behave, which is its own change. ROADMAP carries it.
        // `if`, not `while`: YAML permits at most one anchor per node, so a loop here
        // would only ever accept `&a &b x`, which is not a document anyone can write.
        var anchor: String?
        if r.currentByte == UInt8(ascii: "&") {
            r.advanceBy(1)
            anchor = scanToken(&r)
            // Not `skipInlineSpace`: a flow context may put the value on the next line.
            skipBlanksAndComments(&r)
        }

        // THE UNANCHORED PATH IS LEFT EXACTLY AS IT WAS, tail calls and all, and the
        // duplication below is deliberate. Folding both cases into one `var node: YAML.Node?`
        // and a shared exit is the obvious spelling and it cost 3.3% on the YAML
        // node-parse arm (6.58x -> 6.37x against Yams, two samples each way): the
        // rewrite turns four tail calls into an Optional round-trip through a shared
        // epilogue. An anchor in flow is rare; the unanchored node is every other node
        // in the document, and it should not pay for a feature it never uses.
        if anchor == nil {
            if r.currentByte == UInt8(ascii: "*") {
                r.advanceBy(1)
                guard let name = scanToken(&r), let target = anchors[name] else {
                    r.report(&sink, .yamlUndefinedAlias)
                    return nil
                }
                guard chargeNode(anchorCost[name] ?? 1, r: &r, sink: &sink) else {
                    return nil
                }
                return target
            }
            if r.currentByte == UInt8(ascii: "[") {
                return parseFlowSequence(&r, &sink, depth: depth)
            }
            if r.currentByte == UInt8(ascii: "{") {
                return parseFlowMapping(&r, &sink, depth: depth)
            }
            if let q = r.currentByte, q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
                return parseQuoted(&r, &sink)
            }
            return .scalar(YAML.Scalar(content: scanFlowPlain(&r)))
        }

        // Anchored. `&q *p` is not YAML — an alias is a REFERENCE to an already-anchored
        // node, not a node of its own, so it carries no properties. libyaml rejects it,
        // and the Yams differential rejected the first version of this change, which had
        // recorded `q` as an alias of `p`. Block style had accepted it since anchors
        // existed, silently discarding the `&q` so a later `*q` failed with "undefined
        // alias" and named the wrong problem; `parseNode` now refuses it too.
        if r.currentByte == UInt8(ascii: "*") {
            r.report(&sink, .yamlAnchorOnAlias)
            return nil
        }

        var node: YAML.Node?
        if r.currentByte == UInt8(ascii: "[") {
            node = parseFlowSequence(&r, &sink, depth: depth)
        } else if r.currentByte == UInt8(ascii: "{") {
            node = parseFlowMapping(&r, &sink, depth: depth)
        } else if let q = r.currentByte, q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
            node = parseQuoted(&r, &sink)
        } else {
            node = .scalar(YAML.Scalar(content: scanFlowPlain(&r)))
        }
        guard let result = node else { return nil }
        return recordFlowAnchor(anchor, result, budgetAtEntry)
    }

    /// A plain scalar in flow context, which ends at `,` `]` `}` `: ` or a newline.
    /// Extracted so the anchored and unanchored arms above cannot drift apart.
    @inline(__always)
    private mutating func scanFlowPlain(_ r: inout AssayReader) -> String {
        let start = r.byteOffset
        var end = start
        while let c = r.currentByte {
            if c == UInt8(ascii: ",") || c == UInt8(ascii: "]")
                || c == UInt8(ascii: "}") || c == 0x0A { break }
            if c == UInt8(ascii: ":"), let n = r.byte(at: 1),
               n == 0x20 || n == UInt8(ascii: ",") || n == UInt8(ascii: "]")
                || n == UInt8(ascii: "}") { break }
            r.advanceBy(1)
            if c != 0x20 && c != 0x09 { end = r.byteOffset }
        }
        return r.string(from: start, to: end)
    }

    /// Record a flow-defined anchor, and attach it to a scalar for round-trip fidelity
    /// the way `parseNode` does. Split out because `parseFlowNode` has two exits that
    /// both have to do it, and an anchor recorded on one path but not the other is the
    /// shape of bug this whole change is fixing.
    @inline(never)
    private mutating func recordFlowAnchor(
        _ anchor: String?, _ node: YAML.Node, _ budgetAtEntry: Int
    ) -> YAML.Node {
        guard let a = anchor else { return node }
        var result = node
        if case .scalar(var s) = result {
            s.anchor = a
            result = .scalar(s)
        }
        anchors[a] = result
        anchorCost[a] = max(1, budgetAtEntry - nodeBudget)
        return result
    }
}
