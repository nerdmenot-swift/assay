# Assay — working context

Read this first. It is the settled state of a long design collaboration. `docs/EXPERIENCE.md`
(the developer experience) and `docs/PERFORMANCE.md` (the performance strategy) are the two
authoritative documents; `docs/research/` holds the seven research passes they were built from,
each with an explicit "do not assert these" section at the end.

**Status as of 2026-07-27: phases 1–3 are built, compiled, tested and measured.** A Swift 6.3.3
toolchain is present. The design-era caveat — "nothing here has ever been compiled" — no longer
applies to the parts listed below, and still applies to everything else. `ROADMAP.md` is the
authoritative list of what is deferred and why; `README.md` is the front door.

| | state |
|---|---|
| Experiments §15 #1 (jump table) | **run** — `Experiments/01-jump-table/RESULTS.md` |
| Experiments §15 #2–#4 (Builtin, packaging, `-mattr`) | **run** — `Experiments/02-builtin/RESULTS.md` |
| Experiment §15 #5 (Wasm simd128) | not run; needs the SDK, gates nothing before phase 4 |
| Corpus generator (the "sixth experiment") | **built** — `Benchmarks/Sources/CorpusGen`, 81 files |
| Phase-1 decoder + `@Schema` macro | **built** — 196 tests in 25 suites |
| Falsification condition | **PASSED, 5.44× over Foundation (8.64× float-dense)** — `Benchmarks/RESULTS.md` |
| Full corpus sweep | **built and run** — 9.17× struct decode (25 files), 6.43× prefix+skip (45), 1.49× generic value model (75) |
| Cross-platform | **three supported platforms, all gating**: macOS, Linux (x86-64 + aarch64) and Windows all run the test suite. Plus iOS build, static Linux (musl, 2 arches) and wasm32 cross-compiles. Android is not a target |
| Compile-time budget | **measured and gated** — ~87 ms/type at 10 fields rule-free (gate 100 ms), ~114 ms for a type with a rule on nearly every field (gate 145 ms) |
| Value models (`JSON.Value`, `YAML.Node`, `XML.Node`, `RawValue`) | **built** — `docs/VALUE-MODELS.md` |
| YAML and XML parsers | **built** — hand-written, XXE refused by construction |
| `@Extras` + `unknownKeys: .ignore/.warn/.reject/.collect` | **built**, with Damerau did-you-mean |
| `parse(mmapped:)` (`AssayFoundation`) | **built** — 216x less memory footprint, 3.6x faster |
| Renderers (`.terminal`/`.plain`/`.json`/`.problemDetails`) | **built** — golden caret tests |
| Source spans for YAML and XML | **built 2026-08-13** — schema issues carry carets on all three formats now. `RawValue.Member.span`, excluded from `==`/`hash`. ~2% on YAML, nothing elsewhere; sequence/dictionary *elements* still have no span |
| `@Validate` + rule engine | **built** — hand-rolled `.email`/`.url`/`.uuid`/`.hostname`, type-checked at expansion |
| `@Check` / `@AsyncCheck` / `@Preprocess` / `@Transform` / `@Fallback` | **built** |
| Enum conformances (`RawRepresentable` String/Int, `CaseIterable`) | **built** |
| Differential + fuzz | **built and gated in CI** — 75 files agree with `JSONSerialization`; 9,680 mutations/run |
| YAML/XML differential oracles | **built and green** — vs Yams/libyaml and Foundation `XMLParser`; found and fixed 2 real parser bugs (block-sequence dash, XML line-ending normalisation) on first run |
| YAML/XML benchmarks | **run** — 6.69× node parse vs Yams, 11.27× struct decode vs `YAMLDecoder`, 1.30× XML vs Foundation (asymmetric in Foundation's favour — read `Benchmarks/RESULTS.md` before quoting). The JSON thesis does not transfer; these are tree decoders |
| XML parser speed | **1.89× faster 2026-08-18/19** (1.75× then 1.08×) — 2.38× over Foundation on macOS (was 1.30×), **0.96× against libxml2 on Linux (was 0.54×)**, which is parity while building a tree libxml2's SAX path never builds. The win was `String.firstIndex` iterating by Character in namespace resolution, ~half of all parse time. `Benchmarks/RESULTS.md` |
| x86-64 benchmarks | **run 2026-08-20** on a GitHub-hosted runner — `.github/workflows/benchmark.yml`. **struct decode 10.89×**, the best of the three platforms; XML **1.39×** over libxml2-backed Foundation. Found an x86-64-only crash (a struct-returning libc call declared with `@_silgen_name`) that macOS and aarch64 Linux both ran green |
| Linux benchmarks | **run 2026-08-15** — `Benchmarks/linux-bench.sh`. Struct decode 8.64× (macOS 8.98×), so the thesis is not a Darwin artefact. **XML INVERTS: 0.54× on Linux against 1.30× on macOS**, because `FoundationXML` is libxml2 there. x86-64 needs a GitHub Actions runner; emulation was refused |
| Tests on Linux | **393/393 pass**, identical to macOS. The library has no platform-specific dependency — hand-written parsers are why. Only `DiffFuzz` is Darwin-pinned, on one `CFGetTypeID` call whose portable substitute costs 20× |
| Streaming | **out of scope**, decision recorded in `docs/STREAMING.md` |
| Encoding | **JSON + YAML + XML built** (`@Schema(encodes: true)`). YAML renders through the `RawValue` seam; XML cannot (placement is not expressible there) so it has its own generated body. XML defaults settled by surveying Jackson/Go/.NET/serde. The six semantics questions and their answers are in `docs/ENCODING.md`; round-trip is a stated law with a closed exception list |
| Allocation counts | **measured and gated** — live blocks, not total malloc traffic. Read `Benchmarks/Sources/AssayBench/Allocations.swift`'s three stated limitations before quoting a number |
| `Date` + `@DateFormat` (ISO-8601, unix, RFC 9110, patterns, candidate chains) + `.before/.after/.between` rules | **built and measured** — 6.06× vs Foundation `.iso8601`, 2,279-instant exact differential. Core stays Foundation-free: parsers return epoch seconds, the macro emits `Date(timeIntervalSince1970:)` into the user's module. `.past`/`.future` deferred (no clock seam) |
| `[String: T]` dictionary fields | **built and measured 2026-08-07** — both decode paths, recursive nesting, non-String keys diagnosed at expansion. The §2.5 "worst case" measured **6.95×** over Foundation; narrowing with size confirmed, loss did not materialise |
| `@XML` placement (`.attribute`/`.text`/`.wrapped`) | **built** — expansion-checked; `@XML(root:)` deferred |
| `KeyedSource` row path | **built, measured, REMOVED** — lost to the `RawValue` path (311 vs 95 ns), could not accept the `~Escapable` rows it existed for, cost 1.6–4.7× per row in a driver. `docs/KEYED-SOURCE.md` records why; do not rebuild it |
| `ColumnarSource` + `_assayBatch` | **built** — the surviving half. Field manifest, `BoundPlan` two-phase binding, Arrow-style validity masks. 1.27× the tree path at a flat ~53 ns/row; 1.03× called generically from another module |
| `T.validate(_:)` / `T.diagnose(_ value:)` | **built** — the schema's rules against an already-constructed value, which is the seam a fast external reader wants. 79 ns/value, 87 ns/row batched. `docs/VALIDATE.md` |
| Rule engine, allocation-free | **built and gated** — `.email` 179 → 25 ns, `.uuid` 50 → 28, `.min`/`.max` on String 22 → 14. Differential against the previous implementation as an oracle, 40,062 strings × 6 checks |
| `@Unknown` open enums | **built** — `@Schema enum` + `@Unknown case other(String)`; encoding refuses an unrecognised variant unless `roundTrips: true`. Closed enums still need no macro |
| `@Inline`, `@Wraps`, `Assayer<T>` | **not built** — `ROADMAP.md` |

Everything below that is not marked above is still design, not measurement.

### Named in the design documents and NOT built

`EXPERIENCE.md` is the API spec, written before the implementation, and it describes a
larger surface than exists. These are the pieces a reader will reach for and not find. Each
is a deliberate deferral with its reasoning in `ROADMAP.md`, not an oversight — but "settled
spelling" and "you can call it" are different claims, and this table is which is which.

| named | where | status |
|---|---|---|
| `@Key(path: "a.b")` | EXPERIENCE §4 | not built — `ROADMAP` §3 |
| `@Inline` | EXPERIENCE §4 | not built — `ROADMAP` §3 |
| `@Wraps` | EXPERIENCE §8 | not built — `ROADMAP` §6 |
| `Assayer<T>` | naming section below | not built — `ROADMAP` §7 |
| `@Schema(context:)` | EXPERIENCE §10 | not built — `ROADMAP` §8 |
| `parse(body:contentType:accepting:)` | EXPERIENCE §12 | not built — `ROADMAP` §9 |
| `parse(plist:)` | EXPERIENCE §1 | not built — `ROADMAP` §10 |
| `jsonSchema(for:)`, `StandardSchema` | encoding section below | not built — `ROADMAP` §11 |

---

## What Assay is

A Zod-inspired decoding-and-validation library for Swift, built on a macro rather than on
`Codable`. One sentence, from `EXPERIENCE.md`:

> Assay is not a validation library that also decodes. It is the decoder that tells you what
> went wrong.

```swift
@Schema
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var published: Date
    var tags: [String] = []
}

let article = try Article.parse(json: data)
```

Zero-rule `@Schema` is a first-class mode — Assay is a complete serde with no validation at all,
not an on-ramp to one.

## The governing principle

> **Language ergonomics and idiomatism is more important than porting what worked in another
> language in an exact same way.**

Stated by the user, still in force. When a Zod/serde/pydantic construct does not have an
idiomatic Swift spelling, the answer is a different construct, not a transliteration.

---

## Settled decisions — do not relitigate without cause

### Naming
- Module `Assay`, protocol `Assayable`, macro `@Schema`. The runtime value type is *named*
  `Assayer<T>`; it is not built (see the table above), and the naming argument below is why
  the name is settled in advance.
- The module **cannot** be named `Assayable`: macros are not hygienic and must emit
  `Assay.Assayer`; if the module were `Assayable` that parses as a nested-type lookup inside the
  protocol and fails, and it corrupts the generated `.swiftinterface` under library evolution.
  SE-0491's own motivation cites `Observation`/`Observable`.
- `Assayer<T>`, not `Schema<T>` — SwiftData exports `Schema`. A client `struct Schema` cannot
  shadow the macro (separate lookup namespaces); `@Assay::Schema` works via Swift 6.3 module
  selectors.

### The two verbs
- `try T.parse(json:)` → `T`, throws `AssayError`, discards warnings.
- `T.diagnose(json:)` → `Diagnosis<T>` with `.value`, `.issues`, `.warnings`, `.isValid`,
  `try d.get()`.
- `validate` was cut **as a third parse verb** — `T.validate(json:)` collided with
  `ParsableArguments.validate()` and Vapor's `Validatable.validate()`, and two of the three
  verbs had the same shape. That still stands.
- `try T.validate(_ value:)` / `T.diagnose(_ value:)` (2026-08-10) is a **different**
  function and does not reopen it: static, takes the value as its argument, decodes nothing,
  so it does not collide with an instance `validate()` on either protocol. It runs the
  schema's rules against a value something else produced — the seam for a fast external
  reader. `docs/VALIDATE.md`, and the law it holds: `T.validate(try T.parse(json: d))` never
  reports an issue.

### Issues
Code + params, **never** rendered strings (Ecto's `{template, params}` model). `.message` is
derived on demand; `message(locale:)` takes an identifier `String`, not a `Locale`.

### Rules
- `Rule` is **non-generic** — leading-dot `.min(1)` has no type context for a generic parameter.
- `Rule: ExpressibleByStringLiteral`, so `@Validate(.min(12), "message")` compiles despite the
  rule that a parameter after a variadic requires a label.
- The macro type-checks rule-against-field-type at expansion and emits a purpose-written
  diagnostic.
- `.custom { }` does not exist — a closure in an attribute has no type context. Use
  `@Check(\.field) static func f(_ x: String) -> String?`.
- `@Check` in an extension is permanently invisible to the macro → emit an error.

### Keys
**Built:** `@Schema(keys: .snakeCase)`, `@Key("id")`, `@Key("email", or: "email_address")`
(warns which alias matched), `@Extras var x: [String: RawValue]`,
`@Schema(unknownKeys: .ignore/.warn/.reject/.collect)` with did-you-mean.

**Decided but NOT built** — `@Key(path: "profile.display_name")` and `@Inline`. The spelling
is settled; there is no implementation. `ROADMAP.md` §3.

Rationale: `.convertFromSnakeCase` is lossy at runtime (`avatarURL → avatar_url → avatarUrl`);
converting at compile time from the declared identifier round-trips exactly.

### Five presence states
required / `String?` / `= 3` default (absent only, still validated) / `@Fallback(0)` (absent *or*
invalid, not re-validated) / `@Ignore`. `var x = 3` and `let y: Int = 3` are hard errors.

### Ordering
preprocess → coerce → decode → field rules → cross-field checks → transform → async checks.
`@AsyncCheck` makes `parse` async by a compile-time count; the sync pass collects everything
first, async runs only if sync was clean, then concurrently.

### Packaging
Products `Assay` (core + JSON), `AssayFoundation`, `AssayYAML`, `AssayXML`. Core takes bytes, not
`Data`. `platforms:` names **every** Apple platform (macOS 11 / iOS 14 / tvOS 14 / watchOS 7 /
visionOS 1) — listing macOS alone leaves the others on SwiftPM's ancient default rather than
unconstrained, which broke the iOS build until 2026-08-22. `Limits` (maxIssues 100, maxDepth 64, maxBytes) with
`d.truncatedIssues`. Embedded Swift is explicitly not a target.

**Decided but NOT built** — `parse(body, contentType:, accepting:)`, where `accepting:` is
required with no default (XXE / billion-laughs). The design point stands; the function does
not exist. `ROADMAP.md` §9.

### Encoding
A **deferral, not a refusal**. Placement data (`@Key`, `@XML`, `@DateFormat`) is preserved so the
encoder can be added without a redesign. `T.jsonSchema(for: .input)` is in the feature set.
`StandardSchema` ships as a separate zero-dependency package.

---

## Performance thesis, in one paragraph

**Assay does not need to beat simdjson. It needs to not have a `KeyedDecodingContainer`.**
ZippyJSON bolted simdjson onto `Decodable` and got 1.38× over Foundation (1.04× on the most
API-shaped payload). Apple's prototype that changes nothing about parsing and only deletes the
container protocol reports ~6×. ~83% of a Swift decode is the Codable boundary. The macro deletes
it at compile time.

**Falsification condition, written down on purpose:** if a scalar Swift phase-1 implementation
does not comfortably clear ZippyJSON's 1.38× over Foundation on the corpus in
`docs/PERFORMANCE.md` §12.2, the thesis is wrong and the SIMD/C work is moot. Do not proceed past
phase 1 without that number.

---

## Compile time is the second performance axis

`docs/COMPILE-TIME.md` is the third authoritative document. The short version:

**`@Schema` costs ~80 ms per type at 10 fields — about 3.6× `Codable`.** The cost model is
`9 ms fixed per type + 7.3 ms per field`, so it scales with **generated body size, not with the
number of expansions**. The plugin round trip is the small term.

That inverts the obvious optimization: "call the plugin less" buys nothing, "emit less code per
field" buys everything. Two measured wins already landed — never emit a 256-element array
literal (16%), and one line of generated code per field (a further 4%, 20% on wide types).

Why it is a gate and not a footnote: a developer replaces `: Codable` with `@Schema` across their
model layer in one commit and then waits for a build. **The adoption decision is made at compile
time, before the first runtime benchmark is run.** CI gates at 100 ms/type
(`Experiments/03-compile-time/gate.sh`); currently 87 ms.

## Hard constraints on generated code

These are not style preferences. Violating any of them silently destroys the performance thesis.

1. **Never `switch` over a `String`.** It compiles to `_findStringSwitchCase` — a literal O(n)
   linear scan with a full `String ==` per case. Not a hash, not a jump table.
2. ~~**Never assume `switch` over integer literals gives a jump table.**~~ **RESOLVED by
   experiment #1 — the concern was misplaced.** SILGen does lower integer-literal patterns to a
   comparison chain, but LLVM reforms it: **N ≥ 10 → a real jump table; N < 10 → a balanced
   binary search tree** (~⌈log₂N⌉ predicted compares). Never a linear scan. Mapping the candidate
   index to a dense enum is still worth doing — it removes the range check, and at small N one
   comparison level — but it is a small win, not the difference between a table and a scan.
   **x86-64 measured 2026-08-20 and the threshold is NOT target-independent: a table appears
   at N ≥ 4 for `UInt8` and N ≥ 3 for a dense enum**, so every realistic struct gets a real
   table there while arm64 uses a search tree below ten. The constraint holds on both, with
   more margin on x86-64. `TARGET=x86_64-apple-macosx13.0 sweep.sh` cross-emits the assembly,
   so this needs no x86-64 machine — only throughput does.
3. **Never capture the issue buffer in an escaping closure.** `inout [Issue]` is statically
   enforced and free; boxing it adds a `beginAccess`/`endAccess` pair per field.
4. **Emit many medium functions, not one giant flat decode body.** (This also serves the
   compile-time budget: per-field generated code must be one line, calling an `@inlinable`
   runtime primitive. Anything conditional belongs in `AssayCore`, not in the expansion.) Escape analysis has
   `getComplexityBudget = 1_000_000 / estimatedFunctionSize` (÷10 more for ARC), and budget
   exhaustion is *indistinguishable from "it escapes"* — the retains stay, with no diagnostic.
5. **`@inlinable` on every hot runtime leaf**, or cross-module specialization does not happen for
   a source package. **Never on generated bodies** — they are already in the user's module and
   already concrete, and SE-0193 restricts `@inlinable` to referencing ABI-public declarations,
   which makes every *public* `@Schema` type fail against its own internal memberwise init. Prefer `@_alwaysEmitIntoClient` / `@export(implementation)` to avoid ABI
   lock-in. Do **not** use `@_specialize` (opts out of CMO, cannot name user types) or
   `@_semantics` (closed list).
6. **Generated per-field code is concrete and monomorphic**, emitted into the user's module. No
   generic parameter to specialize is the whole reason a macro decoder can be fast in Swift.
7. **Decode stays synchronous.** `throws` returns in the callee-saved `swifterror` register
   (`r12`/`x21`); async functions do not get it.
8. **Index the hot path with `Span.subscript(unchecked:)`.** The checked subscript uses
   `_precondition`, which survives `-O`, and bounds-check elimination requires a linear induction
   variable — a data-dependent parser cursor is not one.
9. **No closures capturing `Span`-typed values in the hot path.** `mark_dependence` blocks closure
   specialization; one reported `MutableSpan` port cost +75%.
10. **Never `.unsafeFlags`.** Never `-enable-library-evolution`. Never benchmark at `-Ounchecked`.
11. **Unsafe code only below the dispatch seam**, and the seam's signature must be expressible
    entirely in `RawSpan`, `Span`, and values. An `UnsafeRawBufferPointer` in a public signature
    means the design is wrong.

## Entry point shape

```swift
extension User: Assayable {}

extension User {
    nonisolated static func _assay(
        from reader: inout AssayReader
    ) throws(AssayError) -> Self { ... }
}
```

`public protocol Assayable: Sendable` — marker protocol, zero runtime cost, and it prevents
`-default-isolation MainActor` inference. `AssayError` must stay pointer-sized (serde_json:
"a larger Error type was substantially slower").

---

## Build order

1. **Prove the thesis.** Scalar Swift scanner, macro emitting simdjson tier-1 window dispatch,
   monomorphic integer parsers, no-escape string fast path, whole-buffer UTF-8 validation up
   front, lazy source locations, `inout [Issue]`. No SIMD, no C. Benchmark vs Foundation, count
   allocations. → the falsification condition above.
2. **The unclaimed wins.** Hand-written ISO-8601 dates, unknown-key structural skip, exact-sized
   arrays, steady-state scratch reuse in `Assayer<T>`.
3. **Codegen discipline.** SIL dumps to count ARC traffic, `@inlinable` on hot leaves, split
   generated bodies, verify the dispatch lowering.
4. ~~**SIMD behind the seam**~~ — **RETIRED 2026-08-08, unbuilt.** Measured: UTF-8 validation is
   5.0–5.3% of decode on the API shape, so a *perfect* vectoriser buys ~5% there; the measured
   gap to hand-tuned C is ~1.5×. A 5% slice does not close it. `docs/PERFORMANCE.md` §14.
5. ~~**C**~~ — **RETIRED**, it was gated on phase 4's x86-64 numbers and phase 4 will not
   produce any.

## What the experiments actually said

**#1 — jump table: YES, and better than assumed.** A 50-arm switch over a `UInt8` candidate
index lowers to a real arm64 jump table (`ldrb` from `LJTI…` → `br x10`). The threshold is
**N ≥ 10**; below it LLVM emits a *balanced binary search tree*, ~⌈log₂N⌉ predicted compares,
not a linear chain. §4.1/§8's fear was true at SILGen and immaterial after LLVM. Mapping the
index to a dense enum is still worth doing — it removes the range check — but it is a small win,
not the difference between a table and a scan.

**#2 — `Builtin` intrinsics: resolve, emit real NEON.** `Builtin.bitcast_Vec32xInt1_Int32`
exists. arm64 lowering of `bitcast <16 x i1> to i16` is ~6 instructions against simdjson's
2-instruction `vshrn` — previously an open question.

**#3 — `BuiltinModule` survives versioned dependency resolution**, including an `@inlinable`
body referencing `Builtin` inlined into a client that has not enabled the feature.

**#4 — `-Xllvm -mattr=+avx2` does nothing.** Byte-identical output. This *closes off* the
"separate Swift module per ISA" route that `perf-simd-and-c.md` §2.7 listed as option 1. If
x86-64 AVX2 ever matters, C is the only way there.

## Start here now

Since resolved from this list: source spans for YAML and XML (2026-08-13 — `ROADMAP.md` §12,
carets on all three formats, ~2% on YAML and nothing elsewhere), `Date` and `@DateFormat` (2026-08-06 — built, measured at
6.06×, differentially verified; `ROADMAP.md` §2 records what remains deferred and why), and
the loss against yyjson (2026-08-09 — 0.66× on the use-case shape, 0.77× float-dense, 0.06×
DOM-vs-DOM, all published). What remains, in order:

1. **x86-64 numbers.** Linux is now measured (`Benchmarks/linux-bench.sh`, 2026-08-15) and
   the thesis holds there. x86-64 is not, and emulation would time the emulator rather than
   the code — `Experiments/01-jump-table`'s jump-table threshold is still arm64-only.
2. **Cold start**, where a macro emitting no `CodingKeys` should win structurally.

Three things that are done and worth not redoing: the allocation gate exists (live blocks,
with its limits documented rather than buried — `.mallocCountTotal` was rejected because
jemalloc cannot run on the musl or wasm legs), and the full corpus is swept in three passes
because one number could not answer three questions. And the rule engine has been measured
per rule and made allocation-free — `docs/VALIDATE.md` §4 — so "validation is slow" is a
claim that now needs a number, not an intuition.

**A design that was withdrawn, on purpose: the `KeyedSource` row path.** Built, benchmarked,
and removed the same week. It is worth knowing about because it is attractive enough to be
proposed again, and `docs/KEYED-SOURCE.md` and the header of
`Sources/AssayCore/ColumnarSource.swift` both carry the three reasons. The short form: its
justifying premise was never measured and was false, it lost 3.3× to the path it was meant to
replace, and it could not accept the `~Escapable` rows it existed for. `T.validate(_:)` is
what serves that use case, and the columnar half is what survives.

---

## Honesty rules for anything published

Never claim: "fastest JSON decoder"; "fastest on all platforms" (unmeasurable on 3 of 5);
"zero-allocation" or "arena-allocated" (`String`/`Array`/`Dictionary` go to `malloc` via
`swift_slowAlloc`; SE-0527 declined allocator generics); any ratio on a platform where the harness
does not run; any SSO-dependent claim without the length histogram.

Gate CI on allocation counts with absolute thresholds, never on wall clock. **Do not configure
`.instructions` on hosted runners** — `perf_event_open` fails, there is no PMU, and
package-benchmark silently reports zero, so the check is decorative.

The implemented gate measures *live* blocks per decoded value via `malloc_zone_statistics`, not
`.mallocCountTotal`: that metric needs jemalloc installed beside the toolchain and cannot run on
the musl or wasm legs at all. The trade is stated where it is made — live counting misses
transient allocations freed inside a decode, undercounts ~10-15% on Darwin's nano zone, and
cannot compare two decoders that retain the same data. A self-check measures closures whose block
count is arithmetic and disables the gate rather than reporting a number it cannot stand behind.
Total malloc traffic remains genuinely unmeasured and is listed as such in `ROADMAP.md`.

Every number in the docs belongs to someone else's C, C++, Rust or Go, cited as evidence about
*architecture*, not as a prediction about Assay's Swift. No credible published measurement exists
for bounds-check cost, exclusivity cost, ARC-as-%-of-runtime, or existential dispatch in ns/op in
Swift — do not put numbers for those anywhere.

## Corrected premises — do not reintroduce

- `.unsafeFlags` no longer blocks version-pinned dependencies at tools-version ≥ 6.2 (the reasons
  to avoid it are correctness reasons, not packaging ones).
- The Swift Static Linux SDK deletes musl's allocator and links mimalloc 2.2.4. The
  "musl's allocator is slow" argument is stale.
- `withUnsafeTemporaryAllocation`'s stack cliff is **1024 bytes**, not 4 KB.
- `String(unsafeUninitializedCapacity:)` is **SE-0263**, not SE-0309.
- **A `~Escapable` public type does NOT gate its clients** (verified 2026-08-19, Swift 6.3.3).
  `AssayReader.swift` and `docs/KEYED-SOURCE.md` both say a `~Escapable` type in the public
  surface "would put an experimental-feature gate on the whole library". Measured: a client
  package **consumes** one and calls its methods with no `enableExperimentalFeature` at all,
  and the escape check still fires — returning a borrowed view from a client function is a
  compile error. The gate only binds a client that wants to write its OWN `@lifetime`
  annotation. That premise has aged; the toolchain moved.
- **The real reason to refuse `~Escapable` in this API is value semantics, and it is
  decisive.** `Array` requires `Escapable`, so a node cannot have `children: [Node]` — the
  whole tree must become index- or pointer-linked. It cannot be stored in any escapable
  struct, cannot conform to `Equatable`/`Hashable`, and everything must happen inside the
  parsing closure. That is not a flag; it is a different product, and it is why the answer is
  "add a second API" rather than "reverse the decision".
- Foundation's `XMLParser` on Linux does **not** use Obj-C bridging. Do not assert it. It is
  `swift-corelibs-foundation`'s `FoundationXML` over **libxml2**, and it is fast: Assay's XML
  parser measures 0.54× against it on Linux while measuring 1.30× on Darwin. "Assay's XML is
  faster than Foundation's" is a Darwin-only claim.
- `import Builtin` needs `.enableExperimentalFeature("BuiltinModule")`, **not** `-parse-stdlib`.
- "Structs + generics + non-escaping closures = ARC-free" is folklore; only *transitively trivial*
  structs qualify.
- `ContiguousArray` vs `Array` for `UInt8` is a no-op off Darwin — literally the same type.
- Short keys (≤15 bytes on 64-bit) already produce immortal non-allocating `String`s; the real
  Foundation cost is the eager `Dictionary` + SipHash per object, not the `String`.

## Working style

The user prefers you proceed with judgment rather than stopping to ask clarifying questions.
State assumptions and continue.
