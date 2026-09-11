---
title: Presence
description: Five states, one declaration each. Required, optional, defaulted, salvaged, ignored — and the difference between null and absent.
---

These examples are YAML, because a config file is where "what does absent mean" is a
question people actually have. The declaration is the same whatever the format is — swap
`parse(yaml:)` for `parse(json:)` and nothing else changes.

## The five states

```swift
@Schema(keys: .snakeCase, formats: .all)
struct Presence: Equatable {
    var required: String                      // absent → an error
    var optional: String?                     // absent → nil
    var defaulted: Int = 3                    // absent → 3, still validated
    @Fallback(0) var salvaged: Int            // absent OR invalid → 0, with a warning
    @Ignore var notAField: String? = nil      // never read from the document
}
```

Everything present:

```yaml
required: here
optional: also here
defaulted: 9
salvaged: 5
```

```text
Presence(required: "here", optional: Optional("also here"), defaulted: 9, salvaged: 5, notAField: nil)
```

Everything optional absent:

```yaml
required: here
```

```text
Presence(required: "here", optional: nil, defaulted: 3, salvaged: 0, notAField: nil)

warnings: fallback_applied
```

`defaulted` became `3` and `salvaged` became `0`. Note the warning: a fallback that fires
always says so, because silently substituting a value is how data problems hide.

## Defaulted versus salvaged

The difference is what happens when the key is **present and wrong**.

```yaml
required: here
salvaged: not a number
```

```text
Presence(required: "here", optional: nil, defaulted: 3, salvaged: 0, notAField: nil)

warnings: fallback_applied
```

`@Fallback` took the value and recorded it. A `= 0` default would have reported an error
instead, because a default answers "absent", not "invalid".

Choose by whether a wrong value is survivable. For a score you display, yes. For a price
you charge, no.

## Null is not absent

```yaml
a: null
c: null
```

```text
n.yaml: error: c must be an array, found null

1 error
```

`null` for an optional is `nil` — the document said so explicitly and that is the same
answer. `null` for an array with a default is an **error**, because `null` is not a list,
and a default answers absence rather than a wrong type.

## Two spellings that will not compile

```swift
var x = 3               // no type annotation — the macro cannot see the type
let y: Int = 3          // `let` with a value — nothing could ever assign it
```

Both are hard errors with a message naming the fix. They look like defaults and are not.

## Next

- [Names](/recipes/names/) — keys, aliases, paths.
- [Presence, explained](/guides/presence/) — why five and not three.
