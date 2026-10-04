# Contributing

Thanks for looking. Assay is opinionated, but the opinions are written down rather than
lurking in a reviewer's head — so the fastest way in is reading the document your change
touches before you write it.

| If you are changing… | Read first |
|---|---|
| the API's shape | [`docs/EXPERIENCE.md`](docs/EXPERIENCE.md) |
| anything in a hot path | [`docs/EFFICIENCY.md`](docs/EFFICIENCY.md), and the hard constraints in [`CLAUDE.md`](CLAUDE.md) |
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

**Formatting is `swift-format`'s job, not review's.** `.swift-format` is at the repository
root and CI runs `swift-format lint --strict`. Before you push:

```sh
swift-format format --in-place --recursive --configuration .swift-format \
    Sources Tests Benchmarks/Sources Scripts Package.swift
```

One-time local setup, so `git blame` skips the reformat commit the way GitHub already does:

```sh
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

`Sources/AssayMacros/CodeGen.swift` is exempt via `// swift-format-ignore-file`, and its
header says why: it nests multi-line string literals inside interpolations of other
multi-line string literals, and a closing delimiter is what decides the indentation Swift
strips. Reformatting it produced 44 compile errors. If you touch that file, the goldens are
what check you.

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
swift test                                      # 1,046 tests, macro expansion included

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

## Coverage

```sh
swift test --enable-code-coverage
xcrun llvm-cov report .build/debug/AssayPackageTests.xctest/Contents/MacOS/AssayPackageTests \
    -instr-profile .build/debug/codecov/default.profdata Sources
```

**98.8% of 18,167 library lines** on 2026-10-04, from `swift test` alone — not `DiffFuzz`, not
the toml-test suite. It is reported and not gated: a coverage ratchet has no a-priori right
answer and fails on unrelated changes, the same argument that keeps total malloc traffic out
of CI.

Two things about reading the number.

**The macro is only covered by in-process expansion.** A `@Schema` type compiled into the test
target is expanded by the compiler's plugin process, which the profile does not see. An emitter
arm counts as covered when a golden (`Tests/AssayTests/GoldenFixtures.swift`) or an
`expandSchemaForTesting` call reaches it. So a new emitter branch needs a golden even if a
runtime test already exercises what it emits — which is also the only test that pins the
emitted text.

**What is not covered, and why.** Listed so nobody rediscovers it:

| | lines | reason |
|---|---|---|
| `AssayMacros/Plugin.swift`, `MarkerMacros.swift` | 56 | run only inside the compiler plugin; in-process expansion calls `SchemaMacro` directly |
| `Rules.swift`, the `regex_unavailable` arms | 6 | behind `#available(macOS 13, …)`, which is always true where the tests run |
| `DataParsing.swift`, the empty-`Data` arm | 6 | guards a nil base address that `Data()` does not produce here; kept because another platform's may |
| `XMLPlist.swift`, `plist_too_deep` | 5 | the XML parser's own depth limit always fires first; kept as the second line |
| `MappedFile.swift`, `cannotStat` | 2 | `fstat` on a descriptor that just opened does not fail on demand |
| `JSONWriter.swift`, the non-contiguous `String` arm | 2 | needs a bridged `NSString`; native strings are always contiguous UTF-8 |

The rest is single lines: a `default:` that a preceding check makes unreachable, a
`guard` whose failure needs a `String` that is not contiguous UTF-8.

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
