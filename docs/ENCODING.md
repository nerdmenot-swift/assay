# Encoding — the questions that block it, and a recommendation for each

**Status: five of six ACCEPTED and IMPLEMENTED for JSON, 2026-08-09.** This document began
as proposals; the recommendations were accepted and built. What is implemented, what is not,
and why:

| question | status |
|---|---|
| 1 · `@Fallback` writes its value | **built** — decode-time-only, with the exception named in the round-trip law |
| 2 · `@Unknown(roundTrips:)` | **blocked, not deferred** — `@Unknown` itself does not exist yet (`ROADMAP.md` §6). The recommendation stands and applies the day it is built |
| 3 · `@Inverse` + expansion-time check | **built** — a `@Transform` without one is a compile error |
| 4 · encode error channel | **built** — `Issue`/`IssueSink`, `location: nil`, `encode` / `diagnoseEncode` |
| 5 · target `.input`, round-trip as a law | **built** — the law is a test suite with its exception list as named cases, for JSON and YAML |
| 6 · defaults emitted, `@Extras` written back | **built** — collisions are an encode-time error |

**JSON and YAML.** XML encoding remains genuinely blocked on `@XML` placement
(`ROADMAP.md` §4 — without it an encoder cannot know whether a field is an attribute or an
element, and guessing is the exact ambiguity that attribute exists to remove).
`@Schema(encodes: true)` emits a JSON encoder; adding `.yaml` to `formats:` also emits the
`RawValue` projection that YAML renders from.

**YAML encodes through `RawValue`, and that is the architecture, not a shortcut.** Decoding
YAML parses to `YAML.Node`, projects to `RawValue`, and decodes from there; encoding runs
the identical pipeline backwards. Two things fall out: the macro never learns about YAML —
so adding the format required no macro change and a JSON-only type carries no YAML code —
and the losses are the *same* losses decoding already documents rather than a second set
nobody wrote down.

**The whole difficulty in YAML output is quoting, and it is the Norway problem from the
other side.** Assay's decoder refuses to resolve a plain scalar until asked, which is what
sidesteps the bug rather than inheriting it. The encoder has to pay for that guarantee in
the other direction: `RawValue.string("123")` written bare comes back an *integer*, `"true"`
a boolean, `"~"` a null. So plain style is used only where the text provably cannot read as
anything else, and everything uncertain is quoted — a false positive costs two characters, a
false negative silently changes a value's type. 57 hazard cases pin it.

YAML also expresses two things JSON cannot: `NaN` and `±Infinity` are `.nan`/`.inf` rather
than issues. It is the one place the YAML encoder is strictly more capable than the JSON one.

`Tests/AssayTests/EncodingTests.swift` holds the law and every exception.

`EXPERIENCE.md` §14 is the authority on *why* encoding is a deferral rather than a refusal.
The short version: Zod is the only major library in this space that changed its mind about
encoding and it changed *toward* it, so refusing outright does not survive contact with the
evidence. What §14 also establishes is that **encoding is not decoding backwards** — every
library that went bidirectional built two engines, not one (Pydantic's Rust core: ~12k lines
of validators beside ~11k of serializers).

## What is already paid for

Every piece of placement information is *preserved* rather than consumed during decoding —
`@Key` renames, `@XML` element-vs-attribute placement, `@DateFormat` patterns. That cost is
being paid now, in generated code that the decode path never reads back, specifically so that
encoding is additive later instead of a redesign. Whatever is decided below, that stays.

---

## 1. What does `@Fallback` write back?

`@Fallback(0) var retries: Int` decodes as "absent **or invalid** → 0, with a warning, not
re-validated" (`EXPERIENCE.md` §6). Once decoding is done the field simply holds 0, and
nothing distinguishes a genuine 0 from a salvaged one.

- **Write it.** Simple, and a round-trip launders bad data: garbage in, clean output,
  re-asserted as truth.
- **Omit the key.** A perfectly valid document silently loses a field.
- **Track provenance.** Store a "this fell back" bit per field so encode can tell. Changes
  the user's struct layout, the memberwise initializer, `Equatable` — invasive for a case
  that is arguably already served.

**Recommendation: write the value, and document `@Fallback` as decode-time-only with no
encode-side meaning.**

