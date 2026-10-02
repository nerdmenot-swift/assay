---
title: Rules
description: Every validator, with what each reports. Plus custom messages, normalising before checking, and accepting "8080" as a number.
---

Rules are checked against the field's type **at expansion**. Put `.email` on an `Int` and
you get a build error naming the mismatch, rather than a runtime failure on a Tuesday.

They are also cheaper than you are probably budgeting for: running a type's whole rule set
against a value costs **37 ns and one allocation**, which is about a tenth of what decoding
that value cost in the first place. "Validation is slow" is a claim that needs a number
here, and the number does not support it.

## Bounds

```swift
@Validate(.min(1)) var replicas: Int
@Validate(.range(1...65535)) var port: Int
@Validate(.positive) var quantity: Int
@Validate(.multipleOf(15)) var minutes: Int
@Validate(.finite) var score: Double
```

```json
{"replicas": 0, "port": 70000, "quantity": -1, "minutes": 20, "score": 1e999}
```

```text
b.json:1:14: error: replicas must be at least 1
  1 │ {"replicas": 0, "port": 70000, "quantity": -1, "minutes": 20, "score": 1e999}
    │              ^

b.json:1:25: error: port must be between 1 and 65535
  1 │ {"replicas": 0, "port": 70000, "quantity": -1, "minutes": 20, "score": 1e999}
    │                         ^^^^^

b.json:1:44: error: quantity must be positive
  1 │ {"replicas": 0, "port": 70000, "quantity": -1, "minutes": 20, "score": 1e999}
    │                                            ^^

b.json:1:59: error: minutes must be a multiple of 15
  1 │ {"replicas": 0, "port": 70000, "quantity": -1, "minutes": 20, "score": 1e999}
    │                                                           ^^

b.json:1:72: error: score number is out of range
  1 │ {"replicas": 0, "port": 70000, "quantity": -1, "minutes": 20, "score": 1e999}
    │                                                                        ^^^^^

5 errors
```

`.min` and `.max` mean different things depending on the type they sit on, deliberately:
character count on a `String`, element count on an array, magnitude on a number. The message
tells the reader which one it meant.

## Size and collections

```swift
@Validate(.notEmpty) var bio: String
@Validate(.length(6)) var code: String
@Validate(.count(1...3)) var tags: [String]
@Validate(.unique) var ids: [Int]
@Validate(.each(.min(2), .max(8))) var parts: [String]
```

```json
{"bio": "", "code": "abc", "tags": [], "ids": [1, 1], "parts": ["a", "toolongvalue"]}
```

```text
s.json:1:9: error: bio must not be empty
  1 │ {"bio": "", "code": "abc", "tags": [], "ids": [1, 1], "parts": ["a", "toolongvalue"]}
    │         ^^

s.json:1:21: error: code must be exactly 6 characters
  1 │ {"bio": "", "code": "abc", "tags": [], "ids": [1, 1], "parts": ["a", "toolongvalue"]}
    │                     ^^^^^

s.json:1:36: error: tags must contain between 1 and 3 items
  1 │ {"bio": "", "code": "abc", "tags": [], "ids": [1, 1], "parts": ["a", "toolongvalue"]}
    │                                    ^^

s.json:1:47: error: ids must not contain duplicates
  1 │ {"bio": "", "code": "abc", "tags": [], "ids": [1, 1], "parts": ["a", "toolongvalue"]}
    │                                               ^^^^^^

s.json:1:64: error: parts[0] must be at least 2 characters
  1 │ {"bio": "", "code": "abc", "tags": [], "ids": [1, 1], "parts": ["a", "toolongvalue"]}
    │                                                                ^^^^^^^^^^^^^^^^^^^^^

s.json:1:64: error: parts[1] must be at most 8 characters
  1 │ {"bio": "", "code": "abc", "tags": [], "ids": [1, 1], "parts": ["a", "toolongvalue"]}
    │                                                                ^^^^^^^^^^^^^^^^^^^^^

6 errors
```

`.each` reports per element, and puts the index in the path.

## Strings and formats

```swift
@Validate(.email) var email: String
@Validate(.url) var link: String
@Validate(.uuid) var id: String
@Validate(.hostname) var host: String
@Validate(.regex("^[a-z][a-z0-9-]*$")) var slug: String
@Validate(.prefix("sk-")) var key: String
@Validate(.oneOf(["draft", "published"])) var status: String
```

```json
{"email": "jo@localhost", "link": "not a url", "id": "abc", "host": "-bad-",
 "slug": "Not_A_Slug", "key": "pk-1", "status": "deleted"}
```

