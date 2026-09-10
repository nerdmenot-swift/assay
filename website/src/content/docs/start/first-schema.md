---
title: Your first schema
description: One struct, two verbs, and what happens when the data is wrong.
---

Mark a struct. That is the whole setup.

```swift
import Assay

@Schema
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var tags: [String] = []
}
```

No `CodingKeys`. No `init(from:)`. No conformance to write. Every stored property is a
field, and the declaration you already wrote says everything the decoder needs.

```swift
let article = try Article.parse(json: data)
```

## The two verbs

There are two, and which you want depends on who reads the failure.

```swift
// Throws. For code that wants a value or an error.
let article = try Article.parse(json: data)

// Never throws. For code that wants to SHOW someone what happened.
let d = Article.diagnose(json: data)
if d.isValid { use(d.value!) }
for issue in d.issues { print(issue) }
```

`parse` is what you call in a network layer. `diagnose` is what you call behind a form, a
config loader, or a CLI — anywhere a person is going to read the result. It hands back a
`Diagnosis`: the value (when there were no errors), every issue, every warning, and the
source bytes so a renderer can draw carets.

## When it goes wrong

Say the JSON is this:

```json
{
  "title": "On carets",
  "link": "https://example.com/carets",
  "reading_minutes": "four"
}
```

Foundation would tell you it expected an `Int` and found a `String`, and leave you to work
out where. Assay tells you where:

```
article.json:4:22: error: reading_minutes must be an integer, found "four"
  2 │   "title": "On carets",
  3 │   "link": "https://example.com/carets",
  4 │   "reading_minutes": "four"
    │                      ^
  5 │ }

1 error
```

You get that from `d.render(.terminal)` — or `.plain` without the colour, or `.json` for a
log, or `.problemDetails` for an HTTP 4xx body. Same issue, four presentations.

## Keys that do not match your property names

Most APIs are snake_case and most Swift is camelCase. Say so once:

```swift
@Schema(keys: .snakeCase)
struct Article {
    var readingMinutes: Int      // reads "reading_minutes"
}
```

The conversion happens **at compile time**, from the identifier you wrote. That matters more
than it sounds: Foundation's runtime `.convertFromSnakeCase` is lossy — `avatarURL` becomes
`avatar_url` becomes `avatarUrl`, and now your property is unreachable. Converting from the
declaration cannot do that.

When a key is genuinely different, name it:

```swift
@Key("id") var userID: Int
@Key("email", or: "email_address") var email: String    // tries both; warns which matched
```

[Keys](/guides/keys/) has the rest: paths into nested objects, unknown-key policies,
`@Extras`.

## Absent versus wrong

This is the part that repays five minutes. In Assay, how you declare a property *is* the
answer to "what if it is missing?":

```swift
@Schema
struct Account {
    var id: Int                     // required — absent is an error
    var nickname: String?           // absent → nil
    var retries: Int = 3            // absent → 3, but a present value is still validated
    @Fallback(0) var score: Int     // absent OR invalid → 0, with a warning
    @Ignore var cache: Cache?       // never read, never written
}
```

Five states, five spellings, no attribute needed for the common three. [Presence](/guides/presence/)
is the long version, including the two spellings that are compile errors on purpose.

## Adding a rule

A rule turns "this decoded" into "this is usable":

```swift
@Schema(keys: .snakeCase)
struct Deployment {
    @Validate(.min(1), .max(63)) var name: String
    @Validate(.min(1)) var replicas: Int
    @Validate(.url) var healthCheck: String?
}
```

A rule that cannot apply to the field's type is a **build** error with a message written for
it — `.email` on an `Int` does not compile. And a rule failure renders exactly like a
decode failure, because to the person reading it they are the same thing: the data is
wrong, and here is where.

Zero-rule `@Schema` is a first-class mode, though. Assay is a complete serde with no
validation at all, not an on-ramp to one.

## Next

- [Coming from Codable](/start/from-codable/) — every habit you have, and what it becomes.
- [Cheatsheet](/start/cheatsheet/) — one page, everything, no prose.
- [Errors](/guides/errors/) — the part this library exists for.
