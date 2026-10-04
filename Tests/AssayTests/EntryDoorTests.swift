// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayFoundation
import AssayPlist
import AssayTOML
import AssayYAML

//===----------------------------------------------------------------------===//
// The doors nothing walked through.
//
// Every entry point here is a thin wrapper over a primitive some other test exercises, and
// that is exactly why none of them had a test: `parse(mmappedPath:)` was covered, so the
// `URL` overload beside it read as covered too. It was not — it is its own copy of the
// open/decode/borrow sequence, and so is the contextual one. The same is true of the
// contextual TOML and plist doors, which are a second body rather than a call into the
// plain one, because the context has to reach `_assay`.
//
// A copied body is where a door drifts. `MappedParsing.swift` records one such drift in a
// comment (the `JSON.Value` door had its own loop and lost shape memory), so each test
// below is an EQUALITY against the door that is already trusted, not a re-test of decoding.
//===----------------------------------------------------------------------===//

// MARK: - Fixtures

@Schema(keys: .snakeCase)
private struct DoorItem: Equatable {
    var id: Int
    var name: String
}

@Schema(context: TenantContext.self, keys: .snakeCase)
private struct DoorGrant: Equatable {
    var role: String

    @Check
    static func known(_ g: DoorGrant, _ ctx: TenantContext, _ issues: inout Issues<DoorGrant>) {
        if !ctx.availableRoles.contains(g.role) { issues.add("unknown role", at: \.role) }
    }
}

@Schema(context: TenantContext.self, keys: .snakeCase, formats: [.toml])
private struct DoorSeat: Equatable {
    var owner: String
    var role: String

    @Check
    static func known(_ s: DoorSeat, _ ctx: TenantContext, _ issues: inout Issues<DoorSeat>) {
        if !ctx.availableRoles.contains(s.role) { issues.add("unknown role", at: \.role) }
    }
}

@Schema(formats: [.toml])
private struct DoorPrefs: Equatable {
    var name: String
    var count: Int
}

/// A temp file addressed by `URL`, removed afterwards. `MappedFileTests` writes with C stdio
/// because it avoids Foundation; this file is about the `URL` overloads, so it does not.
private func withTempURL(_ text: String, _ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("assay-door-\(UInt64.random(in: 0..<(.max))).json")
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

private let missingURL = URL(fileURLWithPath: "/nonexistent/assay-door/none.json")

// MARK: - parse(mmapped: URL)

@Suite("Memory-mapped parsing, by URL")
struct MappedURLTests {

    @Test("the URL door produces the value the bytes door does")
    func sameValue() throws {
        let json = #"{"id":7,"name":"seven"}"#
        try withTempURL(json) { url in
            let mapped = try DoorItem.parse(mmapped: url)
            let plain = try DoorItem.parse(json: json)
            #expect(mapped == plain)
        }
    }

    @Test("issues carry carets over the mapping, and the source is named for the file")
    func sameIssues() throws {
        let json = #"{"id":"seven","name":"seven"}"#
        try withTempURL(json) { url in
            let mapped = DoorItem.diagnose(mmapped: url)
            let plain = DoorItem.diagnose(json: json)
            #expect(mapped.issues.map(\.code) == plain.issues.map(\.code))
            #expect(mapped.issues.map(\.location) == plain.issues.map(\.location))
            // The last path component, not the whole path: a temp directory in every
            // rendered error is noise, and it differs per run.
            #expect(mapped.sourceName == url.lastPathComponent)
            #expect(mapped.render(.plain).contains("\"seven\""))
        }
    }

    @Test("a missing file is one cannot_map_file issue naming the path, not a trap")
    func missing() {
        let d = DoorItem.diagnose(mmapped: missingURL)
        #expect(d.value == nil)
        #expect(d.issues.map(\.code) == [.cannotMapFile])
        #expect(d.issues.first?.params["path"] == .string(missingURL.path))
        #expect(d.sourceName == "none.json")
        #expect(throws: AssayError.self) { try DoorItem.parse(mmapped: missingURL) }
    }

    @Test("JSON.Value by URL matches JSON.Value from bytes")
    func valueModel() throws {
        let json = #"{"a":[1,2,{"b":null}],"c":"d"}"#
        try withTempURL(json) { url in
            let mapped = try JSON.Value.parse(mmapped: url)
            let plain = try JSON.Value.parse(json)
            #expect(mapped == plain)
        }
    }

    @Test("JSON.Value throws AssayError for a malformed mapped document")
    func valueModelMalformed() throws {
        try withTempURL(#"{"a":[1,2"#) { url in
            #expect(throws: AssayError.self) { try JSON.Value.parse(mmapped: url) }
        }
    }
}

@Suite("Memory-mapped parsing, with a context")
struct MappedContextTests {

    static let plan = TenantContext(availableRoles: ["admin"], maximumSeats: 5)

    @Test("the context reaches the check through the mapped door")
    func contextArrives() throws {
        try withTempURL(#"{"role":"admin"}"#) { url in
            let g = try DoorGrant.parse(mmapped: url, context: Self.plan)
            #expect(g == DoorGrant(role: "admin"))
        }
        // A role only the context can refuse. If the mapped door dropped the context, or
        // resolved to an overload that absorbs it, this would decode cleanly.
        try withTempURL(#"{"role":"owner"}"#) { url in
            let d = DoorGrant.diagnose(mmapped: url, context: Self.plan)
            #expect(!d.isValid)
            #expect(d.issues.first?.path.pathDescription == "role")
            #expect(throws: AssayError.self) {
                try DoorGrant.parse(mmapped: url, context: Self.plan)
            }
        }
    }

    @Test("a decode issue through the contextual mapped door still has its caret")
    func caret() throws {
        try withTempURL(#"{"role":42}"#) { url in
            let d = DoorGrant.diagnose(mmapped: url, context: Self.plan)
            #expect(d.issues.first?.location != nil)
            #expect(d.sourceName == url.lastPathComponent)
        }
    }

    @Test("a missing file is cannot_map_file here too")
    func missing() {
        let d = DoorGrant.diagnose(mmapped: missingURL, context: Self.plan)
        #expect(d.issues.map(\.code) == [.cannotMapFile])
        #expect(d.issues.first?.params["path"] == .string(missingURL.path))
    }
}

