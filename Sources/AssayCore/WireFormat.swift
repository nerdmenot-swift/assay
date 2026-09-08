// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A wire format, as a VALUE. `ROADMAP.md` §9, `EXPERIENCE.md` §12.
//
// WHY A VALUE AND NOT AN OVERLOAD SET, which is the design decision content negotiation
// actually turns on. `parse(body:contentType:accepting:)` has to live somewhere that can
// reach every format, and no such place exists in the package graph: `Assay` cannot depend
// on `AssayYAML` (the dependency runs the other way), and `AssayYAML` cannot host a
// json+yaml+xml entry point without also depending on `AssayXML`. Writing one overload per
// combination is 2^n entry points and a new one every time a format is added.
//
// Making a format a value moves the dependency to the CALL SITE, where it already exists:
// a caller that writes `accepting: [.json, .yaml]` has imported `AssayYAML`, so `.yaml` is
// in scope. `Assay` needs to know nothing about it.
//
// `accepting:` IS REQUIRED, WITH NO DEFAULT, and that is a security decision rather than an
// ergonomic one. An unbounded format guess on untrusted input is how a caller ends up
// running an XML parser — with entity expansion, external entities and all the rest — on a
// payload they believed was JSON. The set of parsers reachable from a request body has to be
// something the caller wrote down.
//===----------------------------------------------------------------------===//

/// One wire format a body may be decoded from: how to recognise it, and how to read it.
///
/// `AssayCore` vends `.json`. `AssayYAML` vends `.yaml`, `AssayXML` vends `.xml` — each in
/// the module that owns the parser, so no module gains a dependency it did not already have.
public struct WireFormat: Sendable {
    /// For diagnostics: `json`, `yaml`, `xml`.
    public let name: String

    /// Whether this format claims a parsed media type. Takes the whole `MediaType` rather
    /// than a string so a format can honour structured suffixes — `application/yaml` and
    /// `application/vnd.thing+yaml` are both YAML.
    public let matches: @Sendable (MediaType) -> Bool

    /// Read the body into the format-neutral projection every non-JSON path already uses.
    /// Returns nil having reported into the sink.
    public let decode: @Sendable (_ bytes: [UInt8], _ sink: inout IssueSink, _ limits: Limits)
        -> RawValue?

    public init(
        name: String,
        matches: @escaping @Sendable (MediaType) -> Bool,
        decode: @escaping @Sendable (_ bytes: [UInt8], _ sink: inout IssueSink,
                                     _ limits: Limits) -> RawValue?
    ) {
        self.name = name
        self.matches = matches
        self.decode = decode
    }
}

// MARK: - Negotiation

/// Why a body could not be decoded, before any parser ran.
public enum NegotiationFailure: Sendable, Equatable, Error {
    /// No `Content-Type` at all, or one that is not a media type. **Never sniffed.**
    case missingContentType
    /// A media type the caller did not list in `accepting:`. Distinct from a parse failure
    /// on purpose: a server maps this to 415, not 400.
    case unsupportedMediaType(String)
    /// A charset this library cannot read without transcoding, which it will not do.
    case unreadableCharset(String)
}

extension NegotiationFailure {
    /// The issue this failure reports. Public because the entry points that add it to a
    /// sink live in `Assay`, a different module.
    public var issue: Issue {
        switch self {
        case .missingContentType:
            return Issue(code: .custom("missing_content_type"), path: [],
                         params: ["reason": .string(
                             "no Content-Type, and the format is never guessed from the bytes")])
        case .unsupportedMediaType(let m):
            return Issue(code: .custom("unsupported_media_type"), path: [],
                         params: ["received": .string(m)], received: m)
        case .unreadableCharset(let c):
            return Issue(code: .custom("unreadable_charset"), path: [],
                         params: ["charset": .string(c),
                                  "reason": .string("only UTF-8 and US-ASCII are read; "
                                                    + "this library does not transcode")],
                         received: c)
        }
    }
}

/// Choose the format for a body, or say why not. Runs no parser.
///
/// Separated from decoding so the choice is testable on its own, and so a caller can assert
/// that a rejected media type never reached a parser at all — which is the property that
/// makes `accepting:` worth requiring.
@inlinable
public func _assayNegotiate(
    contentType: String?, accepting: [WireFormat]
) -> Result<WireFormat, NegotiationFailure> {
    guard let header = contentType, let media = MediaType.parse(header) else {
        return .failure(.missingContentType)
    }
    guard media.charsetIsReadable else {
        return .failure(.unreadableCharset(media.charset ?? "?"))
    }
    guard let format = accepting.first(where: { $0.matches(media) }) else {
        let s = media.suffix.map { "\(media.type)/\(media.subtype)+\($0)" }
            ?? "\(media.type)/\(media.subtype)"
        return .failure(.unsupportedMediaType(s))
    }
    return .success(format)
}
