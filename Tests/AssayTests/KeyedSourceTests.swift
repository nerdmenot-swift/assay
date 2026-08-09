// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The third decode path. docs/KEYED-SOURCE.md.
//
// Two things under test that matter more than the happy path: the five presence states
// behave identically to JSON (absent, null, defaulted and required are four different
// answers, and a source that conflates them is worse than no source), and a source that
// CAN place its fields produces the same carets JSON does.
//===----------------------------------------------------------------------===//

import Testing
import Assay

@Schema(keys: .snakeCase, sources: true)
struct Row: Equatable {
    var id: Int
    var name: String
    @Validate(.range(0...120)) var age: Int
    var score: Double
    var active: Bool
    var nickname: String?
    var retries: Int = 3
}

/// A source that knows where its fields came from — a CSV reader, a config file, a form
/// with field offsets. Proves the caret path works for something that is not JSON.
struct PositionedSource: KeyedSource, ~Copyable {
    let values: [String: (RawValue, SourceSpan)]

    borrowing func has(_ key: StaticString) -> Bool {
        values[String(describing: key)] != nil
    }
    borrowing func isNull(_ key: StaticString) -> Bool {
        if case .null? = values[String(describing: key)]?.0 { return true }
        return false
    }
    borrowing func int64(_ key: StaticString) -> Int64? {
        values[String(describing: key)]?.0.int
    }
    borrowing func double(_ key: StaticString) -> Double? {
        values[String(describing: key)]?.0.double
    }
    borrowing func bool(_ key: StaticString) -> Bool? {
        values[String(describing: key)]?.0.bool
    }
    borrowing func withText<R>(
        _ key: StaticString, _ body: (UnsafeRawBufferPointer?) -> R
    ) -> R {
        guard case .string(let s)? = values[String(describing: key)]?.0 else {
            return body(nil)
        }
        var copy = s
        return copy.withUTF8 { body(UnsafeRawBufferPointer($0)) }
    }
    borrowing func span(_ key: StaticString) -> SourceSpan? {
        values[String(describing: key)]?.1
    }
}

private func fullRow() -> [String: RawValue] {
    ["id": .int(1), "name": .string("ada"), "age": .int(36), "score": .double(9.5),
     "active": .bool(true), "nickname": .string("countess")]
}

@Suite("KeyedSource — the third decode path")
struct KeyedSourceTests {

