# Roadmap

What `docs/EXPERIENCE.md` specifies but this repository does not yet implement, with the reason
each one was deferred rather than cut. Nothing here is abandoned; several items are one
afternoon's work sitting behind a decision that has not been made carefully enough yet.

The ordering is by what a user is most likely to reach for and be surprised is missing.

---

## 1. Encoding

**Status: BUILT 2026-08-09 for JSON, YAML and XML.** `EXPERIENCE.md` §14,
semantics in [`docs/ENCODING.md`](docs/ENCODING.md).

```swift
@Schema(encodes: true) struct Article { var title: String }
let bytes = try article.encode()            // throws AssayError, all issues
let d = article.diagnoseEncode()            // partial bytes + issues, same renderers
```

Opt-in, because generated body size dominates expansion cost and a decode-only type must not
pay for an encoder it never calls — the compile-time gate is unmoved at ~87 ms.

All six semantics questions were answered, accepted and implemented. The sixth
(`@Unknown(roundTrips:)`) was blocked on `@Unknown` existing at all; `@Unknown` shipped
2026-08-09 (§6), and encoding now refuses an unrecognised variant unless `roundTrips: true`.

YAML encodes through the `RawValue` seam — the decode pipeline run backwards. XML does not,
and cannot: placement is not expressible in `RawValue`, so XML has a generated body with
`@XML(.attribute)` / `.text` / `.wrapped` baked into the emitted calls. Both XML defaults
were settled by surveying Jackson, Go, .NET, serde-xml-rs and pydantic-xml rather than by
taste — see `docs/ENCODING.md`.

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

**Was blocked on:** deciding the semantics questions in [`docs/ENCODING.md`](docs/ENCODING.md),
in writing, before any code. That document enumerates six questions (this section originally
named three and miscounted them as five), and **all six were accepted and implemented on
2026-08-09** — its own header says so. The paragraph that stood here described them as
"proposals awaiting a yes or no" for some weeks after they had been answered and built.

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
- ~~**Date *encoding***~~ — **built 2026-08-09** with the rest of encoding (§1). The
  preserved `@DateFormat` placement data is what made it additive rather than a redesign,
  which was the whole bet §1 describes.

---

## 3. `@Inline` and `@Key(path:)`

**Status: neither implemented.** `EXPERIENCE.md` §4.

### `@Key(path:)`

```swift
@Key(path: "profile.display_name")  var displayName: String
@Key(path: "meta.tags[0]")          var primaryTag: String?
```

Pydantic's `AliasPath`. It saves declaring three throwaway structs to reach one field. The
`@Key` macro today takes `(_ name: String, or aliases: String...)` and has no `path:`
parameter at all, so reaching for this is a compile error.

Two things have to be decided before it is worth building, and neither is hard so much as
easy to get wrong:

- **Where the caret goes when a path misses.** `profile.display_name` can fail because
  `profile` is absent, because it is not an object, or because `display_name` is missing
  from it. Those are three different messages and three different offsets, and reporting
  all of them as "displayName is missing" would be the kind of vague error this library
  exists to avoid.
- **What it costs on the JSON path.** A declared key is resolved by the window-dispatch
  table built at expansion; a path is a walk. Whether it can share the dispatch machinery
  or needs a second pass over the object is unmeasured.

Until then, the honest answer is a nested `@Schema` type, which costs one declaration and
produces better errors.

### `@Inline`

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

**Status: BUILT 2026-08-09.** `@XML(.attribute)`, `@XML(.text)` and `@XML(.wrapped)` all
exist, checked at expansion (an `.attribute` on an array, or a `.wrapped` on a scalar, is a
compile error). `@XML(root:)` is the one deferred piece and nothing depends on it.

**The array bug this uncovered is also fixed.** `[T]` fields did not decode from XML at all
before 2026-08-09, in any shape — see below for what was wrong.

**What that bug was, and it is fixed in both shapes.** `[T]` fields did not decode from XML
at all: the projection produced a `.mapping` with repeated keys where the schema path expected
a `.sequence`. Repeated members were preserved (a `Dictionary` would have dropped them), so
the information was there and ungrouped. Both spellings now work, and they work differently
on purpose — verified 2026-09-08:

```swift
var tags: [String]                  // <tags>a</tags><tags>b</tags>  — repeated siblings
@XML(.wrapped) var tags: [String]   // <tags><item>a</item></tags>   — a wrapper element
```

