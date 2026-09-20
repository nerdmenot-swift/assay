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
///
/// `T: Sendable` rather than `T: Assayable`, widened 2026-09-08 for `Assayer<T>`. Strictly
/// wider — `Assayable` refines `Sendable`, so every existing use still compiles — and
/// required because a runtime-built schema produces a `RawValue`, which is not `Assayable`
/// and has no business being.
public struct Diagnosis<T: Sendable>: Sendable {
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

    /// From a sink: the value only if the sink is clean, everything else carried across.
    /// Thirty-three call sites spelled this out by hand until 2026-09-10.
    public init(sink: IssueSink, value: T?, source: SourceBytes, sourceName: String) {
        self.init(value: sink.isValid ? value : nil, issues: sink.issues,
                  warnings: sink.warnings, truncatedIssues: sink.truncatedIssues,
                  source: source, sourceName: sourceName)
    }

    public var isValid: Bool { issues.isEmpty }

    public func get() throws -> T {
        guard let v = value, isValid else {
            throw AssayError(issues: issues, source: source, sourceName: sourceName)
        }
        return v
    }
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

        reader.advanceBy(unsafe UTF8Validation.bomLength(base, count))
        // One path buffer for the whole decode: nested schemas push and pop on it (see
        // `JSONAssayable`), so it never allocates on a clean document.
        var path: [PathComponent] = []
        let v = Self._assay(from: &reader, into: &sink, at: &path)

        // Trailing content is an error, not a shrug.
        // TRAILING CONTENT IS ONLY MEANINGFUL AFTER A VALUE PARSED. When decode failed the
        // reader stopped wherever the syntax error was, so bytes always remain — and this
        // fired as a second, redundant error at the same column on nearly every syntax
        // failure, reporting two problems for one mistake.
        guard v != nil else { return nil }
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
            return Diagnosis(sink: sink, value: nil, source: SourceBytes(bytes), sourceName: sourceName)
        }

        let value: Self? = bytes.withUnsafeBufferPointer { buf -> Self? in
            guard let base = buf.baseAddress else { return nil }
            return unsafe Self._decode(base: base, count: buf.count,
                                       into: &sink, limits: limits)
        }

        return Diagnosis(sink: sink, value: value, source: SourceBytes(bytes), sourceName: sourceName)
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

extension Diagnosis: CustomStringConvertible {
    /// The plain render when anything went wrong; a one-line summary when nothing did.
    /// Never the synthesized dump, which prints the source as an array of bytes.
    public var description: String {
        if issues.isEmpty {
            let w = warnings.count
            return "valid \(T.self)" + (w == 0 ? "" : " (\(w) warning\(w == 1 ? "" : "s"))")
        }
        return render(.plain)
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
    ///
    /// Returns `EncodedBytes`, not `[UInt8]`: the writer owns its buffer and hands it over
    /// here, so nothing copies the document on the way out. `EncodedBytes`'s header carries
    /// the measurement that decided it, and `toArray()` is the way back to a value type.
    public func encodedJSON(pretty: Bool = false) throws -> EncodedBytes {
        var sink = IssueSink()
        var w = JSONWriter(pretty: pretty)
        var path: [PathComponent] = []
        _assayEncode(into: &w, into: &sink, at: &path)
        let bytes = w.finish()
        guard sink.isValid else {
            // Cold, and the only copy on this path: the error carries the partial document
            // so a renderer can point at it.
            throw AssayError(issues: sink.issues,
                             source: SourceBytes(bytes.toArray()),
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
        var path: [PathComponent] = []
        _assayEncode(into: &w, into: &sink, at: &path)
        // `EncodeDiagnosis.bytes` stays `[UInt8]` on purpose — see `EncodedBytes`'s header —
        // so this path, and only this path, copies.
        let bytes = w.finish().toArray()
        return EncodeDiagnosis(bytes: bytes, issues: sink.issues, warnings: sink.warnings)
    }

    /// Convenience: the encoded bytes as a `String`. The writer only ever emits valid
    /// UTF-8, so this cannot repair.
    public func jsonText(pretty: Bool = false) throws -> String {
        try encodedJSON(pretty: pretty).text()
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

extension EncodeDiagnosis: CustomStringConvertible {
    public var description: String {
        if issues.isEmpty {
            let w = warnings.count
            return "valid (\(bytes.count) bytes)" + (w == 0 ? "" : " (\(w) warning\(w == 1 ? "" : "s"))")
        }
        return render(.plain)
    }
}
