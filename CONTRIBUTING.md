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
- **Performance claims need numbers from the harness**, on stated hardware, with the
  caveats attached. The honesty rules in `CLAUDE.md` are not aspirational; "faster"
  without a table does not merge. Wall clock is never gated in CI — allocation counts
  and compile-time are.
- **Compile-time budget**: `bash Experiments/03-compile-time/gate.sh` must stay under
  100 ms per type. "Emit less code per field" is the lever that works.
- **No new dependencies in the library.** The benchmark package may take dependencies
  (Yams lives there as an oracle); the shipping products may not.

## Running everything

```sh
swift test                                        # 250 tests, includes macro tests
cd Benchmarks
swift run -c release CorpusGen                    # regenerate the corpus (deterministic)
swift run -c release DiffFuzz                     # differentials + fuzz — CI-gated
swift run -c release AssayBench                   # benchmarks + allocation gate
bash ../Experiments/03-compile-time/gate.sh       # compile-time budget
```

A note on tests: the library's test target deliberately does not import Foundation
(swift-testing's overlay would raise the deployment floor), which is why
Foundation-dependent verification lives in `Benchmarks/Sources/DiffFuzz`. If your
test needs `Date`, look at how `DateSchemaTests` uses a local stub — that stub is
also what pins the macro's type-name seam.
