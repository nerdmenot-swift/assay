// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// parse(toml:) — the same struct, a different format.
//
// EXPERIENCE.md §12: "One struct, many formats. Same struct. Same rules. Same errors."
// This file discharges that promise for TOML, by the same route as YAML:
//
//   bytes -> TOML.Node (full fidelity) -> RawValue (portable projection) -> your struct
//
// The projection loses exactly one thing — which of the four date-time kinds a value was
// (they all become RFC 3339 strings, which `Date` fields parse). A caller who needs the
// kind parses to `TOML.Node` directly. A TOML document is always a table, so a schema
// whose root is not a struct decodes nothing from it; that is the format, not a limit.
//===----------------------------------------------------------------------===//

public import Assay
public import AssayCore

/// Bytes to a `RawValue` document. Returns nil having already reported.
@usableFromInline
func __assayTOMLDocument(
    _ bytes: [UInt8], into sink: inout IssueSink, limits: Limits
) -> RawValue? {
    var parsed = TOML.decode(bytes, into: &sink, limits: limits)
    guard sink.isValid, let node = parsed.take() else { return nil }
    return RawValue(consuming: node)
}

extension RawDecodable {

    /// Decode from TOML, or throw with every issue found.
    public static func parse(
        toml bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(toml: bytes, limits: limits, sourceName: sourceName).get()
    }

    public static func parse(
        toml text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try parse(toml: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    /// Decode from TOML and report everything.
    public static func diagnose(
        toml bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)
        guard let raw = __assayTOMLDocument(bytes, into: &sink, limits: limits) else {
            return Diagnosis(sink: sink, value: nil, source: SourceBytes(bytes), sourceName: sourceName)
        }
        var __rootPath: [PathComponent] = []
        let value = Self._assay(from: raw, into: &sink, at: &__rootPath)
        return Diagnosis(sink: sink, value: value, source: SourceBytes(bytes), sourceName: sourceName)
    }

    public static func diagnose(
        toml text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        diagnose(toml: Array(text.utf8), limits: limits, sourceName: sourceName)
    }
}

// MARK: - Encoding
//
// docs/ENCODING.md. The schema projects itself into `RawValue` and `TOML.encode` renders
// it. TOML has no null, so an optional field that is nil is OMITTED (the same choice
// every TOML serialiser makes) and a nil anywhere else — an array element, a dictionary
// value — is an issue rather than a silent substitution. `TOML.encode` is where that
// rule lives.

extension RawEncodableSchema {

    /// Write this value as a TOML document, or throw with everything that went wrong.
    public func encodedTOML() throws -> [UInt8] {
        var sink = IssueSink()
        let raw = _assayEncodeRaw(into: &sink, at: [])
        let bytes = TOML.encode(raw, into: &sink)
        guard sink.isValid else {
            throw AssayError(issues: sink.issues, source: SourceBytes(bytes),
                             sourceName: "<encoded.toml>")
        }
        return bytes
    }

    /// Write this value as TOML and report everything, including what it managed.
    public func diagnoseEncodeTOML() -> EncodeDiagnosis {
        var sink = IssueSink()
        let raw = _assayEncodeRaw(into: &sink, at: [])
        let bytes = TOML.encode(raw, into: &sink)
        return EncodeDiagnosis(bytes: bytes, issues: sink.issues, warnings: sink.warnings)
    }

    /// The encoded document as text.
    public func tomlText() throws -> String {
        String(decoding: try encodedTOML(), as: UTF8.self)
    }
}

// MARK: - Content negotiation

extension WireFormat {

    /// TOML, for `parse(body:contentType:accepting:)`. Matches `application/toml`
    /// (RFC 9500 — registered 2024) and any `+toml` structured suffix.
    public static let toml = WireFormat(
        name: "toml",
        matches: { $0.names("toml") },
        decode: { bytes, sink, limits in
            __assayTOMLDocument(bytes, into: &sink, limits: limits)
        })
}

// MARK: - `@Schema(context:)`

/// The contextual door — `docs/EXPERIENCE.md` §10. The same `__assayTOMLDocument` as the
/// context-free door, so the two cannot diverge.
extension ContextualRawDecodable {

    public static func parse(
        toml bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(toml: bytes, context: context,
                     limits: limits, sourceName: sourceName).get()
    }

    public static func parse(
        toml text: String,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try parse(toml: Array(text.utf8), context: context,
                  limits: limits, sourceName: sourceName)
    }

    public static func diagnose(
        toml bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)
        guard let raw = __assayTOMLDocument(bytes, into: &sink, limits: limits) else {
            return Diagnosis(sink: sink, value: nil, source: SourceBytes(bytes), sourceName: sourceName)
        }
        var __rootPath: [PathComponent] = []
        let value = Self._assay(from: raw, into: &sink, at: &__rootPath, context: context)
        return Diagnosis(sink: sink, value: value, source: SourceBytes(bytes), sourceName: sourceName)
    }

    public static func diagnose(
        toml text: String,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        diagnose(toml: Array(text.utf8), context: context,
                 limits: limits, sourceName: sourceName)
    }
}
