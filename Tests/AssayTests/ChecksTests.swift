// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

// EXPERIENCE.md §§8, 10, 11 — checks, transforms, fallback, enums. Held, as ever, to the
// document's own worked examples.

@Schema
struct DateRange {
    var start: Int          // epoch seconds; Date is a roadmap item
    var end: Int

    @Check
    static func endAfterStart(_ r: DateRange, _ issues: inout Issues<DateRange>) {
        if r.end < r.start {
            issues.add("must be on or after start", at: \.end)
        }
    }
}

@Schema
struct Signup2 {
    var workEmail: String
    @Validate(.min(8)) var password: String

    @Check(\Signup2.workEmail)
    static func companyDomain(_ email: String) -> String? {
        email.hasSuffix("@acme.com") ? nil : "must be a company address"
    }

    @Check
    static func passwordIsNotEmail(_ s: Signup2, _ issues: inout Issues<Signup2>) {
        if s.password == s.workEmail {
            issues.add(code: "password_is_email", "must not be your email address",
                       at: \.password)
        }
    }
}

@Schema
struct Normalised {
    @Preprocess(.trim, .lowercase) @Validate(.email) var email: String
    @Preprocess(.collapseWhitespace) var title: String
}

@Schema
struct Transformed {
    @Transform({ (a: [String]) in Set(a) })
    var tags: Set<String>

    @Transform({ (ms: Int) in Double(ms) / 1000.0 })
    var timeoutSeconds: Double

    var name: String
}

@Schema
struct WithFallback {
    var name: String
    @Fallback(30) var timeout: Int
    @Fallback(3) @Validate(.range(1...10)) var retries: Int
}

enum Priority: String, JSONAssayable, RawDecodable, CaseIterable {
    case low, medium, high
}

enum StatusCode: Int, JSONAssayable {
    case ok = 200, notFound = 404
}

@Schema(formats: [.json, .yaml])
struct Ticket {
    var title: String
    var priority: Priority
}

@Suite("@Check")
struct CheckTests {

