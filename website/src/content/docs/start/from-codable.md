---
title: Coming from Codable
description: Every Codable habit you have, and what it turns into here. About ten minutes.
---

You know Codable. This page is the translation table, plus the four places where the answer
is "you do not need that any more".

## The mapping, at a glance

| Codable | Assay |
|---|---|
| `struct T: Codable` | `@Schema struct T` |
| `JSONDecoder().decode(T.self, from: data)` | `T.parse(json: data)` |
| `enum CodingKeys: String, CodingKey` | `@Schema(keys: .snakeCase)` or `@Key("…")` |
| `.keyDecodingStrategy = .convertFromSnakeCase` | `@Schema(keys: .snakeCase)` — at compile time |
| `init(from decoder:)` for a default | `var x: Int = 3` |
| `decodeIfPresent` | `var x: Int?` |
| `.dateDecodingStrategy = .iso8601` | the default; `@DateFormat(…)` to change it |
| A validation pass after decoding | `@Validate`, `@Check` — in the same pass |
| `try/catch` and read `DecodingError` | `T.diagnose(…)` and read `.issues` |
| `Encodable` | `@Schema(encodes: true)` |

## Four things you stop doing

### 1. Writing `CodingKeys`

The whole enum, for a rename or a snake_case API, is one attribute:

```swift
// Before
struct User: Codable {
    let userID: Int
    let displayName: String
    enum CodingKeys: String, CodingKey {
        case userID = "id"
        case displayName = "display_name"
    }
}

// After
@Schema(keys: .snakeCase)
struct User {
    @Key("id") var userID: Int
    var displayName: String
}
```

### 2. Writing `init(from decoder:)` for a default

The most common reason anyone hand-writes a decoder is "this field should default to
something". In Assay that is the declaration:

```swift
// Before: 12 lines of container juggling.
// After:
var retries: Int = 3
```

And the four other presence cases have spellings too — see [Presence](/guides/presence/).

### 3. A separate validation pass

The usual shape is: decode, then walk the value checking it, then build your own error
type. That is two traversals and two error vocabularies.

```swift
// Before
let user = try JSONDecoder().decode(User.self, from: data)
guard user.email.contains("@") else { throw AppError.badEmail }
guard user.age >= 13 else { throw AppError.tooYoung }

// After
@Schema
struct User {
    @Validate(.email) var email: String
    @Validate(.min(13)) var age: Int
}
```

Same pass, same error type, same renderer. And the rule is checked against the field's type
when you build, so `.email` on an `Int` never reaches production.

### 4. Catching on the first error

`JSONDecoder` throws on the first problem it finds. For a network payload that is fine. For
a config file, a form submission or a CSV import it is a loop — run, fix, run, fix.

```swift
let d = Settings.diagnose(json: data)
// d.issues has ALL of them, each with a path and a source span.
```

## Four things that behave differently

### `var x = 3` is a compile error

Codable lets you write `var count = 3` and infers `Int`. Assay refuses it, on purpose:
that spelling reads as "default 3" to one person and "always 3" to another. Write the type:

```swift
var count: Int = 3      // ✓ decoded, defaults to 3
let limit: Int = 100    // ✗ compile error — a `let` with a value is not a field
```

`@Ignore` is how you say "this property is not a field".

### Unknown keys are ignored, unless you say otherwise

Same as Codable's default. But you have three other choices, which Codable does not
offer at all:

```swift
@Schema(unknownKeys: .warn)      // report them, keep decoding — with did-you-mean
@Schema(unknownKeys: .reject)    // an unknown key is an error
@Schema(unknownKeys: .collect)   // put them in an @Extras dictionary
```

### Errors are values, not strings

An `Issue` is a code plus parameters plus a path plus a source span. `.message` is derived
when you ask for it. That means you can branch on `issue.code`, translate it, or map it
onto your form fields — none of which is practical with `DecodingError`'s associated
`Context`.

### Some types are not field types

`Set`, `Data`, `URL`, `Decimal`, tuples, `Any` and a few others are refused at expansion
with a message naming the alternative — usually "decode as `String` and convert with
`@Transform`". Codable would accept several of these and then behave in a way you did not
intend. [Advanced](/guides/advanced/#types-that-are-refused) lists them all with the reason
and the fix.

## Migrating a type, in order

1. Replace `: Codable` with `@Schema`. If the type used `.convertFromSnakeCase`, add
   `keys: .snakeCase`.
2. Delete `CodingKeys`, replacing any genuine renames with `@Key("…")`.
3. Delete `init(from:)` if it existed only for defaults; write the defaults on the
   properties.
4. Replace `JSONDecoder().decode(…)` with `T.parse(json:)`.
5. Move any post-decode validation into `@Validate` / `@Check`.
6. Build. What the macro refuses, it refuses with a message that says what to do instead.

You can do this one type at a time. An Assay type and a Codable type coexist fine — they
are unrelated protocols.

## Both at once

Nothing stops a type being both:

```swift
@Schema
struct User: Codable {
    var id: Int
    var name: String
}
```

Useful while migrating, or when something else in your stack insists on `Encodable`.
`@Schema(encodes: true)` gives you Assay's own writer if you would rather not keep
Codable around for it.

## Next

- [Cheatsheet](/start/cheatsheet/) — the whole surface on one page.
- [Presence](/guides/presence/) — the five states, properly.
- [Errors](/guides/errors/) — what to do with what you get back.
