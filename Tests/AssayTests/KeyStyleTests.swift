// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Key naming styles. `KeyStyle.apply` is where `avatarURL` becomes `avatar_url` at COMPILE
// time — the whole argument against `.convertFromSnakeCase` — and until 2026-09-10 only
// `.snakeCase` had a test. Three of the five styles, and the acronym and digit rules they
// share, are pinned here: once at the unit (`KeyStyle.apply`), once end-to-end through a
// decode, so a change to the splitter cannot pass one and fail the other.
//===----------------------------------------------------------------------===//

import Testing
import Assay
@testable import AssayMacros

@Suite("Key styles — KeyStyle.apply")
struct KeyStyleUnitTests {

    @Test("every style on the same identifiers", arguments: [
        // identifier, camel, snake, kebab, pascal, screaming
        ("title",            "title",            "title",              "title",              "Title",            "TITLE"),
        ("readingMinutes",   "readingMinutes",   "reading_minutes",    "reading-minutes",    "ReadingMinutes",   "READING_MINUTES"),
        ("avatarURL",        "avatarURL",        "avatar_url",         "avatar-url",         "AvatarURL",        "AVATAR_URL"),
        ("parseHTTPResponse","parseHTTPResponse","parse_http_response","parse-http-response","ParseHTTPResponse","PARSE_HTTP_RESPONSE"),
        ("id",               "id",               "id",                 "id",                 "Id",               "ID"),
        ("x",                "x",                "x",                  "x",                  "X",                "X"),
        ("URL",              "URL",              "url",                "url",                "URL",              "URL"),
        ("line2",            "line2",            "line2",              "line2",              "Line2",            "LINE2"),
        ("address2Line",     "address2Line",     "address2_line",      "address2-line",      "Address2Line",     "ADDRESS2_LINE"),
        ("iOSVersion",       "iOSVersion",       "i_os_version",       "i-os-version",       "IOSVersion",       "I_OS_VERSION"),
    ])
    func styles(_ id: String, _ camel: String, _ snake: String, _ kebab: String,
                _ pascal: String, _ screaming: String) {
        #expect(KeyStyle.camelCase.apply(id) == camel)
        #expect(KeyStyle.snakeCase.apply(id) == snake)
        #expect(KeyStyle.kebabCase.apply(id) == kebab)
        #expect(KeyStyle.pascalCase.apply(id) == pascal)
        #expect(KeyStyle.screamingSnakeCase.apply(id) == screaming)
    }

    @Test("the acronym rule: a run of capitals is one word, its last capital starts the next word when followed by lowercase")
    func acronyms() {
        #expect(KeyStyle.split("HTTPResponse") == ["http", "response"])
        #expect(KeyStyle.split("avatarURL") == ["avatar", "url"])
        #expect(KeyStyle.split("URLSessionID") == ["url", "session", "id"])
    }
}

@Schema(keys: .kebabCase)
struct KebabDoc: Equatable { var readingMinutes: Int; var avatarURL: String }

@Schema(keys: .pascalCase)
struct PascalDoc: Equatable { var readingMinutes: Int; var avatarURL: String }

@Schema(keys: .screamingSnakeCase, encodes: true)
struct ScreamingDoc: Equatable { var readingMinutes: Int; var avatarURL: String }

@Suite("Key styles — end to end")
struct KeyStyleDecodeTests {

    @Test("kebab-case keys decode")
    func kebab() throws {
        let v = try KebabDoc.parse(json: #"{"reading-minutes":3,"avatar-url":"/a"}"#)
        #expect(v == KebabDoc(readingMinutes: 3, avatarURL: "/a"))
    }

    @Test("PascalCase keys decode, and an acronym keeps its capitals")
    func pascal() throws {
        let v = try PascalDoc.parse(json: #"{"ReadingMinutes":3,"AvatarURL":"/a"}"#)
        #expect(v == PascalDoc(readingMinutes: 3, avatarURL: "/a"))
    }

    @Test("SCREAMING_SNAKE keys decode, and the missing-key message names the wire key")
    func screaming() throws {
        let v = try ScreamingDoc.parse(json: #"{"READING_MINUTES":3,"AVATAR_URL":"/a"}"#)
        #expect(v == ScreamingDoc(readingMinutes: 3, avatarURL: "/a"))
        let d = ScreamingDoc.diagnose(json: #"{"READING_MINUTES":3}"#)
        #expect(d.issues.first?.path.pathDescription == "AVATAR_URL")
        // And the style round-trips through the encoder.
        #expect(try v.jsonText() == #"{"READING_MINUTES":3,"AVATAR_URL":"/a"}"#)
    }
}
