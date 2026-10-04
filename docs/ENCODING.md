# Encoding

Writing is the easy direction, right up until you ask what a *round trip* means. Then it
turns into six questions that all have to be answered the same way, or the answers contradict
each other.

This document is those six answers, the survey that settled the two XML ones, and the law
the whole thing is held to:

> For any `v` that `parse` produced, `parse(encode(v))` produces a value equal to `v` —
> except in five cases, named below.

That exception list is closed. Adding to it is an API change. Three of the five have a named
test, two do not yet; question 5 says which.

Encoding is opt-in — `@Schema(encodes: true)` — because the writer roughly doubles the
generated code and most types only ever read. It costs about 5% of the type's compile time
and measures about 8.75× `JSONEncoder` at fifty items. All four formats:
`encodes: true` emits a JSON writer, `.yaml` or `.toml` adds the `RawValue` projection those
two render from, and `.xml` gets its own body because placement is not expressible in
`RawValue`.

## The six questions, and where each one landed

| question | answer |
|---|---|
| Does a `@Fallback` write its value? | Yes. It is decode-time only, and that is round-trip exception #1. |
| Can an `@Unknown` case be written back? | Only if the declaration opts in with `roundTrips: true`. Otherwise refused. |
| How does a `@Transform` reverse itself? | `@Inverse`, and a `@Transform` without one is a compile error rather than a surprise. |
| Where do encode errors go? | The same `Issue`/`IssueSink` decoding uses, with `location: nil` — there is no document to point at. |
| Which face does it write? | `.input`. Round-trip is a law with five named exceptions. |
| Are defaults and `@Extras` written? | Both. A key collision between them is an encode-time error. |

## XML's two defaults were settled by survey, not by taste

The first draft of this document guessed at them. Guessing about a format everyone else has
already implemented is how you end up with the one library that behaves differently, so the
guesses were replaced by a look at what four established mappers actually do:

| | decision | who agrees |
|---|---|---|
| **A** · unannotated field | **element**, `@XML(.attribute)` / `@XML(.text)` opt in | Jackson (`isAttribute` defaults false), Go (`,attr` opts in), .NET, pydantic-xml. **None** defaults to an attribute. |
| **B** · unannotated array | **unwrapped repeated siblings**, `@XML(.wrapped)` opts in | Go and serde-xml-rs. Jackson and .NET wrap — and Jackson's wrapping default is one of the most-worked-around things in its XML support. |
| **C** · root name | the type's name, or `@XML(root:)`; `xmlText(root:)` overrides both | — |

The pattern worth recording: **the libraries whose XML support was designed from scratch
(Go, serde) chose unwrapped; the ones that retrofitted a JSON object mapper onto XML
(Jackson, .NET) chose wrapped.** Wrapping is the JSON-shaped answer — it preserves "one
key, one value" at the cost of inventing an element name that appears nowhere in the
schema.

`.wrapped` exists because unwrapped genuinely cannot express one thing: **absent versus
empty**. `<tags/>` is unambiguously an empty array; nothing at all is ambiguous. Assay
distinguishes missing from empty everywhere else (the five presence states), so that got an
opt-in rather than a caveat.

**XML does NOT go through the `RawValue` seam that YAML uses, and that is the finding.**
Placement is not expressible in `RawValue` and never will be — it is deliberately the narrow
intersection of the three formats. But placement *is* compile-time knowledge, so XML gets a
generated body like JSON's with the placement baked into the emitted calls.
`docs/VALUE-MODELS.md` §1 already said the value models cannot be unified because "a YAML
scalar's resolution and an XML element's namespace are not the same kind of thing"; this is
that arriving on the encode side.

**Found while building it:** `[T]` fields did not decode from XML *at all*, in any shape —
undocumented, and unrelated to encoding except that question 5 forbids writing what `parse`
cannot read. Fixed first: repeated siblings accumulate, `.sequence` still works for YAML,
and `@XML(.wrapped)` accepts a wrapper. `@XML(.text)` fields also now read the reserved
empty key the projection stores character data under.

**YAML encodes through `RawValue`, and that is the architecture, not a shortcut.** Decoding
YAML builds a `RawValue` and decodes from it; encoding projects the value to `RawValue` and
`YAML.encode` renders that. Two things fall out: the macro never learns about YAML —
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

`Tests/AssayTests/EncodingTests.swift` holds the law and the `@Fallback` exception; where
the other exceptions are tested, and which are not, is under question 5.

`EXPERIENCE.md` §14 records why encoding was first deferred rather than refused. The short
version: Zod is the only major library in this space that changed its mind about encoding
and it changed *toward* it, so refusing outright does not survive contact with the
evidence. What §14 also establishes is that **encoding is not decoding backwards** — every
library that went bidirectional built two engines, not one (Pydantic's Rust core: ~12k lines
of validators beside ~11k of serializers).

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

