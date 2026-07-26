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
