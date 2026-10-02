// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `parse(body:contentType:accepting:)`, built 2026-09-08. ROADMAP §9.
//
// The design was settled years before the code — `accepting:` required, no default, because
// an unbounded format guess on untrusted input is how you get XXE and billion-laughs. These
// tests are mostly about the media-type grammar, which is where implementations of this go
// wrong, plus one that matters more than the rest: a rejected type must not reach a parser.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore
import AssayYAML
import AssayXML

/// `coerceScalars: true` because XML is in the accepted set and everything in XML is text
/// -- `<count>1</count>` projects to `.string("1")`. That is EXPERIENCE §7's explicit-coercion
/// rule showing up exactly where it should: a type that accepts XML has to say so.
@Schema(coerceScalars: true, formats: .all)
struct Body: Equatable {
    var name: String
    var count: Int
}

@Suite("Media type parsing")
struct MediaTypeTests {

    @Test("the essence is parsed, lowercased, and parameters ignored")
    func essence() {
        let m = MediaType.parse("Application/JSON; charset=UTF-8")
        #expect(m?.type == "application")
        #expect(m?.subtype == "json")
        #expect(m?.charset == "utf-8")
    }

    /// RFC 6839 structured suffixes. Getting these wrong is not cosmetic: most versioned
    /// APIs on the internet spell their content type `...+json`, and a negotiator that does
    /// not know that rejects all of them.
    @Test(
        "structured suffixes are recognised",
        arguments: [
            ("application/vnd.github.v3+json", "json"),
            ("image/svg+xml", "xml"),
            ("application/vnd.thing+yaml", "yaml"),
            ("application/ld+json", "json")
        ])
    func suffixes(_ header: String, _ expected: String) {
        let m = MediaType.parse(header)
        #expect(m?.suffix == expected, "for \(header)")
        #expect(m?.names(expected) == true)
    }

    @Test("a plain type names itself with no suffix")
    func noSuffix() {
        let m = MediaType.parse("application/json")
        #expect(m?.suffix == nil)
        #expect(m?.names("json") == true)
        #expect(m?.names("xml") == false)
    }

    @Test(
        "whitespace, quoting and parameter order do not matter",
        arguments: [
            "application/json;charset=utf-8",
            "  application/json ;  charset = utf-8  ",
            "application/json; charset=\"utf-8\"",
            "application/json; boundary=x; charset=UTF-8"
        ])
    func tolerance(_ header: String) {
        let m = MediaType.parse(header)
        #expect(m?.names("json") == true, "for \(header)")
        #expect(m?.charsetIsReadable == true, "for \(header)")
    }

    @Test(
        "junk is not a media type",
        arguments: [
            "", "json", "/json", "application/", "application", ";charset=utf-8",
            "application/+json"
        ])
    func junk(_ header: String) {
        let m = MediaType.parse(header)
        #expect(
            m == nil || m?.subtype.isEmpty == true, "for \"\(header)\" got \(String(describing: m))"
        )
    }

    /// Checked, never transcoded. The core is Foundation-free and has no converter, so
    /// refusing is correct and quietly reading Latin-1 as UTF-8 would not be.
    @Test("only UTF-8 and US-ASCII are readable")
    func charsets() {
        #expect(MediaType.parse("application/json")?.charsetIsReadable == true)
        #expect(MediaType.parse("application/json; charset=utf-8")?.charsetIsReadable == true)
        #expect(MediaType.parse("application/json; charset=US-ASCII")?.charsetIsReadable == true)
        #expect(MediaType.parse("application/json; charset=iso-8859-1")?.charsetIsReadable == false)
        #expect(MediaType.parse("application/json; charset=utf-16")?.charsetIsReadable == false)
    }
}

@Suite("Content negotiation")
struct NegotiationTests {

