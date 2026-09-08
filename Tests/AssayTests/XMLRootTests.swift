// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@XML(root:)`, built 2026-09-08. ROADMAP §4 deferred it on one open decision — what the
// default is when unannotated — and the answer is the asymmetry these tests pin: encoding
// always writes a root, decoding only checks one you declared.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayXML

@Schema(formats: .all, encodes: true) @XML(root: "book")
struct RootedBook: Equatable { var title: String }

@Schema(formats: .all, encodes: true)
struct UnrootedBook: Equatable { var title: String }

@Suite("@XML(root:)")
struct XMLRootTests {

    @Test("a declared root that matches decodes")
    func matches() throws {
        let v = try RootedBook.parse(xml: "<book><title>T</title></book>")
        #expect(v.title == "T")
    }

    /// The point of the feature. You asserted a fact about the wire; a mismatch is an issue,
    /// not a warning, and it names both sides.
    @Test("a declared root that does not match is an issue")
    func mismatch() {
        let d = RootedBook.diagnose(xml: "<magazine><title>T</title></magazine>")
        #expect(!d.isValid)
        let issue = d.issues.first { $0.code == .custom("xml_root_mismatch") }
        #expect(issue != nil, "got \(d.issues.map(\.code))")
        #expect(issue?.params["expected"] == .string("book"))
        #expect(issue?.received == "magazine")
    }

    /// Unannotated types do not look at the root at all, and that is the deferred decision
    /// being made rather than an oversight: a root element is very often a wrapper the
    /// schema does not model — `<soap:Envelope>`, `<response>` — so checking one nobody
    /// declared would refuse documents that are fine.
    @Test("an unannotated type ignores the root entirely")
    func unannotatedIgnoresRoot() throws {
        let a = try UnrootedBook.parse(xml: "<UnrootedBook><title>T</title></UnrootedBook>")
        let b = try UnrootedBook.parse(xml: "<anything><title>T</title></anything>")
        #expect(a == b)
    }

    /// Matched on the LOCAL name. The projection keys members by `local`, so matching a
    /// namespace URI here would be the one place in the XML path that did.
    @Test("the root is matched on its local name, not its prefix")
    func localNameOnly() throws {
        let v = try RootedBook.parse(
            xml: "<x:book xmlns:x=\"urn:e\"><title>T</title></x:book>")
        #expect(v.title == "T")
    }

    @Test("encoding writes the declared root instead of the type name")
    func encodesDeclaredRoot() throws {
        let text = try RootedBook(title: "T").xmlText()
        #expect(text.contains("<book>"), "got \(text)")
        #expect(!text.contains("<RootedBook>"), "got \(text)")

        // Unannotated still writes the type's own name, which is what it always did.
        let plain = try UnrootedBook(title: "T").xmlText()
        #expect(plain.contains("<UnrootedBook>"), "got \(plain)")
    }

    /// The explicit `root:` argument on the call still wins — it was there before the
    /// attribute and overriding at the call site is a different need.
    @Test("an explicit root: argument overrides the attribute")
    func callSiteOverride() throws {
        let text = try RootedBook(title: "T").xmlText(root: "override")
        #expect(text.contains("<override>"), "got \(text)")
    }
}
