---
title: HTTP bodies
description: Choose the parser from a Content-Type header, safely — with an accepting list that has no default, on purpose.
---

When the format arrives in a header rather than in your code:

```swift
let deployment = try Deployment.parse(
    body: request.body,
    contentType: request.headers["content-type"],
    accepting: [.json, .yaml]
)
```

```text
Content-Type: application/yaml
accepting: [.json, .yaml]
```

```text
Deployment(name: "api", image: "img:1", replicas: 3, region: "eu-west-1", healthCheck: nil)
```

There is a `diagnose(body:contentType:accepting:)` beside it with the same arguments, for
when you want the issues rather than an error.

## `accepting:` is required, and has no default

This is the load-bearing decision on the page, so here is what it buys.

```text
Content-Type: application/xml
accepting: [.json, .yaml]
```

```text
body.xml: error: media type application/xml is not in the accepted list

1 error
```

The XML body never entered an XML parser. It was not partially parsed and then rejected —
negotiation happens first, and a media type outside the list stops there.

That matters because a body you did not ask for is the cheapest attack surface on a server.
An [XML bomb](/reference/limits-and-security/) or an
[XXE attempt](/formats/xml/#xxe-is-refused-by-construction) offered to a JSON endpoint should
cost you one comparison, not a parse. Making the list a required argument means a server
opts in to each parser a request can reach, in writing, at the call site.

`unsupported_media_type` is its own issue code, separate from any parse failure, so your
handler can map it to a 415 rather than a 400 without inspecting the message.

## The format is never guessed from the bytes

There is no sniffing here. None. A missing `Content-Type` is an issue, an unparseable one is
an issue, and a body whose bytes happen to look like JSON while the header says something
else is not JSON.

The only place in the library that reads bytes to pick a decoder is
[property lists](/formats/plist/#this-is-not-sniffing-and-the-distinction-matters), where
the caller has already named the format and the two flavours are encodings of it.

## RFC 9110 and 6839, properly

Structured suffixes work, which is not a nicety: most versioned APIs on the internet spell
their content type that way.

```text
Content-Type: application/vnd.acme.deploy+yaml; charset=utf-8
accepting: [.yaml]
```

```text
Deployment(name: "api", image: "img:1", replicas: 3, region: "eu-west-1", healthCheck: nil)
```

`application/vnd.acme.deploy+yaml` is YAML because the `+yaml` suffix says so.
`application/vnd.github.v3+json` is JSON for the same reason.

The `charset` parameter is **checked and never transcoded**. A UTF-8 charset, or no charset
at all, is fine. Anything else is refused rather than misread, because the alternative is
decoding Latin-1 bytes as UTF-8 and handing you mojibake that validates.

## The formats are values

`accepting:` takes `[WireFormat]`, and each format's value lives in its own module:

| value | needs |
|---|---|
| `.json` | `import Assay` |
| `.yaml` | `import AssayYAML` |
| `.xml` | `import AssayXML` |
| `.toml` | `import AssayTOML` |

That is why they are values rather than enum cases. `Assay` cannot depend on `AssayYAML`, so
a closed enum listing every format would drag every parser into every build. A server that
only ever writes `accepting: [.json]` never links a YAML parser at all.

You can write your own, too. A `WireFormat` is a name, a predicate over the parsed media
type, and a closure producing a `RawValue`.

## JSON keeps its fast path

Worth saying because it would be an easy thing to lose: a `.json` match through this entry
point is routed back onto the byte-direct JSON decoder, not through the value model that
every other format uses.

Negotiating the format costs you a string comparison. It does not cost you the
[performance thesis](/reference/performance/).

## Next

- [Limits](/reference/limits-and-security/) — the budgets behind every parser this reaches.
- [Errors](/guides/errors/) — including the RFC 9457 problem-details renderer, which pairs
  with this rather well.