    static let json = Array(#"{"name": "a", "count": 1}"#.utf8)
    static let yaml = Array("name: a\ncount: 1\n".utf8)
    static let xml = Array("<Body><name>a</name><count>1</count></Body>".utf8)

    @Test("each format decodes when it is accepted")
    func decodesEach() throws {
        let a = try Body.parse(
            body: Self.json, contentType: "application/json",
            accepting: [.json, .yaml, .xml])
        let b = try Body.parse(
            body: Self.yaml, contentType: "application/yaml",
            accepting: [.json, .yaml, .xml])
        let c = try Body.parse(
            body: Self.xml, contentType: "application/xml",
            accepting: [.json, .yaml, .xml])
        #expect(a == b)
        #expect(a == c)
    }

    /// The property that makes `accepting:` worth requiring. An XML body offered to a
    /// JSON-only endpoint is refused BEFORE any parser runs — so the XML parser, entity
    /// expansion and all, is never entered at all.
    @Test("a type outside accepting: is refused, and no parser is entered")
    func unsupportedNeverParses() {
        // A billion-laughs payload. If the XML parser ran, this would be visible as either
        // an expansion issue or a long pause; being refused means it was never read.
        let bomb = Array(
            ("<?xml version=\"1.0\"?><!DOCTYPE e [<!ENTITY a \"xxxxxxxxxx\">"
                + "<!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\">"
                + "<!ENTITY c \"&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;\">"
                + "]><Body><name>&c;</name></Body>").utf8)

        let d = Body.diagnose(body: bomb, contentType: "application/xml", accepting: [.json])
        #expect(!d.isValid)
        #expect(d.issues.count == 1, "exactly one issue, from negotiation: \(d.issues.map(\.code))")
        #expect(d.issues.first?.code == .unsupportedMediaType)
        #expect(d.issues.first?.received == "application/xml")
    }

    /// A distinct code from a parse failure, on purpose: a server maps this to 415 and a
    /// malformed body to 400, and it should not have to guess which it got.
    @Test("unsupported media type is its own code, not a parse error")
    func distinctCode() {
        let d = Body.diagnose(body: Self.json, contentType: "text/csv", accepting: [.json])
        #expect(d.issues.first?.code == .unsupportedMediaType)
        #expect(d.issues.first?.code != .malformedDocument)
    }

    /// No sniffing, ever — not even when the bytes are obviously JSON and JSON is accepted.
    @Test(
        "a missing or unparseable Content-Type is refused rather than guessed",
        arguments: [nil, "", "garbage", "application"])
    func neverSniffs(_ header: String?) {
        let d = Body.diagnose(body: Self.json, contentType: header, accepting: [.json])
        #expect(!d.isValid, "for \(String(describing: header))")
        #expect(d.issues.first?.code == .missingContentType)
    }

    @Test("an unreadable charset is refused rather than reinterpreted")
    func charsetRefused() {
        let d = Body.diagnose(
            body: Self.json,
            contentType: "application/json; charset=iso-8859-1",
            accepting: [.json])
        #expect(d.issues.first?.code == .unreadableCharset)
        #expect(d.issues.first?.received == "iso-8859-1")
    }

    @Test("a versioned +json type routes to the JSON parser")
    func structuredSuffixRoutes() throws {
        let v = try Body.parse(
            body: Self.json,
            contentType: "application/vnd.github.v3+json; charset=utf-8",
            accepting: [.json])
        #expect(v.name == "a")
    }

    /// A malformed body of an ACCEPTED type is a parse failure, not a negotiation one —
    /// the two must stay distinguishable.
    @Test("a bad body of an accepted type reports a parse issue")
    func badBody() {
        let d = Body.diagnose(
            body: Array("{not json".utf8),
            contentType: "application/json", accepting: [.json])
        #expect(!d.isValid)
        #expect(d.issues.first?.code != .unsupportedMediaType)
    }

    /// Order in `accepting:` decides ties. Nothing today matches two formats, but the rule
    /// should be stated rather than emergent.
    @Test("the first matching format in accepting: wins")
    func firstMatchWins() throws {
        let v = try Body.parse(
            body: Self.json, contentType: "application/json",
            accepting: [.json, .yaml])
        #expect(v.count == 1)
    }
}

//===----------------------------------------------------------------------===//
// The three overloads the suite above never reached. `Negotiate.swift` carries four entry
// points, and the tests only ever used one of them — the `JSONAssayable` one — which is why
// the file sat at 46.8% line coverage while looking well tested.
//
// It matters more here than it would elsewhere. This is the door that refuses a hostile
// body BEFORE a parser sees it, and "no parser is entered" was asserted on exactly one of
// the four paths that have to honour it.
//===----------------------------------------------------------------------===//

/// Deliberately has no `.json` in `formats:`, so it is `RawDecodable` and **not**
/// `JSONAssayable`. That is the only way to reach the unconstrained overload: the
/// constrained one absorbs every type that can decode JSON from bytes.
@Schema(keys: .snakeCase, coerceScalars: true, formats: [.yaml, .xml])
struct TreeOnlyBody: Equatable {
    var name: String
    @Validate(.min(1)) var count: Int
}

@Suite("Negotiation on a type with no JSON byte path")
struct NegotiationTreeOnlyTests {

    static let yaml = Array("name: api\ncount: 1\n".utf8)
    static let xml = Array("<root><name>api</name><count>1</count></root>".utf8)

    @Test("a YAML body negotiates and decodes through RawValue")
    func yamlDecodes() throws {
        let v = try TreeOnlyBody.parse(
            body: Self.yaml, contentType: "application/yaml", accepting: [.yaml])
        #expect(v == TreeOnlyBody(name: "api", count: 1))
    }

    @Test("an XML body does too, through the same overload")
    func xmlDecodes() throws {
        let v = try TreeOnlyBody.parse(
            body: Self.xml, contentType: "application/xml", accepting: [.xml])
        #expect(v == TreeOnlyBody(name: "api", count: 1))
    }

