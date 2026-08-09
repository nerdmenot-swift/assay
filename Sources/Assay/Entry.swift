// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The two verbs. docs/EXPERIENCE.md §2.
//
//   parse    — you want the value, and a failure is exceptional. Throws AssayError,
//              which carries *all* the issues, not the first one. Discards warnings.
//   diagnose — you want everything that happened, including the value.
//
// `validate` was cut: it collided with ParsableArguments.validate() in
// swift-argument-parser and with Vapor's Validatable.validate(), and two of the three
// verbs had the same shape anyway.
//
// The core takes bytes, not Data. Data is Foundation, so a Data-typed core API is not
// portable — and Data's performance story now *favours* the non-Apple platforms, because
// Apple retains a legacy ABI the others were free to drop. A Data-typed hot path is
// therefore the one place performance would genuinely differ by platform.
//===----------------------------------------------------------------------===//

/// Everything that happened during a decode.
public struct Diagnosis<T: Assayable>: Sendable {
    /// Present if decoding produced a usable value.
    public var value: T?
    /// Hard failures.
    public var issues: [Issue]
    /// Fallbacks that fired, aliases that matched, unknown keys that were tolerated.
    public var warnings: [Warning]
    /// True when `Limits.maxIssues` was hit — so a caller can tell a hundred-of-a-hundred
    /// from a hundred-of-ten-thousand.
    public var truncatedIssues: Bool
    /// Retained so `render` can produce carets without the caller holding the bytes.
    ///
    /// A `SourceBytes` rather than `[UInt8]` so the mmap path can *borrow* the mapping
    /// instead of copying it — a 10 GB file must not become a 10 GB array just to keep
    /// carets renderable. See AssayCore/SourceBytes.swift.
    public let source: SourceBytes
    public let sourceName: String

    public init(
        value: T?, issues: [Issue], warnings: [Warning],
        truncatedIssues: Bool, source: SourceBytes, sourceName: String
    ) {
        self.value = value
        self.issues = issues
        self.warnings = warnings
        self.truncatedIssues = truncatedIssues
        self.source = source
        self.sourceName = sourceName
    }

    public var isValid: Bool { issues.isEmpty }

    public func get() throws -> T {
        guard let v = value, isValid else {
            throw AssayError(issues: issues, source: source, sourceName: sourceName)
        }
        return v
    }
}

/// The thrown type.
///
/// A struct wrapping a single class reference, so it stays **pointer-sized**. serde_json's
/// maintainers state plainly that "a larger Error type was substantially slower due to all
/// the functions that pass around Result<T, Error>", and moved to a boxed representation
/// for exactly that reason. A `throws` function returns its error in the callee-saved
/// `swifterror` register, which is why the happy path pays nothing — but only if the value
/// fits.
public struct AssayError: Error, Sendable {
    @usableFromInline final class Storage: @unchecked Sendable {
        let issues: [Issue]
        let source: SourceBytes
        let sourceName: String
        init(issues: [Issue], source: SourceBytes, sourceName: String) {
            self.issues = issues
            self.source = source
            self.sourceName = sourceName
        }
    }

    @usableFromInline let storage: Storage

    /// Public so out-of-module encoders (AssayYAML) can throw the same error type.
    /// docs/ENCODING.md question 4: one error vocabulary across every format.
    public init(issues: [Issue], source: SourceBytes, sourceName: String) {
        self.storage = Storage(issues: issues, source: source, sourceName: sourceName)
    }

    public var issues: [Issue] { storage.issues }
}

extension JSONAssayable {

    /// The shared decode core. Both `diagnose(json:)` and `diagnose(mmapped:)` funnel
    /// through here, so the mmap path cannot drift from the in-memory one — same
    /// whole-buffer UTF-8 validation, same scanner, same trailing-content check.
    public static func _decode(
        base: UnsafePointer<UInt8>,
        count: Int,
        into sink: inout IssueSink,
        limits: Limits
    ) -> Self? {
        // One whole-buffer UTF-8 pass at entry, never per-string. serde_json's per-string
        // validation costs 1.65x on twitter.json; sonic-rs made exactly this change.
        // Sound only because the input is a single contiguous buffer that cannot change
        // underneath the parse — which an mmap'd file satisfies literally.
        if let bad = unsafe UTF8Validation.firstInvalid(base, count) {
            sink.add(Issue(
                code: .invalidUTF8,
                params: ["offset": .int(bad)],
                location: SourceSpan(lo: bad, len: 1)))
            return nil
        }

        var reader = unsafe AssayReader(base: base, count: count, limits: limits)
        let v = Self._assay(from: &reader, into: &sink, at: [])

        // Trailing content is an error, not a shrug.
        reader.skipWhitespace()
        if !reader.atEnd {
            sink.add(Issue(code: .trailingContent,
                           location: SourceSpan(lo: reader.byteOffset, len: 1)))
            return nil
        }
        return v
    }

    /// Decode, or throw with every issue found.
    public static func parse(
        json bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        let d = diagnose(json: bytes, limits: limits, sourceName: sourceName)
        return try d.get()
    }

