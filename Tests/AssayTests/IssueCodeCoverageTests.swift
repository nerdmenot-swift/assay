// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// EVERY ISSUE CODE, PROVOKED BY A DOCUMENT.
//
// The audit on 2026-09-12 counted 119 declared codes and found 39 that no test named:
// 19 `xml_*`, 8 `yaml_*`, 7 `plist_*` and 5 rule codes. An error path nothing asserts is
// an error path nobody has run — the parser reached it once, when it was written.
//
// Two things are checked here, and the second is the one that keeps working:
//
//   1. Each code in the table below is produced by the document beside it. That pins the
//      code (it is public API — a server maps it to a response) and proves the path is
//      reachable at all.
//   2. **Every declared code is named by some test.** `completeness` reads
//      `IssueCode+Names.swift` and every file in this directory and fails on a code that
//      appears in neither the table here nor anywhere else in the suite. So a new code
//      added without a test fails the suite that day, rather than accumulating until the
//      next audit counts them.
//
// Check 2 is deliberately a text search rather than something cleverer: it can be fooled
// by writing the code's name in a comment, and it is still the difference between 39
// unasserted codes and none. `messageParity` in RenderTests is the same shape.
//===----------------------------------------------------------------------===//

import Testing
import Foundation
import AssayCore
import Assay
import AssayYAML
import AssayXML
import AssayPlist

@Suite("Issue code coverage")
struct IssueCodeCoverageTests {

    // MARK: The provoking documents

    enum Flavour { case yaml, xml, plist }

    /// One document per code. Where a document provokes several, it appears several times —
    /// the assertion is "this code is among the issues", not "this is the only issue",
    /// because a malformed document legitimately produces more than one complaint.
    static let cases: [(code: IssueCode, flavour: Flavour, doc: String)] = [

        // ---- YAML ----
        (.yamlBadEscape, .yaml, #"a: "x\qy""#),
        (.yamlUnterminatedQuotedScalar, .yaml, "a: \"unclosed"),
        (.yamlUnterminatedFlowSequence, .yaml, "a: [1, 2"),
        (.yamlUnterminatedFlowMapping, .yaml, "a: {b: 1"),
        (.yamlUnexpectedInFlow, .yaml, "a: {,}"),
        (.yamlExpectedColon, .yaml, "a: {b}"),
        (.yamlExpectedValueIndicator, .yaml, "? key\nvalue"),

        // ---- XML ----
        (.xmlNoRoot, .xml, "<!-- just a comment -->"),
        (.xmlBadName, .xml, "<1bad/>"),
        (.xmlUnterminatedTag, .xml, "<a"),
        (.xmlUnclosedElement, .xml, "<a>"),
        (.xmlMismatchedTag, .xml, "<a></b>"),
        (.xmlBadAttributeName, .xml, "<a =1/>"),
        (.xmlExpectedEquals, .xml, "<a b/>"),
        (.xmlUnquotedAttribute, .xml, "<a b=1/>"),
        (.xmlUnterminatedAttribute, .xml, "<a b=\"unclosed/>"),
        (.xmlRawLtInAttribute, .xml, "<a b=\"x<y\"/>"),
        (.xmlUnterminatedComment, .xml, "<a><!-- never closed</a>"),
        (.xmlUnterminatedCdata, .xml, "<a><![CDATA[never closed</a>"),
        (.xmlBadPiTarget, .xml, "<?1bad?><a/>"),
        (.xmlUnterminatedPi, .xml, "<?target never closed"),
        (.xmlUnterminatedEntity, .xml, "<a>&unclosed</a>"),
        (.xmlBadCharacterReference, .xml, "<a>&#xD800;</a>"),
        (.xmlUnterminatedDoctype, .xml, "<!DOCTYPE a [ never closed"),
        // The one that is a WARNING and not an error: an external DTD is ignored, loudly,
        // because silently ignoring it is how a parser pretends it resolved entities.
        (.xmlExternalDtdIgnored, .xml,
         "<!DOCTYPE a SYSTEM \"http://example.invalid/a.dtd\"><a/>"),
    ]

    @Test("each document produces its code",
          arguments: IssueCodeCoverageTests.cases.indices)
    func provokes(_ i: Int) {
        let c = IssueCodeCoverageTests.cases[i]
        var sink = IssueSink(limits: .default)
        let bytes = Array(c.doc.utf8)
        switch c.flavour {
        case .yaml:  _ = YAML.decodeAll(bytes, into: &sink, limits: .default)
        case .xml:   _ = XML.decode(bytes, into: &sink, limits: .default)
        case .plist: _ = Plist.decode(bytes, into: &sink, limits: .default)
        }
        let produced = sink.issues.map(\.code) + sink.warnings.map(\.code)
        #expect(produced.contains(c.code),
                "\(c.code) not produced by \(c.doc.debugDescription); got \(produced)")
    }

