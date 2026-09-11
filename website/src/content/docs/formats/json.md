---
title: JSON
description: The fast path. Straight from bytes into your struct, with every failure pointing at the byte that caused it.
---

JSON is the one format Assay does not build a tree for. The macro writes decode code for
your type at compile time, and that code reads the bytes and fills your fields. Nothing in
between.

That is where the speed comes from, and it is the only format where the speed argument
applies at all. Everything else on this site parses to a value model first.

```swift
@Schema(keys: .snakeCase)
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var tags: [String] = []
}
```

No `formats:` argument needed. JSON is the default, and the only one you get for free.

```json
{"title": "On carets", "link": "https://example.com/carets", "reading_minutes": 4, "tags": ["errors"]}
```

```text
Article(title: "On carets", link: "https://example.com/carets", readingMinutes: 4, tags: ["errors"])
```

## Nesting, arrays, dictionaries

A nested `@Schema` type is just a field. So is an array of them, and so is a dictionary
with `String` keys.

```swift
@Schema(keys: .snakeCase) struct Server { var host: String; var port: Int; var tls: Bool = true }

@Schema(keys: .snakeCase)
struct Cluster {
    var name: String
    var servers: [Server]
    var labels: [String: String] = [:]
}
```

```json
{
  "name": "eu-prod",
  "servers": [
    {"host": "a.internal", "port": 8080},
    {"host": "b.internal", "port": 8081, "tls": false}
  ],
  "labels": {"tier": "prod", "team": "platform"}
}
```

```text
Cluster(name: "eu-prod", servers: [extract.Server(host: "a.internal", port: 8080, tls: true), extract.Server(host: "b.internal", port: 8081, tls: false)], labels: ["tier": "prod", "team": "platform"])
```

Note `tls` on the first server. It is absent in the document and `true` in the result,
because the declaration said so. See [presence](/guides/presence/) for the five states and
what each one means.

## Numbers are checked, not coerced

JSON distinguishes `1` from `1.5` from `"1"`, so Assay does too. A `Double` field accepts
an integer literal, because every JSON integer is a valid number. Nothing else widens.

```swift
@Schema struct Metrics { var count: Int32; var ratio: Double; var enabled: Bool }
```

```json
{"count": 1.5, "ratio": "half", "enabled": "yes"}
```

```text
metrics.json:1:11: error: count must be an integer, found 1.5
  1 │ {"count": 1.5, "ratio": "half", "enabled": "yes"}
    │           ^

metrics.json:1:25: error: ratio must be a number, found "half"
  1 │ {"count": 1.5, "ratio": "half", "enabled": "yes"}
    │                         ^

metrics.json:1:44: error: enabled must be a boolean, found "yes"
  1 │ {"count": 1.5, "ratio": "half", "enabled": "yes"}
    │                                            ^

3 errors
```

Three mistakes, three carets, one pass. The third is the interesting one: `"yes"` is a
string, and a string is not a boolean, so it is an error rather than a quiet `true`.

Overflow is checked against the *declared* width, not against `Int64`:

```json
{"count": 99999999999, "ratio": 0.5, "enabled": true}
```

```text
metrics.json:1:22: error: count must be an integer
  1 │ {"count": 99999999999, "ratio": 0.5, "enabled": true}
    │                      ^

1 error
```

`count` is an `Int32`. The value fits in an `Int64` comfortably and the document is
perfectly well-formed, so this is a schema error rather than a parse error.

If you want `"8080"` to decode into an `Int`, that is
[`coerceScalars`](/formats/xml/#coercion-is-opt-in) and it is opt-in per type or per field.

## Duplicate keys

RFC 8259 leaves duplicates undefined. Assay takes the last one:

```json
{"title": "first", "title": "second", "link": "l", "reading_minutes": 1}
```

```text
Article(title: "second", link: "l", readingMinutes: 1, tags: [])
```

The value model is the other answer. `JSON.Value` keeps every member in document order,
duplicates included, because throwing one away silently is worse than handing you both.

## When the document itself is broken

Parse errors come from the parser and read differently from schema errors. They still
carry a caret.

A trailing comma, which is the one everybody hits:

```json
{"title": "x", "link": "y", "reading_minutes": 1,}
```

```text
bad.json:1:50: error: is not a well-formed document
  1 │ {"title": "x", "link": "y", "reading_minutes": 1,}
    │                                                  ^

bad.json:1:50: error: unexpected content after the end of the document
  1 │ {"title": "x", "link": "y", "reading_minutes": 1,}
    │                                                  ^

2 errors
```

An unquoted key, which is JavaScript and not JSON:

```json
{title: "x"}
```

```text
bad.json:1:2: error: is not a well-formed document
  1 │ {title: "x"}
    │  ^

bad.json:1:2: error: unexpected content after the end of the document
  1 │ {title: "x"}
    │  ^

2 errors
```

A truncated document, where there is no byte to point at because the bytes ran out:

```json
{"title": "x", "link":
```

```text
bad.json: error: link must be a string

bad.json: error: is not a well-formed document

2 errors
```

That last render is worth reading twice. The schema reports what it was missing *and* the
parser reports that the document never ended, because both are true and you would want to
know both.

## Unknown keys

By default they are ignored, which is what you want for an API that adds fields without
telling you. Three other policies exist:

```swift
@Schema(unknownKeys: .warn)      // decode, but say so
@Schema(unknownKeys: .reject)    // an error, with a did-you-mean
@Schema(unknownKeys: .collect)   // into an @Extras dictionary
```

`.reject` and `.warn` both run a Damerau edit-distance check against the keys the schema
knows, so a typo gets named rather than merely counted. [Keys](/guides/keys/) has the
whole story, including aliases and paths.

## Large documents

```swift
import AssayFoundation
let report = try Report.parse(mmapped: url)
```

Maps the file and decodes in place rather than reading it into `Data` first. On a large
document that is a fraction of the memory footprint and meaningfully faster. Throughput
stays flat into the multi-megabyte range.

## When you do not know the shape

`JSON.Value` is the hand-walkable model. Ordered members, duplicates preserved, integers
and doubles kept distinct.

```json
{"kind": "batch", "items": [{"id": 1}, {"id": 2}], "meta": null}
```

```text
v["kind"]?.string              → batch
v["items"]?[1]?["id"]?.int    → 2
v["meta"]                     → null
v["items"]?.array?.count      → 2
v["absent"]                   → nil
```

Subscripts are optional-chaining all the way down, so a wrong guess at any level gives you
`nil` rather than a trap.

One honest note, because it is the opposite of the rest of this page: **the value model is
not the fast path.** Building a tree has no Codable boundary to delete, so the argument
that makes `@Schema` fast does not apply. It measures about 3× `JSONSerialization` and
loses badly to a C DOM parser. [Performance](/reference/performance/) has the numbers and
the reasoning. When you know the shape, declare it.

## Next

- [YAML](/formats/yaml/) — the same struct, a format that will not guess for you.
- [Errors](/guides/errors/) — codes, paths, spans, and the four renderers.
- [Rows and columns](/formats/rows-and-columns/) — the same struct, from a database.