    /// Decode and report everything, including the value when one was produced.
    public static func diagnose(
        json bytes: [UInt8],
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

        let value: Self? = bytes.withUnsafeBufferPointer { buf -> Self? in
            guard let base = buf.baseAddress else { return nil }
            return unsafe Self._decode(base: base, count: buf.count,
                                       into: &sink, limits: limits)
        }

        return Diagnosis(
            value: sink.isValid ? value : nil,
            issues: sink.issues,
            warnings: sink.warnings,
            truncatedIssues: sink.truncatedIssues,
            source: SourceBytes(bytes),
            sourceName: sourceName)
    }

    /// Convenience for text input.
    public static func parse(
        json text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try parse(json: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    public static func diagnose(
        json text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        diagnose(json: Array(text.utf8), limits: limits, sourceName: sourceName)
    }
}

// MARK: - Rendering

extension Diagnosis {

    /// Render every issue and warning.
    ///
    ///     print(d.render(.terminal))
    ///
    ///     deploy.yaml:4:13: error: replicas must be at least 1
    ///       2 │ deployment:
    ///       3 │   name: api
    ///       4 │   replicas: 0
    ///         │             ^
    ///       5 │   image: api:1.4
    ///
    /// `.terminal` disables colour automatically when stdout is not a TTY. `.plain` is the
    /// same output with no ANSI, `.json` is a stable machine shape with codes and params,
    /// `.problemDetails` is RFC 9457.
    public func render(_ style: RenderStyle) -> String {
        Renderer.render(issues: issues, warnings: warnings,
                        source: source, sourceName: sourceName, style: style)
    }
}

extension AssayError {

    /// Render every issue. The error retains the source, so carets work here too —
    /// `catch let e as AssayError { print(e.render(.plain)) }` needs nothing else.
    public func render(_ style: RenderStyle) -> String {
        Renderer.render(issues: storage.issues, warnings: [],
                        source: storage.source, sourceName: storage.sourceName,
                        style: style)
    }
}

// MARK: - Encoding
//
// docs/ENCODING.md. The two verbs mirror the decode side exactly, and deliberately: one
// error vocabulary, one set of renderers, one mental model. `encode` throws when anything
// could not be represented; `diagnoseEncode` hands back what it managed plus every issue.
//
// Q4: issues carry a `path` and no `location`, because there is no source document to
// point at — a state the renderer has always handled, since a missing-field issue has
// never had one either.

extension JSONEncodableSchema {

    /// Write this value as JSON, or throw with everything that could not be represented.
    public func encodedJSON(pretty: Bool = false) throws -> [UInt8] {
        var sink = IssueSink()
        var w = JSONWriter(pretty: pretty)
        _assayEncode(into: &w, into: &sink, at: [])
        let bytes = w.finish()
        guard sink.isValid else {
            throw AssayError(issues: sink.issues,
                             source: SourceBytes(bytes),
                             sourceName: "<encoded>")
        }
        return bytes
    }

    /// Write this value as JSON and report everything, including the bytes it managed.
    ///
    /// The partial output is genuinely useful: an unrepresentable `Double` in field 40 of
    /// 50 still tells you what the other 49 looked like, and the issue names the path.
    public func diagnoseEncodeJSON(pretty: Bool = false) -> EncodeDiagnosis {
        var sink = IssueSink()
        var w = JSONWriter(pretty: pretty)
        _assayEncode(into: &w, into: &sink, at: [])
        let bytes = w.finish()
        return EncodeDiagnosis(bytes: bytes, issues: sink.issues, warnings: sink.warnings)
    }

    /// Convenience: the encoded bytes as a `String`. The writer only ever emits valid
    /// UTF-8, so this cannot repair.
    public func jsonText(pretty: Bool = false) throws -> String {
        String(decoding: try encodedJSON(pretty: pretty), as: UTF8.self)
    }
}

/// What `diagnoseEncode` reports.
///
/// Deliberately NOT a second `Diagnosis` generic: the decode version's `value` is the
/// thing you were trying to produce, and here the thing you were trying to produce is the
/// bytes. Sharing `Issue`, `Warning` and the renderers is the part that matters — inventing
/// a parallel error hierarchy is what `docs/ENCODING.md` question 4 rules out.
public struct EncodeDiagnosis: Sendable {
    /// Everything the writer managed, truncated wherever it stopped.
    public var bytes: [UInt8]
    public var issues: [Issue]
    public var warnings: [Warning]

    public init(bytes: [UInt8], issues: [Issue], warnings: [Warning]) {
        self.bytes = bytes
        self.issues = issues
        self.warnings = warnings
    }

    public var isValid: Bool { issues.isEmpty }
    public var text: String { String(decoding: bytes, as: UTF8.self) }

    public func get() throws -> [UInt8] {
        guard isValid else {
            throw AssayError(issues: issues, source: SourceBytes(bytes),
                             sourceName: "<encoded>")
        }
        return bytes
    }

    /// Same renderers as the decode side — that is the whole point of reusing `Issue`.
    public func render(_ style: RenderStyle) -> String {
        Renderer.render(issues: issues, warnings: warnings,
                        source: SourceBytes(bytes), sourceName: "<encoded>", style: style)
    }
}