    @Test("yaml_empty_stream — the single-document door on an empty stream")
    func yamlEmptyStream() {
        // `decodeAll` returns an empty list without complaint — an empty stream is a legal
        // YAML stream of zero documents. It is `parse(yaml:)` that has to object, because
        // it promised exactly one.
        let d = Anything.diagnose(yaml: [])
        #expect(d.issues.map(\.code).contains(.yamlEmptyStream), "\(d.issues)")
    }

    // MARK: Binary plist — the seven codes that need bytes, not text

    /// A binary plist assembled by hand: magic, an object region, a one-byte offset table
    /// and the 32-byte trailer. Built rather than encoded because every document here is
    /// one an encoder would refuse to write — the rejection is the point.
    ///
    /// Layout, which the trailer describes and the reader trusts only after checking:
    /// `bplist00` | objects | offset table | trailer(offsetIntSize, objectRefSize,
    /// numObjects, topObject, offsetTableOffset).
    static func bplist(objects: [UInt8], offsetTableEntry: Int? = nil,
                       topObject: Int = 0, numObjects: Int = 1) -> [UInt8] {
        var out = Array("bplist00".utf8)
        out += objects
        let tableAt = out.count
        // The reader's `limit` is `count - 32`; an entry defaults to the first object,
        // which sits immediately after the magic.
        let entry = offsetTableEntry ?? 8
        out.append(UInt8(truncatingIfNeeded: entry))
        func be(_ v: Int) -> [UInt8] { (0..<8).reversed().map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
        out += [0, 0, 0, 0, 0, 0, 1, 1]          // 6 unused, offsetIntSize, objectRefSize
        out += be(numObjects) + be(topObject) + be(tableAt)
        return out
    }

    /// `parse(binaryPlist:)` is the door that reaches the binary reader whatever the magic
    /// says — `Plist.decode` routes by magic, so `plist_bad_magic` is unreachable through
    /// it by construction. The schema is irrelevant; the document never gets that far.
    @Schema(formats: .all) struct Anything: Equatable { var unused: String? }

    static func plistCodes(_ bytes: [UInt8]) -> [IssueCode] {
        do { _ = try Anything.parse(binaryPlist: bytes); return [] }
        catch let e as AssayError { return e.issues.map(\.code) }
        catch { return [] }
    }

    @Test("plist_bad_magic — the eight bytes are the whole format check")
    func plistBadMagic() {
        let bytes = Array("bplistXX".utf8) + [UInt8](repeating: 0, count: 32)
        #expect(Self.plistCodes(bytes).contains(.plistBadMagic))
    }

    @Test("plist_truncated — shorter than a header plus a trailer")
    func plistTruncated() {
        #expect(Self.plistCodes(Array("bplist00".utf8)).contains(.plistTruncated))
    }

    @Test("plist_bad_offset — an object offset outside the object region")
    func plistBadOffset() {
        // The entry points at the trailer rather than at an object.
        var bytes = Self.bplist(objects: [0x08])
        bytes[bytes.count - 32 - 1] = UInt8(bytes.count - 10)
        #expect(Self.plistCodes(bytes).contains(.plistBadOffset))
    }

    @Test("plist_int_too_wide — a 128-bit integer has no RawValue")
    func plistIntTooWide() {
        // 0x14: integer, width 1 << 4 == 16. Sixteen payload bytes so it is the WIDTH
        // that is refused and not the length — otherwise this reports plist_truncated and
        // the test passes for the wrong reason.
        let bytes = Self.bplist(objects: [0x14] + [UInt8](repeating: 0, count: 16))
        #expect(Self.plistCodes(bytes).contains(.plistIntTooWide))
    }

    @Test("plist_bad_real — a real that is not 4 or 8 bytes")
    func plistBadReal() {
        let bytes = Self.bplist(objects: [0x21, 0, 0])      // width 1 << 1 == 2
        #expect(Self.plistCodes(bytes).contains(.plistBadReal))
    }

    @Test("plist_bad_date — a date marker that is not 0x33")
    func plistBadDate() {
        let bytes = Self.bplist(objects: [0x30] + [UInt8](repeating: 0, count: 8))
        #expect(Self.plistCodes(bytes).contains(.plistBadDate))
    }

    @Test("plist_bad_root — <plist> with more than one value")
    func plistBadRoot() {
        var sink = IssueSink(limits: .default)
        _ = Plist.decode(Array("""
            <?xml version="1.0"?><plist version="1.0"><string>a</string><string>b</string></plist>
            """.utf8), into: &sink, limits: .default)
        #expect(sink.issues.map(\.code).contains(.plistBadRoot), "\(sink.issues)")
    }

    // MARK: Rule codes

    @Schema struct Pattern: Equatable {
        // An invalid pattern is a RUNTIME fact, not an expansion one: the macro sees a
        // string literal, and `Regex` is what rejects it.
        @Validate(.regex("([unclosed")) var a: String
    }
    @Schema struct Matching: Equatable {
        @Validate(.regex("^[0-9]+$")) var a: String
    }
    @Schema struct Finite: Equatable {
        @Validate(.finite) var a: Double
    }
    @Schema struct Bounded: Equatable {
        @Validate(.max(10)) var a: Int
    }
    @Schema struct NotBefore: Equatable {
        @Validate(.after("2030-01-01T00:00:00Z")) var a: Date
    }

    @Test("invalid_regex_pattern — a pattern that does not compile")
    func invalidPattern() {
        let d = Pattern.diagnose(json: Array(#"{"a":"x"}"#.utf8))
        #expect(d.issues.map(\.code).contains(.invalidRegexPattern), "\(d.issues)")
    }

    @Test("pattern_mismatch — a value the pattern does not accept")
    func patternMismatch() {
        let d = Matching.diagnose(json: Array(#"{"a":"abc"}"#.utf8))
        #expect(d.issues.map(\.code).contains(.patternMismatch), "\(d.issues)")
    }

    @Test("not_finite — infinity reaches the rule as a Double")
    func notFinite() {
        // JSON has no infinity literal, so the value arrives through `diagnose(_ value:)`,
        // which is the door that exists for values something else produced.
        let v = Finite.diagnose(Finite(a: .infinity))
        #expect(v.issues.map(\.code).contains(.notFinite), "\(v.issues)")
    }

    @Test("too_large — the number rule nothing named")
    func tooLarge() {
        let d = Bounded.diagnose(json: Array(#"{"a":11}"#.utf8))
        #expect(d.issues.map(\.code).contains(.tooLarge), "\(d.issues)")
    }

    @Test("date_not_after — a date before the bound")
    func dateNotAfter() {
        let d = NotBefore.diagnose(json: Array(#"{"a":"2020-01-01T00:00:00Z"}"#.utf8))
        #expect(d.issues.map(\.code).contains(.dateNotAfter), "\(d.issues)")
    }

    // MARK: Completeness

    /// Codes that cannot be provoked on the machine this suite runs on, each with the
    /// reason. THIS LIST IS THE POINT OF THE EXERCISE, not an exemption from it: a code
    /// here is a code nothing exercises, and writing down why is what stops it from being
    /// mistaken for one that is covered.
    ///
    /// Both entries were found by trying to write the document and failing:
    ///
    ///   - `regex_unavailable` needs a platform WITHOUT `Regex` — below macOS 13 / iOS 16.
    ///     Every machine in CI is above that floor, so the branch is correct, deliberate
    ///     and untestable here. `Rules.swift` `applyRegex` is where it lives.
    ///   - `xml_expected_element` is unreachable from either of `parseElement`'s two call
    ///     sites (XMLParser.swift:159 and :340): both already check `currentByte == "<"`
    ///     before calling, so the `guard r.consume("<")` inside it cannot fail. The guard
    ///     is worth keeping — it is a recursive function's precondition — but the code is
    ///     dead as the parser stands, and that is a fact about the parser, not a gap in
    ///     this suite.
    static let unreachableHere: Set<String> = ["regex_unavailable", "xml_expected_element"]


    @Test("every declared issue code is named by some test")
    func completeness() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = here                 // Tests/AssayTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Sources/AssayCore/IssueCode+Names.swift")
        let source = try String(contentsOf: names, encoding: .utf8)

        // `static let tooLarge = IssueCode.custom("too_large")` — both spellings count,
        // because a test may assert the symbol or the rendered string.
        var declared: [(ident: String, wire: String)] = []
        for line in source.split(separator: "\n") {
            guard let r = line.range(of: "static let "),
                  let eq = line.range(of: " = IssueCode.custom(\""),
                  let close = line.range(of: "\")", range: eq.upperBound..<line.endIndex)
            else { continue }
            declared.append((String(line[r.upperBound..<eq.lowerBound])
                                .trimmingCharacters(in: .whitespaces),
                             String(line[eq.upperBound..<close.lowerBound])))
        }
        #expect(declared.count > 100, "the parse found \(declared.count) codes — did the file's shape change?")

        var corpus = ""
        for f in try FileManager.default.contentsOfDirectory(at: here, includingPropertiesForKeys: nil)
        where f.pathExtension == "swift" {
            corpus += (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        }
        // THE ALLOWLIST'S OWN LINE IS NOT EVIDENCE. It spells both codes as quoted string
        // literals, so leaving it in the corpus would make every entry satisfy the search
        // that is supposed to be checking it — the allowlist would pass the test whether or
        // not it was there, which is the failure mode this whole suite exists to close.
        // Verified by emptying the list: without this, still green; with it, two failures.
        corpus = corpus.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("static let unreachableHere") }
            .joined(separator: "\n")

        let unasserted = declared.filter {
            !corpus.contains($0.ident) && !corpus.contains("\"\($0.wire)\"")
                && !Self.unreachableHere.contains($0.wire)
        }
        #expect(unasserted.isEmpty, """
            \(unasserted.count) issue codes are declared and never named by a test:
            \(unasserted.map(\.wire).joined(separator: ", "))
            Add a provoking document to IssueCodeCoverageTests.cases, or assert the code
            wherever it is naturally produced. A code nothing asserts is a path nobody runs.
            """)
    }
}

//===----------------------------------------------------------------------===//
// The malformed-document message. The 2026-09-12 audit called this "the single worst
// sentence the library produces, in the case its headline is about": every JSON syntax
// error was the bare predicate `is not a well-formed document` — no subject, no
// expectation — truncated input got a caret one byte past the end (which renders as
// nothing), and `trailingContent` fired as a redundant second error at the same column on
// nearly every syntax failure.
//===----------------------------------------------------------------------===//

@Suite("Malformed documents say what was expected")
struct MalformedMessageTests {

    @Schema struct User: Equatable { var name: String; var age: Int }

    // `Issue` alone is ambiguous here: swift-testing exports one too.
    private func issues(_ doc: String) -> [AssayCore.Issue] {
        User.diagnose(json: Array(doc.utf8)).issues
    }

    @Test("a missing colon names the colon")
    func missingColon() {
        let i = issues(#"{"name": "a", "age" 1}"#)
        #expect(i.count == 1, "\(i.map(\.message))")
        #expect(i.first?.message.contains("expected ':' after the key") == true,
                "\(i.map(\.message))")
    }

    @Test("truncated input says the input ended, and carries a position")
    func truncated() {
        let i = issues(#"{"name": "a","#)
        #expect(i.first?.message.contains("the input ended") == true, "\(i.map(\.message))")
        // The caret lands on the LAST byte. One past the end is outside the source and the
        // renderer draws nothing there, which is how truncated input had no position.
        #expect(i.first?.location?.lo == 12, "\(String(describing: i.first?.location))")
    }

    @Test("one mistake is one error — trailingContent no longer doubles it")
    func noRedundantTrailing() {
        for doc in [#"{"name": "a", "age" 1}"#, #"{"name" "#, #"{"name": "a","#] {
            let codes = issues(doc).map(\.code)
            #expect(!codes.contains(.trailingContent),
                    "\(doc) reported trailing content beside its syntax error: \(codes)")
        }
    }

    @Test("trailing content after a COMPLETE value is still an error")
    func realTrailingContent() {
        let codes = issues(#"{"name": "a", "age": 1}x"#).map(\.code)
        #expect(codes.contains(.trailingContent), "\(codes)")
    }
}

@Suite("Invalid escapes name the escape")
struct InvalidEscapeTests {

    @Schema struct S: Equatable { var a: String; var b: Int = 0 }

    private func issues(_ doc: String) -> [AssayCore.Issue] {
        S.diagnose(json: Array(doc.utf8)).issues
    }

    /// The `\uXXXX` arm got this treatment on 2026-09-10 and the `default:` arm did not,
    /// so an ordinary bad escape reported the WRONG PROBLEM: `must be a string, found y"`,
    /// quoting the garbage that happened to follow the backslash.
    @Test("an unknown escape is invalid_escape, not a type mismatch")
    func unknownEscape() {
        let i = issues(#"{"a":"x\qy"}"#)
        #expect(i.map(\.code) == [.invalidEscape], "\(i.map(\.message))")
    }

    @Test("a bad \\u escape is unchanged")
    func badUnicodeEscape() {
        #expect(issues(#"{"a":"x\u00GG"}"#).map(\.code) == [.invalidEscape])
    }

    @Test("the string is consumed, so a later field still decodes")
    func resynchronises() {
        // The rewind-and-skipString is what makes this one issue rather than a cascade:
        // the bad value is consumed to its closing quote, so `b` is read normally.
        let i = issues(#"{"a":"x\qy","b":2}"#)
        #expect(i.map(\.code) == [.invalidEscape], "\(i.map(\.message))")
    }

    /// A backslash as the LAST byte has no closing quote to scan to, so the value cannot
    /// be consumed and the truncation earns its own error. Two issues here are two
    /// different facts — the escape is cut off AND the document ended — rather than the
    /// same mistake counted twice, which is what `type_mismatch` + `malformed` was.
    @Test("truncated mid-escape names the escape and the truncation, and nothing else")
    func truncatedMidEscape() {
        let codes = issues(#"{"a":"x\"#).map(\.code)
        #expect(codes == [.invalidEscape, .malformedDocument], "\(codes)")
    }

    @Test("a valid document is unaffected")
    func valid() {
        #expect(issues(#"{"a":"ok\n","b":2}"#).isEmpty)
    }
}

//===----------------------------------------------------------------------===//
// `@AsyncCheck` in both forms. The field form did not exist until 2026-09-13: `@Check`
// had one, writing the sibling by analogy is what a developer does, and `@AsyncCheck(\S.a)`
// produced "argument passed to macro expansion that takes no arguments" followed by a type
// error and a WARNING, both inside the expansion — four diagnostics for one fair guess.
//
// A check that needs a round trip to answer is very often a field check ("is this address
// already registered?"), so the answer is the overload, not a better refusal.
//===----------------------------------------------------------------------===//

@Suite("@AsyncCheck, both forms")
struct AsyncCheckFormTests {

    @Schema struct Signup: Equatable {
        var email: String
        var name: String

        @AsyncCheck(\Signup.email)
        static func unique(_ e: String) async -> String? {
            e == "taken@x.com" ? "is already registered" : nil
        }

        @AsyncCheck
        static func distinct(_ v: Signup, _ issues: inout Issues<Signup>) async {
            if v.name == v.email { issues.add("must differ from the email", at: \.name) }
        }
    }

    @Test("a clean document runs both and reports nothing")
    func clean() async {
        let d = await Signup.diagnose(json: Array(#"{"email":"free@x.com","name":"n"}"#.utf8))
        #expect(d.issues.isEmpty, "\(d.issues.map(\.message))")
        #expect(d.value == Signup(email: "free@x.com", name: "n"))
    }

    /// Both forms fail on the same document, and each reports at its own field — the field
    /// form through the key path it was given, the cross-field form through the one the
    /// check passed to `issues.add(at:)`.
    @Test("the field form and the cross-field form each report at their own field")
    func bothReport() async {
        let d = await Signup.diagnose(
            json: Array(#"{"email":"taken@x.com","name":"taken@x.com"}"#.utf8))
        // Compare paths as values: `PathComponent` is Equatable, and its `description`
        // is a debug rendering that is not a contract.
        #expect(d.issues.count == 2, "\(d.issues.map(\.message))")
        let email = d.issues.first { $0.path == [.key("email")] }
        let name = d.issues.first { $0.path == [.key("name")] }
        #expect(email?.message == "is already registered",
                "\(d.issues.map { ($0.path, $0.message) })")
        #expect(name?.message == "must differ from the email",
                "\(d.issues.map { ($0.path, $0.message) })")
    }

    /// Async checks run only on a clean sync pass — spending a round trip on a value that
    /// already failed is waste (EXPERIENCE.md §11).
    @Test("a failed sync pass skips the async checks entirely")
    func syncGatesAsync() async {
        let d = await Signup.diagnose(json: Array(#"{"email":"taken@x.com"}"#.utf8))
        #expect(d.issues.map(\.code) == [.missing], "\(d.issues.map(\.message))")
    }
}
