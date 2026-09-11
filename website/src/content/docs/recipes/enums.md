---
title: Enums
description: Closed sets that need no macro, open ones that survive a new case, a field that is sometimes one and sometimes many, and turning a struct into a constrained scalar.
---

## A closed set

```swift
enum Colour: String, JSONAssayable, RawDecodable, CaseIterable { case red, green, blue }
enum Priority: Int, JSONAssayable, RawDecodable { case low = 1, high = 2 }

@Schema(keys: .snakeCase, formats: .all)
struct Label: Equatable { var colour: Colour; var priority: Priority }
```

YAML here, because a closed vocabulary is usually something a person types by hand.
`RawDecodable` is the conformance that makes these work outside JSON; drop it and
`parse(yaml:)` will not compile for a type with an enum field.

```yaml
colour: green
priority: 2
```

```text
Label(colour: Colour.green, priority: Priority.high)
```

No macro on the enum. Declare the conformance and the implementation comes from a protocol
extension, for any `RawRepresentable` with a `String` or `Int` raw value. Add
`RawDecodable` as well if the type decodes from YAML, XML, TOML or a plist.

`CaseIterable` is optional and pays for itself:

```yaml
colour: chartreuse
priority: 9
```

```text
e.yaml: error: colour "chartreuse" is not a recognised value; must be one of "red", "green", "blue"

e.yaml: error: priority "9" is not a recognised value

2 errors
```

The first field lists what it would have accepted; the second, without `CaseIterable`,
cannot.

## A set that will grow

```swift
@Schema(formats: .all) enum Plan: Equatable {
    case free, pro
    @Unknown case other(String)
}

@Schema(keys: .snakeCase, formats: .all) struct Membership: Equatable { var plan: Plan }
```

```yaml
plan: enterprise
```

```text
Membership(plan: Plan.other("enterprise"))
```

The raw value is kept, so you can branch on the cases you know, treat the rest as a
default, and log what is actually arriving. Without this, one new value upstream is a
decode failure for every record that has it.

Encoding refuses to write an unrecognised variant unless you opt in with
`@Unknown(roundTrips: true)` — writing back a value you did not understand is a decision,
not a default.

## Sometimes one, sometimes many

```swift
@Schema(keys: .snakeCase, formats: .all)
struct Post: Equatable { @OneOrMany var tags: [String] }
```

```json
{"tags": "swift"}
```

```text
(Post(tags: ["swift"]), Post(tags: ["swift", "json"]))
```

Both documents decode. The attribute lands on the JSON path, where the choice is genuine.
On the other formats the tolerance is already there and cannot be removed: XML spells a
sequence as repeated sibling elements, which is indistinguishable from a single scalar at
that layer.

## A struct that is really a scalar

```swift
@Wraps(String.self, .email) struct EmailAddress {}
@Wraps(Int64.self, .range(1...100)) struct Percent {}

@Schema(keys: .snakeCase, formats: .all)
struct Contact: Equatable { var contact: EmailAddress; var complete: Percent }
```

```yaml
contact: not-an-email
complete: 150
```

```text
w.yaml: error: contact must be a valid email address

w.yaml: error: complete must be between 1 and 100

2 errors
```

A wrapper gives you a type the compiler can keep apart from every other `String`, with the
validation attached to the type rather than repeated at each use site.

The issues are **byte-identical** to `@Validate(.email)` on a plain `String` — same code,
same path, same parameters. That equivalence is the feature: a wrapper is not a second
validation mechanism wearing the first one's vocabulary.

The wrapped type is `String`, `Int64`, `Double` or `Bool`, because a macro sees a token and
not a type.

## Next

- [Unions](/recipes/unions/) — when the variants carry different payloads.
- [Advanced](/guides/advanced/) — wrapping, contexts, and runtime schemas.