The reasoning that decides it: **provenance is a property of a particular decode, not of the
value.** `Config(retries: 0)` constructed in code has no fallback history at all, so any
scheme that reads provenance off the value is incoherent for values that never came from a
document. The "this was salvaged" signal already exists and already has a home — the warning
in `Diagnosis`. A caller who must not re-emit salvaged data branches on that warning at the
point where the information actually exists.

## 2. Does an `@Unknown` enum case round-trip?

`@Unknown case other(String)` exists so a v1 client can decode a v2 server's new variant.
On encode, writing the captured string back gives faithful round-tripping — and lets an
arbitrary attacker-supplied value pass through a type that reads, at every use site, as a
closed set.

- **Always write it.** The proxy use case works. The type stops being a guarantee.
- **Always refuse.** Safe, and it breaks the decode-modify-forward pattern the attribute
  exists for.
- **Opt in at the declaration.**

**Recommendation: `@Unknown(roundTrips: true)` opts in; the default is an encode-time error
naming the field and the captured value.**

This follows a decision this codebase has already made once. `parse(body, contentType:,
accepting:)` makes `accepting:` **required with no default**, because an unbounded format
guess on untrusted input is how you get XXE. Same shape here: the dangerous capability is
real and deserves support, it is narrower than the capability people actually reach for
(forward-compatible *decoding*), and conflating the two by default is how the narrow one
arrives unnoticed. An error at encode is loud and immediate; a silent pass-through is
something you learn about from a security report.

## 3. What does `@Transform` mean in reverse?

`@Transform({ (a: [String]) in Set(a) })` decodes `[String]` into `Set<String>`. Encoding
needs the inverse, and a Swift closure does not have one.

- **Encode from the property type**, skipping the transform. Silently emits a document that
  will not re-decode. Wrong.
- **Refuse to encode any type with a transform.** Too blunt; transforms are ordinary.
- **Infer inverses for a known set.** Magic, fragile, and wrong the first time someone writes
  a transform that looks invertible and is not.
- **Let the author supply it.**

**Recommendation: a separate `@Inverse({ (s: Set<String>) in Array(s) })` attribute, and a
type that requests encoding while carrying a `@Transform` without an `@Inverse` is a
COMPILE-TIME error with a purpose-written diagnostic.**

Two reasons this shape rather than a two-closure `@Transform`. First, a transform with no
inverse is *lossy* — that is arithmetic, not a design failure — so the design's job is to let
an inverse be supplied where one exists and to fail loudly where it does not. Second, the
macro can see both attributes and the declared types, so this is exactly the check it already
performs for `@Validate` rules against field types and for `@DateFormat` patterns:

```
error: 'tags' has a @Transform but no @Inverse, so this type cannot be encoded
note: add @Inverse({ (s: Set<String>) in Array(s) }), or remove `encodes: true`
```

Failing at expansion rather than at runtime is the house pattern and the reason the
non-generic `Rule` is type-safe anyway.

## 4. What is the encode-side error channel?

`EXPERIENCE.md` §14 states the problem: *"this value cannot be represented in this format" is
a different kind of problem from "this document is malformed."* A `Double.nan` in JSON, an
XML element name that is not a valid `Name`, a dictionary key that is not a string. And
`Issue` carries `location: SourceSpan?` — a byte offset into a source document that, on
encode, does not exist.

**Recommendation: reuse `Issue` and `IssueSink` with `location: nil`, keep `path`, add
encode-specific codes, and mirror the two verbs.**

```swift
let bytes = try article.encode(json: .default)     // throws AssayError, all issues
let d = article.diagnoseEncode(json: .default)      // partial output + issues + warnings
```

`SourceSpan` being nil is already a supported state — a missing-required issue has no
location today and renders fine. `path` is the part that matters and it is fully meaningful:
`coordinates[3].x cannot be represented in JSON`. New codes: `unrepresentable_value`,
`invalid_element_name`, `non_string_key`.

The thing to **not** do is invent a parallel `EncodeIssue`/`EncodeError`/`EncodeDiagnosis`
hierarchy. One error vocabulary, one set of renderers, one mental model — and `.json` and
`.problemDetails` keep working unchanged for encode failures, which is a real win for a
service that validates and then re-serialises. Collecting rather than throwing on the first
problem is also the library's whole identity; breaking that on one side would be surprising.

## 5. Does the encoder target `.input` or `.output`, and is round-trip a law?

