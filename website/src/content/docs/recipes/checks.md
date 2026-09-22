---
title: Checks and transforms
description: Your own validation on one field or across several, and changing a field's type on the way in.
---

## One field, your own logic

```swift
@Schema(keys: .snakeCase)
struct Handle: Equatable {
    var username: String

    @Check(\Handle.username)
    static func notReserved(_ u: String) -> String? {
        ["admin", "root"].contains(u) ? "is reserved" : nil
    }
}
```

```json
{"username": "admin"}
```

```text
u.json:1:14: error: username is reserved
  1 │ {"username": "admin"}
    │              ^^^^^^^

1 error
```

Return `nil` to pass, a message to fail. The key path root is required — `\.username` has
never compiled, because an attached macro's argument has no type to infer it from.

There is no `.custom { }` rule for the same reason: a closure in an attribute has no type
context.

## Across fields

```swift
@Schema(keys: .snakeCase)
struct Window: Equatable {
    var start: Int
    var end: Int

    @Check
    static func ordered(_ r: Window, _ issues: inout Issues<Window>) {
        if r.end < r.start { issues.add("must be on or after start", at: \.end) }
    }
}
```

```json
{"start": 10, "end": 3}
```

```text
r.json: error: end must be on or after start

1 error
```

The whole value, after every field has decoded and passed its own rules. `at:` puts the
issue on the field a person should look at, which is what makes it show up next to the
right input in a form.

`issues.add(code:_:at:)` takes your own code when you want to branch on it later.

## Change the type after decoding

```swift
@Schema(keys: .snakeCase, encodes: true)
struct Timeouts: Equatable {
    @Transform({ (a: [String]) in Set(a) })
    @Inverse({ (s: Set<String>) in s.sorted() })
    var tags: Set<String>

    @Transform({ (ms: Int) in Double(ms) / 1000.0 })
    @Inverse({ (s: Double) in Int(s * 1000) })
    var timeoutSeconds: Double
}
```

```json
{"tags": ["b", "a", "b"], "timeout_seconds": 1500}
```

```text
Timeouts(tags: Set(["b", "a"]), timeoutSeconds: 1.5)
```

The closure's **parameter** type is what gets decoded; the field keeps its own type. That
is how `Set` becomes a legal field even though the macro refuses it directly, and how a
wire value in milliseconds becomes seconds without a second property.

Transforms run last, after rules and checks.

## Transforms and encoding

`@Inverse` is required once the type encodes, and the build fails naming the signature if
it is missing. Otherwise a round trip would silently write something different:

```json
{"tags": ["b", "a", "b"], "timeout_seconds": 1500}
```

```text
{"tags":["a","b"],"timeout_seconds":1500}
```

Out again as a sorted array and milliseconds. This is the round-trip law doing its job.

## Slow checks

```swift
@AsyncCheck
static func usernameIsFree(_ s: Handle, _ issues: inout Issues<Handle>) async { … }
```

One of these makes `parse` async **for that type**, by a compile-time count. The sync pass
runs first and collects everything; the async checks run only if it was clean, and then
concurrently. There is no point asking a database whether a username is taken when the
username is four characters too short.

## Next

- [Dates](/recipes/dates/) — the other thing that needs more than a rule.
- [Checks, explained](/guides/checks/) — the pipeline order, in full.