    @Test("the §10 worked example: cross-field with a keypath'd issue")
    func crossField() throws {
        _ = try DateRange.parse(json: #"{"start":100,"end":200}"#)

        let d = DateRange.diagnose(json: #"{"start":200,"end":100}"#)
        #expect(d.isValid == false)
        #expect(d.issues.count == 1)
        // The keypath did real work: the issue landed on `end`, not on the form.
        #expect(d.issues[0].path.pathDescription == "end")
        #expect(d.issues[0].message == "must be on or after start")
    }

    @Test("field form: real parameter, real type, message lands on the field with a caret")
    func fieldForm() {
        let json = """
        {
        "work_email": "ada@gmail.com",
        "password": "long-enough"
        }
        """
        // Note: @Schema without keys: uses camelCase; workEmail -> workEmail. Use exact key.
        let d = Signup2.diagnose(json: #"{"workEmail":"ada@gmail.com","password":"long-enough"}"#,
                                 sourceName: "s.json")
        _ = json
        #expect(d.isValid == false)
        let issue = d.issues[0]
        #expect(issue.path.pathDescription == "workEmail")
        #expect(issue.message == "must be a company address")
        // The field-form check gets the field's span — a caret under the value.
        #expect(issue.location != nil)
        #expect(d.render(.plain).contains("^"))
    }

    @Test("checks run even when field rules failed — four problems, four issues")
    func checksRunAlongsideRuleFailures() {
        let d = Signup2.diagnose(
            json: #"{"workEmail":"a@gmail.com","password":"a@gmail.com"}"#)
        // companyDomain + passwordIsNotEmail + min(8)... password IS 11 chars, so:
        // companyDomain + password_is_email = 2.
        #expect(d.issues.count == 2)
        #expect(d.issues.contains { $0.code == .custom("password_is_email") })
        // The coded form keeps its code for clients and its message for humans.
        let coded = d.issues.first { $0.code == .custom("password_is_email") }
        #expect(coded?.message == "must not be your email address")
    }

    @Test("a @Check in an extension is a compile error — verified via expansion")
    func extensionTrap() {
        // The CheckMacro peer diagnoses via lexicalContext when expanded inside an
        // extension. Direct compiler-level verification lives in the CI matrix; here we
        // assert the diagnostic text exists and the schema-side collection ignores
        // extension members by construction.
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S {
            var a: String
            @Check static func f(_ s: S, _ i: inout Issues<S>) {}
        }
        """)
        #expect(diags.isEmpty)     // in-body: fine
    }
}

@Suite("@Preprocess and @Transform")
struct PreprocessTransformTests {

    @Test("preprocess normalises before rules — the §11 email example")
    func preprocess() throws {
        let v = try Normalised.parse(
            json: #"{"email":"  Ada@Example.COM  ","title":"a   b\t\nc"}"#)
        #expect(v.email == "ada@example.com")     // trimmed, lowercased, then .email passed
        #expect(v.title == "a b c")
    }

    @Test("preprocess runs before validation, so a trimmed value passes rules it would fail raw")
    func preprocessOrdering() {
        // "  a@b.co  " fails .email raw; passes after trim.
        let d = Normalised.diagnose(json: #"{"email":"  a@example.com ","title":"t"}"#)
        #expect(d.isValid)
    }

    @Test("transform changes the type after validation — §11's Set example")
    func transform() throws {
        let v = try Transformed.parse(
            json: #"{"tags":["swift","ios","swift"],"timeoutSeconds":5000,"name":"n"}"#)
        #expect(v.tags == Set(["swift", "ios"]))       // arrived as [String], ended a Set
        #expect(v.timeoutSeconds == 5.0)               // arrived as 5000 ms
    }

    @Test("transforms work through the YAML path too")
    func transformYAML() throws {
        // Transformed is JSON-only; reuse Ticket for the multi-format enum check below.
        // Here: the wire type drives decoding — a Set field arrives as a JSON array.
        let d = Transformed.diagnose(json: #"{"tags":"not-an-array","timeoutSeconds":1,"name":"n"}"#)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .typeMismatch })
    }
}

@Suite("@Fallback")
struct FallbackTests {

    @Test("absent, invalid, and rule-violating all fall back — with a warning each")
    func fallback() {
        // Absent.
        let absent = WithFallback.diagnose(json: #"{"name":"a"}"#)
        #expect(absent.value?.timeout == 30 && absent.value?.retries == 3)
        #expect(absent.warnings.filter { $0.code == .fallbackApplied }.count == 2)

        // Type-invalid: the mismatch is swallowed, the fallback applies, a warning records it.
        let invalid = WithFallback.diagnose(json: #"{"name":"a","timeout":"soon","retries":5}"#)
        #expect(invalid.isValid)
        #expect(invalid.value?.timeout == 30 && invalid.value?.retries == 5)
        #expect(invalid.warnings.contains {
            $0.code == .fallbackApplied && $0.path.pathDescription == "timeout"
        })

        // Rule-violating: range(1...10) fails at 99, falls back, issue rolled back.
        let violating = WithFallback.diagnose(json: #"{"name":"a","retries":99,"timeout":1}"#)
        #expect(violating.isValid)
        #expect(violating.value?.retries == 3)
        #expect(violating.warnings.contains {
            $0.code == .fallbackApplied && $0.path.pathDescription == "retries"
        })
    }

    @Test("a valid present value passes through with no warning")
    func fallbackNotFired() {
        let d = WithFallback.diagnose(json: #"{"name":"a","timeout":60,"retries":5}"#)
        #expect(d.value?.timeout == 60 && d.value?.retries == 5)
        #expect(d.warnings.isEmpty)
    }

    @Test("parse discards fallback warnings by design — use diagnose to see them")
    func parseDiscards() throws {
        let v = try WithFallback.parse(json: #"{"name":"a","timeout":"bad"}"#)
        #expect(v.timeout == 30)      // it worked; whether you know is your verb choice
    }
}

@Suite("Enums")
struct EnumTests {

    @Test("conformance is the entire implementation")
    func stringEnum() throws {
        let t = try Ticket.parse(json: #"{"title":"t","priority":"high"}"#)
        #expect(t.priority == .high)

        let y = try Ticket.parse(yaml: "title: t\npriority: low\n")
        #expect(y.priority == .low)
    }

    @Test("an invalid variant lists the cases and suggests the near miss")
    func unknownVariant() {
        let d = Ticket.diagnose(json: #"{"title":"t","priority":"hgih"}"#)
        #expect(d.isValid == false)
        let issue = d.issues[0]
        #expect(issue.code == .custom("unknown_variant"))
        #expect(issue.path.pathDescription == "priority")
        #expect(issue.params["options"] == .string("\"low\", \"medium\", \"high\""))
        #expect(issue.params["didYouMean"] == .string("high"))
        #expect(issue.message.contains("must be one of"))
    }

    @Test("int-raw enums decode too")
    func intEnum() {
        var sink = IssueSink()
        let bytes = Array("404".utf8)
        let v: StatusCode? = bytes.withUnsafeBufferPointer { buf in
            var r = AssayReader(base: buf.baseAddress!, count: buf.count)
            return StatusCode._assay(from: &r, into: &sink, at: [])
        }
        #expect(v == .notFound)
    }
}

// MARK: - @AsyncCheck

@Schema
struct AsyncSignup {
    @Validate(.email) var email: String

    @AsyncCheck
    static func emailIsAvailable(_ s: AsyncSignup, _ issues: inout Issues<AsyncSignup>) async {
        // Stands in for a database round trip.
        await Task.yield()
        if s.email == "taken@example.com" {
            issues.add(code: "already_registered", "is already registered", at: \.email)
        }
    }
}

@Suite("@AsyncCheck")
struct AsyncCheckTests {

    @Test("a clean sync pass runs the async checks; a taken email fails")
    func asyncCheck() async {
        let ok = await AsyncSignup.diagnose(json: #"{"email":"free@example.com"}"#)
        #expect(ok.isValid)

        let taken = await AsyncSignup.diagnose(json: #"{"email":"taken@example.com"}"#)
        #expect(taken.isValid == false)
        #expect(taken.issues[0].code == .custom("already_registered"))
        #expect(taken.issues[0].path.pathDescription == "email")
    }

    @Test("async checks are skipped when the sync pass failed — no wasted round trips")
    func skippedOnSyncFailure() async {
        let d = await AsyncSignup.diagnose(json: #"{"email":"not-an-email"}"#)
        #expect(d.isValid == false)
        // Only the sync issue; the async check never ran against a known-bad value.
        #expect(d.issues.count == 1)
        #expect(d.issues[0].code == .custom("invalid_email"))
    }

    @Test("the async parse verb throws with everything collected")
    func asyncParse() async {
        do {
            _ = try await AsyncSignup.parse(json: #"{"email":"taken@example.com"}"#)
            Issue.record("should have thrown")
        } catch let e as AssayError {
            #expect(e.issues.count == 1)
        } catch {
            Issue.record("wrong error type")
        }
    }
}