`jsonSchema(for: .input)` and `.output` genuinely differ once transforms exist — Zod shipped
the single-document version and corrected it in v4.

**Recommendation: the encoder always targets `.input` — it writes the document `parse` would
accept — and round-trip becomes a stated law with an explicit exception list.**

> For any `v` produced by `parse`, `parse(encode(v))` produces a value equal to `v`, except
> where a `@Fallback` fired, an `@Unknown` case was captured without `roundTrips: true`, or
> unknown keys were dropped by a policy other than `.collect`.

Two things this buys. Targeting `.input` is what makes the law true at all — with `@Inverse`
supplying the wire type, the encoder emits exactly the shape decode accepts. And stating it
as a law with a *closed* exception list turns round-trip from an emergent property nobody
tests into a property with a test suite and three documented holes. `jsonSchema(for: .input)`
then doubles as the encoder's published contract: one description, two uses.

## 6. Do defaults and `@Extras` get written back?

Not on the roadmap's list, and it belongs there — it has the same "you cannot tell what
happened on the way in" shape as `@Fallback`.

**Defaults — recommendation: always emit.** `var retries: Int = 3` writes `3`. Omitting when
a value equals its default is a footgun the moment a consumer's default differs, and
round-trip fidelity beats payload minimalism. If anyone genuinely needs the smaller document,
`@Schema(encodeDefaults: .omit)` is additive later; the reverse is not.

**`@Extras` — recommendation: write them back, and make a collision with a declared key an
encode-time error.** Re-emitting is the entire point of having collected them: a proxy that
decodes, edits known fields and re-encodes must not silently drop everything it did not
recognise. This looks like question 2 but is not, and the difference is the whole reason to
answer them differently — `@Extras var rest: [String: RawValue]` is a declaration that the
author *wants to hold arbitrary data*, whereas `@Unknown` makes a type-system claim about
being a closed set and then quietly is not.

---

## What is still not being promised

Symmetry. `EXPERIENCE.md` §14's point stands whatever is decided above: two engines, not one.
These six answers shape an encoder; they do not make one fall out of the decoder.

## What remains

1. **`@Unknown(roundTrips:)`** — waits on `@Unknown` existing at all.
2. **XML encoding.** Blocked on **two decisions**, both of which need answering before any
   code — the same rule this document was written under.

   **Decision A — what does an unannotated field encode as?** (`ROADMAP.md` §4's stated
   blocker.) *Recommendation: an element,* with `@XML(.attribute)` and `@XML(.text)` as
   opt-ins. An element is the safe superset — attributes cannot nest, cannot repeat, and
   have their whitespace normalised, so anything expressible as an attribute is expressible
   as an element and not the reverse. It also matches what decoding already does: the
   projection flattens attributes and elements into one keyspace and matches by name, so a
   document written all-elements re-decodes to the same value as the attribute-shaped
   original. What it does **not** give is document-shape round-trip — decode
   `<user id="7"/>` and re-encode and you get `<user><id>7</id></user>`, the same *value*
   in a different *document*. That belongs in the law's exception list, stated rather than
   discovered.

   **Decision B — how does a `[T]` field appear in XML?** Found by probing, previously
   undocumented: **arrays do not decode from XML today at all**, in any shape. So this is a
   decode decision that encoding merely forces, and it must be answered first because
   question 5 commits the encoder to writing only what `parse` accepts.
   *Recommendation: repeated sibling elements* — `<tags>a</tags><tags>b</tags>` — because it
   is the idiomatic XML, because the node model already exposes it (`elements(named:)`), and
   because the `RawValue` projection already **preserves** repeated members rather than
   dropping them the way a `Dictionary` would. The information is present and merely
   ungrouped; the change is to group repeated keys into a `.sequence` when the target field
   is an array. A wrapper element (`<tags><item>…</item></tags>`) is the alternative and is
   worse: it invents a name (`item`) that appears nowhere in the schema.

   An optional **Decision C** — the root element's name — can be deferred safely by
   defaulting to the type name and adding `@XML(root:)` later; nothing else depends on it.
4. **`Encodable` conformance synthesis**, which `EXPERIENCE.md` §14 already moved out of the
   refusals and which is strictly easier than any of the above.
5. **Encoding is unbenchmarked.** No number should be quoted for it until the harness has an
   arm, and the honesty rules apply to the encode direction exactly as to the decode one.
