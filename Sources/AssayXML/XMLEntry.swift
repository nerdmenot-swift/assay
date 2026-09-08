// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// parse(xml:) — the same struct, a different format.
//
// Path: bytes -> XML.Document (full fidelity) -> RawValue -> your struct.
//
// The projection is the lossiest of the three (docs/VALUE-MODELS.md §5): attributes and
// child elements flatten into one keyspace, comments and PIs vanish, namespaces are
// dropped, and **every leaf becomes a string** because XML has no number and no boolean.
//
// That last one has a visible consequence: a schema with an `Int` field will not decode
// from XML unless it opts into coercion with `@Coerce` or `@Schema(coerceScalars: true)`.
// That is EXPERIENCE.md §7 working as designed rather than a gap — coercion stays written
// on the struct, where you can see it, instead of being applied silently because the
// format happened to be XML.
//===----------------------------------------------------------------------===//

public import Assay
public import AssayCore

/// The `@XML(root:)` check, if this type declared one.
    ///
    /// A **metatype cast**, not an overload pair. The obvious spelling — a no-op on
    /// `RawDecodable` shadowed by a real one on `RawDecodable where Self: XMLRooted` — does
    /// not work, and the reason is worth recording because the same trap is waiting in
    /// `@Schema(context:)`: overloads are chosen from the STATIC type, and inside
    /// `extension RawDecodable` the compiler does not know `Self: XMLRooted`, so the no-op
    /// wins for every type including the ones that declared a root. It compiled, ran, and
    /// checked nothing.
    ///
/// The cast happens once per document, not per field, and only for types that decode
/// XML at all.
///
/// A FREE function taking the metatype, not a protocol member, and that is what let the
/// contextual door reuse it unchanged: `ContextualRawDecodable` is a different protocol, and
/// a member on `RawDecodable` would have had to be written twice — which is precisely how
/// the bug in the paragraph above gets reintroduced.
@usableFromInline
func __assayCheckXMLRoot(
    _ type: Any.Type, _ doc: XML.Document, _ sink: inout IssueSink
) {
        guard let rooted = type as? any XMLRooted.Type,
              let expected = rooted._assayXMLExpectedRoot else { return }
        let actual = doc.root.name.local
        guard actual != expected else { return }
        sink.add(Issue(code: .custom("xml_root_mismatch"),
                       path: [],
                       params: ["expected": .string(expected)],
                       received: actual))
}

extension RawDecodable {

    /// Decode from XML, or throw with every issue found.
    public static func parse(
        xml bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(xml: bytes, limits: limits, sourceName: sourceName).get()
    }

    public static func parse(
        xml text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try parse(xml: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    /// Decode from XML and report everything.
    public static func diagnose(
        xml bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)
        guard let doc = XML.decode(bytes, into: &sink, limits: limits), sink.isValid else {
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }
        __assayCheckXMLRoot(Self.self, doc, &sink)
        let raw = RawValue(doc)
        let value = Self._assay(from: raw, into: &sink, at: [])
        return Diagnosis(value: sink.isValid ? value : nil,
                         issues: sink.issues, warnings: sink.warnings,
                         truncatedIssues: sink.truncatedIssues,
                         source: SourceBytes(bytes), sourceName: sourceName)
    }

    public static func diagnose(
        xml text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        diagnose(xml: Array(text.utf8), limits: limits, sourceName: sourceName)
    }
}

// MARK: - `@Schema(context:)`

/// The contextual door. Separate extension, separate protocol, same reason as YAML's:
/// a contextual type does not conform to `RawDecodable`, so `parse(xml:)` does not exist
/// for it and cannot be reached by forgetting an argument. `docs/EXPERIENCE.md` §10.
///
/// The `@XML(root:)` check is the same free function the context-free door calls, so the
/// two cannot diverge — see its header for why it is free rather than a protocol member.
extension ContextualRawDecodable {

    public static func parse(
        xml bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(xml: bytes, context: context,
                     limits: limits, sourceName: sourceName).get()
    }

    public static func parse(
        xml text: String,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try parse(xml: Array(text.utf8), context: context,
                  limits: limits, sourceName: sourceName)
    }

    public static func diagnose(
        xml bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)
        guard let doc = XML.decode(bytes, into: &sink, limits: limits), sink.isValid else {
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }
        __assayCheckXMLRoot(Self.self, doc, &sink)
        let value = Self._assay(from: RawValue(doc), into: &sink, at: [], context: context)
        return Diagnosis(value: sink.isValid ? value : nil,
                         issues: sink.issues, warnings: sink.warnings,
                         truncatedIssues: sink.truncatedIssues,
                         source: SourceBytes(bytes), sourceName: sourceName)
    }

    public static func diagnose(
        xml text: String,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        diagnose(xml: Array(text.utf8), context: context,
                 limits: limits, sourceName: sourceName)
    }
}

// MARK: - Encoding
//
// docs/ENCODING.md. XML gets a generated body rather than the RawValue seam YAML uses,
// because placement is not expressible in RawValue — see AssayCore/XMLWriter.swift.

extension XMLEncodableSchema {

    /// Write this value as an XML document, or throw with everything that went wrong.
    ///
    /// `root` defaults to the type's own name, which is the only name available without a
    /// `@XML(root:)` attribute; that attribute is additive later and nothing depends on it.
    public func encodedXML(
        root: String? = nil, pretty: Bool = false, declaration: Bool = true
    ) throws -> [UInt8] {
        var sink = IssueSink()
        var w = XMLWriter(pretty: pretty, declaration: declaration)
        _assayEncodeXML(into: &w, into: &sink, at: [], element: root ?? Self._assayXMLRoot)
        let bytes = w.finish()
        guard sink.isValid else {
            throw AssayError(issues: sink.issues, source: SourceBytes(bytes),
                             sourceName: "<encoded.xml>")
        }
        return bytes
    }

    public func diagnoseEncodeXML(
        root: String? = nil, pretty: Bool = false, declaration: Bool = true
    ) -> EncodeDiagnosis {
        var sink = IssueSink()
        var w = XMLWriter(pretty: pretty, declaration: declaration)
        _assayEncodeXML(into: &w, into: &sink, at: [], element: root ?? Self._assayXMLRoot)
        return EncodeDiagnosis(bytes: w.finish(), issues: sink.issues,
                               warnings: sink.warnings)
    }

    public func xmlText(root: String? = nil, pretty: Bool = false) throws -> String {
        String(decoding: try encodedXML(root: root, pretty: pretty), as: UTF8.self)
    }
}

// MARK: - Content negotiation

extension WireFormat {

    /// XML, for `parse(body:contentType:accepting:)`.
    ///
    /// **This is the format `accepting:` exists to keep out of reach.** Listing it means
    /// accepting that an untrusted body can reach an XML parser, which is where entity
    /// expansion and external-entity attacks live. Assay's parser refuses external entities
    /// by construction and bounds expansion, so the risk is managed rather than absent —
    /// but the decision to run it on a request body should be one someone wrote down.
    ///
    /// Matches `application/xml`, `text/xml`, and any `+xml` structured suffix, so
    /// `image/svg+xml` and `application/atom+xml` are XML.
    public static let xml = WireFormat(
        name: "xml",
        matches: { $0.names("xml") },
        decode: { bytes, sink, limits in
            guard let doc = XML.decode(bytes, into: &sink, limits: limits) else { return nil }
            return RawValue(doc)
        })
}