    /// `WireFormat.json` decodes through `RawValue` rather than the byte path here, because
    /// the type has no byte path. Worth pinning: it is the one case where accepting `.json`
    /// does *not* take the fast route, and it should still produce the same value.
    @Test("accepting .json still works, via RawValue rather than the byte path")
    func jsonThroughRawValue() throws {
        let v = try TreeOnlyBody.parse(
            body: Array(#"{"name":"api","count":1}"#.utf8),
            contentType: "application/json", accepting: [.json])
        #expect(v == TreeOnlyBody(name: "api", count: 1))
    }

    /// The load-bearing one, on this overload. `unsupportedNeverParses` above asserts it
    /// for the JSON-capable type; this is the same claim for the tree-only path.
    @Test("a refused media type never enters a parser on this path either")
    func refusedNeverParses() {
        let bomb = Array(
            """
            <?xml version="1.0"?>
            <!DOCTYPE lol [<!ENTITY a "aaaaaaaaaa">
             <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
             <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>
            <root><name>&c;</name><count>1</count></root>
            """.utf8)
        let d = TreeOnlyBody.diagnose(
            body: bomb, contentType: "application/xml",
            accepting: [.yaml])
        #expect(d.value == nil)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.code == .unsupportedMediaType)
    }

    @Test("a malformed body of an accepted type reports a parse issue, not a media issue")
    func malformedBody() {
        let d = TreeOnlyBody.diagnose(
            body: Array("name: [unclosed\n".utf8),
            contentType: "application/yaml", accepting: [.yaml])
        #expect(d.value == nil)
        #expect(d.issues.allSatisfy { $0.code != .unsupportedMediaType })
    }

    /// The branch that is neither a negotiation failure nor a parse failure: the document
    /// parsed, and then a rule refused it. It exercises the `sink.isValid` guard after a
    /// successful `format.decode`, which nothing reached before.
    @Test("a document that parses and then fails a rule reports the rule")
    func parsesThenFailsARule() {
        let d = TreeOnlyBody.diagnose(
            body: Array("name: api\ncount: 0\n".utf8),
            contentType: "application/yaml", accepting: [.yaml])
        #expect(d.value == nil)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.code == .tooSmall)
        #expect(d.issues.first?.path.pathDescription == "count")
    }

    @Test("the throwing form throws rather than returning a diagnosis")
    func throwingFormThrows() {
        #expect(throws: AssayError.self) {
            try TreeOnlyBody.parse(
                body: Self.yaml, contentType: "text/csv",
                accepting: [.yaml])
        }
    }

    @Test("a nil Content-Type is an issue here too — the bytes are never sniffed")
    func nilContentType() {
        let d = TreeOnlyBody.diagnose(body: Self.yaml, contentType: nil, accepting: [.yaml])
        #expect(d.value == nil)
        #expect(d.issues.count == 1)
    }
}

@Suite("Negotiation on a contextual type")
struct NegotiationContextTests {

    static let ctx = TenantContext(availableRoles: ["admin", "member"], maximumSeats: 5)
    static let json = Array(#"{"email":"a@b.com","role":"admin"}"#.utf8)

    @Test("a contextual type negotiates and gets its context")
    func decodesWithContext() throws {
        let v = try Invitation.parse(
            body: Self.json, contentType: "application/json",
            accepting: [.json], context: Self.ctx)
        #expect(v == Invitation(email: "a@b.com", role: "admin"))
    }

    @Test("a YAML body reaches the same contextual overload")
    func yamlWithContext() throws {
        let v = try Invitation.parse(
            body: Array("email: a@b.com\nrole: member\n".utf8),
            contentType: "application/yaml", accepting: [.yaml], context: Self.ctx)
        #expect(v.role == "member")
    }

    /// The context has to actually arrive, or this overload is decoration. `owner` is not in
    /// `availableRoles`, and only the check can know that.
    @Test("the context's check runs, which is the whole point of the overload")
    func contextCheckRuns() {
        let d = Invitation.diagnose(
            body: Array(#"{"email":"a@b.com","role":"owner"}"#.utf8),
            contentType: "application/json", accepting: [.json], context: Self.ctx)
        #expect(d.value == nil)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.path.pathDescription == "role")
    }

    @Test("a refused media type never enters a parser on the contextual path")
    func refusedNeverParses() {
        let d = Invitation.diagnose(
            body: Array("<?xml version=\"1.0\"?><root/>".utf8),
            contentType: "application/xml", accepting: [.json], context: Self.ctx)
        #expect(d.value == nil)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.code == .unsupportedMediaType)
    }

    @Test("a malformed contextual body reports the parse failure")
    func malformedBody() {
        let d = Invitation.diagnose(
            body: Array(#"{"email":"a@b.com","role":}"#.utf8),
            contentType: "application/json", accepting: [.json], context: Self.ctx)
        #expect(d.value == nil)
        #expect(d.issues.allSatisfy { $0.code != .unsupportedMediaType })
    }

    @Test("the throwing contextual form throws")
    func throwingFormThrows() {
        #expect(throws: AssayError.self) {
            try Invitation.parse(
                body: Self.json, contentType: "text/csv",
                accepting: [.json], context: Self.ctx)
        }
    }
}
