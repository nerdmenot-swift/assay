# Roadmap

What `docs/EXPERIENCE.md` specifies but this repository does not yet implement, with the reason
each one was deferred rather than cut. Nothing here is abandoned; several items are one
afternoon's work sitting behind a decision that has not been made carefully enough yet.

The ordering is by what a user is most likely to reach for and be surprised is missing.

---

## 1. Encoding

**Status: JSON and YAML encoding BUILT 2026-08-09; XML still blocked.** `EXPERIENCE.md` §14,
semantics in [`docs/ENCODING.md`](docs/ENCODING.md).

```swift
@Schema(encodes: true) struct Article { var title: String }
let bytes = try article.encode()            // throws AssayError, all issues
let d = article.diagnoseEncode()            // partial bytes + issues, same renderers
```

Opt-in, because generated body size dominates expansion cost and a decode-only type must not
pay for an encoder it never calls — the compile-time gate is unmoved at ~87 ms.

Five of the six semantics questions were answered, accepted and implemented; the sixth
(`@Unknown(roundTrips:)`) is blocked on `@Unknown` existing at all (§6). **XML encoding is
blocked on `@XML` placement** (§4): an encoder cannot guess attribute-versus-element, and
guessing is the exact ambiguity that attribute exists to remove.

YAML encodes through the `RawValue` seam — the decode pipeline run backwards — so the macro
never learns about YAML and XML will need a renderer rather than a macro change.

Round-trip is a stated law with a closed exception list, tested in
`Tests/AssayTests/EncodingTests.swift`.

This is the largest single gap, and it is deliberate: a decoder that also encodes has to answer
questions a decoder does not — what a `@Fallback` writes back, whether an `@Unknown` enum case
round-trips (either exactly right or a security hole, depending on who is asking), what
`@Transform` means in reverse when the closure has no inverse. Answering those badly and then
living with the answers is worse than not shipping them.

What matters is that the door is held open at real cost: **every piece of placement information
is preserved rather than consumed during decoding.** `@Key` renames, `@XML` element-vs-attribute
placement and `@DateFormat` patterns are all stored in the generated schema even though the
decode path does not read them back. That is why encoding is additive later instead of a
redesign, and it is being paid for now.

**Blocked on:** deciding the semantics questions in [`docs/ENCODING.md`](docs/ENCODING.md),
in writing, before any code. That document now exists — it enumerates six questions (this
section named three and miscounted them as five), states the options for each, and carries a
recommendation and its reasoning. **The recommendations are proposals awaiting a yes or no,
not decisions.** Accepting or rejecting them is the work that unblocks encoding; the last
section lists what building it then costs.

---

## 2. `Date`, and `@DateFormat`

**Status: implemented 2026-08-06**, measured at **6.06× over Foundation's `.iso8601`
strategy** on the `uuids-and-dates` corpus shape (`Benchmarks/RESULTS.md`), with a
2,279-instant exact differential against Foundation in DiffFuzz.

```swift
var created: Date                                  // ISO 8601, the default
@DateFormat(.unixSeconds)          var ts: Date
@DateFormat(.rfc9110)              var expires: Date   // all 3 forms RFC 9110 requires
@DateFormat(.pattern("yyyy-MM-dd")) var day: Date      // checked at compile time
@DateFormat(.iso8601, .unixMillis) var updated: Date   // candidate chain; fallback warns
```

The blocking question — where the epoch conversion lives, given the core's no-Foundation
rule — dissolved once the conversion was recognised as *arithmetic*, not calendar lookup:
Hinnant's days-from-civil is a handful of integer operations, so the parsers live in
`AssayCore/Dates.swift` and return epoch seconds as `Double`. The macro emits
`Date(timeIntervalSince1970:)` **into the user's module**, where `var created: Date` had
already forced a Foundation flavour into scope. No protocol, no retroactive conformance,
no `AssayFoundation` requirement — and the seam is pinned by a test that decodes into a
local stub `Date`.

Rules `.before` / `.after` / `.between` ship with it, type-checked at expansion, bounds
parsed once at rule construction, violations rendered as dates.

**Still deferred, with reasons:**

- **`.past` / `.future` rules.** They need "now", the core has no clock, and a clock seam
  is a design decision (injected? ambient? testable how?) that deserves its own pass.
- **Full UTS-35 patterns** (locale month names, eras). Deliberately excluded from the
  core forever — `EXPERIENCE.md` §11's ICU-cost argument — and still unbuilt in the
  Foundation-dependent layer where it would be an opt-in.
- **Date *encoding***, with the rest of encoding (§1). `@DateFormat` placement data is
  preserved for it.

---

## 3. `@Inline`

**Status: not implemented.** `EXPERIENCE.md` §4.

```swift
@Inline var page: Pagination     // page's keys are read from THIS level
```

serde's `flatten`, except that the macro knows `Pagination`'s keys at compile time, so
unknown-key handling still works correctly through it — precisely the thing serde's runtime
`flatten` cannot do.

