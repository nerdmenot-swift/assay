---
title: YAML
description: Block and flow, anchors and merge keys, block scalars, multi-document streams — and a parser that refuses to guess what NO means.
---

```swift
import AssayYAML

@Schema(keys: .snakeCase, formats: [.json, .yaml])
struct Deployment {
    @Validate(.min(1), .max(63)) var name: String
    var image: String
    @Validate(.min(1)) var replicas: Int
    var region: String = "eu-west-1"
    @Validate(.url) var healthCheck: String?
}

let deployment = try Deployment.parse(yaml: text)
```

The parser is hand-written Swift. No libyaml, nothing to vendor, and it runs everywhere the
rest of the package runs. It is also about 6.6× faster than the Swift binding to libyaml at
building a node tree, and about 11× faster end to end into a struct, which was not the
point but is a pleasant place to end up.

## The Norway problem, and why you do not have it

YAML 1.1 said `NO` was a boolean. Norway's country code is `NO`. Every few years somebody
loses an afternoon to this.

Assay's parser **does not resolve plain scalars at all.** A scalar keeps its text, its
style, its tag and its anchor, and stays that way until something asks it a typed question.
Your field declaration is that question.

```swift
@Schema(formats: [.yaml]) struct Country { var code: String; var enabled: Bool }
```

```yaml
code: NO
enabled: false
```

```text
Country(code: "NO", enabled: false)
```

`NO` asked as a `String` is the string. Now the other half, which surprises people more:

```yaml
code: NO
enabled: no
```

```text
country.yaml:2:10: error: enabled must be a boolean, found "no"
  1 │ code: NO
  2 │ enabled: no
    │          ^^

1 error
```

`no` is **not** a boolean. YAML 1.2's core schema lists exactly `true` and `false`, and
Assay follows 1.2 rather than the 1.1 grammar that made this famous. Writing `enabled: no`
in a config file gets you an error with a caret under it, rather than a value you did not
mean quietly winning.

If your input genuinely comes from a YAML 1.1 world, opt in:

```swift
@Schema(coerceScalars: true, formats: [.yaml])
struct LooseCountry { var code: String; var enabled: Bool }
```

```text
LooseCountry(code: "NO", enabled: false)
```

That is a decision you made, in the declaration, in one place. Which is the whole idea.

## Block and flow

Both spellings work everywhere, and they nest inside each other.

```swift
@Schema(keys: .snakeCase, formats: [.yaml]) struct Server { var host: String; var port: Int; var tls: Bool = true }

@Schema(keys: .snakeCase, formats: [.yaml])
struct Cluster {
    var name: String
    var servers: [Server]
    var labels: [String: String] = [:]
}
```

Block style:

```yaml
name: eu-prod
servers:
  - host: a.internal
    port: 8080
  - host: b.internal
    port: 8081
    tls: false
labels:
  tier: prod
  team: platform
```

```text
Cluster(name: "eu-prod", servers: [Server(host: "a.internal", port: 8080, tls: true), Server(host: "b.internal", port: 8081, tls: false)], labels: ["team": "platform", "tier": "prod"])
```

Flow style, which is JSON wearing a hat:

```yaml
name: eu-prod
servers: [{host: a.internal, port: 8080}, {host: b.internal, port: 8081}]
labels: {tier: prod}
```

```text
Cluster(name: "eu-prod", servers: [Server(host: "a.internal", port: 8080, tls: true), Server(host: "b.internal", port: 8081, tls: true)], labels: ["tier": "prod"])
```

## Anchors, aliases and merge keys

Anchors are the reason people choose YAML for config, so they work properly — including
the `<<` merge key, which is not in the spec but is in everyone's CI file.

```yaml
defaults: &defaults
  port: 8080
  tls: true
name: eu-prod
servers:
  - <<: *defaults
    host: a.internal
  - <<: *defaults
    host: b.internal
    port: 9090
```