**Decision: write the value, and document `@Fallback` as decode-time-only with no
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

**Decision: `@Unknown(roundTrips: true)` opts in; the default is an encode-time error
(`unknown_not_encodable`) naming the type and the captured value.**

**The spelling first proposed did not compile, and that is worth recording rather than
quietly fixing.** It was `enum Status: String { case active; @Unknown case other(String) }`
— but a Swift enum with a raw type cannot have a case with an associated value; the two
features are mutually exclusive in the language. So the construct changed rather than being
transliterated, which is `CLAUDE.md`'s governing principle applied to a case it was written
for. The raw type goes away and `@Schema` supplies the mapping:

```swift-check
@Schema enum Status {
    case active, suspended
    @Unknown case other(String)
}
```

A **closed** enum still needs no macro — `enum P: String, JSONAssayable {}` has been the
whole implementation since day one and stays the primary path. `@Schema` on an enum without
an `@Unknown` case is an error that points back at it, rather than a second, slower way to
do the same thing.

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

**Decision: a separate `@Inverse({ (s: Set<String>) in Array(s) })` attribute, and a
type that requests encoding while carrying a `@Transform` without an `@Inverse` is a
COMPILE-TIME error with a purpose-written diagnostic.**

Two reasons this shape rather than a two-closure `@Transform`. First, a transform with no
inverse is *lossy* — that is arithmetic, not a design failure — so the design's job is to let
an inverse be supplied where one exists and to fail loudly where it does not. Second, the
macro can see both attributes and the declared types, so this is exactly the check it already
performs for `@Validate` rules against field types and for `@DateFormat` patterns:

```
error: 'tags' has a @Transform but no @Inverse, so this type cannot be encoded; add @Inverse({ (v: Set<String>) in /* -> [String] */ }), or remove `encodes: true`
```

Failing at expansion rather than at runtime is the house pattern and the reason the
non-generic `Rule` is type-safe anyway.

## 4. What is the encode-side error channel?

`EXPERIENCE.md` §14 states the problem: *"this value cannot be represented in this format" is
a different kind of problem from "this document is malformed."* A `Double.nan` in JSON is
the motivating case. And `Issue` carries `location: SourceSpan?` — a byte offset into a
source document that, on encode, does not exist.

**Decision: reuse `Issue` and `IssueSink` with `location: nil`, keep `path`, add
encode-specific codes, and mirror the two verbs.**

```swift
let bytes = try article.encodedJSON()      // EncodedBytes; throws AssayError, all issues
let d = article.diagnoseEncodeJSON()       // EncodeDiagnosis: partial bytes + issues + warnings
```

`SourceSpan` being nil is already a supported state — a missing-required issue has no
location today and renders fine. `path` is the part that matters and it is fully meaningful:
`coordinates[3].x cannot be represented in JSON`. The encode codes: `unrepresentable_value`,
`unknown_not_encodable`, `extras_key_collision`, and TOML's `toml_no_null` and
`toml_root_not_a_table`.

The thing to **not** do is invent a parallel `EncodeIssue`/`EncodeError` hierarchy.
`EncodeDiagnosis` is only the result type — bytes, issues, warnings — and it carries the
same `Issue` and renders through the same renderers. One error vocabulary, one set of
renderers, one mental model — and `.json` and
`.problemDetails` keep working unchanged for encode failures, which is a real win for a
service that validates and then re-serialises. Collecting rather than throwing on the first
problem is also the library's whole identity; breaking that on one side would be surprising.

## 5. Does the encoder target `.input` or `.output`, and is round-trip a law?

`jsonSchema(for: .input)` and `.output` genuinely differ once transforms exist — Zod shipped
the single-document version and corrected it in v4.

**Decision: the encoder always targets `.input` — it writes the document `parse` would
accept — and round-trip is a stated law with an explicit exception list.**

> For any `v` produced by `parse`, `parse(encode(v))` produces a value equal to `v`, except
> where a `@Fallback` fired, an `@Unknown` case was captured without `roundTrips: true`,
> unknown keys were dropped by a policy other than `.collect`, an **untagged union** has
> two variants whose types accept the same documents, or — **TOML only** — a table key
> holds a null.

The five, and where each is tested:

