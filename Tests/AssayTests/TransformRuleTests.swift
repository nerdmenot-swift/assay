// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

//===----------------------------------------------------------------------===//
// Rules on a transformed field.
//
// A `@Transform` field has two types: the wire type the closure takes and the property
// type it returns. Rules run BEFORE the transform, so they see the wire value — and until
// 2026-10-04 the expansion-time check compared them against the property type instead.
// That was wrong in both directions, and the first is the kind this macro exists to
// prevent: a rule that compiles and checks nothing.
//===----------------------------------------------------------------------===//

@Schema
struct TransformedWidth: Equatable {
    /// A String rule on a field whose property is an `Int`. Refused before the fix.
    @Validate(.min(2), .ascii) @Transform({ (s: String) in s.count }) var width: Int
    /// An array rule on a field whose property is a `Set`.
    @Validate(.count(1...2), .unique) @Transform({ (a: [String]) in Set(a) }) var tags: Set<String>
}

@Suite("Rules on a @Transform field are checked against the wire type")
struct TransformRuleTests {

    private func diags(_ src: String) -> [String] { expandSchemaForTesting(src).diagnostics }

    @Test("a rule for the property's type, not the wire's, is refused and says why")
    func wrongForTheWire() {
        // `.positive` is a number rule and the property IS a number — but the value the
        // rule would be handed is a String. This compiled, and validated nothing.
        let d = diags(
            "@Schema struct S { @Validate(.positive) @Transform({ (s: String) in s.count }) var w: Int }"
        )
        #expect(d.count == 1, "got \(d)")
        #expect(d.first?.contains("rule '.positive' applies to a number") == true)
        #expect(d.first?.contains("'w' arrives as String") == true)
        #expect(d.first?.contains("before the transform") == true)
    }

    @Test("a rule for the wire type is accepted, whatever the property is")
    func rightForTheWire() {
        #expect(
            diags(
                "@Schema struct S { @Validate(.email) @Transform({ (s: String) in s.count }) var w: Int }"
            )
            .isEmpty)
        #expect(
            diags(
                "@Schema struct S { @Validate(.count(1...3), .unique) @Transform({ (a: [String]) in Set(a) }) var t: Set<String> }"
            ).isEmpty)
    }

    @Test(".each and .unique look at the wire array's element")
    func elementCheck() {
        let d = diags(
            "@Schema struct S { @Validate(.unique) @Transform({ (a: [Bool]) in a.count }) var n: Int }"
        )
        #expect(d.first?.contains("supports elements of String, Int or Double") == true, "got \(d)")
        #expect(d.first?.contains("arrives as [Bool]") == true)
    }

    @Test("an untransformed field's message is unchanged")
    func plainMessage() {
        let d = diags("@Schema struct S { @Validate(.email) var a: Int }")
        #expect(d == ["rule '.email' applies to String, but 'a' is declared Int"])
    }

    @Test("and the accepted rules really run, on the wire value")
    func runs() throws {
        let ok = try TransformedWidth.parse(json: #"{"width":"abc","tags":["a","b"]}"#)
        #expect(ok == TransformedWidth(width: 3, tags: ["a", "b"]))

        let d = TransformedWidth.diagnose(json: #"{"width":"é","tags":["a","a","b"]}"#)
        #expect(d.issues.map(\.code) == [.tooSmall, .notAscii, .wrongCount, .notUnique])
        #expect(d.issues.map(\.path.pathDescription) == ["width", "width", "tags", "tags"])
    }
}