```text
Cluster(name: "eu-prod", servers: [Server(host: "a.internal", port: 8080, tls: true), Server(host: "b.internal", port: 9090, tls: true)], labels: [:])
```

`a.internal` took `port: 8080` from the anchor. `b.internal` overrode it with `9090`.
Both took `tls: true`. The merge is resolved before your schema sees anything, so rules and
presence behave exactly as they would on a document written out longhand.

Aliases are also where a YAML parser can be attacked: a handful of nested anchors can
expand to gigabytes. The node budget in [Limits](/reference/limits-and-security/) is what
stops that, and it stops it during expansion rather than after.

## Block scalars

```swift
@Schema(coerceScalars: true, formats: [.yaml]) struct Note { var title: String; var body: String }
```

Literal, with `|` — newlines kept:

```yaml
title: Release
body: |
  Line one.
  Line two.
```

```text
Note(title: "Release", body: "Line one.\nLine two.\n")
```

Folded, with `>` — newlines become spaces:

```yaml
title: Release
body: >
  This is one
  long line.
```

```text
Note(title: "Release", body: "This is one long line.\n")
```

Chomping indicators (`|-`, `|+`, `>-`) work as specified. The trailing newline in both
results above is the default "clip" behaviour, which is what you get when you write neither.

## Multi-document streams

Three dashes, one file, many values.

```swift
let all = try Deployment.parseAll(yaml: text)
```

```yaml
---
name: a
image: img:1
replicas: 1
---
name: b
image: img:2
replicas: 2
```

```text
["a", "b"]
```

`parseAll` gives you `[T]`. A document that fails does not stop the ones after it: every
document is decoded, the issues accumulate, and you get one error carrying all of them at
the end. The path on each issue starts with the document's index, so you know which one.

## When the YAML is wrong

A type mismatch, which is a schema error and points at the scalar:

```yaml
name: api
image: img:1
replicas: three
```

```text
deploy.yaml:3:11: error: replicas must be an integer, found "three"
  1 │ name: api
  2 │ image: img:1
  3 │ replicas: three
    │           ^^^^^

1 error
```

Bad indentation, which is a parse error and points at where the parser gave up:

```yaml
name: api
image: img:1
  replicas: 3
```

```text
deploy.yaml:3:3: error: unexpected content after the end of the document
  1 │ name: api
  2 │ image: img:1
  3 │   replicas: 3
    │   ^

1 error
```

An unterminated flow collection, where there is no position to point at because the input
ended:

```yaml
name: api
servers: [a, b
```

```text
cluster.yaml: error: unterminated flow sequence

1 error
```

Every one of those carries a source span, which is worth saying because most YAML libraries
lose them. Assay's YAML nodes carry byte spans through the projection into the schema, so a
rule failure three levels deep still gets a caret in the original file. That costs about 2%
on parse and it is the best 2% in the library.

## When you do not know the shape

`YAML.Node` keeps everything the format expressed, including the things a value model
usually throws away.

```yaml
scalar: NO
quoted: "NO"
tagged: !!str 123
```

```text
n["scalar"]?.content        → NO
n["scalar"]?.resolvedBool   → nil
n["quoted"]?.scalar?.style  → doubleQuoted
n["tagged"]?.scalar?.tag    → !!str
```

Four things to notice. `content` is the raw text, always available. `resolvedBool` is `nil`
rather than `false`, because `NO` is not a boolean and the model will not pretend
otherwise. The quoting style survived, so you can tell `"NO"` from `NO`. And an explicit
`!!str` tag survived too.

`resolvedInt` and `resolvedDouble` sit beside `resolvedBool` and answer `nil` the same way
when the scalar is not that thing. `isNull` is the fourth, and it is a `Bool` because
"this is null" and "this is not a null" are the only two answers it can give.

## Next

- [XML](/formats/xml/) — attributes, placement, and a format with no types at all.
- [TOML](/formats/toml/) — the opposite philosophy, typed on the wire.
- [Limits](/reference/limits-and-security/) — alias expansion, depth, and byte budgets.