Repeated siblings need no annotation because that is simply how XML spells a sequence. The
wrapper form does need one, and that is the right asymmetry: `<tags>` containing `<item>`
elements is indistinguishable from a nested object without the schema saying which it means.

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

**`@Unknown` is BUILT (2026-08-09).** It was blocked on item 1 — what an unknown variant does
on the encode side is exactly the kind of question that should be answered before the decode
side commits to a spelling — and that question is now answered in `docs/ENCODING.md` q2:
decoding captures anything unrecognised, and **encoding refuses it unless
`@Unknown(roundTrips: true)` opts in.**

The spelling above does not compile and has been corrected: a Swift enum with a raw type
cannot have a case with an associated value. `@Schema` supplies the mapping instead, and a
*closed* enum still needs no macro at all.

```swift
@Schema enum Status {
    case active, suspended
    @Unknown case other(String)
}
```

`@Wraps` is still unbuilt.

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

**Status: BUILT 2026-08-13.** Schema issues on YAML and XML now carry a caret, as JSON's
always have.

The gap was structural rather than an oversight. JSON decodes from bytes with the cursor in
hand, so a rule violation reports the offset it is standing on. YAML and XML parse to a node
model, project it to `RawValue`, and decode from that — and the byte offset was gone by the
time a `@Validate` rule ran. The same failure rendered with a caret through JSON and without
one through YAML, which is the wrong way round for the library's headline feature.

`RawValue.Member` now carries an optional `span`, filled by whichever parser knows the
offset. YAML records it per mapping pair, XML per element content and per attribute value —
inside the quotes, so a schema issue underlines the value and not the name. Every one of
those fields is **excluded from `==` and `hash`**, so two documents differing only in
whitespace stay equal; a span is provenance, not value.

Two things it cost, both measured:

- **~2% on YAML** (`YAML.parse` 6.86x over Yams to 6.69x; struct decode 11.50x to 11.27x),
  and nothing on XML or JSON. The first implementation cost **25%** by scanning forward from
  the value looking for a trailing comment, which is O(value) per pair; scanning backward
  from the end and stopping at the previous newline is O(one line) and got it back.
- Two guards keep the backward scan correct without tracking quote state: a value ending in
  a quote is a quoted scalar whose `#` is content, and a walk that reaches a newline is
  looking at a multi-line value that cannot have a trailing comment.

**Still without spans:** elements inside a sequence or dictionary value. `Member.span` is
per mapping member, which is the granularity a schema field needs — "the value at this key".
An `@Validate` rule on an array *element* reports with a path and no caret, exactly as it did
before.

## 13. Streaming

**Status: out of scope, documented in `docs/STREAMING.md`.**

Not deferred — decided against, with the reasoning written down. `diagnose` returning issues
incrementally for very large documents is `EXPERIENCE.md` §20's first open question, and the
issue cap already covers the memory concern that motivates it.

---

## Windows: diagnosed, and the first hypothesis was wrong

**Recorded because the wrong guess is the useful part.** `swift test` on Windows ended in
`error: fatalError` with no source location. This document previously blamed expansion size,
reasoning that Windows threads default to a 1 MB stack against Unix's 8 MB and that
swift-syntax walks generated source recursively — which is a coherent story, matches a note
already in `ci.yml` about WebAssembly needing a 16 MB stack, and is **not what was happening**.

A throwaway diagnostic workflow settled it in two runs by asking three questions at once:

1. Does the library build? **Yes.**
2. Does a minimal package containing one large `formats: .all, encodes: true` type build?
   **Yes** — so expansion size is not the trigger and the stack theory is dead.
3. What does a verbose test-target build actually print?

Question 3 gave nothing on the first attempt, because the generated decode bodies emit
hundreds of "trailing closure is confusable" warnings and a 120-line tail was every one of
them and none of the error. Rebuilding with `-suppress-warnings` produced a single line:

```
MappedFileTests.swift:51:9: error: '_open' is unavailable: Variadic function is unavailable
```

`_open` is variadic in ucrt — `int _open(const char*, int, ...)` — and Swift cannot import a
C variadic function. The cause was a Windows shim added days earlier in the belief it was the
portable spelling; it had never been compiled on Windows because Windows had never been
tested. The fix replaces POSIX `open`/`write`/`close`/`unlink` with `fopen`/`fwrite`/
`fclose`/`remove`, which are not variadic, are C89, and exist under exactly those names on
Darwin, Glibc, Musl and ucrt alike — so the platform branching disappeared rather than
gaining a third arm.

