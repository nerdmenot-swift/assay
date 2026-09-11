---
title: Checks
description: Logic a rule cannot express — one field, across fields, or asking a database.
---

A rule is a value: `.min(3)`, `.email`. When what you need is a *function*, that is a check.

## One field

```swift
@Schema
struct Signup {
    var email: String

    @Check(\Signup.email)
    static func companyAddress(_ e: String) -> String? {
        e.hasSuffix("@acme.com") ? nil : "must be a company address"
    }
}
```

Return `nil` for fine, or the message for not fine. The key path says which field the issue
is reported on, so it renders with that field's caret:

```
error: email must be a company address
```

The parameter type must be the field's type. If it is not, the macro says so when you
build, naming both.

**The key path needs its root.** `\Signup.email`, not `\.email`. An attached macro's
argument has no contextual type to infer `Root` from — this is a Swift limitation, not a
style choice, and the short form has never compiled.

## Across fields

```swift
@Schema
struct DateRange {
    var start: Int
    var end: Int

    @Check
    static func ordered(_ r: DateRange, _ issues: inout Issues<DateRange>) {
        if r.end < r.start {
            issues.add("must be on or after start", at: \.end)
        }
    }
}
```

No key path on the attribute; the function takes the whole value and an issue collector,
and reports wherever it likes. Inside the function `\.end` is enough — there *is* a
contextual type here.

The signature must be exactly `(Self, inout Issues<Self>)`. Anything else gets a
diagnostic naming the shape it expected.

## Machine-readable codes

`issues.add("…")` uses the message as the code, which is right for a one-off. When
something downstream needs to branch on it:

```swift
issues.add(code: "password_is_email", "must not be your email address", at: \.password)
```

Now `issue.code == .custom("password_is_email")` and the message is still there for
humans. Same for translation: match the code, render your own words.

## Asking something slow

```swift
@Schema
struct Signup {
    var username: String

    @AsyncCheck
    static func available(_ s: Signup, _ issues: inout Issues<Signup>) async {
        if await db.userExists(s.username) {
            issues.add("is already taken", at: \.username)
        }
    }
}
```

One `@AsyncCheck` anywhere in the type makes `parse` and `diagnose` async **for that type**,
decided by counting attributes at compile time. A type without one stays synchronous, so
you never `await` a schema that has nothing to await.

Three things happen in a fixed order, and the order is the useful part:

1. Everything synchronous runs first and collects **all** of its issues.
2. Async checks run **only if the sync pass was clean.** Spending a database round trip to
   ask about a username you already know is 200 characters long is waste.
3. When they do run, they all run **concurrently**.

```swift
let user = try await Signup.parse(json: data)
```

## Where checks sit in the pipeline

```
preprocess → coerce → decode → field rules → cross-field checks → transform → async checks
```

Cross-field checks see the constructed value, so every field has already decoded and passed
its own rules. That is why a check can assume `start` and `end` are both `Int`s rather than
re-deriving it.

## Rules about checks

**A check must be declared inside the type.** In an extension it is permanently invisible to
the macro — a macro only sees the declaration it is attached to — so that is a compile
error with a message rather than a rule that silently never runs.

**A failing check means the row/value is not produced.** Like any other issue: `diagnose`
gives you `nil` for the value plus the issues, `parse` throws.

**Checks run on every path.** JSON, YAML, XML, TOML and `validate(_:)` on a value something
else produced.

## When to reach for what

| You want | Use |
|---|---|
| A bound, a format, a set | [`@Validate`](/guides/rules/) |
| A function over one field | `@Check(\T.field)` |
| A relationship between fields | `@Check` |
| Anything needing `await` | `@AsyncCheck` |
| To change the value, not judge it | [`@Transform`](/guides/advanced/#transform) |

## Next

- [Errors](/guides/errors/) — what an `Issue` is and the four ways to show one.
- [Advanced](/guides/advanced/) — `@Transform`, contexts, wrappers.
