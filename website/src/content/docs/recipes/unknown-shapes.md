---
title: Unknown shapes
description: Walking a document you cannot declare, and giving a schema to a type that has no declaration to attach one to.
---

## When you do not know the shape

```swift
let v = try JSON.Value.parse(bytes)
```

```json
{"kind": "batch", "items": [{"id": 1}, {"id": 2}], "meta": null}
```

```text
v["kind"]?.string            -> batch
v["items"]?[1]?["id"]?.int  -> 2
v["items"]?.array?.count    -> 2
v["nope"]                   -> nil
```

Subscripts are optional-chaining all the way down, so a wrong guess at any level is `nil`
rather than a trap. Object members keep their order and their duplicates.

Every format has one, and they are deliberately **not** unified behind a single type: a
YAML scalar's resolution and an XML element's namespace are not the same kind of thing.

| | keeps |
|---|---|
| `JSON.Value` | order, duplicate keys, int/double distinct |
| [`YAML.Node`](/formats/yaml/#when-you-do-not-know-the-shape) | quoting style, tags, anchors, unresolved scalars |
| [`XML.Document`](/formats/xml/#when-you-do-not-know-the-shape) | namespaces, attributes, comments, mixed-content order |
| [`TOML.Node`](/formats/toml/#when-you-do-not-know-the-shape) | which of the four date-time kinds |
| `RawValue` | the portable intersection every non-JSON format decodes through |

One honest note: this is not the fast path. Building a tree has no `Codable` boundary to
delete, so the argument that makes `@Schema` fast does not apply here.
[Performance](/reference/performance/) has the numbers.

## A schema with no declaration to attach a macro to

Sometimes the type is not yours to annotate, or it is a constrained scalar rather than a
struct with fields.

```swift
struct Ticket: Equatable, Sendable { var raw: String }

extension Ticket: AssayerBacked {
    nonisolated static let assaySchema =
        Assayer.string.validate(.prefix("TCK-"), .length(9)).map(Ticket.init(raw:))
}

@Schema(keys: .snakeCase) struct Booking: Equatable { var ticket: Ticket }
```

```json
{"ticket": "TCK-00042"}
```

```text
Booking(ticket: Ticket(raw: "TCK-00042"))
```

And when it does not match:

```json
{"ticket": "XX-1"}
```

```text
t.json: error: ticket must start with "TCK-"

t.json: error: ticket must be exactly 9 characters

2 errors
```

Same codes, same paths, same renderer as any other field. A conforming type is already a
nested schema type as far as the macro is concerned — the macro needed no change to support
this, which is the design's whole claim.

`map` is failable on purpose, so a conversion that refuses a value the rules accepted is
reported rather than swallowed.

For the common case of a wrapper with rules, [`@Wraps`](/recipes/enums/#a-struct-that-is-really-a-scalar)
is sugar over exactly this.

## Passing something in at decode time

```swift
@Schema(context: AppContext.self)
struct Document { … }

try Document.parse(json: bytes, context: ctx)
```

A contextual type conforms to `ContextualJSONAssayable` and **not** `JSONAssayable`, so
`parse(json:)` without a context does not exist for it. "You cannot forget to pass it" is
the type system rather than advice.

## Next

- [Rows and columns](/recipes/rows/) — shapes that are not documents at all.
- [Advanced](/guides/advanced/) — the reasoning behind all three.
