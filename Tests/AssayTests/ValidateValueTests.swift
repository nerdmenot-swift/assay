// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Validating a value you already have. docs/VALIDATE.md.
//
// One law dominates this file, and everything else is a consequence of it:
//
//     T.validate(try T.parse(json: d))   never reports an issue
//
// A value the decoder ACCEPTED must not be rejected by the validator. Two entry points
// that disagree about whether the same value is legal would be worse than having only one,
// because a caller cannot tell which answer is the real one — and every exclusion the
// implementation makes (@Preprocess, @Fallback, @Transform) exists to hold this law rather
// than out of any independent preference.
//
// It is checked here by GENERATING the inputs rather than by listing a few: random values
// in and out of range, round-tripped through JSON, so a rule that decoding applies and
// validation forgets shows up as a disagreement rather than as a gap in a hand-written list.
//===----------------------------------------------------------------------===//

import Testing
import Assay

@Schema(keys: .snakeCase)
struct Account: Equatable {
    @Validate(.min(3), .max(20)) var username: String
    @Validate(.email) var email: String
    @Validate(.range(13...120)) var age: Int
    @Validate(.min(1)) var tags: [String] = []
    @Validate(.min(8), "a passphrase needs 8 characters") var passphrase: String?
    var note: String = ""
}

@Suite("Validating a constructed value")
struct ValidateValueTests {

    static let good = Account(username: "ada", email: "ada@example.com", age: 36,
                              tags: ["x"], passphrase: "hunter22", note: "")

    @Test("a legal value reports nothing")
    func clean() throws {
        let v = Account.diagnose(Self.good)
        #expect(v.isValid)
        #expect(v.issues.isEmpty)
        try Account.validate(Self.good)
    }

    @Test("every violation is reported, not just the first")
    func allIssues() {
        var a = Self.good
        a.username = "ab"                  // .min(3)
        a.email = "not-an-email"           // .email
        a.age = 200                        // .range
        let v = Account.diagnose(a)
        #expect(!v.isValid)
        #expect(v.issues.count == 3, "got \(v.issues.map(\.message))")
        let paths = Set(v.issues.map(\.path.pathDescription))
        #expect(paths == ["username", "email", "age"])
    }

