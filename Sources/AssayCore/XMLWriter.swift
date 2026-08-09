// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The XML writer. docs/ENCODING.md.
//
// WHY XML DOES NOT GO THROUGH THE `RawValue` SEAM, unlike YAML. The seam works for YAML
// because a YAML document and a `RawValue` have the same shape: keys and values, nothing
// else. XML has a third thing — placement. Whether `id` is `<user id="7">` or
// `<user><id>7</id></user>` is not expressible in `RawValue` and never will be, because
// `RawValue` is deliberately the narrow intersection of the three formats
// (docs/VALUE-MODELS.md §5).
//
// Placement is compile-time knowledge: the macro reads `@XML(.attribute)` and knows the
// answer. So XML gets a generated body like JSON's, and the placement is baked into the
// emitted calls rather than carried in a runtime table. That is also what
// `EXPERIENCE.md` §12 already says about the value models — "a YAML scalar's resolution
// and an XML element's namespace are not the same kind of thing" — arriving on the
// encode side.
//
// START-TAG STATE. XML requires every attribute inside the start tag, before any child
// content. The writer tracks whether it is still inside one and closes it on the first
// content call, so generated code cannot emit an attribute after a child by accident —
// it would be a malformed document, and the macro orders the calls to prevent it anyway.
//===----------------------------------------------------------------------===//

/// Accumulates XML bytes. A struct passed `inout`, like `JSONWriter` and `IssueSink`.
public struct XMLWriter: ~Copyable {
    @usableFromInline var out: [UInt8]
    /// True while inside a start tag, so `>` is emitted lazily and attributes stay legal.
    @usableFromInline var inStartTag: Bool = false
    @usableFromInline let pretty: Bool
    @usableFromInline var depth: Int = 0
    /// Whether the current element has had element children, so an empty one can close as
    /// `<a/>` and a text-only one stays on a single line.
    @usableFromInline var hasChildElements: [Bool] = []

