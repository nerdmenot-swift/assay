---
title: Errors
description: What a failure actually is, how to show it four ways, and how to wire it into your own UI.
---

This is the part the library exists for.

## Everything, not the first thing

`JSONDecoder` throws on the first problem. For a network payload that is fine. For a config
file, a form, or a CSV import it turns fixing data into a loop: run, fix, run, fix.

```swift
let d = Signup.diagnose(json: data, sourceName: "signup.json")
```

```text
signup.json:2:15: error: username must be at least 3 characters
  1 │ {
  2 │   "username": "jo",
    │               ^^^^
  3 │   "email": "jo@localhost",

signup.json:3:12: error: email must be a valid email address
  1 │ {
  2 │   "username": "jo",
  3 │   "email": "jo@localhost",
    │            ^^^^^^^^^^^^^^
  4 │   "age": "fourteen",

signup.json:4:10: error: age must be an integer, found "fourteen"
  2 │   "username": "jo",
  3 │   "email": "jo@localhost",
  4 │   "age": "fourteen",
    │          ^
  5 │   "newsleter": true

signup.json:5:4: warning: unknown key "newsleter"; did you mean "newsletter"?
  3 │   "email": "jo@localhost",
  4 │   "age": "fourteen",
  5 │   "newsleter": true
    │    ^^^^^^^^^
  6 │ }

3 errors, 1 warning
```

Decode errors and rule errors are mixed together, in source order, because to whoever is
fixing the file they are the same kind of problem.

## An issue is a value, not a string

```swift
for issue in d.issues {
    issue.code        // .tooSmall  — a stable, matchable code
    issue.path        // [.key("username")]
    issue.params      // ["minimum": .int(3), "unit": .string("characters")]
    issue.received    // "jo"
    issue.location    // SourceSpan(lo: 16, len: 4)
    issue.message     // "must be at least 3 characters" — derived, on demand
}
```

The message is **derived when you ask for it**, never stored. That is the difference
between a library you can translate and one that only ever speaks English: match on
`issue.code`, render your own words, and the parameters are right there to interpolate.

Messages are predicate-shaped — `must be at least 3 characters`, not `username must be at
least 3 characters` — so a renderer prefixes the path itself and you can prefix a form
label instead.

**Branch on the code, never on the message.** The wording is not part of the API.

## The four renderers

```swift
d.render(.terminal)         // carets, with colour when attached to a TTY
d.render(.plain)            // the same, no escape codes
d.render(.json)             // machine-readable, one object per issue
d.render(.problemDetails)   // RFC 9457, ready for an HTTP 4xx body
```

`.json` keeps everything, including the byte offsets and the resolved line and column:

```text
{"source":"signup.json","valid":false,"issues":[{"path":"age","code":"type_mismatch","message":"must be an integer, found \"fourteen\"","params":{"expected":"integer"},"received":"\"fourteen\"","offset":58,"length":1,"line":4,"column":10},{"path":"username","code":"too_small","message":"must be at least 3 characters","params":{"minimum":3,"unit":"characters"},"received":"jo","offset":16,"length":4,"line":2,"column":15},{"path":"email","code":"invalid_email","message":"must be a valid email address","received":"jo@localhost","offset":33,"length":14,"line":3,"column":12}],"warnings":[{"path":"","code":"unknown_key","message":"unknown key \"newsleter\"; did you mean \"newsletter\"?","params":{"didYouMean":"newsletter","received":"newsleter"},"offset":73,"length":9,"line":5,"column":4}]}
```

`.problemDetails` is the shape an HTTP client expects:

```text
{"type":"about:blank","title":"Validation failed","status":422,"errors":[{"path":"age","code":"type_mismatch","message":"must be an integer, found \"fourteen\"","params":{"expected":"integer"}},{"path":"username","code":"too_small","message":"must be at least 3 characters","params":{"minimum":3,"unit":"characters"}},{"path":"email","code":"invalid_email","message":"must be a valid email address"}]}
```

## Wiring it to your own UI

The path is what maps an issue onto a field:

```swift
let d = Signup.diagnose(json: body)
var fieldErrors: [String: [String]] = [:]
for issue in d.issues {
    fieldErrors[issue.path.pathDescription, default: []].append(issue.message)
}
// ["username": ["must be at least 3 characters"], "email": ["must be a valid email address"]]
```

`pathDescription` renders the way you would write it in code:
`services[2].healthCheck.timeoutSeconds`.

And for your own wording:

```swift
switch issue.code {
case .tooSmall:
    let n = issue.params["minimum"]?.displayString ?? "?"
    return NSLocalizedString("field.too_short", comment: "") + " (\(n))"
case .invalidEmail:
    return NSLocalizedString("field.bad_email", comment: "")
default:
    return issue.message
}
```

## Warnings

A warning is an issue with softer consequences: the value decoded, but you should know.

```swift
d.warnings      // [Warning] — same shape, same renderers
```

Three things warn: an unknown key under `.warn`, a `@Fallback` that fired, and a
`@Key(_:or:)` alias that matched instead of the primary name.

Warnings never appear through `parse`. If you called `parse` you asked for a value or an
error, and a warning is neither.

## Errors from `parse`

```swift
do {
    let user = try User.parse(json: data)
} catch let error as AssayError {
    print(error)                    // renders with carets — the default description
    error.issues                    // the same [Issue]
    print(error.render(.json))
}
```

`AssayError` carries the source bytes, which is what lets `print(error)` draw a caret
rather than print a struct dump.

## Carets on every format

The spans come from the parsers, so this works the same in YAML, XML and TOML:

```text
deploy.toml:3:12: error: replicas must be at least 1
  1 │ name = "api"
  2 │ image = "registry.internal/api:2.4.1"
  3 │ replicas = 0
    │            ^
  4 │ health_check = "https://api.internal/healthz"

1 error
```

One kind of issue has no byte offset and therefore no caret, by nature rather than by
omission: a value you validated with `T.validate(_:)`, where there was no document to point
at. Those issues carry the path, and the batch form puts the element's index in it —
`[250003].email` — which is the equivalent for a reader that decoded the rows itself.

## Limits

```swift
try T.parse(json: bytes, limits: Limits(maxIssues: 100, maxDepth: 64, maxBytes: 64 << 20))
```

When issue collection hits its cap, `d.issuesWereTruncated` is `true` — so you can tell a
hundred-of-a-hundred from a hundred-of-ten-thousand rather than guessing.

The other two are security limits; see
[Limits and security](/reference/limits-and-security/).

## The codes

Around 120 of them, each with a stable string. The ones you will see most:

| Code | When |
|---|---|
| `missing` | a required key was absent |
| `type_mismatch` | present, wrong type — carries `expected` and `received` |
| `too_small` / `too_large` | `.min` / `.max` — carries `minimum` / `maximum` and a `unit` |
| `invalid_email` / `invalid_url` / `invalid_uuid` | format validators |
| `unknown_key` | under `.warn` or `.reject`; may carry a `didYouMean` |
| `number_overflow` | a number outside the declared width |
| `malformed_document` | the bytes are not that format |
| `depth_exceeded` / `too_many_bytes` | a limit fired |

[Issue codes](/reference/issue-codes/) is the full list.

## Next

- [Formats](/formats/) — the same errors, on four more parsers.
- [Issue codes](/reference/issue-codes/) — all of them, with parameters.
