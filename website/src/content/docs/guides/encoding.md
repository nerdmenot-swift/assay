---
title: Encoding
description: The pipeline run backwards, with round-trip as a stated law and a closed list of exceptions.
---

Encoding is opt-in, for the same reason formats are — generated code is not free:

```swift
@Schema(encodes: true)
struct Article {
    var title: String
    var readingMinutes: Int
}

let bytes = try article.encodedJSON()   // EncodedBytes: an owned buffer, not a copy
let text  = try article.jsonText()     // String
```

`EncodedBytes` owns the buffer the writer filled. You get it handed over, not copied:

```swift
try article.encodedJSON().withUnsafeBytes { try socket.write($0) }   // no copy
let array = try article.encodedJSON().toArray()                      // one copy, you asked
let string = try article.encodedJSON().text()                        // UTF-8, no repair
```

That is why it is `~Copyable`. It frees the buffer exactly once. So you cannot store it
twice, put it in an array, or capture it in an escaping closure. Want any of those? Call
`toArray()` and pay for the copy where you can see it.

`EncodeDiagnosis.bytes` stays a plain `[UInt8]`, deliberately. That is the diagnostic path.
You store it, pass it around, show it to someone — one copy is a fair price for an ordinary
value.

Adding it costs about 5% of the type's compile time. The design note that justified making
it opt-in guessed it would roughly double the per-field code; the code does double, the
compile time does not follow it. The 5% is measured.

## Every format you decode from

```swift
@Schema(formats: .all, encodes: true)
struct Config { … }

try config.encodedJSON()    // and jsonText()
try config.encodedYAML()    // and yamlText()
try config.encodedXML()     // and xmlText()
try config.encodedTOML()    // and tomlText()
```

Against Foundation's `Encodable` + `JSONEncoder`, JSON encoding measures about 8.75× at 50
items and 9.04× at 200. That
is a measurement, not a thesis — the decode multiple has an argument behind it (deleting the
Codable container boundary) and this one does not. It is there so the cost is known and a
regression is visible.

## Errors on the way out

Encoding can fail. `nan` has no JSON spelling, TOML has no null, an `@Extras` key can
collide with a declared one. Same two verbs:

```swift
let bytes = try value.encodedJSON()       // throws AssayError

let d = value.diagnoseEncodeJSON()        // never throws
d.bytes                                   // what it managed to write
d.issues                                  // what went wrong
d.warnings
```

## The round-trip law

> For any `v` produced by `parse`, `parse(encode(v))` produces a value equal to `v` —
> except in four cases, listed below.

Stating it as a law with a **closed** exception list is the point. It turns round-trip from
a property nobody tests into one with a test suite and three documented holes.

The exceptions:

1. **A `@Fallback` fired.** The value you have is the fallback, not what was in the
   document. Encoding writes the fallback.
2. **An `@Unknown` enum case was captured** without `roundTrips: true`. See below.
3. **Unknown keys were dropped** by any policy other than `.collect`. They are gone; the
   encoder cannot invent them.
4. **An untagged union has two variants whose types accept the same documents.** The macro
   refuses two cases carrying the same payload *token*, but two distinct `@Schema` types
   that happen to accept the same documents are indistinguishable to it. A
   [discriminated union](/guides/unions/) has no such exception — the tag names the branch.

## What gets written

**Defaults are written.** A field that defaulted encodes with its value, because the
encoder targets the document `parse` would accept, and that document has the key.

**`@Extras` are written back**, sorted by key so the output is stable. A collected key that
collides with a declared one is reported rather than silently duplicated.

**Optionals are written as explicit `null`** in JSON, YAML and XML — `nil` decoded from an
absent key or a null, and null round-trips both. TOML is the exception, below.

**`@Ignore` fields are not written.** They were never fields.

## Transforms need an inverse

If a field transforms on the way in, encoding needs to know how to go back:

```swift
@Transform({ (s: String) in URL(string: s) })
@Inverse({ (u: URL) in u.absoluteString })
var link: URL?
```

A transformed field with no `@Inverse` on an `encodes: true` type is refused when you build,
with a message saying so — rather than generating a body that cannot compile, or silently
writing the wrong type.

## Open enums

```swift
@Schema enum Status {
    case active, archived
    @Unknown case other(String)
}
```

By default, encoding an `.other("weird")` is refused: you decoded a value the type does not
model, and writing it back out as though it were understood is usually not what you want.
When it *is* what you want — a proxy that must not lose data:

```swift
@Unknown(roundTrips: true) case other(String)
```

Now it writes the captured string back, and exception 2 above no longer applies.

## Format-specific notes

**XML cannot use the shared projection.** Placement — attribute versus element versus text —
is not expressible in `RawValue`, so XML has its own generated writer. Decoding
`<user id="7"/>` and re-encoding gives you `<user><id>7</id></user>`: the same *value* in a
different *document*. That is in the law's exception list under document shape, not value
equality.

The defaults were chosen by surveying Jackson, Go's `encoding/xml`, .NET and serde: an
unannotated field is a child element, and a sequence is repeated siblings rather than a
wrapper element that invents a name (`<item>`) appearing nowhere in your schema.

**TOML has no null.** A nil member of a table is *omitted* — the reader sees an absent key,
which is what an optional decodes nil from, so the round trip holds. A nil anywhere else (an
array element, a dictionary value) has no spelling that reads back as nil and is reported
rather than silently substituted.

**YAML quoting is the whole difficulty**, and it is the Norway problem arriving from the
other side. A `String` holding `"123"`, `"true"`, `"no"` or `""` must be emitted quoted,
because a bare `123` is an integer to every YAML reader alive. So the rule is inverted from
a pretty-printer's: plain style only when the text provably cannot be read as anything else.
57 hazard cases and a differential against libyaml hold it there.

## Describing the shape

```swift
@Schema(describes: true)
struct Article { … }

let schema = Article.jsonSchema(for: .input)
```

Emits a JSON Schema 2020-12 descriptor. The renderer's law is **describe more than the type
accepts, never less** — a rule with no exact keyword becomes `description` prose rather than
an approximate `pattern` that would reject documents the type would take.

`@Key(path:)` and `@XML` placement are refused there rather than described wrongly.

## Next

- [Unions](/guides/unions/) — including the encoding exception above.