    @Test("the throwing form carries every issue, like parse")
    func throwingForm() {
        var a = Self.good
        a.username = "ab"
        a.age = 1
        #expect(throws: AssayError.self) { try Account.validate(a) }
        do {
            try Account.validate(a)
        } catch let e as AssayError {
            #expect(e.issues.count == 2)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("a nil optional is absent, not invalid — the answer decoding gives")
    func nilOptional() {
        var a = Self.good
        a.passphrase = nil
        #expect(Account.diagnose(a).isValid)
        a.passphrase = "short"
        let v = Account.diagnose(a)
        #expect(!v.isValid)
        #expect(v.issues.first?.message == "a passphrase needs 8 characters")
    }

    @Test("issues render without carets, and say so by simply not drawing one")
    func rendering() {
        var a = Self.good
        a.age = 200
        let text = Account.diagnose(a).render(.plain)
        #expect(text.contains("age"))
        #expect(!text.contains("^"), "there is no source document to point at")
    }

    @Test("a message override survives, exactly as on the decode path")
    func overrides() {
        var a = Self.good
        a.passphrase = "1234"
        let viaValidate = Account.diagnose(a).issues.first?.message
        let json = """
        {"username": "ada", "email": "ada@example.com", "age": 36, \
        "tags": ["x"], "passphrase": "1234", "note": ""}
        """
        let viaDecode = Account.diagnose(json: json).issues.first?.message
        #expect(viaValidate == viaDecode)
        #expect(viaValidate == "a passphrase needs 8 characters")
    }
}

@Suite("The round-trip law")
struct ValidateValueRoundTripTests {

    /// A value the decoder accepted must never be rejected by the validator. Generated
    /// rather than listed: the interesting failures are the combinations nobody thinks to
    /// write down.
    @Test("anything that parses cleanly validates cleanly")
    func lawHolds() throws {
        var seed: UInt64 = 0x5EED_1234_ABCD_0001
        func next() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return seed
        }
        var accepted = 0

        // Biased toward the legal ranges rather than uniform over them: the law is about
        // documents that PARSE, so a generator that mostly produces rejects would run 600
        // iterations to check a handful of values.
        for _ in 0..<600 {
            let nameLen = 2 + Int(next() % 20)
            let name = String(repeating: "a", count: nameLen)
            let age = 5 + Int(next() % 130)
            let email = (next() % 2 == 0) ? "u@example.com" : "nope"
            let tagCount = 1 + Int(next() % 3)
            let tags = (0..<tagCount).map { "t\($0)" }
            let pass = (next() % 3 == 0) ? "null" : "\"\(String(repeating: "p", count: 4 + Int(next() % 12)))\""

            let json = """
            {"username": "\(name)", "email": "\(email)", "age": \(age), \
            "tags": [\(tags.map { "\"\($0)\"" }.joined(separator: ", "))], \
            "passphrase": \(pass), "note": "n"}
            """
            let d = Account.diagnose(json: json)
            guard d.isValid, let value = d.value else { continue }
            accepted += 1

            let v = Account.diagnose(value)
            if !v.isValid {
                let why = v.issues.map(\.message).joined(separator: "; ")
                Issue.record("decoding accepted \(json) but validation rejected it: \(why)")
            }
        }
        // Guards the guard: a generator that produced nothing valid would make the loop
        // above pass while checking nothing at all.
        #expect(accepted > 50, "only \(accepted) of 600 generated documents parsed")
    }

    /// The converse direction, which is NOT a law but is the useful property: a value the
    /// decoder rejected on a plain @Validate rule is also rejected by the validator. It
    /// holds for every rule that is not excluded, and the exclusions are tested separately.
    @Test("what decoding rejects on a plain rule, validating rejects too")
    func converse() throws {
        let cases: [(String, String)] = [
            ("\"ab\"", "username"), ("\"\(String(repeating: "z", count: 30))\"", "username"),
        ]
        for (literal, field) in cases {
            let json = """
            {"username": \(literal), "email": "a@b.com", "age": 30, "tags": ["t"], \
            "passphrase": null, "note": ""}
            """
            let d = Account.diagnose(json: json)
            #expect(!d.isValid, "expected decoding to reject \(literal)")

            // Build the same value by hand — decoding refused to produce one.
            var a = ValidateValueTests.good
            a.username = String(literal.dropFirst().dropLast())
            a.tags = ["t"]
            a.passphrase = nil
            let v = Account.diagnose(a)
            #expect(v.issues.contains { $0.path.pathDescription == field },
                    "validating missed what decoding caught on \(field)")
        }
    }
}

// MARK: - The exclusions, pinned

@Schema
struct Salvaged: Equatable {
    @Validate(.range(1...10)) @Fallback(5) var level: Int
    @Validate(.min(2)) var name: String
}

@Schema
struct Converted: Equatable {
    @Validate(.min(2)) @Transform({ (s: String) in s.count }) var width: Int
    @Validate(.min(2)) var name: String
}

@Suite("Rules that cannot be re-checked")
struct ValidateValueExclusionTests {

