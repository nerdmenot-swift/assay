---
title: XML
description: Attributes, elements, text and wrapped arrays — plus the one thing XML forces you to say out loud, and XXE that is refused by construction.
---

```swift
import AssayXML

@Schema(keys: .snakeCase, coerceScalars: true, formats: [.xml])
struct XMLDeployment {
    @Validate(.min(1), .max(63)) var name: String
    var image: String
    @Validate(.min(1)) var replicas: Int
    var region: String = "eu-west-1"
    @Validate(.url) var healthCheck: String?
}

let deployment = try XMLDeployment.parse(xml: bytes)
```

Note `coerceScalars: true`. XML is the one format that makes you say it, and the reason is
the next section.

## XML has no types

Every leaf in an XML document is character data. There is no integer, no boolean, no null —
`<replicas>3</replicas>` is the three-character string `"3"` and the format has no opinion
beyond that.

So a struct with an `Int` field decoding from XML has to agree that text may become a
number. Here is the same shape **without** the flag:

```swift
@Schema(keys: .snakeCase, formats: .all)      // no coerceScalars
struct Deployment {
    @Validate(.min(1), .max(63)) var name: String
    var image: String
    @Validate(.min(1)) var replicas: Int
    var region: String = "eu-west-1"
    @Validate(.url) var healthCheck: String?
}
```

```xml
<deployment><name>api</name><image>img:1</image><replicas>3</replicas></deployment>
```

```text
deploy.xml:1:59: error: replicas must be an integer, found "3"
  1 │ <deployment><name>api</name><image>img:1</image><replicas>3</replicas></deployment>
    │                                                           ^

1 error
```

That error is correct, and it is the library refusing to guess. The identical document
through `XMLDeployment`, which differs only by the flag:

```text
XMLDeployment(name: "api", image: "img:1", replicas: 3, region: "eu-west-1", healthCheck: nil)
```

Those two types are used side by side for the rest of this page, so you can always tell
which behaviour is being shown by which name is in the output.

### Coercion is opt-in

`coerceScalars: true` is per type. `@Coerce` is the same thing per field, for when only one
field should be tolerant. The policy is identical on every format: `"3"` becomes `3`,
`"true"` becomes `true`, and `"8080.5"` does **not** become an integer.

**It is not inherited by nested types.** This one catches people, so here it is happening:

```xml
<cluster>
  <name>eu-prod</name>
  <servers><host>a.internal</host><port>8080</port></servers>
  <servers><host>b.internal</host><port>8081</port><tls>false</tls></servers>
</cluster>
```

```text
cluster.xml:3:41: error: servers[0].port must be an integer, found "8080"
  1 │ <cluster>
  2 │   <name>eu-prod</name>
  3 │   <servers><host>a.internal</host><port>8080</port></servers>
    │                                         ^^^^
  4 │   <servers><host>b.internal</host><port>8081</port><tls>false</tls></servers>

cluster.xml:4:41: error: servers[1].port must be an integer, found "8081"
  2 │   <name>eu-prod</name>
  3 │   <servers><host>a.internal</host><port>8080</port></servers>
  4 │   <servers><host>b.internal</host><port>8081</port><tls>false</tls></servers>
    │                                         ^^^^
  5 │ </cluster>

cluster.xml:4:57: error: servers[1].tls must be a boolean, found "false"
  2 │   <name>eu-prod</name>
  3 │   <servers><host>a.internal</host><port>8080</port></servers>
  4 │   <servers><host>b.internal</host><port>8081</port><tls>false</tls></servers>
    │                                                         ^^^^^
  5 │ </cluster>

3 errors
```

`Cluster` said `coerceScalars: true`. `Server` did not, and `Server` is what those `port`
and `tls` fields belong to. Every nested `@Schema` type decides for itself, because the
alternative is a flag on an outer type silently changing how an inner type — possibly one
you do not own — accepts data.

The fix is to say it on both:

```swift
@Schema(keys: .snakeCase, coerceScalars: true, formats: [.xml])
struct XMLServer { var host: String; var port: Int; var tls: Bool = true }

@Schema(keys: .snakeCase, coerceScalars: true, formats: [.xml])
struct XMLCluster { var name: String; var servers: [XMLServer] }
```

```xml
<cluster>
  <name>eu-prod</name>
  <servers><host>a.internal</host><port>8080</port></servers>
  <servers><host>b.internal</host><port>8081</port><tls>false</tls></servers>
</cluster>
```

```text
XMLCluster(name: "eu-prod", servers: [XMLServer(host: "a.internal", port: 8080, tls: true), XMLServer(host: "b.internal", port: 8081, tls: false)])
```

Which also shows how XML spells an array: **repeated sibling elements.** There is no list
syntax, so two `<servers>` elements are two elements of `servers`. A single one is an array
of one.

## Placement

XML is the only format here where the same value can live in three different places, so it
is the only one with an attribute for saying which.

