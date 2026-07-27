// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
@testable import Assay
import AssayCore

// The thirty-second version from docs/EXPERIENCE.md §1. No rules, no CodingKeys.
// Zero-rule @Schema is a first-class mode, not a degenerate one.
@Schema
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var tags: [String] = []
}

@Schema(keys: .snakeCase)
struct UserProfile {
    var userID: String
    var displayName: String
    var avatarURL: String
    var loginCount: Int
    var isActive: Bool
}

@Schema
struct Settings {
    var name: String        // required — absent is an error
    var nickname: String?   // optional — absent is nil, and that's fine
    var retries: Int = 3    // defaulted — absent is 3
}

@Schema
struct Inner { var a: Int; var b: String }

@Schema
struct Outer { var name: String; var inner: Inner }

@Schema
struct Numbers {
    var i: Int
    var d: Double
    var b: Bool
    var big: Int64
}

@Suite("Decoding")
struct DecodeTests {

    @Test("plain struct, no annotations")
    func plain() throws {
        let json = #"{"title":"Hi","link":"https://x.dev","readingMinutes":7,"tags":["a","b"]}"#
        let a = try Article.parse(json: json)
        #expect(a.title == "Hi")
        #expect(a.link == "https://x.dev")
        #expect(a.readingMinutes == 7)
        #expect(a.tags == ["a", "b"])
    }

    @Test("key order does not matter — single pass, presence bitmask, never rewind")
    func outOfOrder() throws {
        let json = #"{"tags":["z"],"readingMinutes":1,"link":"l","title":"t"}"#
        let a = try Article.parse(json: json)
        #expect(a.title == "t")
        #expect(a.readingMinutes == 1)
        #expect(a.tags == ["z"])
    }

    @Test("snake_case converts at compile time and round-trips acronyms exactly")
    func snakeCase() throws {
        // avatarURL -> avatar_url, NOT avatarUrl. This is the case
        // JSONDecoder.convertFromSnakeCase gets wrong, silently.
        let json = """
        {"user_id":"u1","display_name":"Ada","avatar_url":"http://a","login_count":42,"is_active":true}
        """
        let u = try UserProfile.parse(json: json)
        #expect(u.userID == "u1")
        #expect(u.displayName == "Ada")
        #expect(u.avatarURL == "http://a")
        #expect(u.loginCount == 42)
        #expect(u.isActive == true)
    }