| # | exception | test |
|---|---|---|
| 1 | a `@Fallback` fired | `EncodingTests.swift`, "@Fallback writes its value" |
| 2 | an `@Unknown` case captured without `roundTrips: true` — the encoder refuses it | `UnknownEnumTests.swift`, "an unrecognised variant is REFUSED by the encoder unless it opted in" |
| 3 | unknown keys dropped by a policy other than `.collect` | **no named test** |
| 4 | an untagged union with two variants whose types accept the same documents | `UnionErrorTests.swift`, "two distinct types that accept the same documents are NOT refused" (pins that expansion cannot refuse it) |
| 5 | TOML: a null under a table key is omitted, so the key is absent on the way back | **no named test** — see the TOML section below |

The fourth was added 2026-09-10 with union encoding, and it is the only one the library
cannot see coming: the macro refuses two cases carrying the same payload *token*, and two
distinct `@Schema` types that happen to accept the same documents are indistinguishable to
it. `docs/UNIONS.md` §4. A **discriminated** union has no such exception — the tag names the
branch — which is one more reason to prefer one.

Two things this buys. Targeting `.input` is what makes the law true at all — with `@Inverse`
supplying the wire type, the encoder emits exactly the shape decode accepts. And stating it
as a law with a *closed* exception list turns round-trip from an emergent property nobody
tests into a property with a test suite and five documented holes. `jsonSchema(for: .input)`
then doubles as the encoder's published contract: one description, two uses.

## 6. Do defaults and `@Extras` get written back?

Not one of the original five questions, and it belongs with them — it has the same "you
cannot tell what happened on the way in" shape as `@Fallback`.

**Defaults — decision: always emit.** `var retries: Int = 3` writes `3`. Omitting when
a value equals its default is a footgun the moment a consumer's default differs, and
round-trip fidelity beats payload minimalism. If anyone genuinely needs the smaller document,
an `encodeDefaults: .omit` option (not built) would be additive later; the reverse is not.

**`@Extras` — decision: write them back, and make a collision with a declared key an
encode-time error (`extras_key_collision`).** Re-emitting is the entire point of having
collected them: a proxy that decodes, edits known fields and re-encodes must not silently
drop everything it did not recognise. This looks like question 2 but is not, and the difference is the whole reason to
answer them differently — `@Extras var rest: [String: RawValue]` is a declaration that the
author *wants to hold arbitrary data*, whereas `@Unknown` makes a type-system claim about
being a closed set and then quietly is not.

---

## TOML (2026-09-10)

Through the `RawValue` seam like YAML, with one rule the format forces: **TOML has no
null.** A nil member of a table is omitted — an absent key is what an optional field
decodes nil from, so the round-trip law holds for it — a nil array element is `toml_no_null`
with its path, never a silent substitution, and a root that is not a table is
`toml_root_not_a_table`.

**The omission is also round-trip exception #5.** The writer cannot tell an optional field
from any other table key, so *every* null under a table key is omitted — including a nil
dictionary value and an `@Extras` entry holding `.null`. Those decode back with the key
absent rather than present-and-nil, which is a different value: `["a": nil]` reads back as
`[:]`. It is reported nowhere, and **no test pins it yet**. Layout, quoting and the toml++
read-back oracle are in `docs/TOML.md` §4.

## What is still not being promised

Symmetry. `EXPERIENCE.md` §14's point stands: two engines, not one. These six answers shape
an encoder; they do not make one fall out of the decoder.

Document shape, either. The law is about values: decode `<user id="7"/>` into a type whose
`id` is unannotated, re-encode, and you get `<user><id>7</id></user>` — the same *value* in
a different *document*. That is not an exception to the law, and it is why `@XML(.attribute)`
exists.

## What remains

**`Encodable` conformance synthesis** is the one item not built. `EXPERIENCE.md` §14 moved
it out of the refusals, and it is strictly easier than the encoder itself.

## Throughput

The arm is `Benchmarks/Sources/AssayBench/EncodeBench.swift`: **8.75× at 50 items and 9.04×
at 200** over `Encodable` + `JSONEncoder` as of 2026-09-20, and 11.80× on a single-item
document where Foundation's fixed cost dominates. It was 2.85×/2.80× when first measured on
2026-09-08; the difference is `docs/EFFICIENCY.md` rows 5, 8 and 22 — one diagnostic path
per array rather than per element, key literals that carry their own comma and opening
quote, and a writer that owns its buffer instead of appending to an `Array` (36,004
uniqueness checks per call, gone). YAML and XML are reported as absolute ns/document rather
than ratios — there is no comparable Foundation encoder to divide by, and a ratio against
nothing is how a benchmark starts lying.

**A measurement, not a thesis.** The decode direction's 9× has an argument behind it:
deleting the `KeyedDecodingContainer` boundary. Encoding makes no equivalent claim —
`JSONEncoder` is one amount of machinery and Assay's writer is another, and whichever
wins, the number is a number. It exists so the cost is known and so a regression is
visible.