```swift
@Schema(coerceScalars: true, formats: [.xml])
@XML(root: "item")
struct Item {
    @XML(.attribute) var id: Int          // <item id="7">
    @XML(.attribute) var lang: String = "en"
    @XML(.text) var body: String          // the element's own character data
    @XML(.wrapped) var tags: [String]     // <tags><tags>a</tags></tags>
}
```

```xml
<item id="7" lang="fr">
  The body text.
  <tags><tags>swift</tags><tags>xml</tags></tags>
</item>
```

```text
Item(id: 7, lang: "fr", body: "\n  The body text.\n  ", tags: ["swift", "xml"])
```

Four things in that result:

- `id` came from an attribute and was coerced to `Int`.
- `lang` came from an attribute that was present. Had it been absent you would have `"en"`,
  because presence rules work the same here as everywhere.
- `body` is the element's own text, whitespace and all. XML does not normalise text content
  and neither does Assay; `@Preprocess(.trim)` is there if you want it trimmed.
- `tags` came out of a wrapper element, which is the other common way XML spells a list.

**An unannotated field is a child element.** That is the safe default: an attribute cannot
nest, cannot repeat, and has its whitespace normalised, so anything expressible as an
attribute is also expressible as an element and not the other way round.

### The root

`@XML(root: "item")` checks the root element's name and reports a mismatch:

```xml
<service><name>api</name></service>
```

```text
item.xml: error: root element must be <item>, found <service>

item.xml: error: id is required

item.xml: error: body is required

item.xml: error: tags is required

4 errors
```

Without the annotation the root is not checked at all. That is deliberate rather than lazy:
the root element is very often an unmodelled envelope somebody else chose, and failing on
it by default would make the common case annoying.

## XXE is refused by construction

```xml
<!DOCTYPE deployment [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
<deployment><name>&xxe;</name></deployment>
```

```text
deploy.xml: error: reference to an undeclared entity

deploy.xml: warning: external entity ignored (never fetched)

1 error, 1 warning


warnings: xml_external_entity_ignored
```

Two things happened. The external entity declaration was **ignored**, with a warning saying
so. Then the reference to it failed, because the entity does not exist.

There is no flag for this, and that is the point. The parser has no code path that opens a
file or a socket, so there is nothing to configure, nothing to forget, and no way for a
future refactor to turn it back on. Compare with the usual advice for XML parsers, which is
a list of options you must remember to set on every parser you construct.

Billion laughs is handled by the same node budget as YAML's aliases. See
[Limits](/reference/limits-and-security/).

## CDATA, comments and mixed content

CDATA is text. It is the escape hatch for content full of angle brackets, and it arrives as
the characters it holds:

```swift
@Schema(coerceScalars: true, formats: .all) struct Note { var title: String; var body: String }
```

```xml
<note><title>T</title><body><![CDATA[<b>raw</b> & unescaped]]></body></note>
```

```text
Note(title: "T", body: "<b>raw</b> & unescaped")
```

Comments are preserved in the value model and skipped by the schema path, which is the only
sensible split: a comment is not data, but a tool walking the tree may well want it.

## When the XML is wrong

A mismatched end tag, which the parser catches before any schema runs:

```xml
<deployment><name>api</image></deployment>
```

```text
deploy.xml:1:14: error: name closing tag does not match
  1 │ <deployment><name>api</image></deployment>
    │              ^^^^

1 error
```

Namespaces resolve properly, line endings are normalised per the spec, and a schema error
in a deeply nested element still gets a caret in the original bytes.

## When you do not know the shape

`XML.Document` and `XML.Node` keep what the format expressed: namespaces, attributes,
comments, and the order of mixed content.

```xml
<root xmlns:n="urn:example"><n:child a="1">text<!-- c --></n:child></root>
```

```text
root.name.local          → root
child.name.local         → child
child.name.namespaceURI  → urn:example
child[attribute: "a"]    → 1
child.children.count     → 2   (text + comment)
```

`name.local` is the local name and `name.namespaceURI` is the resolved URI, not the prefix —
prefixes are a document-local spelling and two documents can use different ones for the
same namespace. The child count of two is the text node plus the comment, in document order,
because that order is sometimes the only thing that distinguishes valid markup from
nonsense.

## A note on speed

Assay's XML parser measures about 2.5× Foundation's `XMLParser` on macOS. On Linux it
measures 0.96× — parity — because `FoundationXML` there is libxml2, and matching a mature C
parser while building a full tree its SAX interface never builds is a fine result to stop at.

"Faster than Foundation's XML" is therefore a macOS-only sentence, so it is not one this
site says without the platform attached. [Performance](/reference/performance/) has the
rest.

## Next

- [TOML](/formats/toml/) — a format that is typed on the wire, which XML is not.
- [Property lists](/formats/plist/) — which reuse this parser, XXE refusal included.
- [Attributes](/reference/attributes/) — every `@XML` spelling in one table.
