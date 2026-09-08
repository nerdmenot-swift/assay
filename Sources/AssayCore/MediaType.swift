// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `Content-Type`, parsed. RFC 9110 §8.3 for the grammar, RFC 6839 for the `+json` /
// `+yaml` / `+xml` structured suffixes.
//
// The suffixes are the part people get wrong, and getting them wrong is not cosmetic:
// `application/vnd.github.v3+json` IS json, and a negotiator that does not know that
// rejects most versioned APIs on the internet. Likewise `image/svg+xml`.
//
// THE SECURITY POSITION, which is why this file is stricter than it looks:
//
//   * A missing, empty or unparseable `Content-Type` is an ISSUE. There is no sniffing,
//     ever. Guessing a format from bytes is how a caller ends up running an XML parser on
//     a payload they believed was JSON, and `accepting:` exists precisely so the set of
//     parsers reachable from untrusted input is a decision the caller wrote down.
//   * `charset` is CHECKED and never transcoded. The core is Foundation-free and has no
//     converter; refusing `charset=iso-8859-1` is correct, and quietly treating it as
//     UTF-8 would be the quiet wrongness this library exists to remove.
//===----------------------------------------------------------------------===//

/// A parsed `Content-Type` header: a lowercased type and subtype, plus whatever the
/// `charset` parameter said.
public struct MediaType: Sendable, Equatable {
    /// Lowercased, e.g. `application`.
    public let type: String
    /// Lowercased and WITHOUT any structured suffix, e.g. `vnd.github.v3` for
    /// `application/vnd.github.v3+json`.
    public let subtype: String
    /// Lowercased structured suffix without the `+`, e.g. `json`. Nil when there is none.
    public let suffix: String?
    /// Lowercased `charset` parameter, if the header carried one.
    public let charset: String?

    public init(type: String, subtype: String, suffix: String? = nil, charset: String? = nil) {
        self.type = type
        self.subtype = subtype
        self.suffix = suffix
        self.charset = charset
    }

    /// Whether this media type names `name` either directly (`application/json`) or through
    /// a structured suffix (`application/vnd.github.v3+json`).
    public func names(_ name: String) -> Bool {
        subtype == name || suffix == name
    }

    /// True when the charset is absent or something this library can read without
    /// transcoding. `us-ascii` is a subset of UTF-8, so it is accepted by inclusion.
    public var charsetIsReadable: Bool {
        guard let c = charset else { return true }
        return c == "utf-8" || c == "utf8" || c == "us-ascii" || c == "ascii"
    }

    /// Parse a `Content-Type` header value, or nil if it is not one.
    ///
    /// Deliberately small: type/subtype, parameters split on `;`, `charset` picked out,
    /// everything else ignored. Quoted parameter values are unquoted; a `q=` or `boundary=`
    /// is none of this library's business.
    public static func parse(_ header: String) -> MediaType? {
        var parts = header.split(separator: ";", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        let essence = parts.removeFirst().trimmedASCII().lowercasedASCII()
        guard let slash = essence.firstIndex(of: "/") else { return nil }
        let type = String(essence[essence.startIndex..<slash])
        var rest = String(essence[essence.index(after: slash)...])
        guard !type.isEmpty, !rest.isEmpty else { return nil }
        // A bare `+json` with no subtype is not a media type.
        guard !rest.hasPrefix("+") else { return nil }

        var suffix: String? = nil
        if let plus = rest.lastIndex(of: "+") {
            suffix = String(rest[rest.index(after: plus)...])
            rest = String(rest[rest.startIndex..<plus])
            if suffix?.isEmpty == true { suffix = nil }
        }

        var charset: String? = nil
        for p in parts {
            let kv = p.trimmedASCII()
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let key = String(kv[kv.startIndex..<eq]).trimmedASCII().lowercasedASCII()
            guard key == "charset" else { continue }
            var value = String(kv[kv.index(after: eq)...]).trimmedASCII()
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            charset = value.lowercasedASCII()
        }

        return MediaType(type: type, subtype: rest, suffix: suffix, charset: charset)
    }
}

// ASCII-only case folding and trimming, so the core stays Foundation-free and behaves
// identically on every platform. A media type is ASCII by grammar, so there is nothing to
// lose here — and `lowercased()` on a `String` is locale-sensitive in ways that have
// famously broken Turkish-locale builds of other libraries.
extension StringProtocol {
    fileprivate func lowercasedASCII() -> String {
        String(decoding: utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }

    fileprivate func trimmedASCII() -> String {
        var b = Array(utf8)
        while let f = b.first, f == 0x20 || f == 0x09 { b.removeFirst() }
        while let l = b.last, l == 0x20 || l == 0x09 { b.removeLast() }
        return String(decoding: b, as: UTF8.self)
    }
}
