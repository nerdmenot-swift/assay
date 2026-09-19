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

## The ledger

Numbers are per call of the verb on a 2,000-element fixture, from
`Benchmarks/counts-baseline.aarch64.json` unless stated otherwise. A row is **open** until
its experiment is run, then **kept** or **reverted** with the counts that decided it.

| # | observation | hypothesis | predicted counter change | status |
|---|---|---|---|---|
| 1 | `base/struct`: 10,000 `swift_bridgeObjectRelease` calls inside `AssayReader.scanString()`, one per decoded String field; `values-int` has none. Forcing every string to the heap made it DISAPPEAR (20,002 → 14,002), and `values-long` shows the same — so it is on the SMALL-string path only | a temporary created and released on the small-string branch of `String(unsafeUninitializedCapacity:)` | −1 bridge release per String field, −10,000 on `base/struct` | open |
| 2 | FLOORS: every Array grows by doubling. The top-level 2,000-element array costs 14 blocks against a floor of 1 (12 `_consumeAndCreateNew` reallocations), which is the 2.05× on bytes nearly every struct cell shows; each 10-element inner array in `array-10` costs 5 blocks against 1 | nothing sizes an array before filling it. Inner arrays are the cheap case: the element count can be counted with the structural skip before decoding, or grown from a small reserved capacity. The top-level one needs an estimate that costs less than it saves | `array-10`: 5 → ~1 block per element; struct cells from 2.05× toward ~1.1× bytes | open |
| 3 | ARC audit: the generated `M20._assay` holds 462 release sites against `M5`'s 46 (9 per field at 5 fields, 23 at 20) | every throwing exit destroys every live `__fN: String?` local, so sites grow ~fields² | fewer sites, smaller generated functions; no runtime change expected (the sites are on error paths) | open |
| 4 | `base/validate`: 30,000 `swift_bridgeObjectRetain` and 30,000 releases per call, 3 of each per String field, for one allocated block | the rule engine copies String values it could borrow; `borrowing` parameters on the rule entry points should remove the pairs | −30,000 retains and −30,000 releases on `base/validate`, no block change | open |
| 5 | `base/encode`: 106,011 `swift_isUniquelyReferenced` calls per call, 53 per element (`base/struct` does 2) | the writer appends to its `[UInt8]` in small pieces and every append re-checks uniqueness; a reserved buffer written through one `withUnsafeMutableBufferPointer`-style scope would check once per document | uniqueness checks from ~53 to ~0 per element; instructions down | open |
| 6 | FLOORS: escaped strings allocated 282× the floor at 10% escaped values and 1,986× at 100%, 318 MB of heap per call on a ~100 kB document; `count.py scale`'s new `escaped-elements` axis measured heap slope **2.00** (instructions 1.01: reserving memory does not touch it, which is why no timing ever showed it) | `scanStringSlow` reserved `(count - start) & 0xFFFF` — the rest of the DOCUMENT — per escaped string. Find the quote first (the decoded length can only shrink) and unescape into exactly that: on the stack at ≤1,024 bytes, into the String's own storage above | **KEPT 2026-09-19.** escapes-100/struct: 318 MB → 328 kB (−99.9%), 10,019 → 14 blocks, **−53% instructions**; now byte-identical to base/struct. escapes-10 −99.3% heap, −12% Ir. Heap slope 2.00 → 0.99. No other cell moved. `EscapePathTests` covers both paths across the boundary | **kept** |
| 7 | FLOORS: `nested-3/struct` allocates 4,014 blocks against a floor of 1 — two per element, for nested structs that live inline | something in the nested decode path boxes or builds a per-element array (a diagnostic path, as in the three earlier cases of that mistake?) — `count.py explain --fn alloc_object` first | −4,000 blocks | open |
| 8 | FLOORS: `encode` allocates ~1 block per element (2,009 for 2,000) against a floor of 1 output buffer | a per-element temporary in the generated encode body or the writer; likely the same root as row 5 | −2,000 blocks; bytes toward ~1.1× | open |
