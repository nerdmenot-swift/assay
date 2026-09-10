# Rules

Rules on fields, checks across fields, and diagnostics at compile time.

## Overview

Validation is optional and additive. A `@Schema` type with no rules is a complete decoder;
adding rules changes nothing about how it decodes and adds issues that render exactly like
decoding failures.

```swift
@Schema
struct Deployment {
    @Validate(.min(1), .max(63), .hostname) var name: String
    @Validate(.min(1)) var replicas: Int
    @Validate(.url) var image: String
    @Validate(.email, "must be a company address") var owner: String
}
```

## Field rules

``Validate(_:)`` takes one or more `Rule` values. The macro checks each rule against the
field's type at expansion — `.email` on an `Int` is a compile error with a purpose-written
message, not a runtime surprise. The built-in rules include bounds (`.min`, `.max`,
`.range`, `.positive`, `.nonNegative`, `.multipleOf`, `.finite`), size (`.length`,
`.notEmpty`, `.count`, `.unique`, `.each`), string shape (`.email`, `.url`, `.uuid`,
`.hostname`, `.ascii`, `.regex`, `.prefix`, `.suffix`, `.contains`, `.isTrimmed`,
`.isLowercase`), sets (`.oneOf`), dates (`.before`, `.after`, `.between`), and `.all` to
name a reusable combination.

A string literal after the rules overrides the message for every rule in that attribute.

## Preprocessing and transforms

```swift
@Preprocess(.trim, .lowercase) @Validate(.email) var email: String
@Transform({ (s: String) in URL(string: s) }) var link: URL?
```

``Preprocess(_:)`` runs before decoding and validation on the wire value. ``Transform(_:)``
converts the decoded wire type into the declared type; a `nil` result is an issue.

## Checks

A check is a static function the macro wires in. The field form names one field and
returns a message or `nil`; the cross-field form sees the whole value and reports
wherever it likes:

```swift
@Schema
struct Signup {
    var workEmail: String
    @Validate(.min(8)) var password: String

    @Check(\Signup.workEmail)
    static func companyDomain(_ email: String) -> String? {
        email.hasSuffix("@acme.com") ? nil : "must be a company address"
    }

    @Check
    static func passwordIsNotEmail(_ s: Signup, _ issues: inout Issues<Signup>) {
        if s.password == s.workEmail {
            issues.add(code: "password_is_email", "must not be your email address",
                       at: \.password)
        }
    }
}
```

The key path in the field form is written `\Signup.workEmail`, not `\.workEmail` — an
attached-macro argument has no root type to infer from. A check declared in an extension is
invisible to the macro and is a compile error rather than a silently skipped rule.

``AsyncCheck()`` is the `async` form — it makes `parse` async, runs only if the sync pass
was clean, and runs its checks concurrently.

## Order

preprocess → coerce → decode → field rules → cross-field checks → transform → async checks.

## Validating a value you already have

```swift
try Deployment.validate(existing)       // runs the rules, decodes nothing
Deployment.diagnose(existing)           // the same, collecting
```

The law: `T.validate(try T.parse(json: d))` never reports an issue.
