# Efficiency — counters, not clocks

Assay's performance should come from algorithms and from what Swift's ownership model lets a
decoder avoid, not from extra cores, memory or SIMD. That is a claim about **resources**, and
it can be checked exactly. This document holds the method, the decision rule, and a ledger
with one row per idea. Each row is decided by a count, not by an opinion or a wall clock.

## The instruments

| instrument | question it answers | where it runs | gate |
|---|---|---|---|
| `Benchmarks/count.py` (Callgrind + DHAT) | how many instructions, retains, releases, allocations and uniqueness checks does ONE call of each verb cost, on every matrix fixture | Linux x86-64 + aarch64 (CI); Mac via `count.sh` in a container | calls and blocks ratchet exactly; Ir +2%; heap bytes +1% |
| `Experiments/05-arc-audit` | which retain/release/allocation SITES did the optimiser leave in each function | Linux (CI), any host locally | a hot function gaining a site fails |
| `count.py scale` (Callgrind + DHAT) | is every verb LINEAR in every input property: the log-log slope of instructions and heap bytes over four sizes, on nine axes (`allAxes` in `Shapes.swift`) | Linux (CI), Mac via `count.sh scale` | tail slope > 1.10 fails; absolute, no baseline |
| `ScalingTests` (wall-clock RATIO) | the same question on Windows and macOS, and for YAML/XML/TOML, which the matrix does not cover: 8× the input must cost < 16× | every platform the test suite runs on | a ratio bound, a blowup detector, never tightened |
| `AssayMatrix run` (wall clock) | how fast, on this machine | anywhere | report only, never a gate |
| `AssayBench allocations` (live blocks) | what a decoded value retains | macOS CI | absolute thresholds (existing) |

Why exact counts are possible at all: Valgrind counts in software, so it needs no PMU. That
is also why it works on a hosted runner, where package-benchmark's instruction counter
silently reports zero. Measured 2026-09-19, Swift 6.3.3, aarch64 Linux: runtime call counts
were identical across three runs. Instruction counts varied by ~50 in 4.9 million.

**Sites vs executions.** The ARC audit counts code sites, and `count.py` counts executions.
A release site on an error path costs nothing at run time and still costs code size, so the
two instruments answer different questions and neither replaces the other.

## Across architectures

The first CI run (2026-09-19) counted every cell on x86-64 and aarch64 hosted runners.
Retain, release, allocation and uniqueness counts agree almost everywhere. The exceptions:
- a fixed +1 or +2 per call on x86-64;
- `slow_alloc`, which is always 0 there because the runtime reaches it differently (heap
  blocks agree exactly);
- a handful of String-release differences, listed in ledger row 1.
Instructions differ by a few percent either way. That is why each architecture has its own
baseline.

## Decision rule

1. **Resource counters first**: allocations, retained bytes, peak live bytes, retain/release
   calls, input passes. A change that lowers one may cost up to 5% instructions.
2. **Instructions second.** Wall clock is reported and never decides.
3. **Asymptotic slope is inviolable.** No verb may be super-linear in any input axis.
4. **Every performance claim names the counter behind it.**

Out of scope by construction:
- **Parallel decode**, which buys speed with cores.
- **Async in the decode path.** CLAUDE.md rule 7 keeps decode synchronous for the
  `swifterror` register, and async stays in `@AsyncCheck`.

## Floors

Each cell's heap is set against the least its RESULT can occupy (`Floors.swift`): one block
per non-empty array and per String over 15 bytes, and nothing for anything stored inline.
Measured ÷ floor, blocks and bytes, per call on 2,000 elements (aarch64, 2026-09-19):

| cell | blocks | bytes | reading |
|---|---:|---:|---|
| values-long/struct | 1.00× | 1.27× | at the floor; bytes are malloc rounding plus array growth |
| values-date/struct | 1.00× | 1.40× | at the floor |
| base/struct, and most struct cells | 14× | 2.05× | array growth (row 2) |
| array-10/struct | 5.0× | 3.04× | inner arrays grow too (row 2) |
| nested-3/struct | 4,014× | 4.72× | two blocks per element (row 7) |
| base/encode | 2,009× | 3.59× | a block per element (row 8) |
| escapes-10/struct | ~~1,014×~~ 14× | ~~282×~~ 2.05× | was the escape path's reservation; fixed (row 6) |
| escapes-100/struct | ~~10,019×~~ 14× | ~~1,986×~~ 2.05× | the same; now identical to base |

