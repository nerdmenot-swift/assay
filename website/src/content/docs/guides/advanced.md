---
title: Advanced
description: Transforms, wrappers, contexts, runtime schemas, and the types the macro refuses on purpose.
---

Things you will not need on day one, in roughly the order people reach for them.

## Transform

Decode one type, keep another:

```swift
@Transform({ (s: String) in URL(string: s) })
@Inverse({ (u: URL) in u.absoluteString })
var link: URL?
```

The wire type comes from the closure's parameter; the field's type is what you declared.
Transform runs **last** in the pipeline — after decoding and after rules — so the rules see
the wire value. A `nil` result is an issue on that field.

`@Inverse` is only needed with `encodes: true`, and its absence there is a build error
rather than a silently missing round trip.

## Coerce

```swift
@Schema(coerceScalars: true)     // whole type
@Coerce var port: Int            // one field
```

`"8080"` decodes into an `Int`. The rules are written down and boring: `"8080.5"` is not an
integer, `"true"`/`"yes"`/`"on"`/`"1"` are `true`. XML needs this (every leaf is text) and
CSV usually does.

## One or many

APIs that send a scalar when there is one item and an array when there are several:

```swift
@OneOrMany var tags: [String]      // accepts "swift" and ["swift", "ios"]
```

An honest asymmetry, stated rather than hidden: this attribute governs the **JSON** path,
where the choice is genuine. The `RawValue` path (YAML, XML, TOML) is already tolerant and
cannot be made strict — XML spells a sequence as repeated siblings, which is
indistinguishable from a scalar at that layer.

## Wrapping a scalar

A type that *is* a constrained string or number:

```swift
@Wraps(String.self, .min(3), .isLowercase)
struct Handle { let value: String }

@Schema
struct Profile { var handle: Handle }
```

A `Handle` field and `@Validate(.min(3), .isLowercase) var handle: String` produce
**identical issues** — that equivalence is the feature. The wrapped type must be `String`,
`Int64`, `Double` or `Bool`, because a macro sees a token.

## Contexts

When decoding needs something from outside the document — a tenant, a base URL, a feature
flag:

```swift
@Schema(context: AppContext.self)
struct Link {
    var path: String
    @Check
    static func allowed(_ l: Link, _ i: inout Issues<Link>, context: AppContext) {
        if !context.allowedPaths.contains(l.path) { i.add("is not permitted", at: \.path) }
    }
}

let link = try Link.parse(json: data, context: ctx)
```

A contextual type conforms to a *different* protocol, so `parse(json:)` without a context
**does not exist** for it. "You cannot forget to pass it" is the type system here, not
advice. The context-free expansion is byte-identical, so nothing costs anything when you do
not use one.

## Schemas with no declaration

When the shape is known at runtime — a form built from a database, a config schema shipped
by a server:

```swift
let schema = Assayer<User>(
    fields: [
        .field("id", .int),
        .field("email", .string, rules: [.email]),
    ],
    build: { User(id: $0["id"]!.int!, email: $0["email"]!.string!) }
)
let user = try schema.parse(json: data)
```

Same rules, same issues, same renderers as the macro path. It is also what `@Wraps` is
built on. Slower than the macro — there is a plan being interpreted rather than concrete
code — and that is the trade.

## Types the macro refuses

These are compile errors with a message naming the fix, rather than something that compiles
and behaves oddly.

| You wrote | Why not | Instead |
|---|---|---|
| `Set<T>` | a document carries an ordered array | `[T]`, or `@Transform({ (a: [T]) in Set(a) })` |
| `T?` inside `T??` | a document has one kind of absence | `T?` |
| `[T?]` | an array holds values or nulls | `[T]` (a null element is an error), or `[RawValue]` |
| a tuple | no wire format has one | a nested `@Schema` struct, or an array |
| a function type | not decodable | — |
| `Any` / `AnyObject` | nothing to decode into | `RawValue` |
| `T!` | an absent key must be nil or an error | `T?` |
| `Character` | not a field type | `String` |
| `Data` | documents carry bytes as text | `String` + `@Transform`, or `[UInt8]` |
| `URL` | — | `@Validate(.url) var …: String`, construct where you use it |
| `Decimal` | JSON numbers are doubles; a decimal should travel as a string | `String` + `@Transform` |
| a generic struct | a macro cannot specialise | a concrete type per instantiation |

`UUID` **is** a field type, with `AssayFoundation` imported — that product supplies the
conformance.

## Enums

A closed set of strings or integers needs no macro at all:

```swift
enum Status: String, Codable { case active, archived }
```

`RawRepresentable` with a `String` or `Int` raw value already decodes. Add `CaseIterable`
and the error lists the valid values. `@Schema` on an enum is for
[unions](/guides/unions/) and `@Unknown` open enums.

## Validating without decoding

```swift
try User.validate(user)          // throws with everything
User.diagnose(user)              // never throws
```

The schema's rules against a value something else produced. This is the seam for a fast
custom reader: decode at your own speed in your own module, then let Assay run the rules.
About 79 ns per value.

## Describing the shape

```swift
@Schema(describes: true) struct Article { … }
Article.jsonSchema(for: .input)
```

A JSON Schema 2020-12 descriptor. `.input` describes what `parse` accepts, `.output` what
the value looks like after transforms — genuinely different once transforms exist, which is
a correction Zod shipped in v4.

## Two things that are not here

**Streaming.** Decoding a document larger than memory, incrementally. It is out of scope,
and the reasoning is written down rather than left as a gap — the short version is that a
`@Schema` type is a fixed-size struct and a partially-decoded one is not a thing that
exists. `parse(mmapped:)` covers the "large file" case that people usually mean.

**`StandardSchema`.** The cross-library validation interface. The blocker is a repository
rather than a design: "Assay conforms to it" and "Assay does not depend on it" cannot both
hold in one package, so it needs a third adapter package.

## Next

- [Attributes](/reference/attributes/) — all of them, one table.
- [Design notes](/reference/design-notes/) — why any of this is the way it is.
