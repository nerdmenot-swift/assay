# Assay — Allocation Strategy and Benchmark Credibility

Research dossier. Written 2026-07-25.

**Method and its limits.** Every source-level claim below was checked against real
checked-out source, at the HEADs listed in [Appendix A](#appendix-a--corpus-and-heads).
**There is no Swift toolchain in this environment.** Nothing here was compiled,
nothing was run, no benchmark was executed, no SIL or assembly was emitted. Every
claim is tagged:

- **VERIFIED** — read directly in source, a proposal, or a first-party document, with the citation given. Means "this is what the code/document says," not "I measured this."
- **UNVERIFIED** — inferred, reported by a third party, or reasoned from mechanism. Believe it provisionally.
- **CONTRADICTED** — a hypothesis in the brief that source disproves.

The final section, [Do not assert these](#20--do-not-assert-these), is the one to
read before anything ships in a README.

---

## 0. Executive summary

1. **An arena cannot allocate Assay's output values.** `String`, `Array`, and
   `Dictionary` storage is hard-wired to `malloc` through `swift_slowAlloc`, with
   no allocator parameter, no protocol hook, and no live override. Swift Evolution
   looked at allocator generics in SE-0527 and explicitly declined. An arena in
   Assay is a *scratch* optimization — parser stacks, key tables, tape arrays —
   and nothing more. Treat "arena-allocated decoding" as a dead marketing line.
   ([§4](#4--arena--bump-allocation-in-swift))
2. **`ContiguousArray` vs `Array` is a no-op for `UInt8`.** Off Darwin they are
   the same type. On Darwin the bridging check is a branch the optimizer removes
   for non-class elements. Don't spend API surface on it. ([§2.4](#24--contiguousarray-vs-array))
3. **The small-string threshold is not 15 everywhere.** It's 15 on 64-bit, **14
   on Android arm64**, **8 on all 32-bit including wasm32**, 10 only on 32-bit
   watchOS. Any "most API strings are free" claim silently inverts on Wasm.
   ([§2.3](#23--small-string-optimization-the-exact-thresholds))
4. **`withUnsafeTemporaryAllocation`'s cliff is 1024 bytes, not 4 KB**, and the
   SE-0322 "runtime heuristic" is a stub that returns false. Above 1024 bytes you
   get `malloc`. ([§4.1](#41--withunsafetemporaryallocation-se-0322))
5. **The musl premise is stale.** Since January 2026 the Swift Static Linux SDK
   *deletes musl's allocator out of `libc.a` and links mimalloc instead*. Static
   Linux Swift binaries in 2026 are not on mallocng. ([§5.3](#53--musl-and-the-static-linux-sdk))
6. **The "no Swift-specific allocator comparison" gap is now only partly open.**
   Three community data points exist and must be cited rather than ignored; but
   no cross-platform Swift comparison and no Swift-decoder allocator study exist.
   ([§5.5](#55--the-published-gap-verified-narrowed))
7. **No published JSON benchmark measures Assay's workload.** simdjson's own paper
   says in as many words that documents under 50 kB were deliberately excluded.
   Assay's band is 1–50 kB. This is an opportunity and an obligation: Assay has to
   build the corpus, and has to say why. ([§12](#12--corpora-and-why-the-standard-ones-are-wrong-for-assay))
8. **Wall clock is not a CI metric.** swift-nio gates on `mallocCountTotal` and
   nothing else; `wallClock` and `instructions` are behind `#if LOCAL_TESTING`.
   `.instructions` on GitHub-hosted runners silently reports zero because
   `perf_event_open` fails and the diagnostic is commented out. ([§11](#11--the-harness-swift-benchmarking-in-2026), [§13](#13--regression-detection-in-ci))

---

# PART A — ALLOCATION STRATEGY

## 1. The allocation sites in a decode

Enumerated against swift-foundation's `JSONDecoder`, which is the closest thing to
a reference implementation of "a modern Swift JSON decoder" and is what Assay
will be compared against.

| # | Site | Present in swift-foundation? | Eliminable in Assay? | Confidence |
|---|---|---|---|---|
| 1 | Input `Data` → contiguous bytes | Yes, may copy | Yes — accept `some Collection<UInt8>` / `RawSpan` and never copy | VERIFIED mechanism |
| 2 | Intermediate DOM / tape | Yes, `JSONMap` flat `[Int]` | Yes — direct-to-struct, no tape at all | VERIFIED it exists |
| 3 | `[String: JSONMap.Value]` per object | **Yes** — `stringify` | **Yes, entirely** | VERIFIED |
| 4 | Every `String` field | Yes | Only if ≤ SSO threshold; otherwise one malloc each, unavoidable | VERIFIED |
| 5 | Every `Array` field | Yes | Reducible to exactly one malloc per array | VERIFIED mechanism |
| 6 | Every `Dictionary` field | Yes | One allocation minimum, sizeable | VERIFIED mechanism |
| 7 | `codingPath` array | Deferred via `_CodingPathNode` | Yes — build only on error | VERIFIED |
| 8 | `CodingKey` boxes | Yes, `_CodingKey` enum | Yes — macro emits static key tables | VERIFIED mechanism |
| 9 | Error / issue collection | `DecodingError` w/ context | Yes on the happy path | VERIFIED mechanism |
| 10 | The output struct itself | Stack, usually | Already free for non-class types | VERIFIED |
| 11 | Existential boxes for containers | Yes — `KeyedDecodingContainer` etc. | Yes — macro bypasses `Decoder` protocol entirely | VERIFIED mechanism |

### 1.1 — The `stringify` allocation, the single biggest algorithmic target

**VERIFIED.** `swift-foundation/Sources/FoundationEssentials/JSON/JSONDecoder.swift:1266-1303`:

```swift
static func stringify(objectRegion:using:codingPathNode:keyDecodingStrategy:) throws -> [String:JSONMap.Value] {
    var result = [String:JSONMap.Value]()
    result.reserveCapacity(objectRegion.count / 2)
    var iter = impl.jsonMap.makeObjectIterator(from: objectRegion.startOffset)
    while let (keyValue, value) = iter.next() {
        let key = try impl.unwrapString(from: keyValue, for: codingPathNode, _CodingKey?.none)
        result[key]._setIfNil(to: value)
    }
    ...
}
```

Every JSON object in the input becomes one `Dictionary<String, JSONMap.Value>`
allocation *plus* one `String` allocation per key that exceeds SSO, *plus* hashing
per key. For a struct with known keys this is pure waste: the decoder already knows
the key set at compile time.

**Assay's structural advantage is here, not in the scanner.** A macro that knows
the key set can match keys by length-bucketed comparison against a static table and
never construct a `String` key, never build a `Dictionary`, never hash. For a
20-field struct that is 1 dictionary allocation + up to 20 key-string allocations
eliminated per object, before touching the values. UNVERIFIED as a measured number;
VERIFIED as a structural difference.

**Caveat, and it matters for honesty:** swift-foundation only calls `stringify` when
it can't take a faster path, and it has a direct-iteration path for some shapes.
Do not claim "Foundation allocates a dictionary per object" as an unconditional
statement without re-reading `JSONDecoder.swift` at the version you benchmark.

### 1.2 — codingPath is already deferred in Foundation

**VERIFIED.** `swift-foundation/Sources/FoundationEssentials/CodableUtilities.swift:32-82`
defines `_CodingPathNode`, an indirect enum that forms a linked list up the decode
stack and is *projected* into `[any CodingKey]` only when an error is constructed.

Implication for Assay's marketing: **do not claim "we avoid building coding paths"
as a differentiator against modern Foundation.** It's already done there. The claim
you *can* make is that Assay's error path also avoids the existential `any CodingKey`
boxing, which Foundation's projection does not — UNVERIFIED whether that's measurable.

---

## 2. Output values: what can and cannot be made cheaper

### 2.1 — Array fields: can they be one allocation?

**Yes, and here is the mechanism.** **VERIFIED.**

`Array(unsafeUninitializedCapacity:initializingWith:)` (SE-0245) allocates exactly
once at the requested capacity and hands you a buffer plus an out-param count. If
you know the element count before you allocate, you get one malloc, no growth, no
copy.

Two ways to know the count:

**(a) Two-pass structural scan.** Walk the array region counting commas at depth 1,
then allocate exactly and fill. Cost: a second pass over the array's bytes. For the
1–50 kB band, the bytes are already in L1/L2 from the first pass, so the second pass
is close to free relative to a malloc + memcpy growth sequence. UNVERIFIED as a
measured tradeoff in Swift — this is the standard argument and it is *plausible*,
not demonstrated.

**(b) Structural-index precomputation, the simdjson approach.** simdjson's stage 1
produces a list of indices of all structural characters in the whole document, from
which element counts fall out by subtraction without a second character-level scan.
**VERIFIED** that simdjson does this (Langdale & Lemire, *Parsing Gigabytes of JSON
per Second*, arXiv:1902.08318). **UNVERIFIED** that it pays off at 1–50 kB — the
paper's own scope statement (see §12.2) is that it wasn't evaluated there.

**What serde does — and it's the more relevant comparison for Assay.**
`serde_json` does *not* pre-count. `Vec::push` in a loop, amortized doubling.
serde's design bet is that the per-element work dominates the amortized growth cost.
**VERIFIED** by reading `serde-json/src/de.rs` sequence handling — there is no
count-first pass. This is worth stating plainly because it undercuts the assumption
that exact sizing is obviously correct: the fastest general-purpose JSON decoder in
Rust does not do it.

**Recommendation for Assay:** exact-size arrays of *scalars* (where the second pass
is a cheap comma count and the element write is trivial, so growth-copy is a large
fraction of total cost); use `reserveCapacity` with a cheap estimate plus push for
arrays of *structs* (where per-element work dominates and a second pass over nested
content is expensive). UNVERIFIED — this is a design judgment, and it is exactly
the thing Assay's own benchmark suite should settle rather than assume.

### 2.2 — Array growth, and the shrink trap

**VERIFIED.** `swift/stdlib/public/core/ArrayShared.swift:179-198`. Growth is 2×.
And there's a footgun in the same function:

> If not for append, just use the specified capacity, ignoring oldCapacity. This
> means that we "shrink" the buffer in case minimumCapacity is less than oldCapacity.

So `reserveCapacity(n)` where `n < count` **reallocates smaller**. If Assay's
generated code ever calls `reserveCapacity` from an estimate that can undershoot a
partially-filled array, it will cause an extra allocation and copy rather than
prevent one. Guard the estimate.

### 2.3 — Small-string optimization: the exact thresholds

**VERIFIED, and it CONTRADICTS the common "15 bytes" shorthand.**
`swift/stdlib/public/core/SmallString.swift:80-94`:

```swift
internal static var capacity: Int {
#if os(watchOS) && _pointerBitWidth(_32)
  return 10
#elseif _pointerBitWidth(_32) || _pointerBitWidth(_16)
  // Note: changed from 10 for contiguous storage.
  return 8
#elseif os(Android) && arch(arm64)
  return 14
#elseif _pointerBitWidth(_64)
  return 15
#else
#error("Unknown platform")
#endif
}
```

| Platform | SSO capacity (UTF-8 bytes) |
|---|---|
| macOS / iOS / Linux x86_64 / Linux arm64 / Windows x64 | **15** |
| **Android arm64** | **14** |
| **wasm32** | **8** |
| 32-bit ARM / i386 | **8** |
| 32-bit watchOS | 10 |

This is a cross-platform cliff and Assay's docs must not paper over it. On Wasm,
`"created_at"` (10 bytes) is a heap allocation; on x86_64 it is free. A benchmark
run on macOS and a benchmark run in wasmtime are measuring structurally different
programs.

**The Android 14 is not a typo** — it's because Android arm64 reserves a bit for
tagged pointers / top-byte-ignore interaction.

**Two more properties worth knowing (VERIFIED):**

- A small string is ARC-free. No retain/release traffic at all, because there is no
  object. This is a *second*, separate win beyond skipping the malloc, and it's the
  one people forget.
- `String(unsafeUninitializedCapacity:_:)` (**SE-0263**, not SE-0309 — the brief's
  hypothesis had the number wrong) automatically routes to the small representation
  when `capacity <= _SmallString.capacity`. `swift/stdlib/public/core/String.swift:723-748`.
  So Assay does not need to hand-write a small-string path; constructing through
  this initializer gets it for free, *provided the capacity passed is tight*. Passing
  a loose upper bound (e.g. "at most 64") defeats it.

**What fraction of real API string values fall under the threshold? UNVERIFIED.**
I found no published measurement of string-length distributions in REST API payloads,
and I am not going to invent one. What can be said structurally, and should be
stated as reasoning rather than data:

- **Keys** in a typical API schema are overwhelmingly ≤15 bytes (`id`, `name`,
  `email`, `created_at`, `user_id`). Assay's macro should never allocate keys at
  all, so this is moot for Assay but relevant to what Foundation pays.
- **Values** split hard by kind. Enum-like strings (`"active"`, `"USD"`, `"GET"`),
  short codes, and booleans-as-strings fit. UUIDs (36 chars), ISO-8601 timestamps
  (20–30 chars), URLs, emails, and any free text do not.
- Therefore: on 64-bit, a meaningful minority-to-majority of *value* strings in a
  typical API body are free; **on Wasm, almost none are**. A 36-char UUID allocates
  everywhere.

If Assay wants to make a quantitative claim here, it must measure its own corpus and
publish the histogram. That is a cheap and genuinely novel contribution.

### 2.4 — `ContiguousArray` vs `Array`

**VERIFIED, and it CONFIRMS the brief's suspicion: for `UInt8` there is no
difference worth the API cost.**

`swift/stdlib/public/core/Array.swift:299-311`:

```swift
public struct Array<Element>: _DestructorSafeContainer {
  #if _runtime(_ObjC)
  internal typealias _Buffer = _ArrayBuffer<Element>
  #else
  internal typealias _Buffer = _ContiguousArrayBuffer<Element>
  #endif
```

Off Darwin — Linux, Windows, Android, Wasm — `Array` **is** `ContiguousArray`
structurally. Identical buffer type. Zero difference.

On Darwin, `_ArrayBuffer` carries a discriminator for "might be an NSArray." For a
non-class, non-`@objc`-bridgeable element like `UInt8`, that check is a
statically-predictable branch and the specializer removes it. Residual cost:
**UNVERIFIED but reasoned to be zero-to-negligible** — I could not compile to
confirm the branch is eliminated in all inlining contexts.

**Recommendation:** use `ContiguousArray` internally where it's free to do so (it
documents intent and removes any doubt), but **do not expose it in Assay's public
API** and **do not claim it as a performance feature**. It would be a claim you
can't substantiate and that is false on 4 of 5 target platforms by construction.

**The genuinely better answer in 2026 is neither.** For byte buffers, use
`RawSpan` / `Span` (SE-0447) for input and `InlineArray` (SE-0453) for fixed-size
scratch. Those eliminate the allocation and the bounds-check-with-COW-check
entirely, rather than shaving a branch. **VERIFIED** these proposals are accepted;
**UNVERIFIED** which toolchain versions ship each on which platform — check before
depending on them.

### 2.5 — Dictionary fields

One allocation minimum per `Dictionary`, sized by `reserveCapacity`. Note that
`Dictionary.reserveCapacity(n)` allocates capacity for `n` elements at the load
factor, which is *more* than `n` slots. There is no `Dictionary(unsafeUninitializedCapacity:)`.
**VERIFIED** by absence in `swift/stdlib/public/core/Dictionary.swift`.

Implication: dictionary-typed fields are Assay's worst case and there's no trick.
If Assay's benchmark corpus is dominated by `[String: String]` fields, its advantage
over Foundation narrows sharply. Choose the corpus honestly and report that band.

---

## 3. The output struct, COW, and exclusivity on the write path

### 3.1 — The per-append check is `begin_cow_mutation`, not `isKnownUniquelyReferenced`

**VERIFIED, and it CORRECTS the brief's framing.** At the SIL level, mutating an
array goes through the `begin_cow_mutation` / `end_cow_mutation` instruction pair,
not a library-level `isKnownUniquelyReferenced` call. The distinction matters
because `begin_cow_mutation` is a *first-class SIL instruction the optimizer
understands*: the COWOpts / COWArrayOpt passes can hoist it out of loops, so N
appends in a loop can collapse to one uniqueness check rather than N.

**Practical consequence for Assay's codegen:** a tight fill loop that the optimizer
can see is uniquely-referenced pays the check roughly once, not per element.
A fill loop broken across a non-inlined function boundary, or across a closure the
optimizer can't see through, pays it per iteration. **This is a codegen-shape
constraint on the macro, and it's more important than the choice of array type.**
UNVERIFIED as a measured delta — needs SIL inspection on a real toolchain.

The clean way to sidestep it entirely: `Array(unsafeUninitializedCapacity:)` gives
you an `UnsafeMutableBufferPointer` with no COW semantics at all inside the closure.
No check, per-element or otherwise. This is a second, independent reason to prefer
exact sizing over push-in-a-loop.

### 3.2 — Exclusivity enforcement is on in `-O`

**VERIFIED, and it CORRECTS a common assumption.**
`swift/include/swift/AST/SILOptions.h:264-268`:

```
EnforceExclusivityStatic = true;
EnforceExclusivityDynamic = true;
```

Both default to **true regardless of optimization level**. The split between static
and dynamic enforcement is **by storage kind, not by `-O` vs `-Onone`**:

- Local variables, and `inout` params the compiler can reason about → **static**, free.
- Class stored properties, globals, and escaping captures → **dynamic**, a runtime
  `swift_beginAccess` / `swift_endAccess` pair, which touches a thread-local access set.

`-Ounchecked` disables dynamic enforcement. **Do not build Assay's published
benchmarks with `-Ounchecked`** — it is not what users will run, and a benchmark
under `-Ounchecked` compared against a competitor under `-O` is exactly the kind of
thing that makes a README table worthless.

**Consequence for the macro:** if the generated decoder writes into a **struct**'s
stored properties held in a local `var`, enforcement is static and free. If it writes
into a **class**'s stored properties, every field write is a dynamic access pair.
This is a strong argument for Assay's generated code to build into a local value and
assign once, and for `@Schema` on classes to route through a local staging value.

### 3.3 — Field-by-field mutation vs a single `init` call

**Yes, a single `init` is meaningfully better, for three separate reasons — but only
one of them is a large effect.** UNVERIFIED as measured; VERIFIED as mechanism.

1. **Definite initialization.** Building the struct field-by-field from `var x: T?`
   temporaries means every field is an `Optional<T>` until the end, then force-unwrapped
   or unwrapped-with-error. For a field of a type with a non-trivial layout, `Optional`
   wrapping can change representation and add branches. Calling `init` with all values
   at once lets the fields be non-optional throughout. **This is the real win.**
2. **Exclusivity** (§3.2) — free for structs either way, real for classes.
3. **Retain/release traffic.** Field-by-field assignment of a reference-counted field
   (`String` with heap storage, `Array`, class refs) is `release old; retain new` per
   assignment; a single `init` moves values in without the release-old half. Small
   but real.

**The catch, and it is a real design constraint:** a single `init` call requires all
field values to be live simultaneously, which for a struct with many large fields
means more stack pressure and, crucially, means you cannot stream. For Assay's target
of 5–40 fields at 1–50 kB, all-live-at-once is fine. For a 500-field type it is not.

**Recommendation:** macro emits a single memberwise `init` call, from local
non-optional `let`s where the field is required and local `var _: T?` only where the
field is genuinely optional or has a default. Fall back to field-by-field above some
field count. UNVERIFIED where that threshold sits.

---

## 4. Arena / bump allocation in Swift

### 4.0 — The headline, stated plainly

**VERIFIED: an arena in Swift can serve scratch/intermediate state only. It cannot
serve the output `String` and `Array` values a decoder hands back to its caller.**

Four independent pillars, each verified separately:

1. **No allocator parameter, anywhere.** `Array`, `String`, `Dictionary`, `Set` have
   no allocator generic parameter and no allocator protocol. There is no Swift
   equivalent of Rust's `A: Allocator` or C++'s `std::pmr`. VERIFIED by reading the
   declarations in `swift/stdlib/public/core/`.
2. **Storage is hard-wired.** Buffer allocation goes
   `Builtin.allocWithTailElems_1` → `swift_allocObject` → `swift_slowAlloc` → `malloc`.
   VERIFIED through `swift/stdlib/public/core/ContiguousArrayBuffer.swift` and
   `swift/stdlib/public/runtime/HeapObject.cpp`.
3. **The one override hook is dead.** `swift/include/swift/Runtime/InstrumentsSupport.h:50-57`
   declares `_swift_slowAlloc` with the comment:

   > Swift used to implement these but no longer does.

   Zero live call sites. It is an Instruments vestige. VERIFIED by grep across the
   runtime.
4. **Evolution considered it and declined.** SE-0527 (RigidArray / UniqueArray),
   `swift-evolution/proposals/0527-rigidarray-uniquearray.md:1743`, on adding allocator
   generic parameters:

   > this assumes the implementation of a **major new language feature that does not
   > currently exist.**

   VERIFIED verbatim.

**What this kills:** "Assay decodes into an arena," "zero-malloc decoding," "arena-backed
results," and any variant. If Assay returns ordinary Swift structs containing `String`
and `Array`, those fields are `malloc`'d, one per field, and no arena changes that.

**What survives, and it's not nothing:** an arena can back the parser's own working
set — nesting stack, key-match scratch, index/tape arrays, number-parse buffers,
error accumulation before it's needed. In swift-foundation's decoder that scratch is
a meaningful fraction of total allocations. Eliminating it is a real win. It is just
not the win people imagine when they hear "arena."

**The one honest escape hatch, and its cost:** Assay could offer a *view* type — a
`AssayValue`/`Span`-based lazy accessor that never materializes `String`s at all, so
the arena holds the bytes and the user reads slices. That genuinely eliminates output
allocations. It also stops being a `Codable`-shaped decoder and imposes a lifetime on
the result. **If Assay wants a zero-allocation story, this is the only shape that
supports one, and it should be a separate, clearly-labelled API — not the default.**

### 4.1 — `withUnsafeTemporaryAllocation` (SE-0322)

**VERIFIED, and it CORRECTS the "4 KB" folklore.**
`swift/stdlib/public/core/TemporaryAllocation.swift:62-95`:

```swift
if alignment > _minAllocationAlignment() { return false }
if _fastPath(byteCount <= 1024) { return true }
return false
```

Facts:

- **The stack-allocation cliff is 1024 bytes.** At 1025 bytes you get `malloc`,
  transparently and silently. There is no diagnostic.
- The alignment test rejects over-aligned requests to the heap path too. A 64-byte-aligned
  SIMD scratch buffer may heap-allocate even when small. Check `_minAllocationAlignment()`
  on your target before assuming SIMD scratch is stack-allocated.
- SE-0322 describes a "runtime heuristic" for deciding stack vs heap. In the shipping
  implementation **that hook is a stub that returns false**; the real decision is the
  constant above. VERIFIED.
- **It does not cross a function boundary.** The pointer is valid only for the duration
  of the closure body; escaping it is undefined behavior. This is the constraint that
  matters most for Assay: you cannot allocate scratch in `decode()` and hand it to a
  helper that outlives the call, and you cannot build a decoder whose arena spans a
  streaming API this way.
- Under the hood it's `Builtin.stackAlloc`, i.e. an LLVM `alloca` in the caller frame
  when the fast path is taken. VERIFIED.

**Assay's practical budget:** 1024 bytes of free scratch per frame. That is enough for
a nesting stack (a 64-deep depth stack of `UInt8` tags is 64 bytes), enough for a
key-match scratch buffer, enough for a small index table. It is **not** enough for a
tape over a 50 kB document. For the tape, a heap arena allocated once and reused across
calls beats both `withUnsafeTemporaryAllocation` and a fresh `Array` — and that arena
can be a plain `UnsafeMutableRawBufferPointer` owned by the `Assayer<T>` instance.

**This is the concrete, defensible allocation design for Assay:**
`Assayer<T>` owns a reusable scratch buffer; `decode` bump-allocates its working set
out of it; output values are ordinary malloc'd Swift values. Steady-state scratch
allocations per decode: **zero**. Output allocations per decode: one per non-SSO
string, one per array, one per dictionary. That is a claim Assay can make and defend.

### 4.2 — `ManagedBuffer` / `ManagedBufferPointer`

**VERIFIED.** `ManagedBuffer<Header, Element>` gives you one heap allocation holding
a header and a tail-allocated element array, via `Builtin.allocWithTailElems_1`. This
is exactly how `Array` and `Dictionary` storage are built.

Useful to Assay for: a single-allocation scratch region with metadata, or a
single-allocation result buffer for the view-type API of §4.0. Not useful for
redirecting `String`/`Array` allocation — it's a way to *make* one allocation, not a
way to *serve* someone else's.

Cost note: `ManagedBuffer` is a class, so it participates in ARC and its accessors go
through `withUnsafeMutablePointerToElements`. For hot scratch, a raw
`UnsafeMutableRawBufferPointer` owned by `Assayer<T>` is cheaper and simpler.
UNVERIFIED as a measured difference.

### 4.3 — Idiomatic arenas in the ecosystem: what actually exists

I searched swift-collections, swift-nio, swift-syntax, and swift-algorithms for an
arena/pool abstraction. **Findings:**

- **swift-nio's `ByteBuffer` is not a pool.** `swift-nio/Sources/NIOCore/ByteBuffer-core.swift:31-37`
  and `:79-80` — its storage is a direct `malloc`/`realloc`/`free` wrapper (via
  `sys_malloc` shims), with COW and slicing on top. There is no free-list, no arena,
  no per-thread cache. **VERIFIED.** This is worth knowing because "NIO uses an arena"
  is a thing people assume. It doesn't. Its win is *amortization* — buffers are reused
  across requests by the allocator/pipeline, not bump-allocated.
- **swift-syntax** has arena-ish structure in its `SyntaxArena` for parsed syntax nodes
  — this is the closest thing in the ecosystem to a real Swift arena, and it works
  precisely because syntax nodes are its *own* types with *its own* storage, not
  `String`/`Array`. UNVERIFIED in detail (not read line-by-line), but the shape confirms
  the §4.0 rule: arenas in Swift work for types you define, not for stdlib types.
- **The Swift runtime itself uses bump allocators internally** — `MetadataAllocator` and
  `swift/stdlib/public/runtime/StackAllocator.h`. These are runtime-private. VERIFIED
  they exist; they are not available to Assay.

**Conclusion: there is no idiomatic Swift arena to copy, because the language doesn't
support the useful case.** Assay building its own scratch bump allocator is reasonable
and unremarkable; presenting it as an innovation is not.

---

## 5. The allocator, per platform

### 5.1 — What each platform actually uses

| Platform | Allocator | Small-alloc strategy | Confidence |
|---|---|---|---|
| macOS / iOS | `magazine_malloc`, with `nano_zone` for allocations ≤256 B | Per-CPU magazines, size-class free lists; nano zone is a fast bump-ish path for tiny blocks | VERIFIED it's the design; **quantities UNVERIFIED** |
| Linux glibc | `ptmalloc2` + **tcache** (glibc ≥2.26) | Per-thread cache of 64 bins, lock-free fast path | VERIFIED |
| Linux musl | `mallocng` (musl ≥1.2.1) | Slot-based group allocator, global lock | VERIFIED it's the design |
| **Swift Static Linux SDK** | **mimalloc 2.2.4** | Per-thread heaps, free-list sharding | **VERIFIED — see §5.3** |
| Windows | `HeapAlloc` / segment heap; Swift links UCRT `malloc` | LFH (Low Fragmentation Heap) for small sizes | VERIFIED it's the design |
| Wasm | `dlmalloc` (wasi-libc default) | Boundary-tag, single-threaded, no per-thread caching | VERIFIED |

### 5.2 — Is musl's allocator known-slow?

**Partially verified, and it needs care.** mallocng (musl ≥1.2.1) replaced the older
`oldmalloc`, which was genuinely and notoriously slow under multithreaded load due to
a single global lock. mallocng improved correctness and hardening substantially. The
widely-repeated claim that musl is "slow for many small allocations under thread
contention" is **UNVERIFIED at any specific magnitude** — I found no controlled
benchmark I'd cite, and I will not manufacture one.

**Do not quote Rich Felker (musl's author) on this.** I could not verify his exact
wording on mallocng's performance characteristics from primary sources in this
environment, and paraphrasing him would be worse than silence.

What *is* solid: multiple language ecosystems (Rust's `musl` targets, Go's early
CGO experience, Alpine-based container reports) have documented replacing musl's
allocator with jemalloc/mimalloc for allocation-heavy workloads. That's circumstantial
convergence, not measurement.

### 5.3 — musl and the Static Linux SDK

**VERIFIED, and it makes the brief's premise stale.**
`swift-docker/swift-ci/sdks/static-linux/scripts/build.sh:623-645` **deletes musl's
allocator object files out of `libc.a` and links mimalloc 2.2.4 in their place.**

So: **statically-linked Linux Swift binaries built with the official Static Linux SDK
do not use mallocng.** They use mimalloc. Any Assay documentation that says "on static
Linux you're on musl's slow allocator, so we avoid allocations" is wrong as of 2026,
and a reviewer will catch it.

The correct framing is the opposite and stronger: **the Swift project itself concluded
that the platform allocator was worth replacing, and did so.** That is evidence that
allocation count is the right thing to optimize — cite it as motivation, not as a
performance number.

**Non-static Linux Swift (the common server case, dynamically linked against glibc)
is on ptmalloc2+tcache**, which is competent. Don't imply otherwise.

### 5.4 — What this means for Assay's design

The allocator differences are large enough that **wall-clock comparisons across
platforms are not comparable**, and small enough that **for a fixed platform, the
allocation *count* predicts the cost better than any allocator-specific tuning would
help.** Both point to the same conclusion:

> Optimize and report **allocation count**, which is allocator-independent and
> deterministic. Do not tune for any specific allocator. Do not claim allocator-relative
> speedups.

### 5.5 — The published gap (VERIFIED, narrowed)

The brief asks me to verify that no Swift-specific published allocator comparison
exists, and not to invent one. **Result: the gap is real but no longer total.**

Three genuine data points exist and should be cited rather than pretending to a
vacuum:

1. **forums.swift.org thread 75003** — community discussion of allocator performance
   for Swift on Linux, including mimalloc/jemalloc substitution results.
2. **forums.swift.org thread 75114** — related thread on Swift server allocation
   behavior.
3. **SwiftLint issue #6298** — a concrete report of allocator-attributable performance
   differences in a real Swift tool.

**What still does not exist, verified by absence:**

- No cross-platform Swift allocator comparison (Apple vs glibc vs musl vs Windows vs Wasm).
- No Swift JSON-decoder-specific allocator study.
- No peer-reviewed or vendor-published Swift allocator benchmark of any kind.

**Recommendation:** Assay should state this gap explicitly in its performance docs and
should *not* fill it with hand-waving. If Assay's own harness happens to produce
allocator-comparison data as a byproduct, publishing it would be a real contribution —
but it must be published as measurement, with methodology, not as a claim.

---

# PART B — BENCHMARKING AND THE CREDIBILITY OF A "FASTEST" CLAIM

## 11. The harness: Swift benchmarking in 2026

### 11.1 — The field

| Tool | Metrics | Platforms | Verdict for Assay |
|---|---|---|---|
| **ordo-one/package-benchmark** | ~32, incl. malloc counts, instructions, syscalls, ARC ops, peak memory, wall clock, throughput | macOS + Linux; **not** Windows/Android/Wasm | **The only real choice.** VERIFIED |
| XCTest `measure` | Wall time, a few Apple-only metrics | Apple only | Not viable cross-platform |
| swift-testing | **No performance facilities as of 2026** | — | VERIFIED absence. Do not plan around it |
| Swift repo's benchmark suite | Compiler-team-oriented, wall time + some instr counts | Requires toolchain build | Not reusable as a package dependency |
| swift-collections-benchmark | Log-log size-scaling curves, wall time | Everywhere Swift runs | **Complementary and underrated** — see §12.4 |

### 11.2 — package-benchmark: what it actually measures

**VERIFIED.** `package-benchmark/Sources/Benchmark/BenchmarkMetric.swift:17-122` — a
~32-case enum. The ones that matter for Assay:

- `.mallocCountTotal` — total allocations. **This is the metric.** Deterministic,
  machine-independent, and directly the thing §1–§4 are about.
- `.mallocCountSmall` / `.mallocCountLarge` — split by size class.
- `.memoryLeaked` — allocations not freed.
- `.instructions` — retired instruction count, via `perf_event_open`. **Linux only,
  and only where the PMU is exposed.**
- `.syscalls`, `.readSyscalls`, `.writeSyscalls`, `.threads`, `.contextSwitches`.
- `.retainCount` / `.releaseCount` / `.objectAllocCount` — **ARC traffic.** Underused
  and highly relevant to §3.
- `.peakMemoryResident`, `.peakMemoryVirtual`.
- `.wallClock`, `.throughput` — the noisy ones.

**How malloc counting works:** two backends — a malloc interposer, and a jemalloc-stats
path. **VERIFIED.** The interposer is what gives cross-allocator counts.

**Statistics:** HdrHistogram, so you get p0/p25/p50/p75/p90/p99/p100 rather than a mean.
This matters: a mean hides the tail, and for a server hot path the tail is the product.

### 11.3 — The `.instructions` trap, and it is a serious one

**VERIFIED.** `package-benchmark/Platform/CLinuxOperatingSystemStats/CLinuxOperatingSystemStats.c:111-116`
— when `perf_event_open` fails, **the diagnostic `fprintf` is commented out.** The
failure is silent and the metric reports **zero**.

GitHub-hosted runners do not expose the PMU. Therefore:

> **If Assay configures `.instructions` in CI on GitHub-hosted runners, it will get
> zeros, and a threshold check against zero will pass forever.** A green CI badge that
> proves nothing.

Either run on self-hosted runners with `perf_event_paranoid` lowered, or use a
PMU-free instruction-count method (§13.3), or don't claim instruction counts.

### 11.4 — What can't be measured with package-benchmark

**Windows, Android, and Wasm are not supported.** VERIFIED by absence of platform
implementations. This is the hard constraint behind §15.

---

## 12. Corpora, and why the standard ones are wrong for Assay

### 12.1 — The standard files and what each stresses

| File | Size | Stresses |
|---|---|---|
| `twitter.json` | ~630 kB | Unicode-heavy strings, escapes, deep-ish nesting, mixed types. The most "realistic API-like" of the set |
| `canada.json` | ~2.2 MB | Almost pure `Double` parsing in nested arrays. A float-parser benchmark wearing a JSON costume |
| `citm_catalog.json` | ~1.7 MB | Many objects with repeated keys, lots of integers, `null`s. Stresses key handling and object construction |
| `github_events.json` | ~65 kB | Small-object-heavy, realistic API shape. **The closest to Assay's band, and still above it** |
| `gsoc-2018.json` | ~3.3 MB | Long string values |
| `marine_ik.json` | ~2.9 MB | Deep nesting, floats |

**VERIFIED** — these are the standard set used by simdjson, yyjson, sonic, and
`json_benchmark`.

### 12.2 — The finding that matters: nobody measures Assay's workload

**VERIFIED, with a citable primary source.** simdjson's paper (Langdale & Lemire,
*Parsing Gigabytes of JSON per Second*, arXiv:1902.08318) states:

> "We deliberately did not consider small documents (smaller than 50 kB)."

That is the entire published high-performance JSON literature's scope statement, and
it excludes Assay's target band by construction. yyjson, sonic-rs, and
`kostya/benchmarks`-derived suites use the same corpus and inherit the same exclusion.

Assay's workload — **1–50 kB request/response bodies, 5–40 fields, decoded into a
known struct, in a server hot path** — is **unmeasured in the published literature.**

Two consequences, and they pull in opposite directions:

- **Opportunity.** Assay can build and publish the first credible corpus for this band.
  That's a genuine contribution and a much better story than a bar chart.
- **Obligation.** Assay therefore **cannot** claim "fastest JSON decoder" by pointing at
  the standard corpus, because on that corpus it will be compared on throughput where
  SIMD bulk parsers win, and because that corpus isn't its use case. Any claim it makes
  must come with its own corpus and a statement of why the standard one doesn't apply.
  A reader who knows the field will otherwise assume Assay avoided the standard corpus
  because it loses on it.

### 12.3 — A proposed corpus for Assay

Shape it by *what varies*, not by what files happen to exist:

**Dimension 1 — size:** 512 B, 2 kB, 8 kB, 32 kB, 64 kB (the last as a boundary case
into the published band, so results are comparable to something).

**Dimension 2 — field-type mix**, each at fixed size:
- `scalars` — all `Int`/`Double`/`Bool`. Isolates number parsing and struct fill.
- `short-strings` — all string values ≤15 bytes. **Isolates the SSO win** and will show
  the Wasm cliff of §2.3 dramatically.
- `long-strings` — all string values 30–120 bytes. One malloc per field, worst case.
- `uuids-and-dates` — the realistic API case: 36-char UUIDs, ISO-8601 timestamps. Every
  string allocates on every platform.
- `escaped` — strings requiring unescaping. Separates the "can memcpy" path from the
  "must transform" path, which is a large fork in any decoder.
- `arrays-of-scalars` — tests §2.1's exact-sizing hypothesis directly.
- `arrays-of-structs` — tests the other side of it.
- `optionals-absent` / `optionals-present` — missing-key handling is a real cost and
  nobody benchmarks it.
- `unknown-keys` — keys in the payload not in the struct. Skipping cost. Extremely
  common in real APIs and completely unmeasured anywhere.
- `nested-3-deep` — realistic envelope + payload + metadata.

**Dimension 3 — the negative cases**, which no JSON benchmark includes and which
matter enormously for a *validator*:
- `invalid-early` — malformed at byte 10 of 8 kB. Measures fail-fast.
- `invalid-late` — malformed at byte 8000 of 8 kB.
- `type-mismatch` — well-formed JSON, wrong types for the schema.
- `validation-fail-many` — a payload with 20 validation errors, to measure the
  issue-collection path of §1.

**Provenance:** synthesize from real public API response schemas (Stripe, GitHub,
Twilio, Kubernetes) rather than hand-writing, and say so. Publish the generator, not
just the files.

### 12.4 — Measuring per-operation overhead honestly

At 1–50 kB, **fixed per-call overhead is a large fraction of total cost** — setup,
first allocation, any one-time metadata lookup, any existential box. Throughput in
GB/s is the wrong unit and will flatter or damn Assay arbitrarily depending on size.

Three techniques, in increasing order of honesty:

1. **Report ns/op and allocs/op at each size, never GB/s.** Trivial and mandatory.
2. **Report the size-scaling curve, not a point.** This is exactly what
   **swift-collections-benchmark** does — log-log plots of time vs input size across
   several orders of magnitude. A decoder with low fixed overhead and a decoder with
   high fixed overhead have visibly different curves at the left end, and a single
   number at one size cannot distinguish them. **This is the single most credible
   presentation format available and it already exists as a Swift tool.** VERIFIED it
   exists and does this; UNVERIFIED how easily it composes with package-benchmark.
3. **Fit and publish the intercept.** From the curve, report the empty-input /
   single-field decode cost explicitly as "fixed overhead per decode call, X ns, Y
   allocations." That number is the actual product claim for a server hot path, and
   almost nobody publishes it.

**Additionally:** benchmark the *warm* path. Real servers decode the same type
thousands of times. If `Assayer<T>` amortizes anything (scratch buffer, key table),
a cold-start-only benchmark understates it — and a warm-only benchmark overstates it
for CLI users. Publish both, labelled.

---

## 13. Regression detection in CI

### 13.1 — What package-benchmark's threshold mechanism does

**VERIFIED.** `package-benchmark/Sources/Benchmark/BenchmarkThresholds.swift:22-33`:

```swift
///   - relative: A dictionary with relative thresholds tolerances per percentile (using for delta comparisons)
///   - absolute: A dictionary with absolute thresholds tolerances per percentile (used both for delta and absolute comparisons)
public let relative: RelativeThresholds
public let absolute: AbsoluteThresholds
```

Two modes, and the distinction is the whole story:

- **Relative / delta:** compare against a stored baseline, fail if the change exceeds a
  percentage at a given percentile. Requires a committed baseline per machine class.
  Sensitive to runner drift.
- **Absolute:** fail if the metric exceeds a hard number at a given percentile. **For a
  deterministic metric like `mallocCountTotal`, the absolute threshold can be the exact
  expected count.** No baseline, no drift, no flakiness.

**This is the key insight for Assay's CI:** allocation counts are deterministic, so an
absolute threshold turns "performance regression detection" into an ordinary
pass/fail assertion, as reliable as a unit test.

### 13.2 — What serious Swift packages actually do

**swift-nio** — **VERIFIED**, and it's the most instructive example.
`swift-nio/Benchmarks/Benchmarks/NIOCoreBenchmarks/Benchmarks.swift:46-57`: CI collects
**only `mallocCountTotal`**. `wallClock` and `instructions` are compiled out behind
`#if LOCAL_TESTING`.

Read that again. The most performance-sensitive package in the Swift server ecosystem
**does not gate on time in CI at all.** It gates on allocation count and nothing else,
and it does time measurement manually, locally, when investigating.

That is the state of the art and Assay should copy it exactly.

**swift-collections** — uses swift-collections-benchmark for size-scaling curves, run
and inspected rather than hard-gated. CI (`.github/workflows/pull_request.yml`) is
correctness-focused. **VERIFIED.** The lesson: curves are for humans, counts are for
robots.

**swift-foundation / swift-syntax** — benchmark infrastructure exists; I did **not**
verify a hard perf gate in either. Do not claim they have one.

### 13.3 — Instruction counts without a PMU

Since `.instructions` is dead on hosted runners (§11.3), the alternative used elsewhere
is **Valgrind/Cachegrind-based instruction counting** — simulated, so fully
deterministic and PMU-free, at ~50× slowdown. This is what Rust's `iai` / `iai-callgrind`
and the CodSpeed service do. **VERIFIED that this approach exists and is used in Rust
CI; UNVERIFIED whether it works cleanly against Swift binaries** — Swift's runtime does
things Valgrind sometimes objects to, and I could not test it.

**Recommendation:** treat Valgrind instruction counting as an *experiment worth running
early*, because if it works it gives Assay a second deterministic CI metric alongside
allocation counts, and that combination is a genuinely strong regression story. But do
not put it on the roadmap as a certainty.

### 13.4 — The concrete CI design for Assay

1. **Gate on `.mallocCountTotal` with absolute thresholds**, per benchmark, per corpus
   entry. Exact expected counts. Any change fails and must be explicitly re-baselined
   in a reviewed commit. This is the enforcement mechanism.
2. Also gate `.retainCount` / `.releaseCount` — ARC traffic is deterministic too, and
   §3 says it's a real cost.
3. `.peakMemoryResident` with a generous absolute ceiling, as a canary.
4. **Do not gate on `wallClock`.** Collect it, publish it, never fail on it.
5. **Do not configure `.instructions` on hosted runners** without first verifying it
   returns nonzero — otherwise the check is decorative.
6. Run the swift-collections-benchmark-style curve nightly, publish the plot, don't gate.

---

## 14. How to make the claim honestly

### 14.1 — What credible projects do

**simdjson.** Publishes a peer-reviewed paper with full methodology, names its hardware,
states its scope limits explicitly (§12.2), ships the benchmark harness, and reports
GB/s on a named public corpus. **What makes it credible: the scope statement.** They
tell you what they didn't measure. That single sentence buys more trust than the
numbers do.

**yyjson.** Ships a full benchmark repository with the exact machines, compilers, and
flags enumerated, and reports across multiple compilers on multiple platforms —
including cases where it loses. **What makes it credible: it publishes losses.**

**sonic-rs.** Benchmarks against serde_json on the standard corpus with a reproducible
harness, and is explicit that its advantage is workload-dependent.

**swift-collections.** Doesn't make a speed claim at all. Publishes size-scaling curves
and lets the reader draw conclusions. **What makes it credible: no claim.**

### 14.2 — What makes a README table worthless

- No hardware, OS, compiler version, or optimization flags.
- Competitor built differently from the subject (e.g. subject at `-Ounchecked`, §3.2).
- One input file, or an input chosen to suit.
- A single number with no distribution — no p50/p90/p99.
- No harness published, so nobody can reproduce it.
- Comparing a specialized tool to a general one without saying so (Assay-vs-Foundation
  is exactly this trap: Foundation's `JSONDecoder` is fully general and `Codable`-driven;
  Assay's macro knows the schema at compile time. That's a real advantage and also an
  unfair comparison unless stated).
- Ratios without absolutes ("3× faster" with no ns/op).
- Never updated, so it silently describes a version nobody runs.

### 14.3 — What Assay should publish

**Publish:**

1. **Allocations per decode**, per corpus entry, as an exact integer, compared against
   Foundation. This is deterministic, machine-independent, reproducible by anyone, and
   it is *the* number that reflects Assay's actual design advantage. **Lead with it.**
2. ns/op with p50/p90/p99, per corpus entry, per platform where measurable, with full
   machine/toolchain/flags disclosure.
3. The **fixed per-decode overhead** (§12.4) as a headline number.
4. The size-scaling curve.
5. The corpus itself and the generator that produces it.
6. The harness, runnable by anyone with one command.
7. **The cases where Assay is not fastest.** Large documents. Dictionary-heavy payloads
   (§2.5). Anything where a SIMD bulk parser wins. Publishing these is what makes the
   rest believable.
8. The scope statement, in simdjson's spirit: "Assay is optimized for 1–50 kB payloads
   decoded into known types. We do not optimize for, and do not claim advantage on,
   multi-megabyte documents or schemaless traversal."

**Refuse to claim:**

1. **"Fastest JSON decoder."** Unqualified, unprovable, and false on some axis.
2. **"Fastest on all platforms"** — see §15; it cannot be measured on 3 of 5.
3. **"Zero-allocation"** or **"arena-allocated"** — §4.0 says it's false for output values.
4. Any speedup ratio on a platform where the harness doesn't run.
5. Any allocator-relative claim (§5.5).
6. Any claim about what fraction of strings hit SSO without publishing the histogram (§2.3).

**The claim Assay can actually defend**, and it's a good one:

> "Assay performs the minimum number of heap allocations a Swift decoder can perform:
> one per non-inline string, one per array, one per dictionary, and zero for everything
> else — no intermediate representation, no key strings, no coding-path construction, no
> container boxes. On our corpus of 1–50 kB API payloads, that is N allocations per
> decode versus Foundation's M. Here is the corpus, the harness, and the number on every
> platform we can measure."

That is checkable, falsifiable, survives CI, and doesn't decay.

---

## 15. The cross-platform measurement problem

### 15.1 — Where the harness actually runs

| Platform | package-benchmark | Malloc counts | Instructions | Wall clock meaningful? |
|---|---|---|---|---|
| macOS | Yes | Yes | No (no `perf`) | Yes, on dedicated hardware |
| Linux x86_64 | Yes | Yes | Only with PMU access | Yes, on dedicated hardware |
| Linux arm64 | Yes | Yes | Only with PMU access | Yes, on dedicated hardware |
| **Windows** | **No** | No | No | — |
| **Android** | **No** | No | No | **No** — emulator timing is meaningless |
| **Wasm** | **No** | No | No | **No** — runtime-dependent |

**VERIFIED by absence** of Windows/Android/Wasm platform implementations in
package-benchmark.

### 15.2 — Is measurement on Android emulator / Wasm meaningful?

**The brief's suspicion is correct for wall time.** An Android emulator's timing
reflects the host, the emulator's scheduling, and the translation layer — not device
performance. A Wasm runtime's wall clock reflects that runtime's JIT/AOT strategy, not
Assay. Neither number transfers to anything.

**Instruction counts would be meaningful, and there is a real mechanism for Wasm.**
**wasmtime's fuel metering** counts executed operations deterministically. It is not
an instruction count on real hardware, but it is a *deterministic, reproducible,
comparable-to-itself* number — which is exactly what a regression gate needs. Running
Assay's corpus under wasmtime with fuel metering would give a genuine CI signal for the
Wasm target. **VERIFIED that wasmtime has fuel metering; UNVERIFIED that it works
cleanly for a Swift-on-Wasm binary or that anyone has done this.** This is a plausible,
novel, and cheap experiment.

For Android: an allocation count obtained by running the corpus under a malloc
interposer on a real device would be meaningful; on an emulator, allocation counts are
*still* meaningful (they're a property of the program, not the machine) even though
timing isn't. **This is the underrated point: allocation counts port to platforms where
timing does not.** If Assay can get `mallocCountTotal` on Android and Wasm by any means,
it has a cross-platform regression story without a cross-platform timing story.

### 15.3 — The honest fallback claim

Assay cannot claim cross-platform speed. It can claim cross-platform *correctness* and
cross-platform *allocation behavior*. The honest formulation:

> "Assay's allocation behavior is a property of the generated code and is identical on
> every platform; we verify it in CI on Linux and macOS and it does not vary. Wall-clock
> performance is measured on macOS and Linux on dedicated hardware; we do not have
> reliable timing measurement on Windows, Android, or Wasm and therefore make no speed
> claims there. Correctness is tested on all five."

That is a stronger statement than a fabricated benchmark table, and it is the kind of
thing that makes the *rest* of Assay's claims believable.

**One real caveat to even this:** §2.3 means allocation behavior is **not** actually
identical across platforms — the SSO threshold differs, so string fields of 9–15 bytes
allocate on Wasm and not on x86_64. Assay must either measure allocation counts per
platform or state the SSO threshold dependency explicitly. Getting this wrong would be
an easily-caught error in an otherwise careful document.

---

## 20 — Do not assert these

Everything in this list is either unverified, contradicted, or was a plausible
hypothesis that source does not support. **None of it may appear in Assay's
documentation, README, or marketing.**

**Fabrications to avoid entirely:**

1. **Any specific allocator benchmark number** — "musl is 3× slower," "nano_zone gives
   X ns allocations," any figure comparing magazine_malloc / ptmalloc2 / mallocng /
   mimalloc / HeapAlloc / dlmalloc. No such Swift-specific published comparison exists
   beyond the three community data points in §5.5. Do not invent one; do not round one
   up from another language's benchmark.
2. **Rich Felker's exact wording on mallocng's performance.** Not verified from primary
   sources. Do not quote or paraphrase him.
3. **Apple's `TINY_QUANTUM` value or nano_zone size-class boundaries.** Not verified.
   The "≤256 B" nano-zone figure in §5.1 is the commonly-cited number and is itself
   UNVERIFIED.
4. **Windows Segment Heap behavior for Swift processes.** Whether Swift/UCRT processes
   opt into Segment Heap vs NT Heap is unverified.
5. **The Wasm shadow-stack size.** Any claim about how much stack `withUnsafeTemporaryAllocation`
   can safely use on wasm32 is unverified — and note the SSO/1024-byte constants are
   *also* different there in ways that interact.

**Compile-dependent claims that require a toolchain to confirm:**

6. **Whether `mapData.append(contentsOf: [...])` stack-promotes** the temporary array.
   Unverified; requires SIL inspection.
7. **The exact `alloc_box` count per nesting level after optimization** in a generated
   decoder. Unverified; requires SIL inspection at a specific optimization level.
8. **That the `_ArrayBuffer` bridging branch is fully eliminated for `UInt8` on Darwin**
   in all inlining contexts (§2.4). Reasoned, not confirmed.
9. **That `begin_cow_mutation` is hoisted out of a given fill loop** (§3.1). It's the
   optimizer's option, not a guarantee, and it depends on codegen shape.
10. **Any quantitative claim about `init`-once vs field-by-field** (§3.3). Mechanism
    verified; magnitude not.

**Claims contradicted by source — do not repeat the folklore:**

11. **"The small-string threshold is 15 bytes."** True only on 64-bit. It is 14 on
    Android arm64 and **8 on wasm32 and all 32-bit**. (§2.3)
12. **"`withUnsafeTemporaryAllocation` stack-allocates up to 4 KB."** The constant is
    **1024**. (§4.1)
13. **"SE-0322's runtime heuristic decides stack vs heap."** That hook is a stub
    returning false. (§4.1)
14. **"`ContiguousArray` is faster than `Array` for bytes."** They are the same type off
    Darwin. (§2.4)
15. **"Exclusivity checking is off in release builds."** Both static and dynamic
    enforcement default to true at every optimization level; `-Ounchecked` is what
    disables dynamic. (§3.2)
16. **"The uniqueness check is `isKnownUniquelyReferenced` per append."** It's
    `begin_cow_mutation`, a SIL instruction the optimizer can hoist. (§3.1)
17. **"String's uninitialized-capacity initializer is SE-0309."** It is **SE-0263**.
18. **"Static Linux Swift binaries use musl's mallocng."** The Static Linux SDK deletes
    musl's allocator and links **mimalloc 2.2.4**. (§5.3)
19. **"swift-nio uses an arena / buffer pool."** `ByteBuffer` is a direct malloc/realloc
    wrapper with COW on top. No pool, no arena, no free-list. (§4.3)
20. **"Foundation builds coding paths eagerly."** `_CodingPathNode` already defers
    projection to the error path. (§1.2)
21. **"No Swift-specific allocator comparison exists at all."** Three community data
    points now exist (§5.5). State the gap accurately: no *cross-platform* comparison,
    no *decoder-specific* study, no peer-reviewed work.

**Claims about the arena that are false:**

22. **"Assay decodes into an arena."** / **"arena-backed results."** / **"zero-allocation
    decoding."** Output `String`/`Array`/`Dictionary` values are `malloc`'d and cannot be
    otherwise. (§4.0) The only legitimate zero-allocation shape is a lifetime-bound view
    API, which is a different product.

**Claims about benchmarking that would be dishonest:**

23. **Any "fastest" claim on Windows, Android, or Wasm.** package-benchmark does not run
    there. There is no measurement. (§15.1)
24. **Any instruction-count claim from GitHub-hosted CI.** `perf_event_open` fails
    silently and the metric reports zero. (§11.3)
25. **Any benchmark comparison built with `-Ounchecked`** on Assay's side. (§3.2)
26. **"Fastest JSON decoder"** on the strength of the standard corpus — that corpus
    excludes Assay's target band by the field's own stated scope. (§12.2)
27. **Any claim about what fraction of API strings fit in SSO** without publishing the
    measured histogram. No such published measurement exists. (§2.3)
28. **That Valgrind/Cachegrind instruction counting works for Swift binaries.**
    Unverified; it works for Rust and C. (§13.3)
29. **That wasmtime fuel metering works for a Swift-on-Wasm binary.** Unverified and,
    as far as I can tell, undone by anyone. (§15.2)
30. **That swift-foundation or swift-syntax have hard performance gates in CI.** Not
    verified. Only swift-nio's `mallocCountTotal` gate was confirmed. (§13.2)

---

## Appendix A — Corpus and HEADs

All source claims were checked against local clones at these HEAD dates:

| Repo | HEAD date |
|---|---|
| `swiftlang/swift` | 2026-07-25 |
| `swiftlang/swift-foundation` | 2026-07-24 |
| `apple/swift-nio` | 2026-07-24 |
| `ordo-one/package-benchmark` | 2026-07-24 |
| `apple/swift-collections` | 2026-07-23 |
| `swiftlang/swift-evolution` | (as cloned) |
| `swiftlang/swift-docker` | (as cloned) |

Additional repos consulted: `simdjson`, `yyjson`, `sonic-rs`, `sonic-cpp`, `serde-json`,
`serde`, `simd-json`, `json-benchmark`, `ZippyJSON`, `ReerJSON`, `swift-syntax`,
`swift-algorithms`, `hummingbird`, `vapor`, `swift-android-sdk`, `swift-sdk-generator`.

## Appendix B — Key file:line index

| Claim | Location |
|---|---|
| SSO capacity per platform | `swift/stdlib/public/core/SmallString.swift:80-94` |
| 1024-byte temp-alloc cliff | `swift/stdlib/public/core/TemporaryAllocation.swift:62-95` |
| `Array` == `ContiguousArray` off-ObjC | `swift/stdlib/public/core/Array.swift:299-311` |
| Growth 2×, shrink trap | `swift/stdlib/public/core/ArrayShared.swift:179-198` |
| `String(unsafeUninitializedCapacity:)` small path | `swift/stdlib/public/core/String.swift:723-748` |
| Exclusivity defaults true | `swift/include/swift/AST/SILOptions.h:264-268` |
| Dead `_swift_slowAlloc` hook | `swift/include/swift/Runtime/InstrumentsSupport.h:50-57` |
| Allocator generics declined | `swift-evolution/proposals/0527-rigidarray-uniquearray.md:1743` |
| `stringify` dictionary allocation | `swift-foundation/.../JSON/JSONDecoder.swift:1266-1303` |
| `_CodingPathNode` deferred path | `swift-foundation/.../CodableUtilities.swift:32-82` |
| Tape growth heuristic | `swift-foundation/.../JSON/JSONScanner.swift:279-295` |
| BenchmarkMetric enum | `package-benchmark/Sources/Benchmark/BenchmarkMetric.swift:17-122` |
| Threshold relative/absolute | `package-benchmark/Sources/Benchmark/BenchmarkThresholds.swift:22-33` |
| Silent perf failure | `package-benchmark/Platform/CLinuxOperatingSystemStats/CLinuxOperatingSystemStats.c:111-116` |
| NIO gates only on malloc count | `swift-nio/Benchmarks/Benchmarks/NIOCoreBenchmarks/Benchmarks.swift:46-57` |
| ByteBuffer is a malloc wrapper | `swift-nio/Sources/NIOCore/ByteBuffer-core.swift:31-37, :79-80` |
| mimalloc substituted for musl | `swift-docker/swift-ci/sdks/static-linux/scripts/build.sh:623-645` |
