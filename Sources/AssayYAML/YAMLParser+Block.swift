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
    ) -> B.Value? {
        var items = B.makeItems(reserving: hints.items(at: depth))
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
                    B.append(&items, item)
                } else {
                    B.append(&items, B.scalar("", style: .plain, tag: nil))
                }
                continue
            }
            let itemColumn = currentColumn(&r)
            guard let item = parseNode(&r, &sink, indent: itemColumn - 1,
                                       depth: depth + 1) else { return nil }
            B.append(&items, item)
        }
        hints.setItems(B.itemCount(items), at: depth)
        return B.sequence(items)
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
    ) -> B.Value? {
        var pairs = B.makePairs(reserving: hints.members(at: depth))
        // Merge sources are collected and applied AFTER the mapping is complete.
        // Applying them inline would let `<<:` win over an explicit key that appears
        // later in the document, and YAML says the explicit key always wins
        // regardless of position.
        var mergeSources: [B.Value] = []
        while true {
            skipBlanksAndComments(&r)
            if r.atEnd { break }
            if atLineStart(&r), r.matches("---") || r.matches("...") { break }
            let column = currentColumn(&r)
            if column != indent { break }

            // Explicit key: "? key" then "\n: value"
            var key: B.Value
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
            var value: B.Value
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
                    value = B.scalar("", style: .plain, tag: nil)
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
            if B.isMergeKey(&key) {
                mergeSources.append(consume value)
            } else {
                // `consume`: MOVE the key and value into the pair. This is their last use,
                // yet the optimiser copied both (a retain per String in each scalar) and then
                // destroyed the originals: 20,002 node copies and 20,002 destroys per
                // `base/yaml` call (count.py explain, 2026-09-19).
                let span = trimmedSpan(&r, from: valueStart)
                guard B.appendPair(&pairs, key: consume key, value: consume value,
                                   span: span) else {
                    // A key this builder cannot represent: `RawValue`'s keys are Strings and
                    // `? [a, b] : c` is legal YAML. Reported HERE since 2026-09-20, where the
                    // key is read; the projection used to fail and the entry point reported.
                    r.report(&sink, .yamlUnrepresentableKey)
                    return nil
                }
            }
        }
        for source in mergeSources { B.merge(&pairs, from: source) }
        hints.setMembers(B.pairCount(pairs), at: depth)
        return B.mapping(pairs)
    }

    /// A mapping key: quoted, flow collection, or a plain scalar up to the `:`.
    mutating func parseKeyScalar(
        _ r: inout AssayReader, _ sink: inout IssueSink, depth: Int
    ) -> B.Value? {
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
        return B.scalar(r.string(from: start, to: end), style: .plain, tag: nil)
    }
}
