// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// What an XML parse builds — the same split YAML got, for the same reason.
//
// `parse(xml:)` built an `XML.Element` tree and then projected it into `RawValue` and
// dropped it: about 2,000 heap blocks and a sixth of `base/xml-struct`'s instructions
// (`docs/EFFICIENCY.md` rows 12 and 17). The parser is now generic over what it builds, with
// two conformances here, so there is one grammar and one set of diagnostics.
//
// THE ACCUMULATOR IS THE RESULT, as in `YAMLBuilder.swift`: a builder names what an element's
// children are gathered into and the parser fills that, so finishing an element moves an
// array rather than converting one. Gathering into a neutral array and converting at the end
// left the block count exactly where it was, which is the whole point of the change.
//
// THE CONSTRAINT THAT SHAPES THIS FILE IS THE STACK, not the semantics. `parseElement`
// recurses, so its frame is multiplied by nesting depth, and `XMLParser.swift`'s helpers are
// `@inline(never)` because a fatter frame turned a 5,000-deep document into a SIGBUS. So an
// element's state lives in ONE accumulator value passed `inout`, not in a handful of locals,
// and the builders' methods are the only things added to that frame.
//
// WHAT THE RAW BUILDER HAS TO GET RIGHT, all of it inherited from the projection it replaces
// (`RawValue.init(consuming: XML.Element)`):
//   * THE LEAF TEST. No attributes and no element children means the element IS its text —
//     `<port>8080</port>` is `.string("8080")`, not a mapping. Every other element is a
//     mapping.
//   * ORDER. Attributes first, then children in document order.
//   * WHITESPACE. A whitespace-only character-data run between elements is formatting and is
//     dropped; anything else is kept under the reserved empty key.
//   * A LEAF'S TEXT IS EVERY RUN, whitespace included, concatenated — which is why the
//     accumulator keeps the text as well as the members.
//   * COMMENTS AND PROCESSING INSTRUCTIONS CONTRIBUTE NOTHING.
//===----------------------------------------------------------------------===//

import AssayCore

/// What an XML parse builds. Two conformances: the node tree, and `RawValue` directly.
protocol XMLBuilding {
    /// A finished element: an `XML.Element` for the tree, one `RawValue.Member` for the
    /// projection (an element is a named value in its parent).
    associatedtype Value
    /// An element's state while its children are being read.
    associatedtype Children
    /// What a whole document parses to.
    associatedtype Output

    /// Everything known before the children are read: the resolved name, the resolved
    /// attributes, and how many children the last element at this position had.
    @inline(__always)
    static func makeChildren(
        name: inout XML.Name, attributes: inout [XML.Attribute], reserving n: Int
    ) -> Children

    @inline(__always)
    static func appendElement(_ c: inout Children, _ v: consuming Value)
    /// Character data, `isCDATA` only so the node tree can keep the distinction.
    @inline(__always)
    static func appendText(_ c: inout Children, _ text: consuming String, isCDATA: Bool)
    @inline(__always)
    static func appendComment(_ c: inout Children, _ text: consuming String)
    @inline(__always)
    static func appendInstruction(
        _ c: inout Children, target: consuming String, data: consuming String
    )

    /// How many children were appended, for the parser's shape memory.
    @inline(__always)
    static func childCount(_ c: borrowing Children) -> Int

    @inline(__always)
    static func finish(
        _ c: consuming Children, name: consuming XML.Name,
        attributes: consuming [XML.Attribute],
        contentSpan: SourceSpan?
    ) -> Value

    /// `<tag/>`: no children, and the span covers the tag name.
    @inline(__always)
    static func emptyElement(
        name: consuming XML.Name, attributes: consuming [XML.Attribute],
        contentSpan: SourceSpan?
    ) -> Value

    /// The root, plus the comments and instructions that preceded it.
    static func document(root: consuming Value, prolog: consuming [XML.Node]) -> Output
}

// MARK: - The element tree

