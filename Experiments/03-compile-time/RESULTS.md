# Experiment #6 — what does `@Schema` cost at compile time?

**Status: MEASURED. Budget set. Two optimizations found and landed.**

- Toolchain: Apple Swift 6.3.3, macOS 26.5.2, Apple silicon (18 logical cores)
- `swift build`, debug config, dependency graph prebuilt so only the module under test is timed
- Three arms, semantically identical field sets: `plain` (no conformance) / `codable` / `schema`
- Date: 2026-07-26

## Headline

**~80 ms per `@Schema` type at 10 fields, of which ~7 ms is per *field* and ~9 ms is
fixed per type.** That is **3.6× the cost of `Codable`** and **9.5× a plain struct**.

| types (10 fields each) | plain | codable | schema | vs plain | vs codable |
|---|---|---|---|---|---|
| 10 | 0.42 | 0.58 | 1.14 | 2.71× | 1.97× |
| 25 | 0.49 | 0.84 | 2.24 | 4.57× | 2.67× |
| 50 | 0.61 | 1.30 | 4.15 | 6.80× | 3.19× |
| 100 | 0.84 | 2.23 | 7.94 | 9.45× | 3.56× |

*(The `n=1` row is discarded — it absorbs first-build link and setup cost.)*

### Cost is per-FIELD, not per-expansion

This is the finding that made the optimizations possible. At 50 types:

| fields per type | schema (s) | per type (ms) |
|---|---|---|
| 3 | 1.84 | 37 |
| 5 | 2.37 | 47 |
| 10 | 4.15 | 83 |
| 15 | 6.00 | 120 |

Fitting: **~7.3 ms per field + ~9 ms fixed per type.** The plugin round trip — the thing
everyone blames for macro build cost — is the *small* term. What dominates is
type-checking the generated body, which means the lever is **emit less code per field**,
not "call the plugin less".

## Two optimizations, found by measuring

### 1. Never emit a 256-element array literal — **16% saved**

The window dispatch table is 256 bytes. Emitting it as `[UInt8] = [5, 5, 5, ...]` makes
the type checker check 256 integer literals *per schema type*.

```swift
// before                                   // after
static let __assayKeyTable: [UInt8] =       static let __assayKeyTable: [UInt8] = {
    [5, 5, 5, 5, /* ...252 more... */]          var t = [UInt8](repeating: 5, count: 256)
                                                t[117] = 0
                                                t[100] = 1   // one line per KEY, ≤64
                                                return t
                                            }()
```

Runtime behaviour is byte-identical — a contiguous 256-byte table, one indexed load,
`swift_once`-protected. 9.82 s → 8.25 s at 100 types.

### 2. One line of generated code per field — **a further 4%, and 20% at wide types**

Null handling was an `if reader.consumeNullIfPresent() { … } else { … }` wrapper emitted
around *every* field, roughly doubling per-field statement count. Folding it into
`decodeStringOrNull` / `decodeIntOrNull` / … in `AssayCore` makes the generated per-field
code exactly one line.

Per-field cost 9.4 ms → 7.3 ms. At 15 fields × 50 types: 7.50 s → 6.00 s.

## A correctness bug this harness caught

The generated `_assay` was marked `@inlinable`. Every **public** `@Schema` type then
failed to build:

```
error: initializer 'init(identifier:displayName:…)' is internal and cannot be
       referenced from an '@inlinable' function
```

SE-0193 restricts `@inlinable` bodies to ABI-public declarations, and a public struct's
memberwise initializer is *internal*. The annotation was also pointless: `PERFORMANCE.md`
§8.2 requires `@inlinable` on Assay's **runtime primitives**, which cross into the user's
module — but the generated body is *already in* the user's module and already concrete, so
inlinability buys nothing there. Removed.

**Only public types hit it**, which is why the test suite (all internal types) passed
throughout. Worth a regression test.

## The budget

| schema types | added to a clean build | verdict |
|---|---|---|
| ≤ 50 | < 4 s | fine, ship it |
| 50–200 | 4–16 s | noticeable; put schemas in a module that changes rarely |
| 200–1000 | 16–80 s | measure before adopting wholesale |
| > 1000 | > 80 s | do not adopt without a plan |

**Gate: 100 ms per type at 10 fields, measured in CI, failing the build on regression.**
Current: ~80 ms. See `docs/COMPILE-TIME.md`.

## Caveats

- Debug config, one machine, cold module build. Release adds optimizer time on top.
- **Incremental builds are not measured**, and that is what developers feel all day. A
  single-type edit should only re-expand that type; this has not been verified.
- The prebuilt-swift-syntax path (Swift 6.2+) is active here because `Package.swift` now
  pins the 603 line matching the 6.3.3 toolchain. A stale pin forfeits it and every
  measurement above gets worse.

## Reproduce

```sh
cd Experiments/03-compile-time
./measure.sh                 # type-count sweep
FIELDS=15 ./measure.sh       # field-count sweep
CONFIG=release ./measure.sh  # release build
```
