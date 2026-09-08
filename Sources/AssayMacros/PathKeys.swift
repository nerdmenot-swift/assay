// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Key(path: "profile.display_name")` — EXPERIENCE.md §4, ROADMAP.md §3.
//
// ```swift
// @Schema
// struct Card {
//     @Key(path: "profile.display_name") var displayName: String
//     @Key(path: "profile.avatar")       var avatar: String?
//     var id: String
// }
// ```
//
// A PATH IS A TREE OF THE EXISTING DISPATCH TABLE, which is the whole design and the answer
// to ROADMAP §3's second open question ("whether it can share the dispatch machinery or needs
// a second pass"). It shares it completely. `profile` is an ordinary top-level key: it gets
// one arm in the same window-dispatch table every other key gets an arm in. That arm descends
// into the object and dispatches on the second segment. Two fields under `profile` are ONE
// top-level arm, not two. Nothing rewinds, nothing is scanned twice, and a document whose
// keys arrive in any order still decodes in one pass — the presence mask does the rest, as it
// already did.
//
// THE INNER DISPATCH IS A LINEAR CHAIN, NOT A SECOND WINDOW TABLE, and that is a deliberate
// departure from the shape the roadmap sketched. A window table is 256 bytes of array
// literal, and `docs/COMPILE-TIME.md` rule 1 is specifically that never emitting one bought
// 16% of expansion time. A group holds one to three fields in every realistic schema;
// `Experiments/01-jump-table` measured that LLVM gives a balanced binary search tree below
// ten arms anyway, so the table would buy nothing at runtime and cost real time at compile.
// The outer table is shared with the keys that were always there, so it is free.
//
// WHERE THE CARET GOES — ROADMAP §3's first open question, answered as three cases because
// they are three different failures and reporting them alike is what this library exists not
// to do. **The path names the segment that failed; the caret points at the innermost thing
// that existed.**
//
//   * The intermediate is absent. `{"id": "x"}` against `profile.display_name` reports
//     `.missing` at `profile` — ONE issue for the group, not one per field under it. Saying
//     "profile.display_name is missing" would be false: nothing is missing from `profile`,
//     `profile` is missing.
//   * The intermediate is the wrong type. `{"profile": 42}` reports `.typeMismatch` at
//     `profile`, with the caret on the 42.
//   * The leaf is absent. `{"profile": {}}` reports `.missing` at
//     `profile.display_name` — the full path, because now the containing object really does
//     lack that key.
//
// MISSING IS ABSENCE; WRONG-TYPED IS AN ERROR. A missing intermediate leaves an optional
// field nil, a defaulted field at its default, and a `@Fallback` field at its fallback,
// exactly as a missing top-level key does. A *wrong-typed* intermediate is an issue even when
// every field under it is optional, because `missing != wrong` is existing law everywhere
// else in this library and a path is not the place to make an exception.
//
// WHAT IS REFUSED, at expansion, with a diagnostic naming the alternative: an index segment
// (`meta.tags[0]`, which `EXPERIENCE.md` §4 advertises). Reaching an array element by index
// is a different operation from walking a key — it needs the element *counted* during the
// array's own decode loop, and every presence and caret rule above would need a fourth case
// for "the array was shorter than the index". That is a feature, not a segment type, and it
// is on the roadmap rather than half-built here.
//===----------------------------------------------------------------------===//

/// A node in the `@Key(path:)` prefix tree: the keys reachable one level below some prefix.
///
/// A child is either a leaf (a field's path ends here, `fieldIndex`) or another node. It can
/// be both in principle — `@Key(path: "a")` beside `@Key(path: "a.b")` — and that is refused
/// at expansion, because the same wire key cannot be a scalar and an object.
struct PathNode {
    /// Which bit of `__gpresence` records that this object was seen. Every node gets one,
    /// including nested ones, because "which segment failed" is exactly the question the
    /// caret rule asks and only a per-node bit can answer it.
    var bit: Int = 0
    /// Segment -> the field whose path ends at that segment.
    var leaves: [(segment: String, fieldIndex: Int)] = []
    /// Segment -> the subtree below it.
    var children: [(segment: String, node: PathNode)] = []
}

/// A top-level path group: one first segment, and everything below it.
struct PathGroup {
    var segment: String
    var node: PathNode
    /// Field indices anywhere under this group, for the presence rules.
    var fieldIndices: [Int]
}

enum PathTree {