`EXPERIENCE.md` §20 flags the open question honestly: two structs sharing one key namespace can
collide, a compile-time error is the right answer, and detecting it **across module boundaries**
where the macro cannot see the other type's members may be expensive or impossible. Shipping
`@Inline` with collision detection that works within a module and silently does not across one
would be worse than not shipping it.

**Blocked on:** whether cross-module collision detection is achievable at all.

---

## 4. Format-specific placement: `@XML` — and XML arrays

**Status: not implemented, and blocking XML encoding.** The XML *parser* is built and tested;
the *placement attributes* are not.

**Also found 2026-08-09, previously undocumented: `[T]` fields do not decode from XML at
all.** Neither repeated siblings (`<tags>a</tags><tags>b</tags>`) nor a wrapper
(`<tags><item>a</item></tags>`) decodes into a `[String]` field. Scalars work — attributes,
elements, or a mix of both, since the `RawValue` projection flattens all three into one
keyspace — but arrays fail, because the projection produces a `.mapping` with repeated keys
and the schema path expects a `.sequence`. Repeated members are preserved by the projection
(a `Dictionary` would have dropped them), so the information is there and ungrouped.

This matters for encoding beyond being a bug: `docs/ENCODING.md` question 5 commits the
encoder to targeting `.input` — writing the document `parse` accepts — so an XML encoder
cannot emit an array shape the XML decoder refuses. **XML encoding is therefore blocked on
two decisions, not one**, and they are listed in `docs/ENCODING.md`'s "what remains".

```swift
@XML(.attribute) var id: String
@XML(.element)   var title: String
@XML(.text)      var body: String
```

Without these, XML decoding maps elements to fields by name and cannot distinguish an attribute
from a child element. That covers a real slice of documents and not the interesting half.

**Blocked on:** nothing but the work, and a decision about the default when unannotated.

---

## 5. Shape-tolerance attributes

**Status: not implemented.** `EXPERIENCE.md` §9.

```swift
@OneOrMany var tags: [String]     // "swift" and ["swift","ios"] both decode
@PickFirst var id: StringOrInt    // tries each representation in order
```

These exist for APIs that are inconsistent about whether a single value is wrapped in an array —
which is most APIs that grew over time. `@OneOrMany` is genuinely small. `@PickFirst` needs a
sum-type story first, which is item 6.

---

## 6. `@Wraps` and `@Unknown`

**Status: not implemented.** `EXPERIENCE.md` §8.

```swift
@Wraps(String.self, .email)
struct EmailAddress {}            // storage, conformance, Equatable, Hashable, init?
```

A type that cannot hold an invalid value, from one line. The attribute goes on a **type
declaration** (the first edition's `@Wraps(...) var EmailAddress` was illegal three ways over
and is corrected in §8).

```swift
enum Status: String {
    case active, suspended
    @Unknown case other(String)   // forward compatibility for server-added variants
}
```

`@Unknown` is blocked on item 1: what an unknown variant does on the encode side is exactly the
kind of question that should be answered before the decode side commits to a spelling.

---

## 7. `Assayer<T>` — the runtime value API

**Status: not implemented, and genuinely under review.** `EXPERIENCE.md` §20, open question 6.

A value-level combinator API for schemas built at runtime, where there is no declaration for a
macro to read. The name is settled (`Assayer<T>`, not `Schema<T>` — SwiftData exports `Schema`).

The open question is whether it belongs in a 1.0 at all. Shipping it means committing to
maintaining two front doors forever, and the domain-type use case that motivates half of it
might be covered by a narrower protocol. That question should be answered before the code is
written, not after.

---

## 8. `@Schema(context:)`

**Status: not implemented.** `EXPERIENCE.md` §10.

Threading external state — a tenant ID, a feature flag, a database handle — into checks without
a global. The macro knows the context type at compile time and should use it directly; the
runtime `Assayer<T>` path keeps the type-erased form. Both are correct at their own layer.

Deferred because it has no users yet, and an API shaped for imagined users is an API shaped
wrong.

---

## 9. Content negotiation

**Status: not implemented.**

```swift
try Config.parse(body, contentType: header, accepting: [.json, .yaml])
```

`accepting:` is **required, with no default** — an unbounded format guess on untrusted input is
how you get XXE and billion-laughs. That decision is settled; only the code is missing.

---

## 10. Property lists

**Status: not implemented.** `EXPERIENCE.md` §1 lists `parse(plist:)`.

Binary and XML plists, as a separate product on the `RawValue` projection path the YAML and XML
decoders already use. Mechanically the smallest item on this list.

---

## 11. `jsonSchema(for:)` and `StandardSchema`

**Status: not implemented.** `EXPERIENCE.md` §§14–15.

```swift
let schema = Article.jsonSchema(for: .input)     // JSON Schema 2020-12
```

Emitting a JSON Schema document from a `@Schema` type, for OpenAPI generation and client
validation. `StandardSchema` conformance ships as a **separate zero-dependency package**, so
Assay never gains a dependency for the sake of an interop protocol.