Two things worth keeping from this:

- **`error: fatalError` is SwiftPM saying "a compile subprocess died", nothing more.** It
  carries no location and no stack. The same message appeared while verifying this fix on
  Linux, where the cause was `signal 9` — four stray containers competing for a 4 GiB VM.
  Two entirely different causes, one message. Treat it as "something died, go find out
  what", and suppress warnings before theorising: the actual Windows diagnostic was an
  ordinary unavailability error buried under hundreds of them.
- **A plausible mechanism is not evidence.** The stack story explained the symptom, cited a
  real platform difference, and was wrong. It cost one diagnostic run to disprove and would
  have cost far more to act on.

## Known behavioural gaps found by the pre-release audit

| gap | state |
|---|---|
| **A skipped value's contents are not validated** | `skipValue` checks a value's EXTENT — matching brackets, string state, depth — and never what is inside it. `{"known": 1, "unknown": NaN}` decodes through a schema; `JSON.Value.parse` refuses it. Deliberate: skipping is what makes the prefix path 6.3x, and validating a value to discard it spends what skipping saves. Stated so it is a contract rather than a surprise — `T.parse(json:)` validates the structure and the fields it declares, not the whole document. |
| ~~**Compiled regexes are not cached**~~ | **Fixed 2026-09-08, 28×.** The pattern is compiled once at `Rule` construction — where `.before(_:)` already parses its ISO bound — rather than once per validated value. `.regex` went 12,427 ns → 439; `.each(.regex)` over 20 elements went 12,427 ns/element → 514. The stated blocker ("a cache needs synchronisation the validation path has none of") was real but pointed at the wrong fix: no cache is needed, and the synchronisation problem is that `Regex` carries **no `Sendable` conformance** while `Rule` must be `Sendable` to be a `static let` element. `CompiledPattern` is `@unchecked Sendable` and earns it — the initialiser warms the matching program with a throwaway match while the instance is still local, and a task-group test runs under `--sanitize=thread`. A global pattern→`Regex` cache was rejected: it hashes per value, needs a lock on a path documented as allocation-free, and grows unbounded. **There was no `.regex` row in the per-rule benchmark table** until this change, which is part of why the cost survived so long — it never appeared in the table anyone read. |
| ~~**Anchors defined in flow style are not recorded**~~ | **Fixed 2026-09-08.** `[&a x, *a]` resolves. Two things came out of it. The Yams/libyaml differential rejected the first version on its first run: it recorded `&q *p` as an alias, and an anchor on an alias is not YAML — an alias is a reference to an already-anchored node, not a node of its own. Block style had accepted that since anchors existed, silently discarding the anchor so a later `*q` failed with "undefined alias" and named the wrong problem; both paths now refuse it with `yaml_anchor_on_alias`. And the obvious rewrite — one `var node` with a shared exit — cost **3.3%** on the YAML node-parse arm by turning four tail calls into an Optional round-trip, so the unanchored path is left byte-for-byte as it was and the duplication is deliberate. **Flow tags (`[!!str 1]`) are the same shape and remain unhandled** — consuming them changes how documents that currently parse `!!str x` as a plain scalar behave, which is its own change. |

---

## The third decode path — built, measured, REMOVED

**Status: withdrawn 2026-08-10 on its own numbers.** `docs/KEYED-SOURCE.md` is the record.

A `KeyedSource` protocol for decoding one record at a time from anything already parsed and
addressable by key — database rows, CSV, plists, form data — was designed, built and
benchmarked. It was removed, and the reason is worth having on the roadmap rather than only
in a header, because the idea is attractive enough to be proposed again:

- **The premise was false and unchecked.** It was justified by "the `RawValue` path costs an
  allocation per value per record." `RawValue.mapping` is *one* allocation per record.
- **It lost to the path it was meant to beat**: 311 ns/record against 95 ns for building a
  `RawValue` and decoding through the tree path.
- **It could not accept the borrowed rows it existed for.** A zero-copy row view is
  `~Escapable`, and this library refuses an experimental-feature gate on its public surface.
- **Its cost landed per row in a driver**, where `@inlinable` is forbidden on generated
  bodies (SE-0193) and the witness-table call stands: 1.6–4.7×.

