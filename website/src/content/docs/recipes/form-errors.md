---
title: A form with errors on the fields
description: Turn a diagnosis into one message per field, in your own wording, ready to render beside the input that caused it.
---

A form needs the opposite shape from a log line. Not a report about a document, but a
message attached to a field, in your product's voice, translatable.

```swift
@Schema(keys: .snakeCase, unknownKeys: .warn)
struct Registration {
    @Validate(.min(3), .max(24)) var username: String
    @Validate(.email) var email: String
    @Validate(.range(13...120)) var age: Int
    @Validate(.min(8)) var password: String
}

func fieldErrors(_ d: Diagnosis<Registration>) -> [(String, String)] {
    var out: [(String, String)] = []
    for issue in d.issues {
        let field = issue.path.pathDescription
        let text: String
        switch issue.code {
        case .tooSmall:
            let n = issue.params["minimum"]?.displayString ?? "?"
            text = "needs at least \(n) characters"
        case .tooLarge:
            let n = issue.params["maximum"]?.displayString ?? "?"
            text = "must be \(n) characters or fewer"
        case .notInRange:
            let lo = issue.params["minimum"]?.displayString ?? "?"
            let hi = issue.params["maximum"]?.displayString ?? "?"
            text = "must be between \(lo) and \(hi)"
        case .invalidEmail:
            text = "does not look like an email address"
        case .missing:
            text = "is required"
        default:
            text = issue.message
        }
        out.append((field, text))
    }
    return out
}
```

```json
{"username": "jo", "email": "jo@localhost", "age": 11, "password": "short"}
```

```text
username: needs at least 3 characters
email: does not look like an email address
age: must be between 13 and 120
password: needs at least 8 characters
```

Four problems, four fields, one pass. Nobody fixes their username, resubmits, and learns
about their password.

## Why switch on the code and not the message

`issue.message` is English, derived on demand, and **not part of the API**. It changes when
the wording improves. `issue.code` does not.

The parameters are the other half: `minimum` is the number the rule was built with, as a
value, so your own sentence can interpolate it instead of parsing it back out of a string.
That is the whole reason issues are a code plus parameters rather than a rendered string.

For a real product, the `switch` becomes a lookup:

```swift
NSLocalizedString("error.\(issue.code.codeString)", comment: "")
    .replacingOccurrences(of: "{minimum}",
                          with: issue.params["minimum"]?.displayString ?? "")
```

A key per code, which is a small closed set, rather than a key per field per rule.

## Nested fields

`pathDescription` renders the path the way you would write it in code, so a form with
sections or repeated rows still maps cleanly:

```
addresses[1].postcode
contact.email
```

Split on `.` and `[` if your form identifies inputs some other way. The path is a
`[PathStep]` when you want structure rather than a string.

## The machine-readable render, if you would rather not loop

```text
{"source":"register.json","valid":false,"issues":[{"path":"username","code":"too_small","message":"must be at least 3 characters","params":{"minimum":3,"unit":"characters"},"received":"jo","offset":13,"length":4,"line":1,"column":14},{"path":"email","code":"invalid_email","message":"must be a valid email address","received":"jo@localhost","offset":28,"length":14,"line":1,"column":29},{"path":"age","code":"not_in_range","message":"must be between 13 and 120","params":{"maximum":120,"minimum":13},"received":"11","offset":51,"length":2,"line":1,"column":52},{"path":"password","code":"too_small","message":"must be at least 8 characters","params":{"minimum":8,"unit":"characters"},"received":"short","offset":67,"length":7,"line":1,"column":68}],"warnings":[]}
```

Same information, already shaped: path, code, message, params, and the byte offsets. Useful
when the client rendering the form is not the process that decoded the body.

## Warnings are not errors

`unknownKeys: .warn` means an unexpected field in the submission is reported without
failing anything. Those arrive in `d.warnings`, not `d.issues`, and should not be shown
next to an input — nobody typed them. Log them; they usually mean a client and a server
have drifted.

## Next

- [Errors](/guides/errors/) — codes, paths, spans and all four renderers.
- [Rules](/guides/rules/) — what each rule reports and with which parameters.
- [Issue codes](/reference/issue-codes/) — every code, generated from the source.