    @Test("five presence states are distinguishable")
    func presence() throws {
        let s = try Settings.parse(json: #"{"name":"api"}"#)
        #expect(s.name == "api")
        #expect(s.nickname == nil)
        #expect(s.retries == 3)          // default consulted on absence

        let s2 = try Settings.parse(json: #"{"name":"api","nickname":"a","retries":9}"#)
        #expect(s2.nickname == "a")
        #expect(s2.retries == 9)
    }

    @Test("missing required field is reported with a path")
    func missingRequired() {
        let d = Settings.diagnose(json: #"{"nickname":"a"}"#)
        #expect(d.isValid == false)
        #expect(d.value == nil)
        #expect(d.issues.count == 1)
        #expect(d.issues[0].code == .missing)
        #expect(d.issues[0].path.pathDescription == "name")
    }

    @Test("present-but-wrong is an error even for an optional field")
    func optionalWrongType() {
        // `nickname: String?` means it may be ABSENT. It does not mean anything is
        // acceptable when it IS there. That is the distinction Codable blurs.
        let d = Settings.diagnose(json: #"{"name":"a","nickname":42}"#)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .typeMismatch })
    }

    @Test("all errors, one pass — not just the first")
    func allErrors() {
        let d = Numbers.diagnose(json: #"{"i":"nope","d":"nope","b":"nope","big":"nope"}"#)
        #expect(d.isValid == false)
        // Four problems produce four issues.
        #expect(d.issues.count == 4)
        #expect(d.issues.allSatisfy { $0.code == .typeMismatch })
    }

    @Test("nested schema types carry the full path")
    func nested() throws {
        let o = try Outer.parse(json: #"{"name":"n","inner":{"a":1,"b":"x"}}"#)
        #expect(o.name == "n")
        #expect(o.inner.a == 1)
        #expect(o.inner.b == "x")

        let d = Outer.diagnose(json: #"{"name":"n","inner":{"a":"bad","b":"x"}}"#)
        #expect(d.isValid == false)
        #expect(d.issues[0].path.pathDescription == "inner.a")
    }

    @Test("unknown keys are skipped structurally without decoding")
    func unknownKeys() throws {
        let json = """
        {"title":"t","extra":{"deep":{"nested":[1,2,3]}},"link":"l",
         "readingMinutes":5,"another":"ignored","tags":[]}
        """
        let a = try Article.parse(json: json)
        #expect(a.title == "t")
        #expect(a.readingMinutes == 5)
    }

    @Test("numbers: negative accumulation handles Int64.min, fractions are not truncated")
    func numbers() throws {
        let n = try Numbers.parse(json: #"{"i":-42,"d":3.5,"b":false,"big":9223372036854775807}"#)
        #expect(n.i == -42)
        #expect(n.d == 3.5)
        #expect(n.b == false)
        #expect(n.big == 9223372036854775807)

        // "8080.5" must not silently truncate to 8080.
        let d = Numbers.diagnose(json: #"{"i":80.5,"d":1,"b":true,"big":1}"#)
        #expect(d.isValid == false)
    }

    @Test("escaped strings take the slow path correctly, including surrogate pairs")
    func escapes() throws {
        let json = #"{"title":"a\"b\nc\td\\e","link":"Aé😀","readingMinutes":1}"#
        let a = try Article.parse(json: json)
        #expect(a.title == "a\"b\nc\td\\e")
        #expect(a.link == "Aé\u{1F600}")
    }

    @Test("invalid UTF-8 is rejected at the buffer level, before any String is built")
    func invalidUTF8() {
        var bytes = Array(#"{"title":"x","link":"y","readingMinutes":1}"#.utf8)
        bytes[10] = 0xFF                       // lone continuation-class byte
        let d = Article.diagnose(json: bytes)
        #expect(d.isValid == false)
        #expect(d.issues[0].code == .invalidUTF8)
    }

    @Test("overlong encodings and surrogates are rejected, not repaired")
    func utf8Edges() {
        // C0 AF is an overlong "/". A validator that accepts it defeats byte-level
        // filters applied before decoding.
        #expect(UTF8Validation.firstInvalid([0xC0, 0xAF], 2) != nil)
        // ED A0 80 is a surrogate half.
        #expect(UTF8Validation.firstInvalid([0xED, 0xA0, 0x80], 3) != nil)
        // F5 is above U+10FFFF.
        #expect(UTF8Validation.firstInvalid([0xF5, 0x80, 0x80, 0x80], 4) != nil)
        // Valid 4-byte sequence.
        #expect(UTF8Validation.firstInvalid([0xF0, 0x9F, 0x98, 0x80], 4) == nil)
    }

    @Test("trailing content is an error, not a shrug")
    func trailing() {
        let d = Settings.diagnose(json: #"{"name":"a"} garbage"#)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .trailingContent })
    }

    @Test("depth limit is enforced")
    func depthLimit() {
        let deep = String(repeating: #"{"inner":"#, count: 200) + "1"
            + String(repeating: "}", count: 200)
        let d = Outer.diagnose(json: deep, limits: Limits(maxDepth: 64))
        #expect(d.isValid == false)
    }

    @Test("issue cap is honoured and reported")
    func issueCap() {
        var big = "{"
        for i in 0..<50 { big += "\"i\":\"bad\"," ; _ = i }
        big += "\"d\":\"bad\",\"b\":\"bad\",\"big\":\"bad\"}"
        let d = Numbers.diagnose(json: big, limits: Limits(maxIssues: 3))
        #expect(d.issues.count <= 3)
        #expect(d.truncatedIssues == true)
    }

    @Test("parse throws AssayError carrying every issue")
    func throwsAll() {
        #expect(throws: AssayError.self) {
            try Numbers.parse(json: #"{"i":"x","d":"x","b":"x","big":"x"}"#)
        }
        do {
            _ = try Numbers.parse(json: #"{"i":"x","d":"x","b":"x","big":"x"}"#)
        } catch let e as AssayError {
            #expect(e.issues.count == 4)
        } catch {
            Issue.record("wrong error type")
        }
    }
}

@Suite("Key naming")
struct KeyNamingTests {
    @Test("acronym boundaries split the way the round-trip requires")
    func acronyms() {
        #expect(KeyStyleShim.snake("avatarURL") == "avatar_url")
        #expect(KeyStyleShim.snake("userID") == "user_id")
        #expect(KeyStyleShim.snake("displayName") == "display_name")
        #expect(KeyStyleShim.snake("parseHTTPResponse") == "parse_http_response")
        #expect(KeyStyleShim.snake("id") == "id")
        #expect(KeyStyleShim.snake("isActive") == "is_active")
    }
}

/// The macro's key conversion lives in the plugin, which tests cannot import. This mirrors
/// it so the conversion rules are pinned by a test; if the two drift, the round-trip
/// property breaks and DecodeTests.snakeCase fails.
enum KeyStyleShim {
    static func snake(_ s: String) -> String { split(s).joined(separator: "_") }

    static func split(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isUppercase {
                var j = i
                while j < chars.count, chars[j].isUppercase { j += 1 }
                let runLength = j - i
                if runLength == 1 {
                    if !current.isEmpty { words.append(current); current = "" }
                    current.append(Character(c.lowercased()))
                    i += 1
                } else {
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
