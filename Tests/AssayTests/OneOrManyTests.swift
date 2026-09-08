// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@OneOrMany`, built 2026-09-08. EXPERIENCE §9, ROADMAP §5.
//
// Building this surfaced something undeclared: the `RawValue` path ALREADY accepts a single
// value where an array is declared, so `tags: swift` decodes from YAML and is a type
// mismatch as JSON. Same declaration, different meaning per format.
//
// It cannot simply be made strict, and the reason is worth having in a test file rather than
// only in a commit message. XML spells a sequence as REPEATED SIBLING ELEMENTS, each of
// which arrives as its own decode call with the same key, so the raw path appends rather
// than assigns. At that layer a lone `<tag>a</tag>` is indistinguishable from YAML's
// `tags: swift` — there is nothing to branch on. Making it strict would break every XML
// array, which `XMLRootTests` and the multi-format suite would catch immediately.
//
// So `@OneOrMany` is where the tolerance is a genuine choice, and the asymmetry is stated as
// a contract instead of left to be discovered.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayYAML
import AssayXML

@Schema(formats: .all)
struct Post: Equatable {
    @OneOrMany var tags: [String]
    var title: String
}

@Schema(formats: .all)
struct StrictPost: Equatable {
    var tags: [String]
    var title: String
}

@Schema
struct NumberList: Equatable {
    @OneOrMany var ns: [Int]
}

@Suite("@OneOrMany")
struct OneOrManyTests {

    @Test("a single value decodes into a one-element array")
    func single() throws {
        let p = try Post.parse(json: Array(#"{"tags":"swift","title":"t"}"#.utf8))
        #expect(p.tags == ["swift"])
    }

    @Test("an array still decodes as an array")
    func many() throws {
        let p = try Post.parse(json: Array(#"{"tags":["a","b"],"title":"t"}"#.utf8))
        #expect(p.tags == ["a", "b"])
    }

    @Test("the tolerance is opt-in: an unannotated field still refuses a scalar")
    func optIn() {
        let d = StrictPost.diagnose(json: Array(#"{"tags":"swift","title":"t"}"#.utf8))
        #expect(!d.isValid)
        #expect(d.issues.first?.path == [.key("tags")], "\(d.issues.map(\.path))")
    }

    @Test("it works for non-string elements too")
    func nonString() throws {
        #expect(try NumberList.parse(json: Array(#"{"ns":7}"#.utf8)).ns == [7])
        #expect(try NumberList.parse(json: Array(#"{"ns":[7,8]}"#.utf8)).ns == [7, 8])
    }

    /// A value that is neither an array nor a valid element is still a mismatch — the
    /// tolerant arm must not swallow genuinely wrong shapes.
    @Test("a wrong-typed scalar is still refused")
    func stillTypeChecks() {
        let d = NumberList.diagnose(json: Array(#"{"ns":{"a":1}}"#.utf8))
        #expect(!d.isValid)
    }

    /// The asymmetry, asserted rather than described. The `RawValue` path is tolerant
    /// whether or not the field asked, because XML's repeated siblings require it.
    @Test("the tree path is tolerant unconditionally, and that is XML's doing")
    func treePathAsymmetry() throws {
        // Unannotated, from YAML: accepted, unlike the same document as JSON.
        let y = try StrictPost.parse(yaml: "tags: swift\ntitle: t\n")
        #expect(y.tags == ["swift"])

        // The same unannotated field from JSON: refused. This is the asymmetry.
        #expect(StrictPost.diagnose(json: Array(#"{"tags":"swift","title":"t"}"#.utf8)).isValid
                == false)

        // And the reason it cannot be closed by making the tree path strict: repeated
        // siblings are how XML spells a sequence, and they arrive one call at a time.
        let x = try StrictPost.parse(
            xml: "<StrictPost><tags>a</tags><tags>b</tags><title>t</title></StrictPost>")
        #expect(x.tags == ["a", "b"])
    }
}