`validate` has a floor of zero and allocates one 56-byte block per call. Blocks against a
floor of 1 read as huge ratios; the bytes column is the one to rank by.

## A trap in the instrument itself

An incremental SwiftPM build does not reliably re-expand macros in a dependent module when
the macro IMPLEMENTATION changes. After a `CodeGen` edit, `count.sh` once measured the old
generated code and reported the new change as identical to the previous one. `count.sh` and
`audit.sh` now always rebuild `AssayMatrix`. A clean re-expansion reproduced every committed
cell exactly, so no earlier baseline was affected.

## The ledger

Numbers are per call of the verb on a 2,000-element fixture, from
`Benchmarks/counts-baseline.aarch64.json` unless stated otherwise. A row is **open** until
its experiment is run, then **kept** or **reverted** with the counts that decided it.

| # | observation | hypothesis | predicted counter change | status |
|---|---|---|---|---|
| 1 | `base/struct`: 10,000 `swift_bridgeObjectRelease` calls inside `AssayReader.scanString()`, one per decoded String field; `values-int` has none. Forcing every string to the heap made it DISAPPEAR (20,002 → 14,002), and `values-long` shows the same — so on aarch64 it is on the SMALL-string path only. **On x86-64 it is on BOTH**: `values-long/struct` shows 20,002 bridge releases there against 14,002 on aarch64, one per field, so there it releases real heap storage, not an immortal no-op | ~~a temporary around `String(unsafeUninitializedCapacity:)` in Assay's code~~ **Wrong: it is not in Assay's code.** Disassembled on Linux, `scanString` contains no release at all; its only calls are the String constructor and the slow path. The release is INSIDE libswiftCore's constructors, reached by a tail call, which Callgrind charges to the caller. Variant B (`String(decoding:as:)` at ≤15 bytes) goes through `String._fromUTF8Repairing` and pays the same release | variant B measured: bridge releases unchanged at 20,002; −1.1% instructions on base/struct, −0.6% on base/skip | **closed, not ours.** B reverted: 1% does not justify contradicting `Strings.swift`'s documented reason for avoiding `String(decoding:)`. Revisit if a toolchain changes the stdlib's constructors (the ratchet will show it) |
| 2 | FLOORS: every Array grew by doubling. The top-level 2,000-element array cost 14 blocks against a floor of 1, which is the 2.05× on bytes nearly every struct cell shows; each 10-element inner array in `array-10` cost 5 blocks against 1 | pre-count the elements with a structural scan (`AssayReader._countArrayElements`) and reserve exactly | **SPLIT, KEPT FOR SCALARS 2026-09-19.** Arrays of SCALARS: `array-10/struct` **−18.2% instructions, −57.7% heap bytes**, blocks 10,014 → 2,014. Arrays of OBJECTS: −51% heap bytes and blocks 14 → 3, but **+24% instructions (+55% on the prefix path)**, because the pre-count is a second pass over most of the document. That is past the decision rule's +5%, so arrays of objects keep geometric growth. Still linear (array-length tail ≤ 0.99). The top-level remainder stays open: it needs an element-count ESTIMATE, not a count | kept (scalars); open (objects) |
| 3 | ARC audit: the generated `M20._assay` holds 462 release sites against `M5`'s 46 (9 per field at 5 fields, 23 at 20) | every throwing exit destroys every live `__fN: String?` local, so sites grow ~fields² | fewer sites, smaller generated functions; no runtime change expected (the sites are on error paths) | open |
| 4 | `base/validate`: 30,000 String retains and 30,000 releases per call, three per field. `count.py explain`: 10,000 each from copying the ELEMENT, copying the `Rule`, and `FormatValidators.characterCount` | `withBytes` copied every String to call `withUTF8`; the rule and element loops iterate by value | **PARTLY KEPT 2026-09-19.** `withBytes` now borrows through `withContiguousStorageIfAvailable`: −10,000 pairs and **−14.2% instructions** on base/validate, nothing else moved, and it serves every format validator. The two copies did NOT yield to borrowing syntax. `rules[i]`, `buffer[i]` and `(base + i).pointee` all measured IDENTICALLY to `for r in rules`, and the batch-loop version added a retain per element. A value loaded from memory and passed across an opaque call is copied unless the optimiser can prove nothing writes that memory, and call-site syntax does not change that. All reverted. What would work is making the copy free: `Rule` is `kind` + `message: String?` with String-carrying cases, so moving its Strings out of line would make it trivially copyable | open (the copies) |
| 5 | `base/encode`: 106,011 `swift_isUniquelyReferenced` calls per call, 53 per element (`base/struct` does 2); 90,008 of them in `JSONWriter.writeStringBody` | it appended one byte at a time, and every `Array.append` re-checks uniqueness | **PARTLY KEPT 2026-09-19**: strings now go in as runs between escapable characters, one `append(contentsOf:)` each, from BORROWED storage (`withContiguousStorageIfAvailable`; a first version copied the String for `withUTF8` and paid a retain per string, which the ratchet caught). Uniqueness checks 106,011 → 84,007, and **−34% instructions** on base/encode (−50% fields-2, −66% values-long). The remaining ~42 per element are the single-byte appends of `"`, `,`, `:`, braces; writing through one reserved pointer scope would remove them | open (the remainder) |
| 6 | FLOORS: escaped strings allocated 282× the floor at 10% escaped values and 1,986× at 100%, 318 MB of heap per call on a ~100 kB document; `count.py scale`'s new `escaped-elements` axis measured heap slope **2.00** (instructions 1.01: reserving memory does not touch it, which is why no timing ever showed it) | `scanStringSlow` reserved `(count - start) & 0xFFFF` — the rest of the DOCUMENT — per escaped string. Find the quote first (the decoded length can only shrink) and unescape into exactly that: on the stack at ≤1,024 bytes, into the String's own storage above | **KEPT 2026-09-19.** escapes-100/struct: 318 MB → 328 kB (−99.9%), 10,019 → 14 blocks, **−53% instructions**; now byte-identical to base/struct. escapes-10 −99.3% heap, −12% Ir. Heap slope 2.00 → 0.99. No other cell moved. `EscapePathTests` covers both paths across the boundary | **kept** |
| 7 | FLOORS: `nested-3/struct` allocates 4,014 blocks against a floor of 1, two per element; `count.py explain`: 4,002 are array-buffer allocations | a nested schema field is decoded `at: path + [.key("inner")]`, and `Array.+` always allocates, so every nesting level costs a heap block per element for a path read only on failure. The array-element case was fixed 2026-09-13 by rewriting one shared path; that trick does not cross a call boundary, because the path is passed BY VALUE and a callee cannot extend a buffer it does not own without copying. 142 signatures take it that way, including the `_assay` entry point | a real fix changes the entry point CLAUDE.md lists as settled: pass the path `inout` with push/pop (as `IssueSink` already is), or make the path a small inline-storage type (changes the public `Issue.path`). ~−4,000 blocks on nested-3, and the same on every nested encode | **needs a decision** |
| 8 | FLOORS: `encode` allocated ~1 block per element (2,009 for 2,000) against a floor of 1 output buffer | an array of nested schemas was encoded `at: path + [.key(k)]` INSIDE the loop: one allocation per element, and no `.index(n)`, so an issue in element 7 was reported at `items`, not `items[7]` | **KEPT 2026-09-19**: one path per array, last component rewritten in place, as decode does. Blocks 2,009 → 11 on base/encode, and the path is now correct (`EncodingTests`: `items[2].value`, verified to fail on the old emitter). Heap bytes are still ~2.5× the floor, from the output buffer growing by doubling | kept |