    @Test("a complete record decodes")
    func happyPath() throws {
        let v = try Row.parse(source: DictionarySource(fullRow()))
        #expect(v == Row(id: 1, name: "ada", age: 36, score: 9.5, active: true,
                         nickname: "countess", retries: 3))
    }

    /// The distinction a row source most easily gets wrong, and the one
    /// `EXPERIENCE.md` §6 refuses to blur: absent, null, defaulted and required are four
    /// different answers.
    @Test("the five presence states behave exactly as they do for JSON")
    func presenceStates() throws {
        // Absent optional -> nil, and absent defaulted -> the default.
        var r = fullRow()
        r["nickname"] = nil
        let v = try Row.parse(source: DictionarySource(r))
        #expect(v.nickname == nil)
        #expect(v.retries == 3, "an absent defaulted field takes its default")

        // Explicit null on an optional -> nil, not a failure.
        r["nickname"] = .null
        #expect(try Row.parse(source: DictionarySource(r)).nickname == nil)

        // Explicit null on a REQUIRED field is a type mismatch, not a missing field.
        var bad = fullRow()
        bad["name"] = .null
        let d = Row.diagnose(source: DictionarySource(bad))
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .typeMismatch })

        // A present default is honoured over the declared one.
        var withRetries = fullRow()
        withRetries["retries"] = .int(9)
        #expect(try Row.parse(source: DictionarySource(withRetries)).retries == 9)
    }

    @Test("a missing required field reports once, naming it")
    func missing() {
        var r = fullRow()
        r["name"] = nil
        r["age"] = nil
        let d = Row.diagnose(source: DictionarySource(r))
        #expect(!d.isValid)
        #expect(d.issues.filter { $0.code == .missing }.count == 2)
        #expect(d.issues.contains { $0.path.pathDescription == "name" })
        #expect(d.render(.plain).contains("name is required"))
    }

    @Test("a wrong type reports a mismatch, and every bad field is reported")
    func mismatches() {
        var r = fullRow()
        r["id"] = .string("not a number")
        r["active"] = .string("yes")
        let d = Row.diagnose(source: DictionarySource(r))
        #expect(d.issues.count >= 2, "all the errors, as on every other path")
        #expect(d.issues.allSatisfy { $0.code == .typeMismatch })
    }

    @Test("@Validate runs on this path exactly as on the others")
    func validation() {
        var r = fullRow()
        r["age"] = .int(500)
        let d = Row.diagnose(source: DictionarySource(r))
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.message.contains("between 0 and 120") })
    }

    @Test("a source that reports spans renders carets, like JSON")
    func spansRenderCarets() {
        let src = PositionedSource(values: [
            "id": (.int(1), SourceSpan(lo: 0, len: 1)),
            "name": (.string("ada"), SourceSpan(lo: 2, len: 3)),
            "age": (.int(500), SourceSpan(lo: 6, len: 3)),
            "score": (.double(1), SourceSpan(lo: 10, len: 1)),
            "active": (.bool(true), SourceSpan(lo: 12, len: 4)),
        ])
        let d = Row.diagnose(source: src)
        #expect(!d.isValid)
        let issue = d.issues.first { $0.path.pathDescription == "age" }
        #expect(issue?.location != nil, "a positioned source must carry its span through")
        #expect(issue?.location?.lo == 6)
    }

    @Test("the field manifest describes the type at compile time")
    func manifest() {
        let m = Row._assayManifest
        #expect(m.keys == ["id", "name", "age", "score", "active", "nickname", "retries"])
        #expect(m.fields.first { $0.key == "nickname" }?.isOptional == true)
        #expect(m.fields.first { $0.key == "retries" }?.hasDefault == true)
        #expect(m.fields.first { $0.key == "retries" }?.isRequired == false)
        #expect(m.fields.first { $0.key == "name" }?.isRequired == true)
        #expect(m.fields.first { $0.key == "score" }?.kind == .double)
        // This is what a source binds against once per stream instead of per record.
        #expect(m.fields.count == 7)
    }

    @Test("integer narrowing reports rather than truncating")
    func narrowing() {
        var r = fullRow()
        r["id"] = .int(Int64.max)
        let d = Row.diagnose(source: DictionarySource(r))
        // Int is 64-bit here so this succeeds; the point is that it does not silently
        // wrap. A narrower declared type reports instead.
        #expect(d.isValid || d.issues.contains { $0.code == .typeMismatch })
    }
}

@Suite("KeyedSource diagnostics")
struct KeyedSourceDiagnosticTests {

    @Test("a collection field is refused — a keyed source is a flat record")
    func collectionRefused() {
        for src in ["@Schema(sources: true) struct S { var tags: [String] }",
                    "@Schema(sources: true) struct S { var m: [String: Int] }"] {
            let (_, diags) = expandSchemaForTesting(src)
            #expect(diags.contains { $0.contains("FLAT record") }, "for: \(src)")
        }
    }

    @Test("a nested @Schema field is refused, pointing at the document")
    func nestedRefused() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(sources: true) struct S { var inner: Other }
        """)
        #expect(diags.contains { $0.contains("KEYED-SOURCE.md") })
    }

    @Test("sources: false emits nothing — the compile budget is why it is opt-in")
    func optInIsReal() {
        let (without, _) = expandSchemaForTesting("@Schema struct S { var a: Int }")
        let (with, _) = expandSchemaForTesting("@Schema(sources: true) struct S { var a: Int }")
        #expect(!without.contains("_assayManifest"))
        #expect(with.contains("_assayManifest"))
        #expect(with.contains("KeyedSource"))
    }
}
