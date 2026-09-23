# Contributing

Thanks for looking. Assay is opinionated, but the opinions are written down rather than
lurking in a reviewer's head — so the fastest way in is reading the document your change
touches before you write it.

| If you are changing… | Read first |
|---|---|
| the API's shape | [`docs/EXPERIENCE.md`](docs/EXPERIENCE.md) |
| anything in a hot path | [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md), [`docs/EFFICIENCY.md`](docs/EFFICIENCY.md) |
| the macro's output | [`docs/COMPILE-TIME.md`](docs/COMPILE-TIME.md) — build time is a gate here |
| a parser's accept/reject behaviour | [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md) |
| something listed as deferred | [`ROADMAP.md`](ROADMAP.md) — the deferral reason is the conversation |

The hard constraints on generated code live in [`CLAUDE.md`](CLAUDE.md) — "never switch over
a `String`", "one line of generated code per field", and a few others that look arbitrary
until you read the paragraph under each. They are enforced in review.

## What review will ask you

**A parser change keeps the differentials green.** `cd Benchmarks && swift run -c release
DiffFuzz` decodes every format twice — once by Assay, once by the incumbent — and disagreement
fails. Fixed a parser bug? Add the document that found it.

**A new issue code gets a message.** The coverage suite fails on a code that renders as its
own identifier, which is the failure mode where an error says `too_small` at a human.

**Anything that turns input into output gets an amplification case.** This rule has a story.
A YAML alias bomb — 331 bytes reaching 11.4 million nodes, no issue reported — walked past 250
tests, a differential per format, and the fuzzer. Fuzzing proves nothing crashed.
Differentials prove two parsers agree. Neither one asks what a *cheap input costs*.
`Tests/AssayTests/AmplificationTests.swift` asks. If you add expansion, aliasing, references,
repetition, or any construct where one token yields many values, add a case.

Assert on deterministic quantities — nodes, bytes, issues. Never wall clock. The few
time-based ceilings in that file are blowup detectors for quadratic paths, sized absurdly
loose on purpose, and tightening one into a performance gate is how you get a flaky suite.

**A performance claim arrives with numbers.** From the harness, on stated hardware, caveats
attached. "Faster" without a table does not merge. Wall clock is never gated in CI;
allocation counts, exact instruction counts and compile time are.

**Compile time stays under budget.** `bash Experiments/03-compile-time/gate.sh`, 100 ms per
type. The lever that works is "emit less code per field" — not "call the macro less", which
buys nothing.

**Zero warnings**, in `Sources/`, `Tests/` and every macro expansion. The library carried 56
for a while, and `.strictMemorySafety()` was decorative for exactly that long. A warning
inside generated code is the emitter's bug: fix it in `AssayMacros`, never by suppressing it
where it surfaced.

**No new dependencies in the library.** The benchmark package may take them — Yams lives
there as an oracle — but nothing that ships does.

## Running it

One command before you push:

```sh
bash Scripts/check.sh
```

Build (warning-free, forced recompile — an incremental build reports no warning for a file it
did not rebuild), tests, documented examples, the benchmark package's build, the
differentials. It reports every step and exits with the number of failures, so a partial pass
is visible instead of being whatever the last command happened to return.

It leaves out the two slow gates on purpose. Individually:

```sh
swift test                                      # 825 tests, macro expansion included

cd Benchmarks
swift run -c release CorpusGen                  # the corpus, deterministic
swift run -c release DiffFuzz                   # differentials + fuzz, CI-gated
swift run -c release DiffFuzz toml-numbers      # ~4,900 numeric literals against toml++
swift run -c release AssayBench --list          # every arm, with a one-line summary
swift run -c release AssayBench allocations     # the arm CI gates on
swift run -c release AssayBench                 # all of them, about eight minutes
swift run -c release AssayMatrix run            # the profiling matrix, ~3 minutes
./count.sh                                      # exact counters, in a container
bash ../Experiments/03-compile-time/gate.sh     # the compile-time budget
```

The official TOML suite is worth having locally — one clone, 710 cases:

```sh
git clone --depth 1 https://github.com/toml-lang/toml-test ~/src/toml-test
TOML_TEST_DIR=~/src/toml-test swift run -c release DiffFuzz toml-test
```

**Never run two timing harnesses at once.** They measure each other's contention. A run
contaminated that way was thrown away on 2026-09-10, and the arm selector exists so nobody
waits eight minutes to learn that.

Which instrument for which question:

- **`AssayBench`** — a specific question with a named competitor. "Is encoding still faster
  than `JSONEncoder`?"
- **`AssayMatrix`** — the wide net. Eighteen fixtures that each move *one* property off a
  base, crossed with seven verbs, so a number that moves points at the property responsible.
  Reach for it when you are unsure of a change's blast radius.
- **`count.sh`** — the exact one. Instructions, retains, releases, allocations and uniqueness
  checks per call, under Callgrind and DHAT. Deterministic run to run, which is why it gates
  and wall clock does not.

## Documentation

`Sources/Assay/Assay.docc` is the DocC catalogue that the Swift Package Index builds. The
package deliberately does not depend on `swift-docc-plugin` — every consumer would fetch it —
so build it locally from a symbol graph:

```sh
swift build --target Assay --scratch-path .build/symbol-graph \
    -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc /tmp/sg
mkdir -p /tmp/sg-assay && cp /tmp/sg/Assay.symbols.json /tmp/sg/Assay@Swift.symbols.json /tmp/sg-assay/
xcrun docc preview Sources/Assay/Assay.docc --additional-symbol-graph-dir /tmp/sg-assay \
    --fallback-display-name Assay --fallback-bundle-identifier dev.assay.Assay
```

Use the separate `--scratch-path`. The symbol-graph flags change the compile job shape, and
sharing the ordinary `.build` graph with them corrupted an incremental build once.

The website lives in [`website/`](website/) and its own README explains the extract: every
error render on that site is produced by building the examples against the real library, and
CI fails if a committed render no longer matches. If you change an error message, run
`bun run extract` in `website/` and commit what moves.

## API stability

`swift package diagnose-api-breaking-changes <ref>` compares the public API against a git
ref, and CI runs it on every pull request. Breaking the API on purpose is allowed before 1.0:
add the `api-break` label, which skips the job, and a line in
[`CHANGELOG.md`](CHANGELOG.md) saying what broke and why. The label exists so it is never
accidental.

## One trap worth knowing

The library's test target does not import Foundation — swift-testing's overlay would raise
the deployment floor — which is why Foundation-dependent verification lives in
`Benchmarks/Sources/DiffFuzz`. If your test needs `Date`, see how `DateSchemaTests` uses a
local stub. That stub is also what pins the macro's type-name seam, so it is load-bearing in
two directions at once.
