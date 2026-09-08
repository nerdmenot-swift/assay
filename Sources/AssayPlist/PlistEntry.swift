// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `parse(plist:)` — EXPERIENCE.md §1, ROADMAP.md §10.
//
//     @Schema(formats: .all)
//     struct Settings { var name: String; var retries: Int }
//
//     let s = try Settings.parse(plist: bytes)
//
// TWO FLAVOURS, ONE ENTRY POINT, AND THAT IS NOT SNIFFING. `parse(body:contentType:accepting:)`
// refuses to guess a *format* from bytes, and that refusal stands: it is the difference
// between a caller who said "this is JSON" and a decoder that decided. Here the caller has
// said "this is a property list", and binary and XML are two encodings of the one format the
// caller named — the same relation UTF-8 and UTF-16 have inside XML, which every XML parser
// resolves from the bytes. The discriminator is also exact rather than heuristic: `bplist00`
// is eight magic bytes at offset zero, not a shape someone recognised.
//
// A caller who wants to REQUIRE one encoding has `parse(binaryPlist:)` and `parse(xmlPlist:)`.
// The default is the one that reads what Apple's tooling actually emits, which is either.
//
// The core stays Foundation-free: `PropertyListSerialization` is not linked, not referenced,
// and not available on Linux or Windows, where this decodes exactly as it does on Darwin.
//===----------------------------------------------------------------------===//

public import Assay
public import AssayCore

extension RawDecodable {

    /// Decode from a property list — binary or XML, discriminated by the `bplist00` magic.
    public static func parse(
        plist bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(plist: bytes, limits: limits, sourceName: sourceName).get()
    }

    public static func diagnose(
        plist bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        decodePlist(bytes, limits: limits, sourceName: sourceName) { b, sink, lim in
            Plist.decode(b, into: &sink, limits: lim)
        }
    }

    /// Binary only. For a caller who has a reason to refuse the XML flavour — a size budget,
    /// or a producer contract that says the file is generated.
    public static func parse(
        binaryPlist bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try decodePlist(bytes, limits: limits, sourceName: sourceName) { b, sink, lim in
            BinaryPlist.decode(b, into: &sink, limits: lim)
        }.get()
    }

    /// XML only.
    public static func parse(
        xmlPlist bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try decodePlist(bytes, limits: limits, sourceName: sourceName) { b, sink, lim in
            XMLPlist.decode(b, into: &sink, limits: lim)
        }.get()
    }

    public static func parse(
        plist text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try parse(plist: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    public static func diagnose(
        plist text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        diagnose(plist: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    /// The shared shell: byte cap, produce a `RawValue`, run the generated body, wrap.
    /// One copy, so the three entry points cannot drift on what a too-large document does.
    static func decodePlist(
        _ bytes: [UInt8],
        limits: Limits,
        sourceName: String,
        _ produce: ([UInt8], inout IssueSink, Limits) -> RawValue?
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)
        if bytes.count > limits.maxBytes {
            sink.add(Issue(code: .tooManyBytes, params: ["maxBytes": .int(limits.maxBytes)]))
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }
        guard let raw = produce(bytes, &sink, limits) else {
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
}

/// The value-model door, for callers who want the tree rather than a schema — the same shape
/// `YAML.decodeAll` and `XML.decode` present.
public enum Plist {

    /// Which encoding a document is in. Exact, from the magic — never a guess about shape.
    public enum Encoding: Sendable, Equatable {
        case binary
        case xml
    }

    public static func encoding(of bytes: [UInt8]) -> Encoding {
        bytes.count >= 8 && Array(bytes[0..<8]) == BinaryPlist.magic ? .binary : .xml
    }

    /// Decode either flavour to `RawValue`, or nil having reported into `sink`.
    public static func decode(
        _ bytes: [UInt8], into sink: inout IssueSink, limits: Limits = .default
    ) -> RawValue? {
        switch encoding(of: bytes) {
        case .binary: return BinaryPlist.decode(bytes, into: &sink, limits: limits)
        case .xml:    return XMLPlist.decode(bytes, into: &sink, limits: limits)
        }
    }
}

// MARK: - The contextual door

/// `@Schema(context:)` types get `parse(plist:context:)` for the same reason they get
/// `parse(yaml:context:)`: a contextual type does not conform to `RawDecodable`, so the
/// entry points above do not exist for it and cannot be reached by forgetting an argument.
extension ContextualRawDecodable {

    public static func parse(
        plist bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(plist: bytes, context: context,
                     limits: limits, sourceName: sourceName).get()
    }

    public static func diagnose(
        plist bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)
        if bytes.count > limits.maxBytes {
            sink.add(Issue(code: .tooManyBytes, params: ["maxBytes": .int(limits.maxBytes)]))
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }
        guard let raw = Plist.decode(bytes, into: &sink, limits: limits) else {
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }
        let value = Self._assay(from: raw, into: &sink, at: [], context: context)
        return Diagnosis(value: sink.isValid ? value : nil,
                         issues: sink.issues, warnings: sink.warnings,
                         truncatedIssues: sink.truncatedIssues,
                         source: SourceBytes(bytes), sourceName: sourceName)
    }
}
