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

// MARK: - Encoding
//
// docs/ENCODING.md. XML gets a generated body rather than the RawValue seam YAML uses,
// because placement is not expressible in RawValue — see AssayCore/XMLWriter.swift.

extension XMLEncodableSchema {

    /// Write this value as an XML document, or throw with everything that went wrong.
    ///
    /// `root` defaults to the type's own name, which is the only name available without a
    /// `@XML(root:)` attribute; that attribute is additive later and nothing depends on it.
    public func encode(
        xml root: String? = nil, pretty: Bool = false, declaration: Bool = true
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

    public func diagnoseEncode(
        xml root: String? = nil, pretty: Bool = false, declaration: Bool = true
    ) -> EncodeDiagnosis {
        var sink = IssueSink()
        var w = XMLWriter(pretty: pretty, declaration: declaration)
        _assayEncodeXML(into: &w, into: &sink, at: [], element: root ?? Self._assayXMLRoot)
        return EncodeDiagnosis(bytes: w.finish(), issues: sink.issues,
                               warnings: sink.warnings)
    }

    public func encodedXML(root: String? = nil, pretty: Bool = false) throws -> String {
        String(decoding: try encode(xml: root, pretty: pretty), as: UTF8.self)
    }
}