    @inlinable
    public init(pretty: Bool = false, declaration: Bool = true) {
        self.pretty = pretty
        self.out = []
        self.out.reserveCapacity(512)
        if declaration {
            out.append(contentsOf: Array(#"<?xml version="1.0" encoding="UTF-8"?>"#.utf8))
            if pretty { out.append(0x0A) }
        }
    }

    @inlinable
    public consuming func finish() -> [UInt8] {
        if pretty, out.last != 0x0A { out.append(0x0A) }
        return out
    }

    @inlinable @inline(__always)
    mutating func raw(_ s: String) { out.append(contentsOf: Array(s.utf8)) }

    /// Close the start tag if one is open, so content can follow.
    @inlinable
    mutating func closeStartTag() {
        if inStartTag {
            out.append(0x3E)                     // >
            inStartTag = false
        }
    }

    @inlinable
    mutating func indent() {
        guard pretty else { return }
        out.append(0x0A)
        for _ in 0..<depth { out.append(0x20); out.append(0x20) }
    }

    // MARK: Elements

    @inlinable
    public mutating func beginElement(_ name: String) {
        closeStartTag()
        if !hasChildElements.isEmpty { hasChildElements[hasChildElements.count - 1] = true }
        indent()
        out.append(0x3C)                         // <
        raw(name)
        inStartTag = true
        depth &+= 1
        hasChildElements.append(false)
    }

    @inlinable
    public mutating func endElement(_ name: String) {
        depth &-= 1
        let hadChildren = hasChildElements.popLast() ?? false
        if inStartTag {
            // Nothing at all inside: the empty-element form.
            out.append(contentsOf: [0x2F, 0x3E])  // />
            inStartTag = false
            return
        }
        if hadChildren { indent() }
        out.append(contentsOf: [0x3C, 0x2F])      // </
        raw(name)
        out.append(0x3E)
    }

    /// An attribute. Legal only before any content, which the writer enforces by ignoring
    /// the call once the start tag has closed — the macro orders attributes first.
    @inlinable
    public mutating func attribute(_ name: String, _ value: String) {
        guard inStartTag else { return }
        out.append(0x20)
        raw(name)
        out.append(contentsOf: [0x3D, 0x22])      // ="
        writeEscaped(value, inAttribute: true)
        out.append(0x22)
    }

    // MARK: Content

    @inlinable
    public mutating func text(_ s: String) {
        closeStartTag()
        writeEscaped(s, inAttribute: false)
    }

    /// A complete leaf element with text content — the common case, one call.
    @inlinable
    public mutating func element(_ name: String, _ value: String) {
        beginElement(name)
        text(value)
        endElement(name)
    }

    /// The five predefined entities, plus the whitespace an attribute value must escape
    /// so it survives XML 1.0 §3.3.3 attribute-value normalisation on the way back in.
    /// Getting that wrong is how a tab in an attribute silently becomes a space.
    @inlinable
    mutating func writeEscaped(_ s: String, inAttribute: Bool) {
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "<"): raw("&lt;")
            case UInt8(ascii: ">"): raw("&gt;")
            case UInt8(ascii: "&"): raw("&amp;")
            case UInt8(ascii: "\""): if inAttribute { raw("&quot;") } else { out.append(b) }
            case 0x09: if inAttribute { raw("&#9;") } else { out.append(b) }
            case 0x0A: if inAttribute { raw("&#10;") } else { out.append(b) }
            case 0x0D: raw("&#13;")
            default: out.append(b)
            }
        }
    }

    // MARK: Scalars, mirroring JSONWriter's surface

    @inlinable
    public mutating func element(_ name: String, _ v: Int) { element(name, String(v)) }
    @inlinable
    public mutating func element(_ name: String, _ v: Int64) { element(name, String(v)) }
    @inlinable
    public mutating func element(_ name: String, _ v: Int32) { element(name, String(v)) }
    @inlinable
    public mutating func element(_ name: String, _ v: UInt) { element(name, String(v)) }
    @inlinable
    public mutating func element(_ name: String, _ v: Bool) {
        element(name, v ? "true" : "false")
    }
    @inlinable
    public mutating func attribute(_ name: String, _ v: Int) { attribute(name, String(v)) }
    @inlinable
    public mutating func attribute(_ name: String, _ v: Int64) { attribute(name, String(v)) }
    @inlinable
    public mutating func attribute(_ name: String, _ v: Int32) { attribute(name, String(v)) }
    @inlinable
    public mutating func attribute(_ name: String, _ v: UInt) { attribute(name, String(v)) }
    @inlinable
    public mutating func attribute(_ name: String, _ v: Bool) {
        attribute(name, v ? "true" : "false")
    }

    /// XML has no numeric type, so a non-finite double has no spelling that survives a
    /// round trip — `NaN` decodes as the string "NaN". Reported, like JSON's.
    @inlinable
    public mutating func doubleText(
        _ v: Double, _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> String {
        guard v.isFinite else {
            sink.add(Issue(
                code: .unrepresentableValue,
                path: path + [.key(String(describing: key))],
                params: ["format": .string("XML")],
                received: v.isNaN ? "NaN" : (v > 0 ? "Infinity" : "-Infinity")))
            return "0"
        }
        if v == v.rounded(), abs(v) < 9_007_199_254_740_992 { return String(Int64(v)) }
        return String(v)
    }
}

// MARK: - Helpers generated code calls

/// A date as XML text, in the field's primary format. Same rule as every other encoder:
/// write what `parse` accepts.
@inlinable
public func _assayXMLDate(_ seconds: Double, _ formats: [DateFormat]) -> String {
    switch formats.first ?? .iso8601 {
    case .unixSeconds: return seconds == seconds.rounded() ? String(Int64(seconds)) : String(seconds)
    case .unixMillis:  return String(Int64(seconds * 1_000))
    case .iso8601, .rfc9110, .pattern:
        return seconds.isFinite ? DateParser.formatISO8601(seconds) : ""
    }
}

/// An open `RawValue` — `@Extras`, and declared `RawValue` fields — as XML.
///
/// A sequence becomes repeated siblings sharing `name`, which is the same default the
/// generated code uses for arrays, so the two agree.
public func _assayEncodeRawXML(
    _ v: RawValue, named name: String, into w: inout XMLWriter,
    into sink: inout IssueSink, at path: [PathComponent]
) {
    switch v {
    case .null:          w.beginElement(name); w.endElement(name)
    case .bool(let b):   w.element(name, b ? "true" : "false")
    case .int(let i):    w.element(name, String(i))
    case .double(let d): w.element(name, w.doubleText(d, &sink, path, ""))
    case .string(let s): w.element(name, s)
    case .sequence(let xs):
        for x in xs { _assayEncodeRawXML(x, named: name, into: &w, into: &sink, at: path) }
    case .mapping(let ms):
        w.beginElement(name)
        for m in ms {
            _assayEncodeRawXML(m.value, named: m.key, into: &w, into: &sink, at: path)
        }
        w.endElement(name)
    }
}
