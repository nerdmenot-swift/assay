import Testing
import Assay
import AssayCore

// EXPERIENCE.md §5 — the validation surface, held to its own worked examples.

@Schema
struct Signup {
    @Validate(.min(3), .max(20), .regex(#"^[a-z0-9_]+$"#)) var username: String
    @Validate(.email) var email: String
    @Validate(.min(12), "must be at least 12 characters") var password: String
    @Validate(.range(13...120)) var age: Int
    @Validate(.count(1...10), .each(.email)) var recipients: [String]
}

@Schema(keys: .snakeCase, formats: [.json, .yaml])
struct Deployment {
    @Validate(.notEmpty) var name: String
    @Validate(.min(1)) var replicas: Int
    @Validate(.prefix("registry.internal/")) var image: String
}

extension Rule {
    static let companySlug = Rule.all(.min(3), .max(40), .regex("^[a-z][a-z0-9-]*$"))
}

@Schema
struct Org {
    @Validate(.companySlug) var slug: String
}

@Schema
struct PerRuleMessages {
    @Validate(.min(3, or: "too short"), .max(20, or: "too long")) var username: String
}

@Schema
struct Formats {
    @Validate(.uuid) var id: String
    @Validate(.url) var link: String
    @Validate(.hostname) var host: String
    @Validate(.ascii) var code: String
}

@Schema
struct Numbers2 {
    @Validate(.positive) var count: Int
    @Validate(.nonNegative) var offset: Int
    @Validate(.multipleOf(5)) var step: Int
    @Validate(.finite) var ratio: Double
}

@Schema
struct Collections2 {
    @Validate(.unique) var tags: [String]
    @Validate(.notEmpty) var items: [Int]
}

@Schema
struct OptionalValidated {
    @Validate(.email) var backup: String?
    @Validate(.min(1)) var retries: Int = 3
}

@Suite("@Validate")
struct ValidateTests {

    @Test("the §5 worked example: every rule, every field")
    func signup() throws {
        let good = try Signup.parse(json: #"""
        {"username":"ada_l","email":"ada@example.com","password":"correct-horse-battery",
         "age":36,"recipients":["a@example.com","b@example.com"]}
        """#)
        #expect(good.username == "ada_l")

        let d = Signup.diagnose(json: #"""
        {"username":"A!","email":"nope","password":"short","age":9,"recipients":[]}
        """#)
        #expect(d.isValid == false)
        // All the errors, one pass: min(username) + regex(username), email, password, age, count.
        #expect(d.issues.count == 6)
        #expect(d.issues.contains { $0.code == .custom("invalid_email") })
        #expect(d.issues.contains { $0.code == .custom("not_in_range") })
        #expect(d.issues.contains { $0.code == .custom("wrong_count") })
    }

    @Test("decode errors and rule violations collect in the same pass")
    func mixedFailures() {
        // One type mismatch AND one rule violation: both reported, not first-wins.
        let d = Signup.diagnose(json: #"""
        {"username":"ok_name","email":"nope","password":true,"age":36,"recipients":["a@example.com"]}
        """#)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .typeMismatch })          // password
        #expect(d.issues.contains { $0.code == .custom("invalid_email") })
    }

    @Test("the flagship: a caret under a value that parsed fine and validated badly")
    func caretOnValidation() {
        let json = """
        {
        "name": "api",
        "replicas": 0,
        "image": "registry.internal/api"
        }
        """
        let d = Deployment.diagnose(json: json, sourceName: "deploy.json")
        #expect(d.isValid == false)

        let expected = """
        deploy.json:3:13: error: replicas must be at least 1
          1 │ {
          2 │ "name": "api",
          3 │ "replicas": 0,
            │             ^
          4 │ "image": "registry.internal/api"

        1 error

        """
        #expect(d.render(.plain) == expected)
    }

    @Test("attribute-level message override, the message-as-a-rule trick")
    func messageOverride() {
        let d = Signup.diagnose(json: #"""
        {"username":"ada_l","email":"a@example.com","password":"short","age":36,
         "recipients":["a@example.com"]}
        """#)
        let issue = d.issues.first { $0.path.pathDescription == "password" }
        #expect(issue?.message == "must be at least 12 characters")
        // The code and params survive underneath the override — clients still branch.
        #expect(issue?.code == .custom("too_small"))
        #expect(issue?.params["minimum"] == .int(12))
    }

    @Test("per-rule or: messages pick the right one")
    func perRuleMessages() {
        let short = PerRuleMessages.diagnose(json: #"{"username":"ab"}"#)
        #expect(short.issues.first?.message == "too short")
        let long = PerRuleMessages.diagnose(
            json: #"{"username":"abcdefghijklmnopqrstuvwxyz"}"#)
        #expect(long.issues.first?.message == "too long")
    }

    @Test("composed rules via static let, the non-generic payoff")
    func composition() throws {
        _ = try Org.parse(json: #"{"slug":"acme-corp"}"#)
        let d = Org.diagnose(json: #"{"slug":"X"}"#)
        #expect(d.isValid == false)
        #expect(d.issues.count == 2)          // min AND regex, both from the composition
    }

    @Test("hand-rolled format validators behave, identically on every platform")
    func formats() throws {
        _ = try Formats.parse(json: #"""
        {"id":"3db7582f-b24c-4245-8556-3c25956d108f","link":"https://example.com/x",
         "host":"api.example.com","code":"abc123"}
        """#)

        let bad = Formats.diagnose(json: #"""
        {"id":"not-a-uuid","link":"no scheme here","host":"-bad-.example","code":"café"}
        """#)
        #expect(bad.issues.count == 4)
        #expect(bad.issues.contains { $0.code == .custom("invalid_uuid") })
        #expect(bad.issues.contains { $0.code == .custom("invalid_url") })
        #expect(bad.issues.contains { $0.code == .custom("invalid_hostname") })
        #expect(bad.issues.contains { $0.code == .custom("not_ascii") })
    }

    @Test("email validation without a regex engine")
    func email() {
        for good in ["a@example.com", "first.last@sub.example.co", "x+tag@example.io"] {
            #expect(FormatValidators.isEmail(good), "\(good) should pass")
        }
        for bad in ["nope", "@example.com", "a@", "a@localhost", "a..b@example.com",
                    ".a@example.com", "a@-bad-.com", "a@1.2.3.4",
                    String(repeating: "x", count: 65) + "@example.com"] {
            #expect(!FormatValidators.isEmail(bad), "\(bad) should fail")
        }
    }

    @Test("uuid is the canonical form and nothing else")
    func uuid() {
        #expect(FormatValidators.isUUID("3db7582f-b24c-4245-8556-3c25956d108f"))
        #expect(FormatValidators.isUUID("3DB7582F-B24C-4245-8556-3C25956D108F"))
        #expect(!FormatValidators.isUUID("3db7582fb24c42458556-3c25956d108f"))
        #expect(!FormatValidators.isUUID("{3db7582f-b24c-4245-8556-3c25956d108f}"))
        #expect(!FormatValidators.isUUID("urn:uuid:3db7582f-b24c-4245-8556-3c25956d108f"))
    }

    @Test("numeric rules")
    func numbers() {
        let d = Numbers2.diagnose(json: #"{"count":0,"offset":-1,"step":7,"ratio":1.5}"#)
        #expect(d.issues.count == 3)
        #expect(d.issues.contains { $0.code == .custom("not_positive") })
        #expect(d.issues.contains { $0.code == .custom("negative") })
        #expect(d.issues.contains { $0.code == .custom("not_multiple") })
        _ = Numbers2.diagnose(json: #"{"count":5,"offset":0,"step":10,"ratio":0.5}"#)
    }

    @Test("collection rules: unique, notEmpty, each with element paths")
    func collections() {
        let d = Collections2.diagnose(json: #"{"tags":["a","b","a"],"items":[]}"#)
        #expect(d.issues.count == 2)
        #expect(d.issues.contains { $0.code == .custom("not_unique") })
        #expect(d.issues.contains { $0.code == .custom("empty") })

        let e = Signup.diagnose(json: #"""
        {"username":"ada_l","email":"a@example.com","password":"long-enough-pass",
         "age":36,"recipients":["ok@example.com","nope"]}
        """#)
        let bad = e.issues.first { $0.code == .custom("invalid_email") }
        #expect(bad?.path.pathDescription == "recipients[1]")
    }

    @Test("optionals skip rules when nil, validate when present; defaults are validated")
    func optionalsAndDefaults() throws {
        let absent = try OptionalValidated.parse(json: "{}")
        #expect(absent.backup == nil && absent.retries == 3)

        let present = OptionalValidated.diagnose(json: #"{"backup":"not-an-email"}"#)
        #expect(present.isValid == false)

        // A default that VIOLATES its own rule is caught — "absent is 3, still validated".
        let d = OptionalValidated.diagnose(json: #"{"retries":0}"#)
        #expect(d.issues.contains { $0.code == .custom("too_small") })
    }

    @Test("validation runs identically through the YAML path")
    func yamlPath() {
        let d = Deployment.diagnose(yaml: """
        name: api
        replicas: 0
        image: docker.io/api
        """)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .custom("too_small") })
        #expect(d.issues.contains { $0.code == .custom("missing_prefix") })
    }

    @Test("problemDetails carries validation codes and params for API clients")
    func problemDetails() throws {
        let d = Signup.diagnose(json: #"""
        {"username":"ada_l","email":"nope","password":"short","age":36,
         "recipients":["a@example.com"]}
        """#)
        let v = try JSON.Value.parse(d.render(.problemDetails))
        let errors = v["errors"]?.array ?? []
        #expect(errors.contains {
            $0["code"]?.string == "invalid_email" && $0["path"]?.string == "email"
        })
        #expect(errors.contains {
            $0["code"]?.string == "too_small"
                && $0["params"]?["minimum"]?.int == 12
        })
    }
}

@Suite("@Validate macro diagnostics")
struct ValidateMacroDiagnosticTests {

    @Test("rule/type mismatch is caught at expansion with the §5 wording")
    func typeMismatch() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S { @Validate(.email) var age: Int }
        """)
        #expect(diags.contains {
            $0.contains("rule '.email' applies to String") && $0.contains("'age' is declared Int")
        })
    }

    @Test("array rules on scalars, number rules on strings")
    func moreMismatches() {
        let (_, d1) = expandSchemaForTesting(
            "@Schema struct S { @Validate(.unique) var name: String }")
        #expect(d1.contains { $0.contains("'.unique' applies to an Array") })

        let (_, d2) = expandSchemaForTesting(
            "@Schema struct S { @Validate(.positive) var name: String }")
        #expect(d2.contains { $0.contains("'.positive' applies to a number") })
    }

    @Test("a lone message with no rule is a diagnostic, not a silent no-op")
    func loneMessage() {
        let (_, diags) = expandSchemaForTesting(
            #"@Schema struct S { @Validate("nope") var name: String }"#)
        #expect(diags.contains { $0.contains("a lone message does nothing") })
    }

    @Test("opaque composed rules pass expansion untouched")
    func opaquePasses() {
        let (_, diags) = expandSchemaForTesting(
            "@Schema struct S { @Validate(.companySlug) var slug: String }")
        #expect(diags.isEmpty)
    }
}
