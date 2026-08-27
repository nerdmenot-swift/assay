# Assay — the performance strategy

*Second document. `EXPERIENCE.md` settled the shape: `@Schema`, `Assayable`, `Assayer<T>`,
two verbs, issues as code+params, keys before formats. This one asks what it would take for
that shape to also be the fastest thing in its category, and where unsafe code and C actually
earn their keep.*

*Status of the evidence: everything numeric below is either extracted from a primary source
(a repository read at a named path and line, a paper, a maintainer's own benchmark output) or
explicitly marked as unmeasured. **This document was written before anything here had been
compiled**, in an environment with no Swift toolchain: every claim about what Swift's optimizer
would do with Assay's generated code was a claim about the compiler's source, not about Assay's
binary. §17 listed five experiments that had to be run before any of it counted as a plan
rather than a hypothesis.*

*As of 2026-07-27 that caveat is largely discharged. Four of the five experiments have been run
(`Experiments/*/RESULTS.md`); the fifth gates nothing before phase 4. The falsification
condition in §14 has been tested and **passed at 5.44× against a threshold of 1.38×**, with a
full-corpus sweep in `Benchmarks/`. Where this document predicts and an experiment measures, the
experiment wins — read `CLAUDE.md`'s status table first, and treat every unmeasured passage here
as the hypothesis it was.*

---

## 0. The answer, in one page

**Assay does not need to beat simdjson. It needs to not have a `KeyedDecodingContainer`.**

That is the whole strategy, and the strongest evidence for it is adversarial. Somebody already
ran the experiment Assay would otherwise have to run: ZippyJSON bolted simdjson — the fastest
JSON parser in existence, the one with the peer-reviewed paper — onto Swift's `Decodable`, and
got **1.38× average over Foundation, and 1.04× on the most API-shaped payload in its own
benchmark set**. Its README now says, in its authors' own words, that `JSONDecoder` is faster
than ZippyJSON on iOS 17+. Meanwhile Apple's internal prototype that changes *nothing* about
parsing and only removes the container protocol reports **~6×**.

Put those two numbers side by side and the decomposition falls out: the parser is not the
bottleneck. Roughly five sixths of a Swift decode is structural overhead — existential
containers, per-key `String` allocation, a `Dictionary` per object, `codingPath` bookkeeping,
unspecialized generic dispatch — and roughly one sixth is looking at bytes. Assay's macro
deletes the five sixths at compile time. That is a larger, cheaper, and more certain win than
any amount of vectorization, and it is available on every platform without a line of C.

Six consequences, ranked by how much they change what gets built:

1. **The architecture already chosen is the biggest lever.** Direct-to-struct beats a tape by
   ~1.4× and beats anything dictionary-per-object by 2–7×, and it wins on *instruction count*,
   not just on skipped work. Nothing else on this list is worth as much.
2. **Do not build SIMD first, and possibly not at all.** yyjson is scalar C89 with zero SIMD and
   executes *fewer* instructions per byte than simdjson on the tweet corpus (4.62 vs 4.72), and
   on ARM it meets or beats simdjson's On-Demand path in half the benchmarks and beats its DOM
   path in all of them. Vector width is the last 15% on x86-64 and approximately 0% on ARM.
3. **C is optional, and should stay optional for v1.** The two operations everyone assumes force
   you into C — a byte shuffle and a movemask — are both reachable from ordinary Swift, and the
   standard library itself does exactly that. The one thing C still buys is per-function ISA
   targeting for runtime-dispatched AVX2, which matters on x86-64 and nowhere else.
4. **The remaining wins are allocation wins, not throughput wins.** Never build a `String` for a
   key. Never build a `Dictionary` per object. Never materialize a coding path. The number to
   lead the README with is an exact integer — allocations per decode — not a ratio.
5. **Always-collecting errors is free on the happy path**, and each piece of that has been
   checked separately: lazy line/column, a pointer-sized typed thrown error in a callee-saved
   register, an empty array that is a store of an immortal global. It stays free only if the
   generated code obeys three specific rules (§9).
6. **Swift's own codegen is the constraint that shapes the macro.** `switch` over a `String` is
   a literal linear scan with a full `String ==` per case. Escape analysis has a size budget and
   exhausting it is indistinguishable from failure. Cross-module specialization does not happen
   for a source package unless every hot primitive is `@inlinable`. These are not tuning knobs;
   they determine what the macro is allowed to emit.

And one thing Assay must never claim: **zero-allocation decoding.** `String`, `Array` and
`Dictionary` storage is hard-wired to `malloc` through `swift_slowAlloc`, with no allocator
parameter and no hook, and Swift Evolution looked at allocator generics in SE-0527 and declined.
The arena is real, but it is a *scratch* arena, and it buys steady-state zero *scratch*
allocations, which is a different and smaller sentence.

---

## 1. Where the time actually goes

### 1.1 The two experiments that were already run

**ZippyJSON.** simdjson underneath, `Decodable` on top. Measured 1.38× average over Foundation,
and **1.04×** on the payload shape closest to a real API response. That is the ceiling of "make
the parser faster and keep Swift's decoding API". Its source shows exactly why: every value
still crosses an existential container boundary, every key still goes through `CodingKey`,
and its own fast paths bail to Foundation on non-ASCII keys, custom key strategies, and
simulators. The convergence is the point — Foundation caught up, because Foundation was
optimizing the part that mattered.

**Apple's `new-codable` prototype.** Removes the container protocol, keeps the parser. Reports
**~6×** (Kevin Perry, 2026-03-06). It is on an experimental branch and currently build-broken
(swift-foundation #2074), which is a scheduling fact, not an evidentiary one.

Two experiments, opposite ends, same conclusion: **~83% of a Swift decode is the Codable
boundary.**

### 1.2 What Foundation actually does per object

Foundation's `JSONDecoder` in 2026 is genuinely good — and this matters, because the honest
framing is not "Foundation is slow" but "Foundation is a good scanner wearing a costume it
cannot take off". It builds `JSONMap`, a flat `[Int]` index with `nextSiblingOffset` for O(1)
subtree skipping and zero copies of non-structural data. That is a competent design. It is lazy
right up until `Decodable` asks for a keyed container, and then `KeyedContainer.stringify`
eagerly materializes `[String: JSONMap.Value]`.

The consequence is worth stating precisely, because the obvious version of it is wrong. It
allocates one `String` per key **present in the payload**, not per key the struct asks for. A
forty-field object read for three fields pays forty `String` constructions, forty SipHash
computations, and one `Dictionary` allocation and its rehashing. This is the single biggest
algorithmic target in the Swift decoding stack, and it is entirely structural: no amount of
faster byte scanning touches it.

`codingPath` is already deferred in Foundation via `_CodingPathNode`, a linked list rather than
an array — worth stealing, and worth *not* claiming as a win Assay invented.

### 1.3 The published architecture comparison

From `simdjson/json_benchmark_results` v0.8.0 — the only public dataset that measures simdjson
DOM, simdjson On-Demand and yyjson on one machine with hardware counters. Skylake, 4.0 GHz,
clang 11, `twitter.json` at 631,515 bytes.

| benchmark | parser | GB/s | ins/byte | cyc/byte | branch misses |
|---|---|---|---|---|---|
| partial_tweets | simdjson_dom | 2.29 | 4.72 | 1.612 | 3,558 |
| partial_tweets | **simdjson_ondemand** | **3.15** | 3.59 | 1.171 | 2,141 |
| partial_tweets | yyjson | 1.76 | **4.62** | 2.094 | 9,848 |
| partial_tweets | sajson | 1.06 | 9.31 | 3.471 | 10,098 |
| partial_tweets | rapidjson | 0.29 | 34.67 | 12.803 | 29,651 |
| partial_tweets | nlohmann_json | 0.08 | 127.16 | 48.271 | 150,200 |
| large_random (all floats, **all fields used**) | dom / ondemand | 0.52 / **0.70** | 22.58 / **14.61** | 7.150 / 5.239 | — |
| kostya (floats, one field skipped) | dom / ondemand | 1.49 / **2.25** | 7.17 / **4.74** | 2.472 / 1.636 | — |

The `large_random` row is the one that settles the architecture question. Every field is used,
so On-Demand skips nothing — and it still executes **35% fewer instructions** than the tape.
The saving is not "we avoided reading some of the document". It is that materializing a generic
intermediate representation and then reading it out costs real work per value even when every
value is wanted. Cross-checked in Rust: serde_json deserializing into a struct runs at ~580 MB/s
against ~320 MB/s into its DOM, and sonic-rs's DOM path is 3.4–6.8× slower than its struct path.

Assay's macro path is the struct path. It starts on the right side of a 1.4–2× architectural
gap before anyone writes a scanner.

---

## 2. The scalar-C result, and why it changes the build order

yyjson is C89, no intrinsics, no SIMD, one file. On the Skylake run above it executes **fewer
instructions per byte than simdjson's DOM** (4.62 vs 4.72). It loses on wall clock there because
of branch misses — 9,848 against 3,558 — not because it does more work.

On ARM, from the same dataset (Ampere Altra / Neoverse N1, 3.3 GHz):

| benchmark | simdjson_dom | simdjson_ondemand | yyjson | yyjson_insitu |
|---|---|---|---|---|
| partial_tweets | 0.40 | 0.60 | 0.60 | **0.62** |
| distinct_user_id | 0.41 | 0.61 | 0.60 | **0.64** |
| find_tweet | 0.42 | **0.70** | 0.63 | 0.66 |
| top_tweet | 0.41 | 0.61 | 0.62 | **0.65** |
| large_random | 0.15 | 0.23 | 0.23 | 0.23 |
| kostya | 0.36 | **0.54** | 0.48 | 0.51 |

**Scalar C meets or beats SIMD On-Demand in three of six, and beats SIMD DOM in all six.** For a
library whose primary targets are Apple Silicon and ARM Linux servers, this is the load-bearing
fact in the entire research corpus. simdjson performs no ARM microarchitecture dispatch at all;
its NEON kernel is the same code everywhere.

The Rust cross-check is even blunter: simd-json (a direct port of simdjson) against serde_json
on struct deserialization of `canada.json` measures **580 MB/s versus 580 MB/s**. Identical.
When the destination is a struct, the vectorized structural indexer buys nothing.

What yyjson actually does instead, and all six are expressible in Swift:

- one allocation for the whole document, sized by a byte-count heuristic;
- a flat array of fixed-size nodes, no pointer chasing;
- zero-copy strings when the value contains no escape;
- a 16×-unrolled table-driven character scan;
- whole-parser specialization — separate compiled parsers for the common flag combinations,
  so option checks vanish rather than branching per value;
- cold-marking the rare paths so the icache holds the hot ones.

Assay's macro is a *better* version of point five: yyjson specializes on parser options at
compile time, Assay specializes on the entire schema at compile time.

**Build order consequence:** the scanner is written in plain Swift first. SIMD is a later,
optional, seam-local change. Anyone who starts with the vector kernel will spend their first
month on the term the data says is worth ~15% on one architecture and ~0% on the other.

---

## 3. The core loop

### 3.1 Single pass, no rewind, presence in a bitmask

serde is single-pass: it emits `Option<T>` locals per field, fills them as keys arrive in
whatever order the payload happens to use, never rewinds, and resolves missing-required at the
end. simdjson's On-Demand `find_field_unordered` does the opposite — it rewinds and rescans,
which is O(N²) in the worst case — and **simdjson has abandoned that model for its new
reflective path**, which is serde's design plus a compile-time dispatcher. That is precisely
what Assay is. Two independent projects converged on the shape Assay already has; take the
convergence as confirmation and do not invent a third model.

Presence tracking is a `UInt64` bitmask, one bit per declared field, set when a key matches.
Missing-required is then `~mask & requiredMask` — one AND-NOT, one compare against zero — and
the fields to report are the set bits, walked only in the failure case. Above 64 fields, an
`InlineArray` of words; the common case never leaves a register.

This maps exactly onto the five presence states from `EXPERIENCE.md`:

| state | mechanism |
|---|---|
| required | bit in `requiredMask`; absence is `~mask & requiredMask` |
| `String?` | not in `requiredMask`; local stays `nil` |
| `= 3` default | not in `requiredMask`; local initialized to the default, then validated |
| `@Fallback(0)` | not in `requiredMask`; on absence *or* on any issue at this field, assign and clear the issue, do not re-validate |
| `@Ignore` | not in the dispatch table at all; skipped as an unknown key |

The `@Fallback` case is the only one that needs a mark in the issue list, so it can be truncated
back on assignment. Everything else is bit arithmetic.

### 3.2 The generated entry point

```swift
extension User: Assayable {}

extension User {
    nonisolated static func _assay(
        from reader: inout AssayReader
    ) throws(AssayError) -> Self { ... }
}
```

Concrete, non-generic, emitted into the *user's* module. That last part is why it can be fast at
all — it needs no cross-module specialization, because there is no generic parameter to
specialize (§8.2).

`public protocol Assayable: Sendable` — `Sendable` is a marker protocol with exactly zero runtime
cost, no witness table, and no calling-convention change, and inheriting it prevents
`-default-isolation MainActor` from silently inferring main-actor isolation onto every conforming
type in an app that enables it. Free correctness.

**Decode stays synchronous.** A `throws` function returns its error in the callee-saved
`swifterror` register (`r12` on x86-64, `x21` on arm64), which is why the happy path pays nothing
for the possibility of throwing — but **async functions do not get that register**. `@AsyncCheck`
therefore runs strictly after the synchronous decode completes, which is already the ordering
`EXPERIENCE.md` specifies for a different reason. Two independent arguments for the same design
is a good sign.

### 3.3 The reader

`AssayReader` wraps a `RawSpan` over the input bytes plus a cursor plus a reference to the
scratch arena. It is a `~Escapable` struct; `Span`/`RawSpan` give compile-time lifetime safety
with no runtime representation.

One caveat that is easy to get wrong: `Span`'s checked `subscript` uses `_precondition`, which
**survives `-O`**. Bounds-check elimination for it requires a linear induction variable iterating
`0..<count`, and a data-dependent parser cursor is definitionally not that. So the internal hot
path indexes via the public `subscript(unchecked:)` — which is public, documented, and free —
with the safety argument carried by the parser's own invariants and the padded-buffer discipline,
not by the compiler.

A second caveat: avoid closures that capture `Span`-typed values in the hot path. The
`mark_dependence` instruction that enforces the lifetime blocks closure specialization; one
reported `MutableSpan` port cost **+75%** for exactly this reason.

---

## 4. Field dispatch

### 4.1 What not to do

**Do not `switch` over a `String`.** In Swift this compiles to `_findStringSwitchCase`, a literal
O(n) linear scan performing a full `String ==` per case. It is not a hash lookup and it is not a
jump table. This is not a micro-detail; it silently converts the most-executed decision in the
decoder into the worst thing on the list.

**Do not `switch` over integer literals either, expecting a jump table.** SILGen treats integer
literal patterns as wildcard `ExprPattern`s and lowers them to a comparison chain at all
optimization levels. Only a `switch` over an **enum** produces a real jump table. If the field
dispatch needs a jump table, the candidate index must be an enum case or must reach LLVM as a
genuine `switch` on an integer — which is exactly experiment #1 in §17, because it is currently
an assumption.

**Do not build a perfect hash.** rust-phf loses to a plain `match` at N ≈ 300 in three of four
key positions. gperf-style tables are tier 3 in simdjson's own dispatcher, reached only after
two cheaper tiers fail. A JSON object with 300 distinct keys is not the workload.

### 4.2 What to do: the unaligned 8-bit window

simdjson's `key_selector.h` is a `consteval` compile-time key dispatcher, and its **tier 1** is
what Assay's macro should emit. In simdjson's own words:

> Many small key sets can be told apart by inspecting a *single* 8-bit window of the key bytes —
> and that window need not be byte-aligned. Because every JSON key is terminated by a `"`, the
> bytes at and before a key's length are well defined for any key at least that long: byte i is
> the key character when i is inside the key and the closing quote when i == len. So we read two
> bytes at a fixed offset, extract 8 consecutive bits at a fixed intra-byte shift, and if that
> value is distinct for every key, a 256-entry table maps it straight to a candidate key.

Two details make it work, and both are non-obvious.

**The virtual quote byte.** At index == length, the key's byte is defined to be `'"'` (0x22)
rather than out of bounds. That is what separates `{"jo","joe"}` with no length test at all, and
it is why the confirming compare needs no separate length compare — it fuses into the content
compare the way simdjson's `unsafe_is_equal` does:
`(raw()[target.size()] == '"') && !memcmp(raw(), target.data(), target.size())`.

**The unaligned shift.** Allowing a shift of 1..7 mixes bits from two adjacent bytes, which
discriminates key sets no aligned byte can. simdjson's worked example: the `partial_tweets` keys
`{created_at, id, text, in_reply_to_status_id, user, retweet_count, favorite_count}` collide at
every aligned position 0, 1 and 2 — yet the eight bits starting at bit offset 2 are unique across
all seven.

The search the macro runs at expansion time is the same one simdjson runs at `consteval` time:

```
for offset in 0...minLen {
  for shift in 0..<8 {
    if shift != 0 && offset + 1 > minLen { continue }
    if windowValue(k, offset, shift) is distinct across all keys {
      emit 256-byte table; return
    }
  }
}
```

Runtime cost per key: `loadUnaligned(fromByteOffset:as: UInt16.self)`, a shift, a mask, a table
index, and one fixed-length compare whose length is a compile-time constant because the candidate
index is. That is roughly six instructions to identify a field.

**Aliases fall out for free.** `@Key("email", or: "email_address", "mail")` flattens all three
strings into the candidate set before the window search runs, mapping three window values to one
field index. serde does the same thing as extra match arms at runtime; Assay resolves it at
compile time. This is a case where a design chosen for ergonomics in `EXPERIENCE.md` happens to
cost nothing.

### 4.3 The fallback ladder

When the window search fails — and the macro knows at expansion time whether it did:

1. **Length bucket plus `UInt64` word compares.** `switch keyLength` (over an integer, so see
   §4.1's caveat — bucket via a computed branch or an enum), then compare eight bytes at a time
   within the bucket. Keys longer than eight bytes chunk into consecutive `UInt64`s with the
   final chunk *overlapping* the previous one rather than masking a partial tail; the length is
   known from the quote position, so the overlapping read is in bounds.
2. **gperf-style associated-value sum**, only if N grows past ~50 or the window search fails on a
   pathological set.

Case-insensitive matching, if it is ever offered: `| 0x20` is a *filter*, never the test.
It is injective-safe only on `[A-Za-z]`; it also folds `@`↔`` ` ``, `[`↔`{`, `\`↔`|`, `]`↔`}`,
`^`↔`~`, and `_`↔`DEL`. Digits already have 0x20 set, so digits are safe. Use it to pick a
candidate, then confirm with a real ASCII case-insensitive compare; a false positive costs one
wasted branch.

### 4.4 The unknown-key path

`@Schema(unknownKeys:)` has four modes, and the performance-relevant one is `.ignore`, which must
skip the value without decoding it. That is a depth-counted structural skip: count `{`/`[` against
`}`/`]` while respecting string state, and never touch the contents. Foundation's `JSONMap` gets
this right with `nextSiblingOffset` for O(1) subtree skip — steal the idea, but Assay's version is
a forward scan rather than an index lookup, because Assay has no index.

Unknown keys are extremely common in real API payloads and are **completely unmeasured** in every
published JSON benchmark. That is both an opportunity and a corpus requirement (§13).

---

## 5. Strings — the second-biggest win, obtained by not creating them

### 5.1 Keys

Never allocate a `String` for a key. This is the direct counter to Foundation's `stringify`, and
IkigaJSON already demonstrates the technique in Swift: compare the `CodingKey`'s UTF-8 bytes
directly against the source bytes with a length precheck, allocating nothing. Assay goes further,
because the macro knows the key set at compile time and can use §4's window instead of a linear
byte compare.

One prior hypothesis is **partially falsified** and should not be repeated: short keys (≤ 15 UTF-8
bytes on 64-bit) already produce an immortal, non-allocating, non-refcounted `String` via the
small-string optimization. So "we avoid allocating a String per key" is not automatically true for
short keys. The real Foundation cost is the eager `Dictionary` construction plus SipHash per key,
not the `String` itself. State the win as *"no Dictionary and no hashing per object"* — that is the
part that is unambiguously true, and it is the bigger term anyway.

### 5.2 Values

The fast path is the no-escape path: scan for the closing quote, and if no backslash was seen,
the value is a contiguous byte range that can go straight into a `String` with one copy — or
zero, in the in-situ case, which Assay cannot use because it does not own the caller's buffer.

Two Swift-specific traps:

`String(decoding:as: UTF8.self)` validates and repairs — two passes over the bytes. It is the
correct default and the wrong hot path.

`String(unsafeUninitializedCapacity:)` (SE-0263, not SE-0309 — the number is commonly misquoted)
is the one-copy path, but it branches on the **declared** capacity, not the written count. Declare
above the small-string threshold and it heap-allocates even if you write three bytes. So the
declared capacity must be the true byte count, which the scanner knows exactly because it found
the closing quote before constructing anything.

The small-string threshold is **not 15 everywhere**:

| platform | threshold |
|---|---|
| 64-bit (Darwin, Linux, Windows) | 15 |
| Android arm64 | 14 |
| 32-bit watchOS | 10 |
| all other 32-bit, **including wasm32** | **8** |

Any claim of the form "most API strings are free" silently inverts on Wasm, where an 8-byte
threshold means almost every real string allocates. Assay must never publish an SSO-dependent
claim without publishing the length histogram of the corpus alongside it (§14).

### 5.3 Escapes

The escape path is a separate function, cold-marked, that copies into the scratch arena and
resolves `\uXXXX` including surrogate pairs. swift-extras-json's branch-free `hexAsciiTo4Bits` is
worth stealing; IkigaJSON's `firstIndex(of:)`-based hex decode is not.

The fork between "can memcpy" and "must transform" is one of the largest in any decoder, which is
why the corpus needs an `escaped` dimension (§13).

### 5.4 UTF-8 validation

One whole-buffer pass at entry, never per-string. serde_json's per-string validation costs
**1.65×**. simdjson gets validation for free by fusing it into the structural pass; yyjson
validates scalar, always-on, strings only.

Assay's position: validate the whole input buffer once, up front, then treat every byte range
carved out of it as known-valid and build `String`s with the unchecked constructor. This is a
correctness-preserving trade — it does strictly more validation than a lazy decoder, at a cost
that is one linear pass with excellent ILP, and it removes validation from every subsequent
string construction.

The precise caveat: this is only sound if the input is a single contiguous buffer that does not
change underneath the parse. `RawSpan` guarantees exactly that, which is a second reason the
public API takes bytes and not a stream.

---

## 6. Numbers

### 6.1 Integers matter; doubles mostly do not

For API payloads the integers are one to six digits — IDs, counts, status codes, timestamps.
**The SWAR eight-digit trick is a loss at that width**, and both simdjson and yyjson use plain
digit loops for short integers. Do not port it.

What to emit instead is a monomorphic parser per integer type, accumulating negatively
(`acc = acc &* 10 &- digit`) so that `Int.min` needs no special case, and skipping the per-digit
overflow check for the first `String(T.max).count - 1` digits, where overflow is arithmetically
impossible. Monomorphic per type, emitted by the macro, so there is no generic `FixedWidthInteger`
dispatch at all.

### 6.2 Doubles

Eisel-Lemire (`fast_float`) is genuinely excellent and genuinely not the priority. Go's adoption
of it improved the primitive by **44%** and improved end-to-end `canada.json` — the most
float-dense file in the standard corpus — by **1.08×**. On an API payload with three floats, the
end-to-end effect is unmeasurable.

Swift's own state changed recently: `Double(String)` is now pure Swift (swiftlang/swift#85797),
but swift-foundation's JSON path still calls `strtod_l`, which is a locale-aware C function and
a real cost. Assay should not call `strtod` — that much is clear. Whether v1 ships a full
Eisel-Lemire or a correctly-rounded Clinger fast path with a slow fallback is a decision to make
against a measured corpus, not in advance. What is not negotiable is **correct rounding**;
IkigaJSON's `strtodSpan` is incorrect here and that is a bug, not a trade-off.

### 6.3 Dates — genuinely unclaimed territory

Foundation decodes `.iso8601` by building a full `String` and then calling
`Date.ISO8601FormatStyle().parse()` **per value**. That is an allocation, a format-style
construction, and a general-purpose parse, for a fixed 20-to-30-byte pattern.

And: **nothing in the entire shared JSON benchmark corpus contains a single date.** Not
`twitter.json`, not `canada.json`, not `citm_catalog.json`. Every real API payload is full of
them. A hand-written ISO-8601 byte parser — which is a fixed-offset digit extraction, not a
parser in any interesting sense — is probably the highest ratio of win-to-effort in the entire
document, and no published benchmark will show it because no published corpus contains the input.

This also aligns with `_crossplatform_audit.md`'s conclusion that `@DateFormat(.pattern)` must be
a fixed ICU-free subset. The ergonomic constraint and the performance opportunity are the same
constraint.

---

## 7. Errors are free on the happy path — and exactly how

`EXPERIENCE.md` promises that Assay always collects every issue, with source spans, and that this
costs nothing when the data is valid. Every piece of that has been checked independently.

**Source locations are computed lazily.** Store a byte offset — one integer — and derive
line/column only when an issue is actually constructed. This is what everyone serious does:
Swift's own `SourceLoc` is a single pointer, Clang's is a bare `uint32_t`, and serde_json runs
`memrchr` backwards from the failure offset at error-construction time and never before.

**The thrown error costs nothing when not thrown.** `throws` returns via the callee-saved
`swifterror` register. Typed `throws(AssayError)` additionally avoids boxing into `any Error`.
Keep `AssayError` pointer-sized: serde_json's maintainers state plainly that "a larger Error type
was substantially slower", and they moved to a boxed representation for exactly that reason.

**An empty `[Issue]` is not an allocation.** It is a store of the immortal empty-array singleton
pointer.

**Paths are not materialized on the happy path.** pydantic-core stores path components in reverse
order, appending as the error propagates outward, so no path exists until an error does. Assay's
`[PathComponent]` should be built the same way — the macro knows the static path prefix at each
site, so the component can be a compile-time constant appended only in the failure branch.

Three rules the generated code must obey or all of this evaporates:

1. **`inout [Issue]` and nothing else.** Exclusivity on an `inout` parameter is statically
   enforced and free — *unless* the generated code captures it in an escaping closure, at which
   point it boxes and every access grows a `beginAccess`/`endAccess` pair. The macro must never
   emit an escaping closure over the issue buffer.
2. **The issue-construction path is a separate, cold-marked function.** Not inlined into the
   field loop, where it would bloat the hot function past the escape-analysis budget (§8.3).
3. **The `Limits` cap is checked in the failure branch only.** `maxIssues` (100 by default) is a
   comparison that the happy path never reaches, and `d.truncatedIssues` is set there.

---

## 8. What Swift's compiler will and will not do for us

These four constraints are not tuning; they determine what the macro is permitted to emit.

### 8.1 Library evolution is not Assay's problem

Resilience is off by default and cannot be enabled from `Package.swift` anyway. The "resilience
destroys performance" worry is real in general and irrelevant here. Do not ship
`-enable-library-evolution`, and do not reach for `.unsafeFlags` — the premise that `.unsafeFlags`
blocks version-pinned dependency resolution has actually **changed** (SwiftPM hard-codes
`usesUnsafeFlags: false` for tools-version ≥ 6.2), but the reasons to avoid it are correctness
reasons, not packaging ones.

### 8.2 Cross-module specialization is the existential threat, and the macro is the answer

Foundation's JSON implementation has **zero** `@inlinable` annotations and wins anyway, because it
is compiled with whole-module optimization inside one module. Assay cannot do that: the runtime
lives in the `Assay` module and the schema lives in the user's.

Two answers, and Assay uses both:

**For the generated per-field code: sidestep the problem entirely.** The macro emits *concrete,
monomorphic* code into the user's module. There is no generic parameter to specialize because
there is no generic parameter. This is the single most important structural reason a macro
decoder can be fast in Swift, and it is worth saying out loud in the README.

**For the shared runtime primitives: `@inlinable` on every hot leaf.** Byte accessors, the
window lookup, the integer parsers, the string constructor — each needs its body in the client's
SILModule or none of it specializes. A Swift forums report (750712) measured cross-module
optimization flags giving nothing and `@inlinable` taking the same workload from 92 µs to 3 µs.
Prefer `@_alwaysEmitIntoClient` / `@export(implementation)` where possible to avoid ABI lock-in,
and remember the SE-0193 constraint that `@inlinable` bodies cannot reference non-public
declarations without `@usableFromInline` or contain local types.

Do **not** use `@_specialize`: it opts the function out of cross-module optimization and cannot
name user types anyway. Do not use `@_semantics`: it is a closed list.

There is a quietly damning corroboration inside swift-foundation itself, in a comment on
deliberately duplicated code: *"This code is duplicate for performance reasons, as use of
`@_specialize` has not been able to completely replicate the benefits of manual duplication."*
Apple hand-monomorphized because the tooling was not good enough. A macro automates exactly that.

### 8.3 The escape-analysis complexity budget

Swift's escape analysis computes `getComplexityBudget = 1_000_000 / estimatedFunctionSize`, and
divides it by a further factor of ten for ARC-related queries. When the budget is exhausted the
analysis bails — and **budget exhaustion is indistinguishable from "it escapes"**: the retains
and releases simply stay in the output, with no diagnostic.

For a macro that generates decode bodies, this is an architectural constraint. A 60-field struct
flattened into one enormous decode function may silently lose all ARC optimization. **Emit many
medium-sized functions, not one giant flat body** — a per-field or per-field-group helper, each
small enough to analyze, with the dispatch loop calling into them.

This also composes badly with `@inlinable`, which grows callers. The interaction is unmeasured
and belongs on the experiment list.

### 8.4 ARC folklore, corrected

"Structs plus generics plus non-escaping closures equals ARC-free at `-O`" is folklore. Only
*transitively trivial* structs are ARC-free; a struct containing a `String`, `Array`, closure or
class instance is not. `AssayReader` must therefore hold only trivial things — a `RawSpan`, an
`Int` cursor, an `UnsafeMutableRawPointer` into the arena — and the issue buffer must be passed
`inout` rather than stored.

`@_effects(readnone)` / `@_effects(readonly)` on genuinely pure leaf helpers is the most
under-used lever available, and it is safe to apply to the byte-level primitives where the
contract is obviously satisfied.

Verify all of this by dumping SIL and counting `retain`/`release`, not by reasoning about it.
`-Ounchecked` should never be used to make a benchmark look good; comparing an `-Ounchecked`
Assay against a `-O` Foundation is on the list of things that make a README table worthless (§14).

---

## 9. Allocation

### 9.1 The arena, honestly

**An arena cannot allocate Assay's output values.** `String`, `Array` and `Dictionary` storage
goes through `swift_slowAlloc` to `malloc`, with no allocator parameter, no protocol hook, and no
live override. SE-0527 considered allocator generics and Swift Evolution declined. "Arena-allocated
decoding" and "zero-allocation decoding" are dead marketing lines and must not appear anywhere in
Assay's documentation.

What survives is worth having anyway: **`Assayer<T>` owns a reusable scratch buffer**, so in
steady state — a server decoding the same type thousands of times — the *scratch* allocation count
per decode is zero. Unescaping buffers, nested-container stacks, the issue buffer's backing store:
all reused. That is a real claim, it is precisely bounded, and it is measurable with
`mallocCountTotal`.

`withUnsafeTemporaryAllocation` handles the one-shot case, with one correction to the folklore:
its stack cliff is **1024 bytes, not 4 KB**, and SE-0322's "runtime heuristic" is a stub that
returns false. Above 1024 bytes you get `malloc` regardless.

### 9.2 The per-decode allocation floor

Enumerate the irreducible allocations for a decode into a struct:

| source | count |
|---|---|
| each string value longer than the SSO threshold | 1 |
| each array field | 1 (exactly-sized, if the count is known before filling) |
| each dictionary field | 1 plus rehashing |
| keys | **0** |
| coding path | **0** |
| container boxes | **0** |
| intermediate representation | **0** |
| scratch, in steady state | **0** |

Two notes. Exact-sizing arrays requires knowing the element count before allocating, which for
JSON means either a counting pre-scan of the array (cheap — a depth-counted structural skip) or
accepting geometric growth. Measure before choosing; and beware the shrink trap, where
`reserveCapacity` after the fact reallocates.

`ContiguousArray` versus `Array` for `UInt8` is a **no-op** — off Darwin they are literally the
same type, and on Darwin the bridging check is a branch the optimizer removes for non-class
elements. Do not spend API surface on it.

### 9.3 Writing into the struct

Prefer building all fields into locals and calling a single memberwise `init` over field-by-field
mutation of a partially-initialized value. Field-by-field mutation on a struct containing an
`Array` triggers `begin_cow_mutation` per append — the actual instruction is `begin_cow_mutation`,
not `isKnownUniquelyReferenced` — and exclusivity enforcement is on at `-O`. Locals plus one
`init` also matches serde's shape and the `Option<T>` presence model of §3.1, so it is not an
extra constraint.

### 9.4 The allocator, per platform

One stale premise corrected: since January 2026 the Swift **Static Linux SDK deletes musl's
allocator out of `libc.a` and links mimalloc 2.2.4**. Static Linux Swift binaries in 2026 are not
on mallocng, and any "musl's allocator is slow, so we allocate less" argument is out of date.
Assay should make no allocator-relative claims at all.

---

## 10. SIMD, unsafe, and the verdict on C

This is the section that answers the question directly.

### 10.1 The verdict

**Pure Swift core. One dispatch seam. C is additive, later, and only for x86-64 AVX2.**

| target | pure Swift sufficient? | why |
|---|---|---|
| arm64 Apple (macOS/iOS/tvOS/watchOS/visionOS) | **yes** | NEON is architecturally mandatory; `Builtin.int_aarch64_neon_tbl1` is reachable |
| arm64 Linux / Android arm64-v8a | **yes** | same |
| wasm32 | **yes** | simd128 is a compile-time decision; no runtime dispatch exists in C either |
| x86-64, SSE2 baseline | **yes** | `pcmpeqb` + `pmovmskb` + `pand` are all SSE2, which is enough for structural scanning |
| x86-64 with runtime AVX2 | **no** — needs C | Swift has no per-function target attribute at any level |
| armv7 / i686 | **yes** (scalar) | fallback path, which exists anyway as the correctness oracle |

### 10.2 Why C is not required

The two operations everyone assumes force a C target are a byte shuffle (`pshufb` / `tbl1`) and a
movemask (`pmovmskb`). Both are expressible from ordinary Swift.

Swift's standard library has **no** shuffle and **no** movemask in its public SIMD API — verified,
and that is the origin of the folklore. But `Builtin.int_<llvm-intrinsic>` reaches *any* LLVM
intrinsic with no allow-list, and the standard library itself does exactly this
(`UTF16.swift:460-489`). A portable movemask exists verbatim in the stdlib at
`StringCreate.swift:27-31` and can be copied.

Access is a **first-class `SwiftSetting`**: `.enableExperimentalFeature("BuiltinModule")`. The
folklore that this needs `-parse-stdlib` is stale — it needs `Feature::BuiltinModule`, and nothing
else.

Landmines, so they are known in advance: `Builtin.shufflevector` is **constant-mask only** and
crashes the compiler otherwise; `SIMD` comparison operators and `&+`/`&-`/`&*` do lower to real
vector instructions, but general arithmetic does not; and `Builtin` is an unstable interface, so
the vector core lives behind `#if compiler(>=6.2)` with the scalar path as fallback.

### 10.3 The one thing C actually buys

Clang has `__attribute__((target("avx2")))`, which needs no `-mavx2` on the command line and lets
one translation unit contain SSE2, AVX2 and AVX-512 kernels selected at runtime. **Swift has no
equivalent at any level** — no declaration attribute, no IRGen path emitting `target-features`;
Swift derives target features module-wide from the TargetMachine.

So on x86-64, pure Swift is pinned to the SSE2 baseline. On arm64 that is irrelevant (NEON is
mandatory) and on wasm32 it is irrelevant (simd128 is compile-time). The gap is exactly one
architecture wide.

If it turns out to matter, the fix is ~200 lines of C: a `SIMDJSON_TARGET_REGION`-style
`_Pragma("clang attribute push")` around an AVX2 kernel, plus raw `cpuid` detection — simdjson
deliberately does **not** use `__builtin_cpu_supports`, and copying their detection is the right
move. `target_clones`/ifunc is unsuitable. It goes behind the same seam, so it is strictly
additive.

### 10.4 The architecture

```
Sources/
  AssaySIMD/           # pure Swift, .enableExperimentalFeature("BuiltinModule")
    Vector.swift       #   protocol AssayVector { shuffle, movemask, eq, and, or }
    Scalar.swift       #   always built, always tested — the correctness oracle
    NEON.swift         #   #if arch(arm64)
    SSE2.swift         #   #if arch(x86_64)
    Wasm.swift         #   #if arch(wasm32)
  AssayCore/           # pure Swift; -strict-memory-safety on
  Assay/               # public API: RawSpan in, values out; @safe entry points
# LATER, only if x86-64 AVX2 measurably matters:
#  Sources/CAssayAVX2/ — ~200 lines, __attribute__((target("avx2"))) + cpuid
```

Four invariants:

**One dispatch seam, chosen once.** A `static let` global holding the selected implementation.
Swift's lazy globals are `swift_once`-protected and free after the first call. Whether the
implementation behind the seam is Swift or C is invisible above it. This is the property that
makes adding C later additive rather than a rewrite.

**The bit-per-lane ratio is implementation-defined.** x86 movemask gives one bit per byte; arm64's
cheap path (`vshrn_n_u16`) gives four bits per byte. Do not let that leak into the parser loop.

**The scalar path is not optional.** It is the fallback for armv7, i686 and anything unknown, and
it is the differential-testing oracle. Fuzz scalar against SIMD on every commit.

**The public API takes `RawSpan`, not pointers**, with `@safe` on the entry points and
`-strict-memory-safety` on internally.

### 10.5 The safety boundary — the user's actual condition

The user's condition was that unsafe or C at the core is fine *as long as the layers above are
solid and ergonomic*. Swift in 2026 makes that mechanically enforceable rather than a matter of
discipline:

- `Span` / `RawSpan` are `~Escapable` (SE-0447), so a borrowed view of the input **cannot** outlive
  the buffer — the compiler rejects it, at no runtime cost. `RawSpan.withUnsafeBytes` scopes the
  pointer.
- `@_lifetime` plus `_overrideLifetime` is the shipping pattern for wrapping unsafe storage in a
  lifetime-correct API; swift-collections' `RigidArray` and NIO's `ByteBuffer` both do exactly
  this, and can be copied rather than invented.
- **SE-0458 guarantees that unsafety does not leak to clients.** A library that uses unsafe
  constructs internally does not force `-strict-memory-safety` diagnostics on its users; the
  diagnostics are warnings, `@safe` exists to mark audited boundaries, and pointer-free C is
  considered safe.
- `-strict-memory-safety` on the internal targets means every unsafe construct must be explicitly
  marked, so the unsafe surface is enumerable rather than ambient.

The rule to hold: **unsafe code may exist only below the seam, and the seam's signature must be
expressible entirely in `RawSpan`, `Span`, and values.** If a design requires an
`UnsafeRawBufferPointer` in a public signature, the design is wrong.

### 10.6 Vendoring C, when the time comes

From swift-crypto, Yams and NIO, which all do this correctly: separate C target, `.define` and
`.headerSearchPath` only, no `.unsafeFlags`, module map, and — the trap — the Windows `dllimport`
define must appear on **both** the C target and the Swift target that imports it. Mixed-language
targets are still not available. A C target is the single largest source of breakage for Wasm SDK
builds, Android cross-compilation, static-musl builds and Xcode previews, which is the cost side
of §10.1's recommendation to defer it.

---

## 11. The other formats

`EXPERIENCE.md` promises one struct, many formats. The performance ceilings are not the same and
the documentation should say so rather than implying uniformity.

**YAML tops out around 200 MB/s** and structurally cannot use a JSON-style structural index —
indentation-sensitivity and the block/flow duality defeat it. Budget it at roughly a quarter to a
fifth of the JSON path. Yams is not usable for the fast path: it allocates a `Tag` class per node,
a `String` per scalar, an `Event` class per event, runs `Dictionary(grouping:)` per mapping just to
detect duplicate keys, and does O(N·K) mapping lookup with a `Tag` allocation per probe. That is
the largest available headroom anywhere in the Swift survey — and it is *libyaml's bridging layer*
that is slow, not libyaml. The one thing worth stealing is Yams' zero-copy ingest via
`withContiguousStorageIfAvailable`.

**XML** is worse. Every Swift XML library bottoms out in libxml2, three of five through a SAX
delegate bridge whose signature takes `String`s — one to four `String`s per element and two to
four per attribute, unavoidable while the delegate contract is what it is. XMLCoder builds the
tree **twice** (`XMLCoderElement` then `transformToBoxTree`), roughly eight to ten allocations per
element. One prior hypothesis is **refuted**: Foundation's `XMLParser` on Linux does *not* go
through Obj-C bridging — there are zero `NSDictionary`/`_bridgeToObjectiveC` matches. Do not assert
the bridging claim.

The best idea in Swift XML is Fuzi's `lazy var` string materialization: untouched subtrees cost
zero `String`s. That composes perfectly with a schema-driven decoder, which knows exactly which
subtrees it will touch. The pugixml recipe — in-place mutation, arena, compact flat nodes — is the
target shape.

`_crossplatform_audit.md` already concluded XML must be a separate product and should not use
`XMLParser`. The performance evidence agrees.

---

## 12. What "fastest" would have to mean

### 12.1 Nobody measures Assay's workload

simdjson's paper states it outright: *"We deliberately did not consider small documents (smaller
than 50 kB)."* Assay's band is 1–50 kB. **The field's own scope statement excludes Assay's entire
workload.**

Of seven Swift benchmarking harnesses surveyed, none benchmarks a 1–10 kB `Codable` decode
properly. The standard corpus — `twitter.json`, `canada.json`, `citm_catalog.json` — is
megabyte-scale, contains no dates, contains no unknown keys, contains no missing optionals, and
contains no invalid inputs at all.

At 1–50 kB, fixed per-call overhead is a large fraction of total cost, so **GB/s is the wrong
unit** and will flatter or damn Assay arbitrarily depending on the file chosen.

### 12.2 The corpus Assay has to build

Three dimensions, generated rather than hand-written, from real public API response schemas
(Stripe, GitHub, Twilio, Kubernetes), with the generator published alongside the files.

Size: 512 B, 2 kB, 8 kB, 32 kB, 64 kB — the last as a boundary into the published band so that
something is comparable to prior art.

Shape, each at fixed size: `scalars`; `short-strings` (≤15 bytes, to isolate the SSO win and to
expose the Wasm cliff); `long-strings` (30–120 bytes, one malloc per field); `uuids-and-dates`
(the realistic API case, where every string allocates on every platform); `escaped`;
`arrays-of-scalars`; `arrays-of-structs`; `optionals-absent` and `optionals-present`;
`unknown-keys`; `nested-3-deep`.

Negative cases, which no JSON benchmark includes and which matter enormously for a validator:
`invalid-early` (malformed at byte 10 of 8 kB, measuring fail-fast); `invalid-late` (malformed at
byte 8000); `type-mismatch` (well-formed JSON, wrong types); `validation-fail-many` (twenty
validation errors, measuring the issue-collection path of §7).

Baselines must include **Ananda + AnandaMacros** — it is Assay's only true macro-decoder peer and
omitting it would be conspicuous — alongside Foundation, IkigaJSON and ZippyJSON.

### 12.3 Presentation

Report **ns/op and allocs/op at each size, never GB/s.** Report the **size-scaling curve**, not a
point: swift-collections-benchmark already produces exactly these log-log plots, and a decoder
with low fixed overhead and one with high fixed overhead have visibly different curves at the left
end that no single number can distinguish. Fit and publish **the intercept** — the fixed
per-decode overhead in ns and allocations — because that is the actual product claim for a server
hot path and almost nobody publishes it.

Benchmark both cold and warm, labelled. Real servers decode the same type thousands of times, so
if `Assayer<T>` amortizes anything, a cold-only benchmark understates it — and a warm-only
benchmark overstates it for CLI users.

### 12.4 CI

Gate on **`.mallocCountTotal` with absolute per-benchmark thresholds** — exact expected counts, any
change fails and must be re-baselined in a reviewed commit. This is swift-nio's design and it is
correct: allocation counts are deterministic, machine-independent, and port across platforms where
timing does not. Also gate `.retainCount` / `.releaseCount`, since ARC traffic is deterministic too
and §8.4 says it is a real cost. `.peakMemoryResident` with a generous ceiling as a canary.

**Do not gate on wall clock.** Collect it, publish it, never fail on it. swift-nio puts `wallClock`
and `instructions` behind `#if LOCAL_TESTING` and compiles them out of CI entirely.

**The `.instructions` trap is serious**: on GitHub-hosted runners `perf_event_open` fails, there is
no PMU, and package-benchmark **silently reports zero** because the diagnostic is commented out. A
threshold on a metric that is always zero always passes. Verify it returns nonzero before
configuring it, or do not configure it.

Run the size-scaling curve nightly, publish the plot, do not gate on it.

### 12.5 The claim Assay can actually defend

Refuse to claim: "fastest JSON decoder" (unqualified, unprovable, and false on some axis);
"fastest on all platforms" (it cannot even be measured on three of five); "zero-allocation" or
"arena-allocated" (§9.1); any speedup ratio on a platform where the harness does not run; any
allocator-relative claim; any SSO-dependent claim without the length histogram.

Publish the losses. yyjson's benchmark repository is credible specifically because it publishes
cases where yyjson loses, and simdjson's paper is credible specifically because of its scope
statement — that one sentence buys more trust than the numbers do. Assay's equivalent:

> Assay is optimized for 1–50 kB payloads decoded into known types. We do not optimize for, and do
> not claim advantage on, multi-megabyte documents or schemaless traversal.

And the positive claim, which is checkable, falsifiable, survives CI, and does not decay:

> Assay performs the minimum number of heap allocations a Swift decoder can perform: one per
> non-inline string, one per array, one per dictionary, and zero for everything else — no
> intermediate representation, no key strings, no coding-path construction, no container boxes.
> On our corpus of 1–50 kB API payloads that is N allocations per decode against Foundation's M.
> Here is the corpus, the harness, and the number on every platform we can measure.

One fairness note that must be stated rather than buried: Foundation's `JSONDecoder` is fully
general and `Codable`-driven; Assay's macro knows the schema at compile time. That is a real
advantage and also an unfair comparison unless said out loud. Say it out loud.

---

## 13. Two things that are free and easy to miss

**Deleting `CodingKeys` shrinks binaries and speeds up unrelated code.** Each synthesized
`CodingKeys` enum carries roughly 1.8 KB of metadata. Removing them took a 10,000-struct test
binary from 49 MB to 31.1 MB and from 70,321 to 20,321 type descriptors — and because the runtime's
dynamic-cast cache is a global structure, that made **the whole host app's** dynamic casts faster.
Assay's macro emits no `CodingKeys`. This is a real, measurable, unexpected benefit of the
architecture that costs nothing to obtain and is worth a paragraph in the README.

**`Assayable: Sendable` costs zero.** Marker protocol, no witness table, no calling-convention
change. It is a free correctness win, not a performance cost, and it is worth taking (§3.2).

---

## 14. Build order

The ordering is chosen so that each step is independently measurable and no step depends on an
unverified assumption from a later one.

**Phase 1 — prove the thesis.** A scalar Swift scanner, a macro that emits the tier-1 window
dispatch, monomorphic integer parsers, no-escape string fast path, whole-buffer UTF-8 validation
up front, lazy source locations, `inout [Issue]`. No SIMD, no C, no arena beyond a reusable scratch
buffer. Benchmark against Foundation on the corpus of §12.2 and count allocations. **If this does
not comfortably clear ZippyJSON's 1.38×, the thesis is wrong and everything below is moot.** That
is the falsification condition and it should be written into the repository.

**Phase 2 — the unclaimed wins.** ISO-8601 date parsing by hand. Unknown-key structural skip.
Exact-sized arrays. Steady-state scratch reuse in `Assayer<T>`. These are all allocation and
special-case wins, all measurable with `mallocCountTotal`, all independent of each other.

**Phase 3 — codegen discipline.** SIL dumps to count ARC traffic. `@inlinable` on the hot leaves.
Split generated bodies until the escape-analysis budget is comfortably met. Verify the field
dispatch actually lowers to what §4 assumes.

**Phase 4 — SIMD, behind the seam. RETIRED 2026-08-08, unbuilt.** This said: measure, and "if
that is what the numbers say, stop here and say so publicly." The numbers came in. Saying so
publicly.

Two measurements retire it, both in `Benchmarks/RESULTS.md`:

*The ceiling.* SIMD's target here is the whole-buffer UTF-8 pass — that is what a vectorised
kernel replaces. Measured as a share of end-to-end decode: **5.0–5.3% on the API-shaped
payload**, 12–14% on string-heavy shapes, under 2% on float-dense. Amdahl does the rest: a
*perfect* validator, costing literally zero rather than merely being faster, buys at most 13.6%
on the friendliest shape and about 5% on the one the falsification condition used. A realistic
4× validator buys ~4% where it matters.

*The gap it would need to close.* Against yyjson — hand-tuned C, `-O3`, values asserted equal
first — Assay decodes at **0.65×** on the use-case arm. The real distance to C is ~1.5×.
Vectorising a 5% slice does not close a 1.5× gap. Whatever would, it is not this.

So phase 4 is not deferred, postponed, or awaiting resources. It is **cancelled**, on evidence,
and `Sources/AssaySIMD/` stays empty. Experiments #2 and #3 remain valid and are worth keeping:
they establish that `Builtin` intrinsics resolve, emit real NEON, and survive versioned
dependency resolution. That is a door left open, not a plan.

**Phase 5 — C. RETIRED 2026-08-08, unbuilt.** It was gated on phase 4's x86-64 numbers, and
phase 4 will not produce any. Experiment #4 established that `-Xllvm -mattr=+avx2` is
byte-identical output, so C was the only route to x86-64 AVX2 — but that route was only ever
worth taking if the destination was worth reaching, and the two measurements above say it is
not. Building ~200 lines of AVX2 and `cpuid` to chase a fraction of a 5% slice, and taking on a
C toolchain across five platforms to do it, is a bad trade made with numbers instead of
instinct.

**What replaces them.** Nothing, and that is the finding. Assay's remaining time is dominated by
`String` construction for values (the sampling profile says so), which is not vectorisable
work — it is the irreducible cost of producing Swift `String`s. The performance thesis was
always that *the parser was never the bottleneck, the `Codable` container boundary was*; that
boundary is deleted and the win is banked at 5–9× Foundation. There is no second act of the same
kind waiting, and pretending otherwise would be the sort of roadmap item that never gets
re-examined.

Correctly-rounded doubles are required at phase 1 for correctness. A full Eisel-Lemire port was
listed as "a phase 4 decision at the earliest" and is retired with it: the float-dense arm sits
at **0.78×** against a parser that *does* carry a bespoke float algorithm, a narrower gap than
Assay's on ordinary API payloads. §6's decision to defer to the stdlib holds.

---

## 15. The five experiments to run first

Each takes minutes with a real toolchain, and each could change the plan. **Nothing in this
document has been compiled.** These come before implementation, not after.

1. **Does the field dispatch lower to a jump table?** Write a 50-arm switch over a `UInt8`
   candidate index, dump IR, and look for a genuine `llvm::SwitchInst` rather than a comparison
   chain. §4 assumes a table; §8's finding that Swift lowers integer-literal patterns to
   comparison chains says it may not. This is the highest-stakes assumption in the document.
2. **Do the `Builtin` intrinsics resolve, and with what argument-type suffix?**
   `Builtin.int_x86_ssse3_pshufb_128`, `Builtin.int_aarch64_neon_tbl1`, `Builtin.int_wasm_swizzle`.
   `swiftc -emit-assembly` and read for `pshufb` / `tbl` / `i8x16.swizzle`. Also
   `Builtin.bitcast_Vec32xInt1_Int32`, and what arm64 emits for `bitcast <16 x i1> to i16` compared
   against simdjson's hand-written `vshrn` sequence.
3. **Does `.enableExperimentalFeature("BuiltinModule")` survive as a versioned dependency?** It
   works in a local package; the question is whether a *second* package can depend on Assay by
   version tag with that setting present.
4. **Does `-Xllvm -mattr=+avx2` change Swift codegen at all,** or is it overridden by IRGen's own
   TargetMachine construction? This decides whether a non-C route to AVX2 exists.
5. **Does the Swift SDK for WebAssembly enable `simd128` by default?** (`grep simd128` in the SDK's
   `swift-sdk.json`.) And do the `llvm.wasm.*` builtins select without it?

A sixth, cheaper than all of these and arguably more valuable: **write the corpus generator before
writing the parser.** Everything in §12 depends on it, it has no toolchain risk, and having the
negative-case files in hand will change how the error path is designed.

---

## 16. What is still open

Honest list of things this document asserts on the strength of source reading rather than
measurement, plus things nobody knows.

The interaction between `@inlinable` and the escape-analysis complexity budget is unmeasured, and
they pull in opposite directions. Whether a `RawSpan` parser generates identical code to an
`UnsafeRawBufferPointer` parser is unverified in the specific shape Assay needs. The exact
`Builtin.int_*` argument-suffix mangling for each target intrinsic is unknown. The quality of
arm64 lowering for `bitcast <16 x i1> to i16` is unknown. Whether `Foundation.Data` exposes a
`span` property is unconfirmed, which matters for the zero-copy ingest path.

No credible published measurement exists for bounds-check cost, exclusivity cost, ARC as a
percentage of runtime, or existential dispatch in ns/op — in Swift, at all. **Do not put numbers
for any of these in Assay's documentation.** Every figure in this document belongs to someone
else's C, C++, Rust or Go, and is cited as evidence about *architecture*, not as a prediction
about Assay's Swift.

Some target platforms cannot be meaningfully benchmarked at all — Wasm timing is not
trustworthy, and Windows currently builds without running the test suite. The honest fallback
there is the allocation count, which is why §12.4 makes it the gate rather than a nice-to-have.

**Updated 2026-08-20:** Linux and x86-64 are now measured on real hardware, so the "one arm64
Mac" caveat that qualified every ratio in this document is retired for those. See
`Benchmarks/RESULTS.md`.

---

## 17. The one-paragraph version, for the README

Assay is fast because of what it does not do. It does not build a document; the macro generates a
decoder that reads bytes directly into your struct's fields, which is worth 1.4× over a tape and
several times over anything that builds a dictionary per object — and that is a measured
architectural gap, not a hope. It does not allocate a `String` for a key, build a `Dictionary` per
object, construct a coding path, or box a value in an existential container, which together are
roughly five sixths of what a Swift decode normally costs. It parses your dates rather than
constructing a formatter for each one. It collects every error with a source span and pays nothing
for that when the data is valid. The core is pure Swift, portable to every platform Swift targets,
with SIMD behind a single dispatch seam and a scalar implementation that is always built and always
tested. Where it is not the fastest thing available — multi-megabyte documents, schemaless
traversal — the benchmarks say so, because they are published, and so is the corpus, and so is the
generator that made it.
