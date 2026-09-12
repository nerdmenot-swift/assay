# Contributing

Thanks for looking. Assay is opinionated in ways that are written down, so the best
first step for any non-trivial change is reading the documents the change touches:

- **`docs/EXPERIENCE.md`** — the developer experience. Authoritative for API shape.
- **`docs/PERFORMANCE.md`** — the performance strategy, and `docs/COMPILE-TIME.md` —
  the compile-time budget. Authoritative for how generated and runtime code may be
  written; the hard constraints in `CLAUDE.md` ("never switch over a String", "one
  line of generated code per field", …) are enforced in review.
- **`ROADMAP.md`** — what is deliberately deferred and why. If your idea is there,
  the deferral reason is the conversation to have first.

## Ground rules that will come up in review

- **Every parser change needs the differential to stay green.**
  `cd Benchmarks && swift run -c release DiffFuzz` runs the JSON, YAML, XML and date
  oracles plus the fuzzer. If you fixed a parser bug, add the case that found it.
- **Every new issue code needs a message.** The message-coverage suite fails on a
  code that renders as its own identifier.
- **Anything that turns input into output needs an amplification case.**
  `Tests/AssayTests/AmplificationTests.swift` bounds how much output a small input may
  buy. It exists because a YAML alias bomb — 331 bytes reaching 11.4 million nodes with
  no issue reported — survived 250 tests, a differential per format, and the fuzzer:
  fuzzing proves no crash, differentials prove two parsers agree, and neither asks what a
  cheap input *costs*. If you add expansion, aliasing, references, repetition, or any
  construct where one token can produce many values, add a case there. Assert on
  deterministic quantities (nodes, bytes, issues), never on wall clock — the few
  time-based ceilings in that file are blowup detectors for quadratic paths, sized
  absurdly loose on purpose, and must not be tightened into performance gates.
- **Performance claims need numbers from the harness**, on stated hardware, with the
  caveats attached. The honesty rules in `CLAUDE.md` are not aspirational; "faster"
  without a table does not merge. Wall clock is never gated in CI — allocation counts
  and compile-time are.
- **Compile-time budget**: `bash Experiments/03-compile-time/gate.sh` must stay under
  100 ms per type. "Emit less code per field" is the lever that works.
- **Zero warnings, in `Sources/`, `Tests/` and every macro expansion.** CI fails on one.
  The library carried 56 for a while and `.strictMemorySafety()` was decorative for
  exactly that long. A warning inside generated code is the emitter's bug, not the
  user's — fix it in `AssayMacros`, never by suppressing it at the use site.
- **No new dependencies in the library.** The benchmark package may take dependencies
  (Yams lives there as an oracle); the shipping products may not.

## Running everything

One command, before you push:

```sh
bash Scripts/check.sh
```

It runs the build (warning-free, with a forced recompile — an incremental build reports no
warning for a file it did not rebuild), the tests, the documented examples, the benchmark
package's build, and the differentials. It reports every step and exits with the number of
failures, so a partial pass is visible instead of being whatever the last command returned.

It deliberately leaves out the two slow gates, which must not run at the same time as each
other — see the note below the list. Individually:

```sh
swift test                                        # ~700 tests, includes macro tests
cd Benchmarks
swift run -c release CorpusGen                    # regenerate the corpus (deterministic)
swift run -c release DiffFuzz                     # differentials + fuzz — CI-gated
TOML_TEST_DIR=~/src/toml-test swift run -c release DiffFuzz toml-test   # needs a checkout
swift run -c release AssayBench --list            # the benchmark arms
swift run -c release AssayBench allocations       # the one arm CI gates on
swift run -c release AssayBench encode zippy      # any arms you touched, in under a minute
swift run -c release AssayBench                   # every arm — about eight minutes
bash ../Experiments/03-compile-time/gate.sh       # compile-time budget
```

Run only the arms your change can affect while iterating, and the whole set once before
you commit a number. Two arms running at once measure each other's contention, so never
run `AssayBench` and `gate.sh` concurrently; a run contaminated that way was discarded on
2026-09-10 and the arm selector exists so that nobody has to wait eight minutes to find
out.

### Documentation

`Sources/Assay/Assay.docc` is the DocC catalogue — the landing page and four articles —
and the Swift Package Index builds it for every product named in `.spi.yml`. The package
deliberately does not depend on `swift-docc-plugin` (every consumer would fetch it), so to
build locally use the toolchain's `docc` on a symbol graph:

```sh
swift build --target Assay --scratch-path .build/symbol-graph \
    -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc /tmp/sg
mkdir -p /tmp/sg-assay && cp /tmp/sg/Assay.symbols.json /tmp/sg/Assay@Swift.symbols.json /tmp/sg-assay/
xcrun docc preview Sources/Assay/Assay.docc --additional-symbol-graph-dir /tmp/sg-assay \
    --fallback-display-name Assay --fallback-bundle-identifier dev.assay.Assay
```

Use the separate `--scratch-path`: the symbol-graph flags change the compile job shape,
and sharing the ordinary `.build` graph with them corrupted an incremental build once.

CI runs `docc convert` on the catalogue and fails on a broken symbol link.

### API stability

`swift package diagnose-api-breaking-changes <ref>` compares the public API against a
git ref. CI runs it on every pull request against the base branch; a PR that breaks API on
purpose carries the `api-break` label, which skips the job, and a line in `CHANGELOG.md`
saying what broke and why. Before 1.0 that is allowed in a minor version — the label is
so it is never accidental.

A note on tests: the library's test target deliberately does not import Foundation
(swift-testing's overlay would raise the deployment floor), which is why
Foundation-dependent verification lives in `Benchmarks/Sources/DiffFuzz`. If your
test needs `Date`, look at how `DateSchemaTests` uses a local stub — that stub is
also what pins the macro's type-name seam.
