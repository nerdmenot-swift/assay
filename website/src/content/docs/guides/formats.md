---
title: Formats
description: One struct, five formats — and the honest list of what each one costs you.
---

Formats are opt-in per type:

```swift
@Schema(formats: [.json, .yaml, .toml])
struct Config {
    var name: String
    var replicas: Int
}
```

`.all` is JSON, YAML, XML and TOML. The default is `.json` alone.

This is opt-in for a real reason: generated code is not free. A YAML/XML decode body costs
about 34 ms per type at build time, roughly 41% of the expansion — and a type that only
ever sees JSON should not pay for a capability it never calls. Calling `parse(yaml:)` on a
type that did not list `.yaml` is a **compile** error, because the conformance that entry
point needs simply is not there.

## The parsers

| Format | Product | Notes |
|---|---|---|
| JSON | `Assay` | RFC 8259. Decodes straight from bytes into your struct — the fast path |
| YAML 1.2 | `AssayYAML` | Hand-written. Block and flow, anchors, aliases, multi-document |
| XML 1.0 | `AssayXML` | Hand-written. Namespaces, CDATA, mixed content. XXE refused by construction |
| TOML 1.0.0 | `AssayTOML` | Hand-written. Passes all 710 documents of the official `toml-test` suite |
| plist | `AssayPlist` | Both flavours behind one entry point, discriminated by magic bytes |

All hand-written, all pure Swift. No libyaml, no libxml2, nothing to vendor — which is why
the same code runs on macOS, Linux and Windows and why the carets work everywhere.

## How the non-JSON formats decode

JSON decodes directly from bytes into your struct. Everything else parses to its own value
model first, then decodes through a shared projection called `RawValue`:

```
bytes → YAML.Node / XML.Node / TOML.Node → RawValue → your struct
```

Two consequences worth knowing. The tree path is slower than the JSON path — it is
building a tree first. And your rules, checks, keys and presence states are all identical
across formats, because they run on the far side of the projection.

## XML needs coercion

Every leaf in an XML document is text. There are no numbers and no booleans in the format,
so a struct decoding from it has to say that scalars may be coerced:

```swift
@Schema(coerceScalars: true, formats: [.xml])
struct Config {
    var name: String
    var replicas: Int         // "3" → 3
    var enabled: Bool         // "true" → true
}
```

This is per type or per field (`@Coerce`), and it is opt-in rather than automatic because
`"8080"` decoding into an `Int` should be a decision you made, not one made for you.

### Placement

XML has attributes as well as elements, and the two are different things:

```swift
@Schema(coerceScalars: true, formats: [.xml])
struct Item {
    @XML(.attribute) var id: Int          // <item id="7">
    @XML(.text) var body: String          // the element's own character data
    @XML(.wrapped) var tags: [String]     // <tags><tags>a</tags></tags>
    var name: String                      // a child element, the default
}
```

An unannotated field is a child element. That is the safe default: an attribute cannot
nest, cannot repeat, and has its whitespace normalised, so anything expressible as an
attribute is expressible as an element and not the other way round.

`@XML(root: "config")` checks the root element's name. Without it the root is not checked
at all, because it is very often an unmodelled wrapper somebody else chose.

## YAML keeps its ambiguity yours

YAML's famous problem is that `NO` is a boolean in some parsers and the country code for
Norway in yours. Assay's parser does not resolve plain scalars at all — a scalar keeps its
text, style, tag and anchor until something asks a typed question:

```swift
var country: String    // "NO" is the string "NO"
var enabled: Bool      // "NO" is false
```

Your declaration is the question. The parser does not guess ahead of it.

Multi-document streams:

```swift
let configs = try Config.parseAll(yaml: text)
```

## TOML is typed on the wire

The opposite of YAML: in TOML, `1` is an integer, `"1"` is a string and `1979-05-27` is a
date, by the grammar. There is nothing to resolve.

TOML has four date-time kinds and `RawValue` has none, so they arrive as RFC 3339 strings —
which is exactly what a `Date` field parses:

```swift
@Schema(formats: [.toml])
struct Entry {
    var when: Date              // 1979-05-27T07:32:00Z
    var day: Date               // 1979-05-27, with a @DateFormat
}
```

## Property lists

```swift
try Settings.parse(plist: bytes)          // either flavour
try Settings.parse(binaryPlist: bytes)    // require binary
try Settings.parse(xmlPlist: bytes)       // require XML
```

The combined entry point discriminates on the exact `bplist00` magic. That is not content
sniffing — you already said "this is a plist"; binary and XML are two encodings of it.

The XML flavour reuses the XXE-refusing XML parser, which matters: every XML plist carries
a `SYSTEM` DOCTYPE pointing at apple.com, and a reader that resolved it would be the
textbook XXE.

## Serving HTTP

When the format comes from a `Content-Type` header:

```swift
let config = try Config.parse(
    body: bytes,
    contentType: request.headers["content-type"],
    accepting: [.json, .yaml]
)
```

`accepting:` is required and has **no default**. That is deliberate: it means a
billion-laughs XML body offered to a JSON-only endpoint produces one negotiation issue and
never enters an XML parser. A server has to opt in to parsing XML at all.

RFC 9110 and 6839 rules apply, so `application/vnd.thing+yaml` matches YAML. The charset
parameter is checked and never transcoded, and there is no sniffing — ever. An unacceptable
type reports `unsupported_media_type`, its own code, so you can map it to a 415.

## When you do not know the shape

Every format has a value model you can traverse by hand:

```swift
let v = try JSON.Value.parse(bytes)
v["user"]?["tags"]?[0]?.string

let n = try YAML.parse(text)        // + .resolvedInt, .tag, .anchor, .style
let x = try XML.parse(bytes)        // .root, attributes, mixed content
let t = try TOML.parse(text)        // + .dateTime, which of the four kinds
```

They are deliberately *not* unified behind one type: a YAML scalar's resolution and an XML
element's namespace are not the same kind of thing, and pretending otherwise loses
information. `RawValue` is the narrow intersection for when you want portability more than
fidelity.

One honest note: the value-model path is where Assay's speed argument does not apply.
Building a tree has no Codable boundary to delete — `JSON.Value` measures about 1.5×
`JSONSerialization`, and loses badly to a C DOM parser. It is there for the cases where you
genuinely do not know the shape. When you do, `@Schema` is the fast path.

## Large files

```swift
import AssayFoundation
let big = try Report.parse(mmapped: url)
```

Maps the file and decodes in place rather than reading it into `Data` first. On a large
document that is a fraction of the memory and meaningfully faster.

## Next

- [Dates](/guides/dates/) — formats, candidate chains, and why there is no `.past`.
- [Encoding](/guides/encoding/) — the same formats, in reverse.
