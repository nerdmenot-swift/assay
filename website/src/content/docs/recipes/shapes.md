---
title: Shapes
description: Nested types, arrays, dictionaries, optionals, integer widths, byte arrays, and reading a nested type's fields from the same object.
---

## A nested type is just a field

```swift
@Schema(keys: .snakeCase) struct Point: Equatable { var x: Int; var y: Int }

@Schema(keys: .snakeCase)
struct Shape: Equatable {
    var name: String
    var origin: Point                       // nested
    var vertices: [Point]                   // an array of them
    var labels: [String: String] = [:]      // a String-keyed dictionary
    var parent: Point?                      // optional nested
}
```

```json
{
  "name": "triangle",
  "origin": {"x": 0, "y": 0},
  "vertices": [{"x": 1, "y": 0}, {"x": 0, "y": 1}],
  "labels": {"colour": "red"}
}
```

```text
Shape(name: "triangle", origin: Point(x: 0, y: 0), vertices: [Point(x: 1, y: 0), Point(x: 0, y: 1)], labels: ["colour": "red"], parent: nil)
```

No `CodingKeys`, no `init(from:)`, no conformance to write. The nested type carries its own
`@Schema` and that is all.

## Errors keep the path

```json
{"name": "t", "origin": {"x": 0}, "vertices": [{"x": 1, "y": 0}, {"x": "two", "y": 1}]}
```

```text
shape.json:1:72: error: vertices[1].x must be an integer, found "two"
  1 │ {"name": "t", "origin": {"x": 0}, "vertices": [{"x": 1, "y": 0}, {"x": "two", "y": 1}]}
    │                                                                        ^

shape.json: error: origin.y is required

2 errors
```

`vertices[1].x` is the path to the byte. Arrays carry their index, nested types carry their
key, and it composes to any depth.

## Integer widths and bytes

```swift
@Schema(keys: .snakeCase)
struct Widths: Equatable {
    var small: Int8
    var medium: UInt16
    var large: Int64
    var ratio: Float
    var payload: [UInt8]          // a byte array, not Data
}
```

```json
{"small": 127, "medium": 65535, "large": 9007199254740993, "ratio": 0.5, "payload": [1, 2, 255]}
```

```text
Widths(small: 127, medium: 65535, large: 9007199254740993, ratio: 0.5, payload: [1, 2, 255])
```

Every fixed-width integer type decodes, and the width is checked against the **declared**
type rather than against `Int64`:

```json
{"small": 128, "medium": 65536, "large": 1, "ratio": 0.5, "payload": []}
```

```text
widths.json:1:14: error: small must be an integer
  1 │ {"small": 128, "medium": 65536, "large": 1, "ratio": 0.5, "payload": []}
    │              ^

widths.json:1:31: error: medium must be an integer
  1 │ {"small": 128, "medium": 65536, "large": 1, "ratio": 0.5, "payload": []}
    │                               ^

2 errors
```

A well-formed number that does not fit is an overflow, not a type mismatch, and it says
which.

## Reading a nested type from the same object

Sometimes the wire is flat and your types are not.

```swift
@Schema(keys: .snakeCase)
struct Record: Equatable {
    @Schema(keys: .snakeCase) struct Audit: Equatable { var createdBy: String; var revision: Int }
    var id: Int
    @Inline var audit: Audit
}
```

```json
{"id": 7, "created_by": "jo", "revision": 3}
```

```text
Record(id: 7, audit: Record.Audit(createdBy: "jo", revision: 3))
```

`created_by` and `revision` sat at the top level and landed in `audit`. The type has to be
**nested inside** the one inlining it, which is how the macro can see both key sets and
refuse a collision at build time.

## What is refused

`Set<T>`, `T??`, `[T?]`, tuples, `Any`, `T!`, `Character`, `Data`, `URL`, `Decimal` and
generic types are build errors, each naming the alternative. A `Set` is
[a transform](/recipes/checks/#change-the-type-after-decoding); `Data` is `[UInt8]`.
[Advanced](/guides/advanced/#types-the-macro-refuses) has the table with reasons.

## Next

- [Presence](/recipes/presence/) — what absent means, per field.
- [Names](/recipes/names/) — when the wire key is not the property name.