    /// The law in its sharpest form. Decoding SWALLOWS a @Fallback violation — the field
    /// takes 5 and records a warning — so a validator that reported it afterwards would
    /// reject the exact value decoding just produced.
    @Test("a @Fallback field's rules do not run, because decoding swallowed them")
    func fallbackExcluded() throws {
        let d = Salvaged.diagnose(json: #"{"level": 999, "name": "ok"}"#)
        #expect(d.isValid, "the fallback applies and decoding succeeds")
        let value = try #require(d.value)
        #expect(value.level == 5)
        #expect(!d.warnings.isEmpty, "and it says so")

        // The law: what decoding produced must validate.
        #expect(Salvaged.diagnose(value).isValid)

        // Even a value that could never have been decoded passes here — the honest
        // consequence, and the reason the exclusion is documented on _assayCheck.
        #expect(Salvaged.diagnose(Salvaged(level: 999, name: "ok")).isValid)

        // Every OTHER field on the same type is still checked.
        #expect(!Salvaged.diagnose(Salvaged(level: 5, name: "x")).isValid)
    }

    @Test("a @Transform field's rules do not run; the rest of the type still does")
    func transformExcluded() throws {
        let d = Converted.diagnose(json: #"{"width": "abcde", "name": "ok"}"#)
        let value = try #require(d.value)
        #expect(Converted.diagnose(value).isValid)
        // Rules are type-checked against `String`, the wire type; the property holds an
        // Int. Nothing here can re-run them, and the generated doc comment says which.
        #expect(Converted.diagnose(Converted(width: 0, name: "ok")).isValid)
        #expect(!Converted.diagnose(Converted(width: 5, name: "x")).isValid)
    }

    @Test("the expansion names the excluded fields where quick-help will show them")
    func exclusionsAreDocumented() {
        let (code, _) = expandSchemaForTesting("""
        @Schema struct S {
            @Validate(.range(1...10)) @Fallback(5) var level: Int
            @Validate(.min(2)) var name: String
        }
        """)
        #expect(code.contains("Rules NOT re-checked here"))
        #expect(code.contains("`level`"))
        #expect(!code.contains("`name`"), "name is checked, so it must not be listed")
    }
}

// MARK: - Cross-field checks and opt-out

@Schema
struct Booking: Equatable {
    var start: Int
    var end: Int
    @Validate(.min(1)) var guests: Int

    @Check
    static func endAfterStart(_ b: Booking, _ issues: inout Issues<Booking>) {
        if b.end <= b.start { issues.add("end must be after start", at: \.end) }
    }
}

@Schema
struct Plain: Equatable {
    var a: Int
    var b: String
}

@Suite("Checks, and the types that get no validator")
struct ValidateValueCheckTests {

    @Test("@Check runs against a constructed value, naming the field")
    func crossField() {
        let v = Booking.diagnose(Booking(start: 10, end: 5, guests: 2))
        #expect(!v.isValid)
        #expect(v.issues.first?.path.pathDescription == "end")
        #expect(v.issues.first?.message == "end must be after start")
    }

    @Test("field rules and cross-field checks report together, in one pass")
    func both() {
        let v = Booking.diagnose(Booking(start: 10, end: 5, guests: 0))
        #expect(v.issues.count == 2)
    }

    @Test("a batch names the row, and one sink bounds the whole report")
    func batch() {
        let rows = [Booking(start: 0, end: 1, guests: 1),
                    Booking(start: 5, end: 1, guests: 1),
                    Booking(start: 0, end: 1, guests: 0)]
        let v = Booking.diagnose(rows)
        #expect(v.issues.count == 2)
        let paths = v.issues.map(\.path.pathDescription)
        #expect(paths.contains { $0.contains("[1]") }, "got \(paths)")
        #expect(paths.contains { $0.contains("[2]") }, "got \(paths)")

        #expect(throws: AssayError.self) { try Booking.validate(rows) }
        try? Booking.validate([rows[0]])
    }

    @Test("maxIssues bounds the report over a batch, not each element")
    func batchLimits() {
        let bad = Array(repeating: Booking(start: 5, end: 1, guests: 0), count: 500)
        let v = Booking.diagnose(bad, limits: Limits(maxIssues: 10))
        #expect(v.issues.count == 10)
        #expect(v.truncatedIssues)
    }

    @Test("a type with no rules gets no validator, and so costs nothing")
    func noRulesNoBody() {
        let (code, _) = expandSchemaForTesting("@Schema struct S { var a: Int }")
        #expect(!code.contains("_assayCheck"))
        #expect(!code.contains("Validatable"))

        let (withRules, _) = expandSchemaForTesting("""
        @Schema struct S { @Validate(.min(1)) var a: Int }
        """)
        #expect(withRules.contains("_assayCheck"))
        #expect(withRules.contains("Assay.Validatable"))
    }
}
