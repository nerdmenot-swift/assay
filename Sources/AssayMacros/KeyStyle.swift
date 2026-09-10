// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Key naming. Converted at *compile* time from the declared identifier.
//
// This is why Assay's key handling is not merely a reimplementation of
// `.convertFromSnakeCase`. Foundation converts at runtime, on the wire key, and it is
// lossy: `avatarURL` encodes as `avatar_url`, which decodes back as `avatarUrl` — a
// different property. Converting from the real declared identifier keeps the acronym
// information intact, so `avatarURL -> avatar_url -> avatarURL` round-trips exactly.
//===----------------------------------------------------------------------===//

enum KeyStyle: String {
    case camelCase
    case snakeCase
    case kebabCase
    case pascalCase
    case screamingSnakeCase

    func apply(_ identifier: String) -> String {
        switch self {
        case .camelCase:
            return identifier
        case .pascalCase:
            guard let f = identifier.first else { return identifier }
            return f.uppercased() + identifier.dropFirst()
        case .snakeCase:
            return Self.split(identifier).joined(separator: "_")
        case .kebabCase:
            return Self.split(identifier).joined(separator: "-")
        case .screamingSnakeCase:
            return Self.split(identifier).map { $0.uppercased() }.joined(separator: "_")
        }
    }

    /// Split an identifier into lowercased words, treating a run of capitals as one word
    /// so `avatarURL` -> ["avatar", "url"] and `parseHTTPResponse` -> ["parse", "http",
    /// "response"]. The acronym boundary is the whole point.
    static func split(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isUppercase {
                // Start of an acronym run?
                var j = i
                while j < chars.count, chars[j].isUppercase { j += 1 }
                let runLength = j - i
                if runLength == 1 {
                    if !current.isEmpty { words.append(current); current = "" }
                    current.append(Character(c.lowercased()))
                    i += 1
                } else {
                    // A run of >=2 capitals. If it is followed by a lowercase letter, the
                    // final capital begins the *next* word: `HTTPResponse` -> HTTP,
                    // Response.
                    let endsWord = j < chars.count && chars[j].isLowercase
                    let acronymEnd = endsWord ? j - 1 : j
                    if !current.isEmpty { words.append(current); current = "" }
                    words.append(String(chars[i..<acronymEnd]).lowercased())
                    i = acronymEnd
                }
            } else if c == "_" || c == "-" {
                if !current.isEmpty { words.append(current); current = "" }
                i += 1
            } else {
                current.append(c)
                i += 1
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { !$0.isEmpty }
    }
}