Both need item 1's placement data to be complete before they can describe output shapes
faithfully.

---

## 12. Source spans for YAML and XML

**Status: partial, and the split is worth being precise about.**

*Syntax* errors in YAML and XML already render with carets, because the parsers report them from
a live cursor:

```
d.yaml:2:12: error: unexpected character in a flow collection; expected ',' or a closing bracket
  1 │ name: api
  2 │ replicas: [}]
    │            ^
```

*Schema* issues — a type mismatch on a field, a `@Validate` violation — do not:

```
d.yaml: error: replicas must be at least 1
```

The reason is structural. YAML and XML decode through the `RawValue` projection, and the node
trees drop byte offsets when they are built, so by the time a rule runs there is nothing left to
point at. JSON decodes straight from bytes and keeps its spans throughout.

Closing this means carrying offsets on `YAML.Node` and `XML.Node` and threading them through the
projection. Mechanical rather than hard, and the highest ratio of user-visible value to work on
this list — the caret is the headline feature and half the formats do not get it where it counts
most.

---

## 13. Streaming

**Status: out of scope, documented in `docs/STREAMING.md`.**

Not deferred — decided against, with the reasoning written down. `diagnose` returning issues
incrementally for very large documents is `EXPERIENCE.md` §20's first open question, and the
issue cap already covers the memory concern that motivates it.

---

## Known behavioural gaps found by the pre-release audit

| gap | state |
|---|---|
| **XML internal entities are not re-expanded** | `<!ENTITY a "&b;">` yields the literal `&b;` instead of resolving `b`. The expansion budget charges replacement length and never rescans, which is why the budget is trivially sufficient — but a nested-entity document reads differently from a conforming parser. The differential cannot adjudicate it either: Foundation's SAX mode drops internal entity references entirely. |
| **Compiled regexes are not cached** | `@Validate(.regex(...))` recompiles the pattern for every value validated, so a rule on an array element pays compilation per element. The rule array is a `static let`; the compiled regex cannot be, because the pattern is a runtime string. A cache needs synchronisation the validation path currently has none of. |
| **Anchors defined in flow style are not recorded** | `[&a x, *a]` does not resolve — `parseFlowNode` handles aliases but not anchor properties. Block style, which is where anchors are actually written, is unaffected. |

---

## Verification gaps

Not features, but they are equally part of "done":

| gap | what is missing |
|---|---|
| **Windows** | The CI leg is enabled and has never run — the repository has no remote. Cannot be built from macOS either, so every Windows claim is unverified. |
| **Android** | Same: the emulator job is configured, and has never run. |
| **x86-64 Linux performance** | CI builds and tests there; no benchmark numbers. Every published ratio is one arm64 Mac. |
| ~~**SIMD decoder comparison**~~ | **Closed 2026-08-08.** Measured against yyjson (hand-tuned C, `-O3`): **0.65×** on the use-case arm, **0.78×** on float-dense, **0.06×** DOM-vs-DOM. The predicted loss arrived and is published in `Benchmarks/RESULTS.md`. Still not compared to simdjson itself (C++, needs an interop shim) or to ZippyJSON. |
| **Multi-megabyte documents** | Outside the target band and unmeasured. The corpus stops at 64 kB. |
| ~~**`[String: T]` dictionary fields**~~ | **Closed 2026-08-07** — implemented on both decode paths, recursive, non-String keys diagnosed at expansion. The "worst case" measured **6.95× over Foundation** (`Benchmarks/RESULTS.md`); the predicted narrowing is visible in the size trend, the predicted risk was not. |
| **Total malloc traffic** | The allocation gate counts *live* blocks, which misses transient allocations freed inside a decode. `.mallocCountTotal` would catch those and needs jemalloc. |

---

## Phases 4 and 5 of the performance plan

`CLAUDE.md`'s build order runs to five phases. Phases 1 through 3 are done — the thesis is
proven, the unclaimed wins that were taken are taken, the codegen discipline holds.

**Both are RETIRED as of 2026-08-08, unbuilt, on evidence.** Not deferred — cancelled. The
plan always said "if the numbers say stop, stop and publish it"; the numbers said stop.

- UTF-8 validation, which is what a SIMD kernel replaces, is **5.0–5.3% of decode** on the
  API-shaped payload. A *perfect* validator therefore buys ~5% there, ~13.6% at absolute best on
  the friendliest shape.
- The measured gap to hand-tuned C (yyjson) is **~1.5×** on the use-case arm. A 5% slice does not
  close it.
- Phase 5 was gated on phase 4's x86-64 numbers. Phase 4 will not produce any.

Full reasoning and tables: `docs/PERFORMANCE.md` §14 and `Benchmarks/RESULTS.md`. `Sources/AssaySIMD/`
stays empty. Experiments #2–#4 remain valid and are worth keeping — they establish that `Builtin`
intrinsics resolve, emit real NEON, and survive versioned dependency resolution, and that
`-mattr=+avx2` does nothing. That is a door left open, not a plan.
