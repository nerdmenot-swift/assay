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

## The ledger

Numbers are per call of the verb on a 2,000-element fixture, from
`Benchmarks/counts-baseline.aarch64.json` unless stated otherwise. A row is **open** until
its experiment is run, then **kept** or **reverted** with the counts that decided it.

| # | observation | hypothesis | predicted counter change | status |
|---|---|---|---|---|
| 1 | `base/struct`: 10,000 `swift_bridgeObjectRelease` calls inside `AssayReader.scanString()`, one per decoded String field; `values-int` has none. Forcing every string to the heap made it DISAPPEAR (20,002 → 14,002), and `values-long` shows the same — so it is on the SMALL-string path only | a temporary created and released on the small-string branch of `String(unsafeUninitializedCapacity:)` | −1 bridge release per String field, −10,000 on `base/struct` | open |
| 2 | `base/struct`: 14 heap blocks for a 2,000-element top-level array, 12 of them `_consumeAndCreateNew` reallocations | the top-level array grows by doubling because nothing sizes it; the floor is ~2 blocks | fewer blocks and copied bytes; needs an element-count estimate that costs less than it saves | open |
| 3 | ARC audit: the generated `M20._assay` holds 462 release sites against `M5`'s 46 (9 per field at 5 fields, 23 at 20) | every throwing exit destroys every live `__fN: String?` local, so sites grow ~fields² | fewer sites, smaller generated functions; no runtime change expected (the sites are on error paths) | open |
| 4 | `base/validate`: 30,000 `swift_bridgeObjectRetain` and 30,000 releases per call, 3 of each per String field, for one allocated block | the rule engine copies String values it could borrow; `borrowing` parameters on the rule entry points should remove the pairs | −30,000 retains and −30,000 releases on `base/validate`, no block change | open |
| 5 | `base/encode`: 106,011 `swift_isUniquelyReferenced` calls per call, 53 per element (`base/struct` does 2) | the writer appends to its `[UInt8]` in small pieces and every append re-checks uniqueness; a reserved buffer written through one `withUnsafeMutableBufferPointer`-style scope would check once per document | uniqueness checks from ~53 to ~0 per element; instructions down | open |
