# Assay

A decoder for Swift that tells you what went wrong.

```swift
@Schema
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var tags: [String] = []
}

let article = try Article.parse(json: data)
```

No rules. No `CodingKeys`. Zero-rule `@Schema` is a first-class mode — Assay is a complete
serde with no validation at all, not an on-ramp to one.

**Status: phase 1 built and measured. Not released, not stable, not feature-complete.**

## Where it stands

| | |
|---|---|
| Decode speed | **5.53× Foundation** on 1–50 kB API payloads, **8.72×** float-dense ([results](Benchmarks/RESULTS.md)) |
| Compile cost | **~82 ms per `@Schema` type** (JSON default), ~3.6× `Codable` ([budget](docs/COMPILE-TIME.md)) |
| Tests | 119 passing |
| Allocations per decode | **not measured yet** — no allocation claim is being made |

The speed number is the one the design staked itself on. `docs/PERFORMANCE.md` §14 wrote the
falsification condition down in advance: *if a scalar Swift implementation does not comfortably
clear ZippyJSON's 1.38× over Foundation, the thesis is wrong.* ZippyJSON is simdjson — the
fastest JSON parser in existence — bolted onto Swift's `Decodable`, and it managed 1.38×.
Assay is scalar Swift with no SIMD and no C, and it lands next to Apple's own `new-codable`
prototype (~6×) rather than next to ZippyJSON.

That is the whole thesis in one line: **the parser was never the bottleneck; the `Codable`
container boundary was.**

## What is deliberately not claimed

- Not "the fastest JSON decoder." Unqualified, unprovable, and false on some axis.
- Not benchmarked against a SIMD decoder. Assay beats *Foundation* on float-dense input
  (8.72×, because Foundation calls `strtod` per value) — that says nothing about simdjson
  or yyjson, which carry Eisel-Lemire. That comparison is owed and is where a loss is
  genuinely expected.
- Multi-megabyte documents are outside the target band and unmeasured.
- `[String: T]` dictionary fields are not implemented, so `PERFORMANCE.md`'s stated worst
  case is untested.
- No allocation claim until allocations are actually counted.
- No claim on Windows, Android or Wasm, where the harness does not run.
- Measured on one arm64 macOS machine. Linux and x86-64 are unverified.
- `@Schema` is not "free at compile time." It costs ~3.6× `Codable`, and that is stated
  rather than buried.

## The documents

| file | what it is |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | settled decisions, hard constraints, current status |
| [`docs/EXPERIENCE.md`](docs/EXPERIENCE.md) | the developer experience, end to end — the API spec |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | the runtime strategy and the falsification condition |
| [`docs/COMPILE-TIME.md`](docs/COMPILE-TIME.md) | the second performance axis, and the CI gate |
| [`docs/research/`](docs/research/) | the seven research passes the above were built from |
| [`Experiments/`](Experiments/) | the toolchain experiments, with results |

Every research file ends with an explicit **"do not assert these"** section. Read it before
repeating anything from that file. Several of its open questions are now answered in
`Experiments/*/RESULTS.md` — where the two disagree, the experiment wins.

## Reproduce

```sh
swift test                                        # 22 tests

cd Benchmarks && swift run -c release CorpusGen   # 76-file corpus, deterministic
cd Benchmarks && swift build -c release && ./.build/release/AssayBench

Experiments/01-jump-table/sweep.sh                # does dispatch reach a jump table?
Experiments/03-compile-time/gate.sh               # compile-time budget gate
```
