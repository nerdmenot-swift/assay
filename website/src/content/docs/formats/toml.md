---
title: TOML
description: Tables, arrays of tables, four kinds of date-time, and a redefinition rule that catches the mistake TOML is actually prone to.
---

```swift
import AssayTOML

@Schema(keys: .snakeCase, formats: [.toml])
struct Deployment {
    var name: String
    var image: String
    var replicas: Int
}

let deployment = try Deployment.parse(toml: text)
```

The parser passes **all 710 documents** of the official `toml-test` suite: 210 valid ones
decoded to the exact expected value, 501 invalid ones refused. That runs in CI on every
commit, with toml++ as a differential oracle beside it.

## Typed on the wire

TOML is the opposite of YAML. The grammar decides the type, so there is nothing to resolve
and nothing to coerce:

| written | is |
|---|---|
| `1` | an integer |
| `"1"` | a string |
| `1.0` | a float |
| `true` | a boolean |
| `1979-05-27` | a local date |
| `0xDEAD_BEEF` | an integer, in hex, with readable underscores |

You will never need `coerceScalars` for TOML, and a type mismatch here is a genuine
mismatch rather than an ambiguity somebody has to adjudicate.

It also means the parser can be strict about literals that look fine but are not:

```toml
name = "api"
image = "img:1"
replicas = 01
```

```text
deploy.toml:3:12: error: invalid number literal
  1 │ name = "api"
  2 │ image = "img:1"
  3 │ replicas = 01
    │            ^^

1 error
```

`01` is not a TOML integer. Leading zeros are forbidden by the grammar, because they are how
octal gets confused with decimal in every language that allows them.

## Tables and arrays of tables

```swift
@Schema(keys: .snakeCase, formats: [.toml]) struct Server { var host: String; var port: Int; var tls: Bool = true }

@Schema(keys: .snakeCase, formats: [.toml])
struct Cluster {
    var name: String
    var servers: [Server]
    var labels: [String: String] = [:]
}
```

`[[servers]]` is an array of tables. Each header appends an element:

```toml
name = "eu-prod"

[[servers]]
host = "a.internal"
port = 8080

[[servers]]
host = "b.internal"
port = 8081
tls = false

[labels]
tier = "prod"
team = "platform"
```

```text
Cluster(name: "eu-prod", servers: [Server(host: "a.internal", port: 8080, tls: true), Server(host: "b.internal", port: 8081, tls: false)], labels: ["tier": "prod", "team": "platform"])
```

The same document written with inline tables, which is the compact spelling:

```toml
name = "eu-prod"
servers = [{host = "a.internal", port = 8080}]
labels = {tier = "prod"}
```

```text
Cluster(name: "eu-prod", servers: [Server(host: "a.internal", port: 8080, tls: true)], labels: ["tier": "prod"])
```

Both spellings land in the same struct, because your schema does not care how the file was
laid out. Dotted keys are the third spelling and define a *table* rather than an array of
them, so `labels.tier = "prod"` is the one-line form of the `[labels]` section above.

## Redefinition is an error

This is the rule TOML exists to enforce and the mistake people actually make: writing the
same table header twice, usually after a copy-paste, usually in a file long enough that you
do not notice.

```toml
name = "x"

[labels]
tier = "prod"

[labels]
team = "platform"
```

```text
cluster.toml:6:2: error: table 'labels' is already defined
  4 │ tier = "prod"
  5 │ 
  6 │ [labels]
    │  ^^^^^^
  7 │ team = "platform"

1 error
```

Most of the difficulty in a TOML parser is here rather than in the tokens. The rule Assay
implements is "every value except an open table is closed once parsed", plus one origin tag
per table recording whether it came from a header, from dotted keys, or from being implied
by a deeper header. Those three cases have different rules about what may extend them
later, which is why the tag exists.

An inline table is closed the moment its brace shuts, so `a = {x = 1}` followed by
`a.y = 2` is an error as well. That is the spec, and it is a good rule: an inline table is a
value, not a section.

## Four kinds of date-time

TOML is the only format here with dates in the grammar, and it has four of them:

| spelling | kind |
|---|---|
| `1979-05-27T07:32:00Z` | offset date-time |
| `1979-05-27T07:32:00` | local date-time, no zone |
| `1979-05-27` | local date |
| `07:32:00` | local time |

For a `Date` field, all of this is already handled:

```swift
@Schema(keys: .snakeCase, formats: [.toml])
struct Entry {
    var name: String
    var createdAt: Date
    @DateFormat(.unixSeconds) var seenAt: Date
}
```

```toml
name = "release"
created_at = 1979-05-27T07:32:00Z
seen_at = 1700000000
```

```text
Entry(name: "release", createdAt: 1979-05-27 07:32:00 +0000, seenAt: 2023-11-14 22:13:20 +0000)
```

Under the hood a TOML date-time projects to an RFC 3339 string before it reaches your
schema, which is exactly what a `Date` field already knows how to parse. So the date support
you get is the same date support every other format gets, including
[`@DateFormat`](/guides/dates/) candidate chains and the `.before` / `.after` / `.between`
rules.

A date that parses as a shape but is not a real day is refused by the parser:

```toml
name = "release"
created_at = 2023-02-29
seen_at = 1
```

```text
entry.toml:2:14: error: invalid date-time
  1 │ name = "release"
  2 │ created_at = 2023-02-29
    │              ^^^^^^^^^^
  3 │ seen_at = 1

1 error
```

2023 was not a leap year.

## TOML has no null

There is no way to write one, so encoding has a rule: a `nil` optional is **omitted**, and
any other null is reported rather than silently dropped. See
[Encoding](/guides/encoding/) for what round-trips and what cannot.

## When you do not know the shape

`TOML.Node` keeps the date-time kinds distinct, because collapsing them loses the one piece
of information TOML bothered to encode.

```toml
odt = 1979-05-27T07:32:00Z
ldt = 1979-05-27T07:32:00
ld  = 1979-05-27
lt  = 07:32:00
hex = 0xDEAD_BEEF
```

```text
t["odt"]?.dateTime → offsetDateTime(1979-05-27T07:32:00Z)
t["ldt"]?.dateTime → localDateTime(1979-05-27T07:32:00)
t["ld"]?.dateTime  → localDate(1979-05-27)
t["lt"]?.dateTime  → localTime(07:32:00)
t["hex"]?.int      → 3735928559
```

`TOML.DateTime` is an enum with those four cases. The hex literal is an ordinary integer by
the time you read it — the radix was a spelling, not a type.

## A note on speed

TOML is a tree decoder, like YAML and XML, so the argument that makes Assay's JSON path fast
does not apply. The numbers are about parity with C: roughly 1.17× toml++ at building the
tree, and 1.95× TOMLKit's `Codable` decoder end to end.

That second number is the familiar shape — the gap is the `Codable` boundary, not the
parser. [Performance](/reference/performance/) has the rest.

## Next

- [Property lists](/formats/plist/) — the fifth format, and two encodings of it.
- [Dates](/guides/dates/) — formats, candidate chains, and the rules.
- [Encoding](/guides/encoding/) — writing TOML back out.