/// Builds `XML.Element`: namespaces, attribute order, comments, instructions, CDATA, all kept.
enum XMLNodeBuilder: XMLBuilding {
    typealias Value = XML.Element
    typealias Output = XML.Document

    /// Just the children: the name and the attributes stay where the parser put them and
    /// move into the element at `finish`, as they did before there was a builder.
    typealias Children = [XML.Node]

    @inline(__always)
    static func makeChildren(
        name: inout XML.Name, attributes: inout [XML.Attribute], reserving n: Int
    ) -> [XML.Node] {
        var nodes: [XML.Node] = []
        nodes.reserveCapacity(n)
        return nodes
    }

    @inline(__always)
    static func appendElement(_ c: inout [XML.Node], _ v: consuming XML.Element) {
        c.append(.element(consume v))
    }

    @inline(__always)
    static func appendText(_ c: inout [XML.Node], _ text: consuming String, isCDATA: Bool) {
        c.append(isCDATA ? .cdata(consume text) : .text(consume text))
    }

    @inline(__always)
    static func appendComment(_ c: inout [XML.Node], _ text: consuming String) {
        c.append(.comment(consume text))
    }

    @inline(__always)
    static func appendInstruction(
        _ c: inout [XML.Node], target: consuming String, data: consuming String
    ) {
        c.append(.processingInstruction(target: consume target, data: consume data))
    }

    @inline(__always)
    static func childCount(_ c: borrowing [XML.Node]) -> Int { c.count }

    @inline(__always)
    static func finish(
        _ c: consuming [XML.Node], name: consuming XML.Name,
        attributes: consuming [XML.Attribute], contentSpan: SourceSpan?
    ) -> XML.Element {
        XML.Element(
            name: consume name, attributes: consume attributes,
            children: consume c, contentSpan: contentSpan)
    }

    @inline(__always)
    static func emptyElement(
        name: consuming XML.Name, attributes: consuming [XML.Attribute],
        contentSpan: SourceSpan?
    ) -> XML.Element {
        XML.Element(
            name: consume name, attributes: consume attributes, children: [],
            contentSpan: contentSpan)
    }

    static func document(
        root: consuming XML.Element, prolog: consuming [XML.Node]
    ) -> XML.Document {
        XML.Document(root: consume root, prolog: consume prolog)
    }
}

// MARK: - RawValue, directly

/// Builds `RawValue`: what every `@Schema` type decodes from, with no element tree between.
enum XMLRawBuilder: XMLBuilding {
    typealias Value = RawValue.Member
    typealias Output = RawDocument

    /// The projection, plus the root's name: `@XML(root:)` is checked against it, and the
    /// value alone no longer carries it.
    struct RawDocument {
        var rootName: String
        var value: RawValue
    }

    /// An element under construction. `text` is every character-data run concatenated, for
    /// the leaf case; `members` is the mapping, seeded with the attributes.
    struct Children {
        var key: String
        var members: [RawValue.Member]
        var text: String
        var hadAttributes: Bool
        var sawElement: Bool
    }

    @inline(__always)
    static func makeChildren(
        name: inout XML.Name, attributes: inout [XML.Attribute], reserving n: Int
    ) -> Children {
        var key = ""
        swap(&key, &name.local)
        var members: [RawValue.Member] = []
        members.reserveCapacity(attributes.count + n)
        // Attributes first, in document order, as the projection put them, and MOVED out of
        // the array: copying them instead cost 12,000-18,000 String retains per call.
        let hadAttributes = !attributes.isEmpty
        if hadAttributes {
            unsafe attributes.withUnsafeMutableBufferPointer { src in
                for i in src.indices {
                    var key = ""
                    unsafe swap(&key, &src[i].name.local)
                    var value = ""
                    unsafe swap(&value, &src[i].value)
                    members.append(
                        RawValue.Member(
                            key: consume key,
                            value: .string(consume value),
                            span: unsafe src[i].valueSpan))
                }
            }
        }
        return Children(
            key: consume key, members: members, text: "",
            hadAttributes: hadAttributes, sawElement: false)
    }

