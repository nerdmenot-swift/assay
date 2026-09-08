// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `parse(body:contentType:accepting:)`. ROADMAP §9, EXPERIENCE §12.
//
// The design was settled long before the code: `accepting:` is REQUIRED, with no default,
// because an unbounded format guess on untrusted input is how you get XXE and
// billion-laughs. What was missing was a way to write it that did not force `Assay` to
// depend on `AssayYAML` and `AssayXML` — see `WireFormat` for how that resolves.
//
// TWO OVERLOADS, and the difference between them is not stylistic. Everything decodes
// through `RawValue`, which is the projection YAML and XML already use — except JSON, which
// has a byte path that deletes the `Codable` boundary and is the whole performance thesis.
// A JSON body arriving through negotiation must not silently lose that, so the constrained
// overload below special-cases a `.json` match back onto `parse(json:)`.
//===----------------------------------------------------------------------===//

public import AssayCore

extension WireFormat {

    /// JSON. Lives here rather than in `AssayCore` only because `RawValue(JSON.Value)` and
    /// the limits plumbing are both public API — there is nothing format-specific about the
    /// module boundary.
    ///
    /// Matches `application/json`, `text/json`, and any structured suffix per RFC 6839, so
    /// `application/vnd.github.v3+json` is JSON. That last part is not a nicety: most
    /// versioned APIs on the internet spell their content type that way.
    public static let json = WireFormat(
        name: "json",
        matches: { $0.names("json") },
        decode: { bytes, sink, limits in
            guard let v = JSON.Value.decode(bytes, into: &sink, limits: limits) else {
                return nil
            }
            return RawValue(v)
        })
}

extension RawDecodable {

    /// Decode a request body, choosing the parser from `Content-Type`.
    ///
    /// ```swift
    /// let user = try User.parse(body: bytes,
    ///                           contentType: request.headers["Content-Type"],
    ///                           accepting: [.json])
    /// ```
    ///
    /// `accepting:` has **no default**, deliberately. It is the list of parsers a request
    /// body can reach, and that list should be a decision someone wrote down rather than
    /// whatever the library happened to link. A media type outside it is reported as
    /// `unsupported_media_type` — a distinct code from a parse failure, so a server maps it
    /// to 415 rather than 400 — and **no parser is entered**.
    ///
    /// The format is never guessed from the bytes. A missing or unparseable `Content-Type`
    /// is an issue.
    public static func diagnose(
        body bytes: [UInt8],
        contentType: String?,
        accepting: [WireFormat],
        limits: Limits = .default,
        sourceName: String = "<body>"
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)
        switch _assayNegotiate(contentType: contentType, accepting: accepting) {
        case .failure(let why):
            sink.add(why.issue)
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        case .success(let format):
            guard let raw = format.decode(bytes, &sink, limits), sink.isValid else {
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

    /// Throwing form.
    public static func parse(
        body bytes: [UInt8],
        contentType: String?,
        accepting: [WireFormat],
        limits: Limits = .default,
        sourceName: String = "<body>"
    ) throws -> Self {
        try diagnose(body: bytes, contentType: contentType, accepting: accepting,
                     limits: limits, sourceName: sourceName).get()
    }
}

extension RawDecodable where Self: JSONAssayable {

    /// The same entry point, for a type that can also decode JSON from bytes directly.
    ///
    /// A `.json` match routes to `parse(json:)` rather than through `RawValue`, so a JSON
    /// body arriving through negotiation costs exactly what one arriving through the front
    /// door costs. Without this overload, adding content negotiation to a service would
    /// quietly move every JSON request onto the tree path — which is the boundary the whole
    /// library exists to delete.
    public static func diagnose(
        body bytes: [UInt8],
        contentType: String?,
        accepting: [WireFormat],
        limits: Limits = .default,
        sourceName: String = "<body>"
    ) -> Diagnosis<Self> {
        switch _assayNegotiate(contentType: contentType, accepting: accepting) {
        case .failure(let why):
            var sink = IssueSink(limits: limits)
            sink.add(why.issue)
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        case .success(let format) where format.name == "json":
            return diagnose(json: bytes, limits: limits, sourceName: sourceName)
        case .success(let format):
            var sink = IssueSink(limits: limits)
            guard let raw = format.decode(bytes, &sink, limits), sink.isValid else {
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
}