**What survives.** `ColumnarSource` and `_assayBatch`, behind `@Schema(sources: true)`: a
column store hands over whole arrays, so it has no per-row borrow, no per-row dispatch and no
per-row presence ambiguity — the three things that sank the other half. 1.27× over the tree
path at a flat ~53 ns/row, and 1.03× when called generically from another module.

**What replaces it.** `T.validate(_:)` — `docs/VALIDATE.md`. A specialised reader decodes at
its own speed in its own module, and Assay runs the rules afterwards. That is the seam the
decode path was reaching for, and neither side pays for the other.

Still deferred: nested and collection fields on a `sources: true` type, which remain compile
errors naming the field rather than runtime surprises.

## Verification gaps

Not features, but they are equally part of "done":

| gap | what is missing |
|---|---|
| ~~**Windows**~~ | **Closed 2026-08-29.** The row below is what this said until then, and it is worth keeping visible: *"The CI leg is enabled and has never run — the repository has no remote. Cannot be built from macOS either, so every Windows claim is unverified."* A remote exists, `Test (Windows)` runs on `windows-latest` on every push and gates, and it found a real bug on its first green-to-red transition — `_open` is variadic in ucrt and Swift cannot import C variadics, in a shim that had never been compiled on Windows because Windows had never been tested. |
| ~~**x86-64 Linux performance**~~ | **Closed 2026-08-20.** Measured on a GitHub-hosted runner via `.github/workflows/benchmark.yml`: **struct decode 10.89×**, the best of the three platforms, and XML **1.39×** over libxml2-backed Foundation. It also found an x86-64-only crash — a struct-returning libc call declared with `@_silgen_name` — that macOS and aarch64 Linux both ran green. `Experiments/01-jump-table`'s threshold is now measured on both architectures and is **not** target-independent: a table appears at N ≥ 4 for `UInt8` on x86-64 against N ≥ 10 on arm64. |
| ~~**SIMD decoder comparison**~~ | **Closed 2026-08-08.** Measured against yyjson (hand-tuned C, `-O3`): **0.65×** on the use-case arm, **0.78×** on float-dense, **0.06×** DOM-vs-DOM. The predicted loss arrived and is published in `Benchmarks/RESULTS.md`. Still not compared to simdjson itself (C++, needs an interop shim) or to ZippyJSON. |
| **Multi-megabyte documents** | Outside the target band and unmeasured. The corpus stops at 64 kB. |
| ~~**`[String: T]` dictionary fields**~~ | **Closed 2026-08-07** — implemented on both decode paths, recursive, non-String keys diagnosed at expansion. The "worst case" measured **6.95× over Foundation** (`Benchmarks/RESULTS.md`); the predicted narrowing is visible in the size trend, the predicted risk was not. |
| **Total malloc traffic** | The allocation gate counts *live* blocks, which misses transient allocations freed inside a decode. `.mallocCountTotal` would catch those and needs jemalloc, which cannot run on the musl or wasm legs at all — so closing this is either a bounded Darwin/Linux-only addition or a permanent gap, and it should be recorded as whichever it turns out to be. |
| **Encoding throughput** | Encoding has correctness oracles in `Benchmarks/Sources/DiffFuzz/` and **no performance arm at all** — `grep encode Benchmarks/Sources/AssayBench` returns nothing. `docs/ENCODING.md` §288 already forbids quoting a number until one exists; this row is that prohibition made visible. |
| **Cold start** | Named in `CLAUDE.md`'s "Start here now" and never measured. A macro emitting no `CodingKeys` should win structurally, which is exactly the kind of should that this file exists to stop anyone asserting. |

**A note on how two of these closed, because it is the more useful lesson.** The Windows and
x86-64 rows sat here describing a repository with no remote for some time after the remote
existed and both legs were green. Nothing detected that; a reader asking "what is unverified?"
was told something false by the document whose job is to answer exactly that. Rows here are
now expected to be struck through with a date and a number when they close, and a plan that
touches verification should re-read this table rather than trusting it.

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

## Small integer widths — BUILT 2026-08-31

`Int8`, `Int16`, `UInt8`, `UInt16`, `UInt32` and `UInt64` are field types on every path:
JSON, `RawValue` (YAML/XML), validation rules, all three encoders, and the columnar
manifest. `[UInt8]` works with them, and now maps to `bytesColumn` through the
`ColumnDecodable` conformance that was written and withheld — see
`docs/COLUMN-DECODABLE.md`.

