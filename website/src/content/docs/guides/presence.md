---
title: Presence
description: Missing, null, wrong, defaulted and salvaged are five different things. The declaration is where you say which.
---

Most decoding bugs are a conflation of these five. Assay keeps them apart in the
declaration, and the difference shows up in the error.

```swift
@Schema
struct Settings {
    var name: String                 // required — absent is an error
    var nickname: String?            // optional — absent is nil, and that is fine
    var retries: Int = 3             // defaulted — absent is 3, present is validated
    @Fallback(0) var count: Int      // salvaged — absent OR invalid becomes 0, with a warning
    @Ignore var cache: Cache?        // not a field at all
}
```

Four of the five need no attribute. That is the point: you were going to write the property
anyway.

## Required

```swift
var name: String
```

Absent is an error. Present but the wrong type is a different error. Both name the field.

```
error: name is required
error: name must be a string, found 42
```

## Optional

```swift
var nickname: String?
```

Absent is `nil`. An explicit `null` is also `nil`. **Present but wrong is still an error** —
and this is the distinction that costs people the most time, because Codable blurs it.

```
error: nickname must be a string, found 42
```

`String?` means *this key may be missing*. It does not mean *anything is acceptable here*.
If you genuinely want "if it is broken, forget it", that is `@Fallback`, below.

## Defaulted

```swift
var retries: Int = 3
```

Absent is `3`. A **present** value is decoded and validated as normal, so
`@Validate(.min(1)) var retries: Int = 3` still rejects a `0` that was written down.

The default is your ordinary Swift initializer expression. It is evaluated in your module,
so anything you can write there works.

## Salvaged

```swift
@Fallback(0) var count: Int
```

Absent **or invalid** becomes `0`, and the fallback value is not re-validated. You get a
warning saying it happened:

```
warning: count fell back to 0
```

The difference from `= 3` is exactly the difference between Valibot's `default` and
`fallback`, and it is worth stating because it is easy to get backwards:

|  | absent | present but invalid | value re-validated? |
|---|---|---|---|
| `var x: Int = 3` | `3` | **error** | yes, when present |
| `@Fallback(3) var x: Int` | `3` | `3` + warning | no |

A fallback silently swallowing bad data is the *point* — that is what you asked for. The
warning is how you find out it happened, which is why fallbacks only surface through
`diagnose`. If you called `parse`, you said you did not want to know.

## Ignored

```swift
@Ignore var cache: Cache?
```

Never read from the document, never written when encoding. It needs a default or to be
optional, because the memberwise initializer still has to produce one.

## Two spellings that will not compile

```swift
@Schema
struct Bad {
    var x = 3               // error: needs an explicit type annotation
    let y: Int = 3          // error: a `let` with an initializer cannot be decoded
}
```

Neither is an oversight.

**`var x = 3`** is refused because a macro sees source text, not types. It cannot ask the
compiler what `3` is, and guessing `Int` is wrong the moment somebody writes
`var timeout = 1.5` in a codebase where the wire type is a `Duration`. Write the type and
the ambiguity is gone.

**`let y: Int = 3`** is refused because it reads two ways: "default to 3" or "always 3, do
not decode this". If you meant the first, use `var`. If you meant the second, `@Ignore`
says so out loud.

## Null versus absent

For an optional, both give you `nil`, and most of the time that is what you want.

When you need to tell them apart — a PATCH body where "absent means leave it alone" and
"null means clear it" are different instructions — decode that field as `RawValue`:

```swift
@Schema
struct Patch {
    var name: RawValue?          // nil = absent; .some(.null) = explicitly null
}
```

`RawValue` is the format-neutral value type. `nil` means the key was not there; `.null`
means it was there and was null.

## Collections

An empty array and an absent array are different too, and the same rules apply:

```swift
var tags: [String]                 // required — absent is an error
var tags: [String] = []            // absent → empty
var tags: [String]?                // absent → nil, present-but-empty → []
```

If "present but empty" should be an error, that is a rule rather than a presence state:

```swift
@Validate(.notEmpty) var tags: [String]
```

Which reports `tags must not be empty` — different from `tags is required`, which is the
whole idea.

## Next

- [Keys](/guides/keys/) — when the wire name is not the property name.
- [Rules](/guides/rules/) — `.notEmpty` and the other thirty-odd.