```text
s.json:1:11: error: email must be a valid email address
  1 │ {"email": "jo@localhost", "link": "not a url", "id": "abc", "host": "-bad-",
    │           ^^^^^^^^^^^^^^
  2 │  "slug": "Not_A_Slug", "key": "pk-1", "status": "deleted"}

s.json:1:35: error: link must be a valid URL
  1 │ {"email": "jo@localhost", "link": "not a url", "id": "abc", "host": "-bad-",
    │                                   ^^^^^^^^^^^
  2 │  "slug": "Not_A_Slug", "key": "pk-1", "status": "deleted"}

s.json:1:54: error: id must be a valid UUID
  1 │ {"email": "jo@localhost", "link": "not a url", "id": "abc", "host": "-bad-",
    │                                                      ^^^^^
  2 │  "slug": "Not_A_Slug", "key": "pk-1", "status": "deleted"}

s.json:1:69: error: host must be a valid hostname
  1 │ {"email": "jo@localhost", "link": "not a url", "id": "abc", "host": "-bad-",
    │                                                                     ^^^^^^^
  2 │  "slug": "Not_A_Slug", "key": "pk-1", "status": "deleted"}

s.json:2:10: error: slug must match the pattern ^[a-z][a-z0-9-]*$
  1 │ {"email": "jo@localhost", "link": "not a url", "id": "abc", "host": "-bad-",
  2 │  "slug": "Not_A_Slug", "key": "pk-1", "status": "deleted"}
    │          ^^^^^^^^^^^^

s.json:2:31: error: key must start with "sk-"
  1 │ {"email": "jo@localhost", "link": "not a url", "id": "abc", "host": "-bad-",
  2 │  "slug": "Not_A_Slug", "key": "pk-1", "status": "deleted"}
    │                               ^^^^^^

s.json:2:49: error: status must be one of "draft", "published"
  1 │ {"email": "jo@localhost", "link": "not a url", "id": "abc", "host": "-bad-",
  2 │  "slug": "Not_A_Slug", "key": "pk-1", "status": "deleted"}
    │                                                 ^^^^^^^^^

7 errors
```

The four format validators are hand-written rather than delegated, so behaviour is
identical on every platform you ship to. `UUID(uuidString:)` has two C implementations
picked by platform, and nothing in Foundation validates an email at all.

There is also `.ascii`, `.suffix`, `.contains`, `.isTrimmed` and `.isLowercase`. The last two
**assert** rather than normalise — they do not change the value, only refuse it.

## Your own wording

```swift
@Validate(.min(8), "pick something longer") var password: String
@Validate(.range(13...120), "we can only accept teenagers and up") var age: Int
```

```json
{"password": "short", "age": 9}
```

```text
m.json:1:14: error: password pick something longer
  1 │ {"password": "short", "age": 9}
    │              ^^^^^^^

m.json:1:30: error: age we can only accept teenagers and up
  1 │ {"password": "short", "age": 9}
    │                              ^

2 errors
```

For anything you need to translate, switch on `issue.code` and read `issue.params` instead —
[a form](/recipes/form-errors/) shows that shape.

## Normalise first

```swift
@Schema(keys: .snakeCase)
struct Normalise: Equatable {
    @Preprocess(.trim, .lowercase) @Validate(.email) var email: String
    @Preprocess(.collapseWhitespace) @Validate(.isTrimmed) var title: String
}
```

```json
{"email": "  JO@Example.COM  ", "title": "a   spaced   title"}
```

```text
Normalise(email: "jo@example.com", title: "a spaced title")
```

`@Preprocess` runs **before** the rules, so `"  JO@Example.COM  "` passes and reaches you
normalised. `.trim`, `.lowercase`, `.uppercase`, `.collapseWhitespace`.

## Accepting "8080" as a number

```swift
@Schema(keys: .snakeCase)
struct Coerce: Equatable {
    var strict: Int
    @Coerce var lenient: Int
}
```

```json
{"strict": "8080", "lenient": "8080"}
```

```text
c.json:1:12: error: strict must be an integer, found "8080"
  1 │ {"strict": "8080", "lenient": "8080"}
    │            ^

1 error
```

One field took the string, the other refused it. `coerceScalars: true` on the type throws the
same switch for every field, and you need it for [XML](/formats/xml/), where every leaf is
text. It stays opt-in because `"8080"` becoming `8080` should be a decision you made rather
than one made for you.

`"8080.5"` is still not an integer, on any path.

## Next

- [Checks and transforms](/recipes/checks/) — when a rule is not enough.
- [Rules, explained](/guides/rules/) — what a rule is underneath.