    @inline(__always)
    static func appendElement(_ c: inout Children, _ v: consuming RawValue.Member) {
        // Text seen BEFORE the first element child was held as a possible leaf's text; now
        // that this element is a mapping, that run becomes a member — before this child, so
        // document order holds.
        if !c.sawElement { flushPendingText(&c) }
        c.sawElement = true
        c.members.append(consume v)
    }

    /// Whitespace-only runs are formatting and are dropped; anything else is kept under the
    /// reserved empty key. Both rules come from the projection this replaces.
    private static func flushPendingText(_ c: inout Children) {
        guard !c.text.isEmpty else { return }
        var run = ""
        swap(&run, &c.text)
        guard !run.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        else { return }
        c.members.append(RawValue.Member(key: "", value: .string(consume run)))
    }

    /// A run is handled ONCE. While the element could still be a leaf its text accumulates
    /// (a leaf IS its text, whitespace included, and the common element is a leaf with a
    /// single run, which therefore MOVES); once the element is known to be a mapping the runs
    /// go straight in as members. Handling every run both ways cost a String copy per run.
    @inline(__always)
    static func appendText(_ c: inout Children, _ text: consuming String, isCDATA: Bool) {
        guard c.sawElement || c.hadAttributes else {
            if c.text.isEmpty { c.text = consume text } else { c.text += consume text }
            return
        }
        var run = consume text
        guard !run.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        else { return }
        var moved = ""
        swap(&moved, &run)
        c.members.append(RawValue.Member(key: "", value: .string(consume moved)))
    }

    @inline(__always)
    static func appendComment(_ c: inout Children, _ text: consuming String) {}

    @inline(__always)
    static func appendInstruction(
        _ c: inout Children, target: consuming String, data: consuming String
    ) {}

    /// The parser's hint wants how many children an element had, and for this builder the
    /// members array is what gets reserved next time.
    @inline(__always)
    static func childCount(_ c: borrowing Children) -> Int { c.members.count }

    @inline(__always)
    static func finish(
        _ c: consuming Children, name: consuming XML.Name,
        attributes: consuming [XML.Attribute], contentSpan: SourceSpan?
    ) -> RawValue.Member {
        var c = c
        var key = ""
        swap(&key, &c.key)
        // Text after the last element child, in mixed content.
        if c.sawElement || c.hadAttributes { flushPendingText(&c) }
        // THE LEAF TEST: no attributes and no element children means the element is its text.
        if !c.hadAttributes, !c.sawElement {
            var text = ""
            swap(&text, &c.text)
            return RawValue.Member(
                key: consume key, value: .string(consume text),
                span: contentSpan)
        }
        var members: [RawValue.Member] = []
        swap(&members, &c.members)
        return RawValue.Member(
            key: consume key, value: .mapping(consume members),
            span: contentSpan)
    }

    @inline(__always)
    static func emptyElement(
        name: consuming XML.Name, attributes: consuming [XML.Attribute],
        contentSpan: SourceSpan?
    ) -> RawValue.Member {
        var name = name
        var attributes = attributes
        let c = makeChildren(name: &name, attributes: &attributes, reserving: 0)
        return finish(
            c, name: consume name, attributes: consume attributes,
            contentSpan: contentSpan)
    }

    /// A document IS its root element's value: the projection unwrapped the root the same
    /// way (`RawValue.init(consuming: XML.Document)`). The name travels alongside for the
    /// root check rather than inside the value, which has nowhere to put it.
    static func document(
        root: consuming RawValue.Member, prolog: consuming [XML.Node]
    ) -> RawDocument {
        var root = root
        var value = RawValue.null
        swap(&value, &root.value)
        var name = ""
        swap(&name, &root.key)
        return RawDocument(rootName: consume name, value: consume value)
    }
}