// MARK: - TOML and plist with a context

@Suite("Contextual TOML and plist doors")
struct ContextualFormatDoorTests {

    static let plan = TenantContext(availableRoles: ["admin"], maximumSeats: 5)
    static let good = "owner = \"ada\"\nrole = \"admin\"\n"
    static let refused = "owner = \"ada\"\nrole = \"owner\"\n"

    static func plist(role: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>owner</key><string>ada</string>
        <key>role</key><string>\(role)</string>
        </dict></plist>
        """
    }

    @Test("TOML: text and bytes agree, and the context arrives")
    func toml() throws {
        let want = DoorSeat(owner: "ada", role: "admin")
        #expect(try DoorSeat.parse(toml: Self.good, context: Self.plan) == want)
        #expect(try DoorSeat.parse(toml: Array(Self.good.utf8), context: Self.plan) == want)

        let d = DoorSeat.diagnose(toml: Self.refused, context: Self.plan)
        #expect(!d.isValid)
        #expect(d.issues.first?.path.pathDescription == "role")
        #expect(throws: AssayError.self) {
            try DoorSeat.parse(toml: Self.refused, context: Self.plan)
        }
    }

    @Test("TOML: a document that does not parse never reaches the check")
    func tomlMalformed() {
        let d = DoorSeat.diagnose(toml: "owner = \n", context: Self.plan, sourceName: "seat.toml")
        #expect(d.value == nil)
        #expect(!d.isValid)
        #expect(d.sourceName == "seat.toml")
        #expect(d.issues.allSatisfy { !$0.message.contains("unknown role") })
    }

    @Test("plist: the context arrives")
    func plist() throws {
        let good = Array(Self.plist(role: "admin").utf8)
        #expect(
            try DoorSeat.parse(plist: good, context: Self.plan)
                == DoorSeat(owner: "ada", role: "admin"))

        let d = DoorSeat.diagnose(plist: Array(Self.plist(role: "owner").utf8), context: Self.plan)
        #expect(!d.isValid)
        #expect(d.issues.first?.path.pathDescription == "role")
    }

    @Test("plist: maxBytes refuses before the parser, on the contextual door as on the plain one")
    func plistTooLarge() {
        let bytes = Array(Self.plist(role: "admin").utf8)
        var limits = Limits.default
        limits.maxBytes = 16

        let contextual = DoorSeat.diagnose(plist: bytes, context: Self.plan, limits: limits)
        #expect(contextual.issues.map(\.code) == [.tooManyBytes])
        #expect(contextual.value == nil)

        let plain = DoorPrefs.diagnose(plist: bytes, limits: limits)
        #expect(plain.issues.map(\.code) == [.tooManyBytes])
    }

    @Test("plist: a malformed document through the contextual door is an issue, not a value")
    func plistMalformed() {
        let d = DoorSeat.diagnose(plist: Array("<plist><dict>".utf8), context: Self.plan)
        #expect(d.value == nil)
        #expect(!d.isValid)
    }
}

@Suite("Plist doors that name a flavour")
struct PlistFlavourDoorTests {

    static let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>name</key><string>n</string>
        <key>count</key><integer>3</integer>
        </dict></plist>
        """

    @Test("parse(xmlPlist:) decodes XML and refuses a binary header")
    func xmlOnly() throws {
        #expect(
            try DoorPrefs.parse(xmlPlist: Array(Self.xml.utf8)) == DoorPrefs(name: "n", count: 3))
        #expect(throws: AssayError.self) {
            try DoorPrefs.parse(xmlPlist: Array("bplist00".utf8) + [0, 0, 0, 0])
        }
    }

    @Test("the String doors match the byte doors")
    func text() throws {
        #expect(try DoorPrefs.parse(plist: Self.xml) == DoorPrefs(name: "n", count: 3))
        // A string where the schema declares an Int. (`<integer>x</integer>` would be the
        // PARSER's refusal, at the document root, before the schema is consulted.)
        let wrong = Self.xml.replacingOccurrences(
            of: "<integer>3</integer>", with: "<string>three</string>")
        let d = DoorPrefs.diagnose(plist: wrong)
        #expect(!d.isValid)
        #expect(d.issues.first?.path.pathDescription == "count")
    }
}
