---
title: Unions
description: One of several shapes — tagged by a field, or matched by trying. JSON only, and here is why.
---

A payload that is one of several shapes is an enum:

```swift
@Schema(keys: .snakeCase, discriminator: "type")
enum Event {
    case click(Click)
    @Key("page_view") case pageView(PageView)
    case purchase(Purchase)
}
```

```json
{"type": "click", "x": 12, "y": 40}
```

The tag names the branch, the branch decodes the whole object, and the case name is the tag
value unless `@Key` says otherwise.

## Prefer the tagged form

A discriminated union is better in every way that matters, and it is worth saying plainly
because untagged looks more convenient:

- **The error is about one branch.** The tag said `purchase`, so a failure is a `purchase`
  failure with its own caret. There is nothing to compose.
- **An unknown tag is one clear error**, not "none of these four matched, here is why for
  each".
- **It encodes without an exception.** The untagged form has one; see below.
- **It is faster.** Scan the keys for the tag (values skipped structurally), rewind, decode
  the named branch. One pass over the document plus one decode.

## Untagged, when the wire gives you no choice

```swift
@Schema(discriminator: .untagged)
enum Value {
    case number(NumberSpec)
    case text(TextSpec)
}
```

First match wins, in declaration order. Order them most specific first — a variant that
accepts almost anything will shadow the ones after it.

### What a failure looks like

When nothing matches, you get one summary plus the **closest** branch's detail — the branch
that got furthest before failing:

```
error: value did not match any variant of Value (2 tried)
error: value.maximum must be a number, found "ten"
```

Producing that detail costs something worth knowing: the measuring pass rolls every branch
back, so by the time the winner is known its issues are gone, and the winner is **run
twice**. The alternative — snapshotting every branch's issues as it goes — costs an
allocation per branch on every decode, including the ones that succeed.

`Limits(verboseUnions: true)` keeps every branch's issues instead, for when you are
debugging which variant you meant.

### What bounds the backtracking

`Limits.maxUnionAttempts` (10,000 by default) caps total branch attempts across the whole
document, not per union. It is **not** refunded by a rewind — a nested untagged union in an
array is multiplicative, and a global budget is what makes that bounded.

## Encoding

Both forms encode with `encodes: true`. The tagged form writes the tag **first**, which is
not cosmetic: a reader that has to scan past the payload to find the tag pays for it, and
Assay's own decoder would.

The untagged form carries the round-trip law's fourth exception: if two variants' types
accept the same documents, re-decoding may pick the other one. The macro refuses two cases
carrying the same payload *token*, but two distinct `@Schema` types that happen to accept
the same documents are indistinguishable to a macro. The tagged form has no such exception.

## JSON only

Unions decode and encode from JSON, and that is a real limit rather than a queue position.

The tagged form needs to **scan for the tag, then rewind and decode the branch over the
whole object** — that is a byte reader's operation. The `RawValue` projection every other
format goes through is a tree that has already been built, and the mechanism does not
transfer. Rather than silently omitting the body for YAML or XML, `formats:` including a
non-JSON format on a union is refused at expansion.

If you need a union from YAML: parse to `YAML.Node`, look at the tag yourself, and decode
the branch you chose. Three lines, and honest about what it is doing.

## What a variant must be

A payload type is a `@Schema` type. Two rules the macro enforces:

- **No two cases with the same payload type.** For untagged that is undecidable at runtime;
  for tagged it is a copy-paste error. Either way it is a build error.
- **A case with no payload** is fine in the tagged form (the tag alone identifies it) and
  refused in the untagged one, where there would be nothing to match on.

## Open enums are a different thing

For a closed set of strings, you do not need any of this — a plain `RawRepresentable` enum
decodes with no macro at all:

```swift
enum Status: String, JSONAssayable, CaseIterable { case active, archived }
```

For a set that the server may add to:

```swift
@Schema enum Status {
    case active, archived
    @Unknown case other(String)
}
```

Anything unrecognised lands in `.other` with its string, rather than failing the whole
decode because someone deployed a new status. See
[Encoding](/guides/encoding/#open-enums) for `roundTrips:`.

## Next

- [Encoding](/guides/encoding/) — the exception list in full.
- [Advanced](/guides/advanced/) — contexts, wrappers, runtime schemas.