    /// Build the groups from the fields that declared a path. Returns nil having diagnosed.
    ///
    /// Order is declaration order of the first field that introduced each segment, so the
    /// generated table is stable across builds — a macro that reordered its own output would
    /// make every diff unreadable and every compile-time measurement noise.
    static func build(_ fields: [SchemaField]) -> [PathGroup] {
        var order: [String] = []
        var byFirst: [String: [(Int, [String])]] = [:]
        for (i, f) in fields.enumerated() {
            guard let segs = f.pathSegments, let first = segs.first else { continue }
            if byFirst[first] == nil { order.append(first) }
            byFirst[first, default: []].append((i, Array(segs.dropFirst())))
        }
        var nextBit = 0
        return order.map { first in
            let members = byFirst[first]!
            return PathGroup(segment: first,
                             node: node(from: members, bit: &nextBit),
                             fieldIndices: members.map(\.0))
        }
    }

    private static func node(from members: [(Int, [String])], bit: inout Int) -> PathNode {
        var n = PathNode()
        n.bit = bit
        bit += 1
        var order: [String] = []
        var deeper: [String: [(Int, [String])]] = [:]
        for (index, rest) in members {
            guard let head = rest.first else { continue }
            if rest.count == 1 {
                n.leaves.append((head, index))
            } else {
                if deeper[head] == nil { order.append(head) }
                deeper[head, default: []].append((index, Array(rest.dropFirst())))
            }
        }
        n.children = order.map { seg -> (String, PathNode) in
            (seg, node(from: deeper[seg]!, bit: &bit))
        }
        return n
    }

    /// The presence tests, outermost first, each nested inside the one above so an absent
    /// `profile` reports once and suppresses every leaf beneath it.
    ///
    /// Returns generated source, indented to `indent`, or "" when the schema uses no paths.
    static func presenceChecks(
        _ groups: [PathGroup], fields: [SchemaField], indent: Int
    ) -> String {
        var out = ""
        for g in groups {
            out += checks(g.node, fields: fields, prefix: [g.segment],
                          parentPath: "path", indent: indent)
        }
        return out
    }

    private static func checks(
        _ n: PathNode, fields: [SchemaField], prefix: [String],
        parentPath: String, indent: Int
    ) -> String {
        let pad = String(repeating: " ", count: indent)
        let segment = prefix[prefix.count - 1]
        let here = "\(parentPath) + [.key(\"\(segment)\")]"

        // Leaves that must exist once this object does.
        var inner = ""
        for (seg, i) in n.leaves where isRequired(fields[i]) {
            inner += "\(pad)    if __presence & \(1 << UInt64(i)) == 0 {\n"
                + "\(pad)        reader.missingRequired(&sink, \(here), \"\(seg)\")\n"
                + "\(pad)    }\n"
        }
        // Recursion emits the child's own "is it here?" test, so there is nothing to wrap
        // it in. Wrapping it as well emitted the test twice — visible only by reading the
        // expansion, since a doubled test is still correct and still passes every test.
        for (seg, child) in n.children {
            inner += checks(child, fields: fields, prefix: prefix + [seg],
                            parentPath: here, indent: indent + 4)
        }
        guard !inner.isEmpty else { return "" }

        // The object itself. Reported at the PARENT path naming this segment, which is the
        // difference between "profile is missing" and the false "profile.display_name is".
        if requiresAnything(n, fields) {
            return "\(pad)if __gpresence & \(1 << UInt64(n.bit)) == 0 {\n"
                + "\(pad)    reader.missingRequired(&sink, \(parentPath), \"\(segment)\")\n"
                + "\(pad)} else {\n" + inner + "\(pad)}\n"
        }
        return "\(pad)if __gpresence & \(1 << UInt64(n.bit)) != 0 {\n" + inner + "\(pad)}\n"
    }

    /// A field whose absence is an issue: not optional, no default, no `@Fallback`.
    /// The five presence states, unchanged — a path changes where a key is looked for, not
    /// what its absence means.
    ///
    /// Defined once and shared with the RawValue path. Two copies of a presence predicate is
    /// how the two decode paths start disagreeing about what "missing" means.
    static func isRequired(_ f: SchemaField) -> Bool {
        !f.isOptional && f.defaultExpr == nil && f.fallback == nil
    }

    static func requiresAnything(_ n: PathNode, _ fields: [SchemaField]) -> Bool {
        n.leaves.contains { isRequired(fields[$0.fieldIndex]) }
            || n.children.contains { requiresAnything($0.node, fields) }
    }

    /// Every wire key a path group occupies at the top level, for the duplicate-key check:
    /// `@Key(path: "profile.x")` and a plain `var profile: P` collide, and the collision is
    /// real — one arm cannot both descend and decode a value.
    static func topLevelKeys(_ groups: [PathGroup]) -> [String] { groups.map(\.segment) }
}