**`UInt64` cannot reach its own maximum**, and that is inherited rather than introduced:
`scanInt64` returns `Int64`, so any unsigned value above `Int64.max` fails to scan. `UInt`
has had exactly this ceiling since it was added. Lifting it needs a `scanUInt64` in the
number parser — its own change, with its own tests. There is a test pinning the current
behaviour so whoever writes it finds a green assertion rather than a surprise.

Two pre-existing bugs surfaced while doing this and were fixed with it, both in the
functions being extended:

- **`decodeInt64` and `decodeInt32` never called `beginValue()`**, so validation carets on
  those fields pointed at the wrong bytes — for `{"wide": 999, ...}` the span came out as
  (lo: 0, len: 9), the start of the document. `Int` was correct, which is why it survived
  the golden caret tests.
- **`write(_ v: UInt)` reinterpreted the bit pattern** rather than converting, so every
  unsigned value above `Int64.max` encoded as negative: `UInt.max` came out as `-1`.
  Well-formed JSON carrying a different number, against a stated round-trip law. Not
  reachable by decoding, since the scanner caps input at `Int64.max`; reachable by any
  program that constructs the value and encodes it.

## Array element issues — FIXED 2026-09-08, and one worse thing found next to it

`[Int32]`, `[UInt8]` or any array with a bad element reported `[.key("xs")]` and named no
element. It now reports `[.key("xs"), .index(1)]`.

The index is passed to the decode primitive as a **scalar argument** and consumed inside the
cold `@inline(never)` failure path, so the emitted loop still contains no `path + [...]` and
allocates nothing per element — that is structural, not a hope that the optimiser sinks
something, and the emitted source was read to confirm it. Measured anyway: struct decode
8.94× before, 9.01× after; prefix+skip 6.19× before, 6.18× after.

**Not** the empty-`StaticString` sentinel the rule engine uses for the same purpose. The XML
projection stores an `@XML(.text)` field under a reserved EMPTY key, so a sentinel spelled
that way has a real collision in it. An explicit defaulted `Int` has none.

**The worse defect, found by a test written for this one.** A collection field whose whole
value is wrong — `{"xs": 5}` against `var xs: [String]` — reported an issue whose path was
**empty**. Not a missing index: no field name at all. Both the array and dictionary arms now
name the field. That is fixed here because it is the same three lines and the same reader,
and leaving it would have meant shipping a better element diagnostic next to a worse field
one.

**Still open:** an element inside a *nested* array (`[[Double]]`) gets the outer index only.
The inner index needs a prebuilt path prefix per outer element rather than a scalar, which is
a different trade — it is the one place this change would have added an allocation, so it was
not taken blind.

## The eagerly-built diagnostic path — RESOLVED 2026-09-07, no change needed

A report measured `path + [.index(__r)]` per row on the columnar path and
`path + [.key(k), .index(i)]` per element on the JSON path, and proposed removing both. Its
measurements reproduce exactly; its conclusion does not survive checking against the real
generated code.

**Columnar: the optimiser already does it.** Emitting the row path inside the failure
branches produces *byte-identical machine code* to emitting it once per row — same 548
instructions, same five `PathComponent` buffer calls, empty `diff` of the disassemblies. The
macro change was made, measured, found to be a no-op and reverted.

**JSON: not justified.** Deleting the concat outright from the macro, purely to measure,
moved a nested array element from 61.89 to 60.66 ns. The invasive redesign it was proposed
for — a parent pointer instead of a materialised `[PathComponent]`, touching `Issue`,
`IssueSink` and every `_assay` signature — buys nothing.

**The instability was the benchmark.** Every arm observed only `.count` of the decoded
array, which lets the optimiser discard the decode non-deterministically; that produced
~4 ns/row in some builds and ~45 in others and sent the investigation after a
specialisation theory that was wrong. Forcing the values live through an `@inline(never)`
consumer makes every arm stable. `@inlinable` on `SourceDecodable.batch(from:)` was tried
on the same wrong theory and had no reliable effect; also reverted.

`Benchmarks/Sources/AssayBench/DiagnosticPathBench.swift` keeps the measurements and the
methodological trap: a hand-rolled reproduction needs `@inline(never)`, which is exactly
what prevents the optimisation being measured, so reproductions look worse than the product.

