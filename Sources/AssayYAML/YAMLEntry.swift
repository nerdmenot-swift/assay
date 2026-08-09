// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// parse(yaml:) — the same struct, a different format.
//
// EXPERIENCE.md §12: "One struct, many formats. Same struct. Same rules. Same errors."
// That promise is what this file discharges for YAML.
//
// Path: bytes -> YAML.Node (full fidelity) -> RawValue (portable projection) -> your
// struct. The projection is lossy in exactly the ways docs/VALUE-MODELS.md §5 documents —
// tags, scalar styles and anchors do not survive, and a non-string mapping key is a hard
// error rather than a coerced one. A caller who needs any of that parses to YAML.Node
// directly and works with the node model.
//===----------------------------------------------------------------------===//

public import Assay
public import AssayCore

extension RawDecodable {

    /// Decode from YAML, or throw with every issue found.
    public static func parse(
        yaml bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(yaml: bytes, limits: limits, sourceName: sourceName).get()
    }

    public static func parse(
        yaml text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try parse(yaml: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    /// Decode from YAML and report everything.
    public static func diagnose(
        yaml bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)
        let docs = YAML.decodeAll(bytes, into: &sink, limits: limits)

        guard sink.isValid else {
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }
        guard let doc = docs.first else {
            sink.add(Issue(code: .custom("yaml_empty_stream")))
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }
        if docs.count > 1 {
            // Silently taking the first document would be the wrong kind of convenient;
            // `parseAll(yaml:)` exists for the multi-document case.
            sink.add(Issue(code: .custom("yaml_multiple_documents"),
                           params: ["count": .int(docs.count)]))
        }

        guard let raw = RawValue(doc) else {
            sink.add(Issue(code: .custom("yaml_unrepresentable_key"),
                           params: ["reason": .string(
                               "a mapping key is not a plain scalar; parse to YAML.Node instead")]))
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }

        let value = Self._assay(from: raw, into: &sink, at: [])
        return Diagnosis(value: sink.isValid ? value : nil,
                         issues: sink.issues, warnings: sink.warnings,
                         truncatedIssues: sink.truncatedIssues,
                         source: SourceBytes(bytes), sourceName: sourceName)
    }

    public static func diagnose(
        yaml text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        diagnose(yaml: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    /// Every document in a multi-document stream. `EXPERIENCE.md` §12.
    public static func parseAll(
        yaml text: String,
        limits: Limits = .default
    ) throws -> [Self] {
        var sink = IssueSink(limits: limits)
        let docs = YAML.decodeAll(Array(text.utf8), into: &sink, limits: limits)
        var out: [Self] = []
        for doc in docs {
            guard let raw = RawValue(doc) else {
                sink.add(Issue(code: .custom("yaml_unrepresentable_key")))
                continue
            }
            if let v = Self._assay(from: raw, into: &sink, at: [.index(out.count)]) {
                out.append(v)
            }
        }
        guard sink.isValid else {
            throw YAMLParseError(issues: sink.issues)
        }
        return out
    }
}

// MARK: - Encoding
//
// docs/ENCODING.md. Mirrors the JSON verbs and the decode pipeline: the schema projects
// itself into `RawValue` and `YAML.encode` renders it, exactly as decoding parses to
// `YAML.Node`, projects to `RawValue` and decodes from that.

extension RawEncodableSchema {

    /// Write this value as a YAML document, or throw with everything that went wrong.
    public func encodedYAML() throws -> [UInt8] {
        var sink = IssueSink()
        let raw = _assayEncodeRaw(into: &sink, at: [])
        let bytes = YAML.encode(raw)
        guard sink.isValid else {
            throw AssayError(issues: sink.issues, source: SourceBytes(bytes),
                             sourceName: "<encoded.yaml>")
        }
        return bytes
    }

    /// Write this value as YAML and report everything, including what it managed.
    public func diagnoseEncodeYAML() -> EncodeDiagnosis {
        var sink = IssueSink()
        let raw = _assayEncodeRaw(into: &sink, at: [])
        return EncodeDiagnosis(bytes: YAML.encode(raw),
                               issues: sink.issues, warnings: sink.warnings)
    }

    /// The encoded document as text. YAML is a human-facing format, so this is usually
    /// the spelling you want.
    public func yamlText() throws -> String {
        String(decoding: try encodedYAML(), as: UTF8.self)
    }
}
