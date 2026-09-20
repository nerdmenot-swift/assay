---
title: Encoding
description: The same struct out to JSON, YAML, TOML and XML, what round-trip guarantees, what can fail, and a JSON Schema from the same declaration.
---

## One switch, four writers

```swift
@Schema(keys: .snakeCase, formats: .all, encodes: true, describes: true)
struct Build: Equatable {
    @Validate(.min(1), .max(40)) var name: String
    @Validate(.range(1...99)) var version: Int
    var stable: Bool
    var notes: String?
    @Validate(.count(1...5)) var tags: [String]
}
```

`encodes: true` adds a writer for every format in `formats:`.

JSON:

```swift
Build(name: "api", version: 2, stable: true, notes: nil, tags: ["a", "b"])
```

```text
{"name":"api","version":2,"stable":true,"notes":null,"tags":["a","b"]}
```

YAML:

```text
name: api
version: 2
stable: true
notes: null
tags:
  - a
  - b
```

TOML:

```text
name = "api"
version = 2
stable = true
tags = ["a", "b"]
```

XML:

```text
<?xml version="1.0" encoding="UTF-8"?><Build><name>api</name><version>2</version><stable>true</stable><tags>a</tags><tags>b</tags></Build>
```

`jsonText()`, `yamlText()`, `tomlText()` and `xmlText()` give you a `String`;
`encodedJSON()` and friends give you `EncodedBytes`, which owns the buffer the writer wrote
and hands it over without copying it. Use `withUnsafeBytes` to write it somewhere, `text()`
for a `String`, or `toArray()` when you need a plain `[UInt8]` and can pay for the copy. All
throw.

Note `notes` is absent from every output rather than written as null. TOML has no null at
all, so omitting a nil optional is the only spelling that works everywhere.

## Round-trip is a law, with a closed exception list

```text
encode, then decode, then compare
```

```text
true
```

> For any `v` produced by `parse`, `parse(encode(v))` produces a value equal to `v` —
> except in four listed cases.

Stating it as a law with a **closed** list of exceptions is the point. It turns round-trip
from a property nobody tests into one with a test suite and four documented holes: a
`@Fallback` that fired, an `@Unknown` case captured without `roundTrips: true`, XML
placement that cannot be expressed, and two untagged union variants that accept the same
document.

## What can fail on the way out

Encoding does not re-run your rules. It reports what cannot be **written**.

```swift
Unwritable(label: "x", ratio: inf)
```

```text
bytes written: 26
issues:
  ratio: cannot be represented in JSON (Infinity)
```

`nan` and infinity have no JSON spelling. TOML has no null, so any null that is not an
omitted optional is reported. An `@Extras` key can collide with a declared one.

`diagnoseEncodeJSON()` is the non-throwing form and hands back what it managed to write
alongside the issues.

## A JSON Schema from the same declaration

`describes: true` adds `jsonSchema(for:)`:

```swift
Build.jsonSchema(for: .input).text()
```

```text
{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "Build",
    "type": "object",
    "properties": {
      "name": {
        "type": "string",
        "minLength": 1,
        "maxLength": 40
      },
      "version": {
        "type": "integer",
        "minimum": 1,
        "maximum": 99
      },
      "stable": {
        "type": "boolean"
      },
      "notes": {
        "type": [
          "string",
          "null"
        ]
      },
      "tags": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "minItems": 1,
        "maxItems": 5
      }
    },
    "required": [
      "name",
      "version",
      "stable",
      "tags"
    ]
  }
```

One renderer law, and it is worth knowing before you rely on the output: **describe more
than the type accepts, never less.** A rule with no exact 2020-12 keyword becomes
`description` prose rather than an approximate `pattern`, because a schema that rejects a
document the decoder would have accepted is worse than a vague one.

`@Key(path:)` and `@XML` placement are refused at expansion rather than described wrongly.

## Next

- [Encoding, explained](/guides/encoding/) — the six semantics questions and their answers.
