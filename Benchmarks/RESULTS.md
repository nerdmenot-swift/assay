# Current numbers

**One machine, one run: macOS 26.5.2, Apple silicon (arm64), Apple Swift 6.3.3, `-O`, warm,
minimum of 5 rounds — 2026-09-20, commit `abf38a8`.** None of these is a claim about
another platform (`CLAUDE.md`'s honesty rules); Linux and x86-64 have their own table
below. Each row names the benchmark source that produces it, which is where its method is
stated. Regenerate with `swift run -c release AssayBench` and replace this table — the numbers
are machine-specific by design, so this is pasted, not automated. Two cells do not come from
`AssayBench`: the compile-time row is `Experiments/03-compile-time/gate.sh`, and the Linux
half of the XML row is `Benchmarks/linux-bench.sh`.

**Every row was re-measured on 2026-09-20** at the end of the efficiency campaign
(`docs/EFFICIENCY.md`), and the campaign is why several of them moved a long way. Each
"before" figure here is the previously published commit rebuilt and re-run on this OS, not
the number that was published from it: encoding 2.98× → **8.75×** (the writers own their
buffers, rows 5/22), YAML struct decode 11.09× → **18.20×** and TOML node parse 1.51× →
**4.06×** (one parser per format building `RawValue` directly, rows 12/17 and the TOML
arena).

**Compare a row with a rebuild of the old commit, never with the old table.** A ratio
against Foundation belongs to the machine and the OS that produced it; "How to read these"
below has the measurements behind that.

**The wall clock still catches things the counters do not.** Re-measuring for this table is
what found the one regression this campaign shipped: an exact reservation for arrays of
scalars, decided on instruction and allocation counts, cost up to **+39.5%** on the corpus's
long arrays, because the matrix cell that decided it holds ten-element arrays and the corpus
holds arrays of 9,510. It is reverted, the ledger's row 2 carries the numbers, and
`array-640` now exists so the counters can see what the clock saw.

| arm | number | against | source |
|---|---|---|---|
| struct decode, full corpus | **9.14×** mean over 25 files (5.16–18.07) | `JSONDecoder` | `FalsificationBench.swift` (the sweep), `Corpus.swift` (the shapes) |
| prefix decode + unknown-key skip | **5.62×** over 45 files (2.74–8.49) | `JSONDecoder` | `FalsificationBench.swift` (the sweep), `Corpus.swift` (the shapes) |
| generic value model | **3.35×** over 75 files | `JSONSerialization` | `FalsificationBench.swift` |
| falsification arm (`apimodel`, 5 sizes) | **5.24×** mean (8.13× float-dense) | `JSONDecoder` | `FalsificationBench.swift` |
| vs ZippyJSON (simdjson + Codable) | **3.61×** faster | ZippyJSON, which is 1.60–1.84× over Foundation here | `ZippyBench.swift` |
| vs yyjson, use-case shape | **0.69×** (loses) | yyjson parse + extraction | `SIMDBaseline.swift` |
| vs yyjson, float-dense | **0.69×** (loses) | same | `SIMDBaseline.swift` |
| vs yyjson, DOM vs DOM | **0.16×** (loses) | `yyjson_read` | `SIMDBaseline.swift` |
| YAML node parse | **8.35×** | Yams `compose` | `Formats.swift` |
| YAML struct decode | **18.20×** | Yams `YAMLDecoder` | `Formats.swift` |
| XML tree parse | **2.47×** (macOS; **0.96×** on Linux, 2026-08-18) | Foundation `XMLParser` | `Formats.swift` |
| TOML node parse | **4.06×** | toml++ via TOMLKit | `TOMLBench.swift` |
| TOML struct decode | **6.55×** | TOMLKit `TOMLDecoder` | `TOMLBench.swift` |
| `Date` fields | **5.40×** mean over 5 sizes | `JSONDecoder` + `.iso8601` | `DatesBench.swift` |
| binary plist | **4.05×** | Foundation `PropertyListDecoder` | `CoverageBench.swift` |
| XML plist | **1.28×** | Foundation `PropertyListDecoder` | `CoverageBench.swift` |
| union vs its variant | **1.09×** (the tag scan) | the variant decoded directly | `CoverageBench.swift` |
| `@Inline` vs nesting | **0.87×** (faster) | the nested `@Schema` it replaces | `CoverageBench.swift` |
| `@Wraps` vs `@Validate` | **1.80×** (slower) | the plain field + rule it is sugar for | `CoverageBench.swift` |
| encoding, 50 / 200 items | **8.75× / 9.04×** | `JSONEncoder` | `EncodeBench.swift`, `docs/ENCODING.md` |
| cold start, 60 types | **6.6×** first decode (median); 5.4× steady | `JSONDecoder` | `ColdStartBench.swift` |
| multi-megabyte documents | **8.57–8.78×**, ~1,040 MB/s, flat | `JSONDecoder` | `LargeDocBench.swift` |
| total allocations, 50 items | **159** against Foundation's 377 | `JSONDecoder` | `TotalAllocations.swift` |
| `T.validate(_:)` | **37 ns** per value, 1 block; **46 ns/row** batched, 0.11× a decode | — | `ValidateBench.swift`, `docs/VALIDATE.md` |
| live allocations, `apimodel-8k` struct | gated, **PASS** | absolute thresholds | `AllocationGate.swift` |
| compile time, 10 fields | **80.8 ms/type** (gate 100) | `Codable`: 4.22× | `Experiments/03-compile-time/gate.sh`, `docs/COMPILE-TIME.md` |

`AssayBench` also has `dict`, `keypath`, `decomposition`, `fieldsweep` and `rules` arms. They
have no row here; run the arm for its number (`AssayBench --list` names them).

---

# How to read these

**The comparison is unfair in one direction, and that is said out loud.** Foundation's
`JSONDecoder` is fully general and `Codable`-driven; Assay's macro knows the schema at compile
time. That is the whole thesis, not a footnote to it.

The rest is arranged in the baseline's favour or symmetric, with one exception, stated
second:

- No `Codable` model uses `.convertFromSnakeCase`, which would cost Foundation a `String`
  allocation per key. The corpus and falsification models declare snake_case member names
  directly; the ZippyJSON, large-document, total-allocation and encode models use explicit
  `CodingKeys`.
- **The exception: the corpus sweep and the plist rows construct the baseline's decoder
  per call.** `Corpus.swift` creates a `JSONDecoder` and `CoverageBench.swift` a
  `PropertyListDecoder` inside the timed closure, so that cost sits on the baseline's side
  of the 9.14× and 5.62× rows and of both plist rows. Every other arm hoists the decoder
  out of the loop (warm). The cold-start row exists because warm flatters anything that
  amortises setup.
- Assay receives `[UInt8]`; Foundation receives `Data`, its native input. Neither converts
  inside the timed region.
- Minimum of 5 rounds, not a mean (the cold-start row is the median of 60 single samples).
  Each arm checks agreement with its baseline before timing: bit-for-bit for dates, floats
  and the yyjson DOM; spot checks (counts and first elements) on the struct arms; and on the
  corpus sweep and the YAML node-parse row only that both sides produced a value.
  Value-for-value agreement over the whole corpus is `DiffFuzz`'s job, not the timer's.

**The three corpus rows answer three questions.** *Struct decode* is shapes a fixed struct
consumes entirely. *Prefix + skip* is a small struct against a wide document, the most common
real shape there is. *Generic value model* is `JSON.Value` against `JSONSerialization`: no
`Codable` boundary to delete, so it is what the scanner is worth on its own. Read the first
row next to the third.

**The yyjson rows are losses and stay published.** yyjson's document is freed inside the
timed region, as Assay's ARC teardown is. Its in-situ mode is not used, because it mutates
the input and Assay does not — so the baseline runs with one hand behind its back, and a
reader should know that. The use-case arm makes yyjson build real Swift `String`s and
`Array`s, because that is the cost Assay pays.

**XML is asymmetric in Foundation's favour.** Assay builds and keeps the whole document tree;
the Foundation baseline runs a counting SAX delegate and keeps nothing. And "Foundation's
`XMLParser`" is two programs: Apple's own on Darwin, libxml2 on Linux. "Assay's XML is faster
than Foundation's" is a Darwin-only claim.

**A ratio against Foundation belongs to the OS that produced it.** The same commit, rebuilt,
has measured ~6% apart on the struct arm a week apart, and nearly 2× apart on the dates arm
across an OS update. Compare against a rebuild of the old commit, never against an old table.

# Other platforms

Measured 2026-08-15 (Linux aarch64, virtualised, 2 vCPU) and 2026-08-20 (Linux x86-64, a
GitHub-hosted runner, `.github/workflows/benchmark.yml`), Swift 6.3.3 throughout. **These
predate the efficiency campaign, so compare the columns with each other, not with the table
above.** The absolute timings on a virtualised box mean nothing; the ratios are against a
baseline on the same box.

| | macOS arm64 | Linux aarch64 | Linux x86-64 |
|---|---|---|---|
| struct decode vs Foundation | 8.98x | 8.64x | 10.89x |
| prefix + skip | 6.28x | 6.10x | 5.96x |
| generic value model | 1.47x | 2.07x | 3.15x |
| `[String: T]` dictionaries | 7.25x | 6.01x | 6.50x |
| YAML node parse vs Yams | 6.69x | 7.68x | 7.16x |
| YAML struct decode | 11.27x | 14.02x | 13.51x |
| XML vs Foundation | 2.26x | 0.96x (2026-08-18) | 1.39x |
| UTF-8 validation, share of decode | 4.2% | 4.1% | 4.6% |

The struct-decode multiple is highest on x86-64, so deleting the `Codable` boundary is not a
Darwin or an arm64 artefact. The value-model row widens as Foundation's `JSONSerialization`
goes from C (Darwin) to pure Swift (Linux): it says more about Foundation's platform split
than about Assay.

# Allocations

Two instruments, because neither can do the other's job.

**Live blocks per decoded value**, via `malloc_zone_statistics` — gated in CI with absolute
thresholds (`AllocationGate.swift`). It misses transient allocations freed inside a decode,
was measured to undercount ~10–15% on Darwin's nano zone (the self-check has since read
exactly 2.00 and 4.00, and disables the gate if it drifts), and cannot compare two decoders
that retain the same data. `Allocations.swift` states all three limits; read them before
quoting a number.
`.mallocCountTotal` was rejected rather than deferred: it needs jemalloc beside the
toolchain and cannot run on the musl or wasm legs.

**Total allocations**, via `malloc_logger`, Darwin only — reported and never gated
(`TotalAllocations.swift`). It is the measurement that can compare the two decoders honestly,
since the retained output is identical on both sides and cancels. Linux has no exact counter
and the arm says "unavailable" rather than guessing.

Exact instruction, retain/release and heap-block counts under Valgrind are a third thing:
`Benchmarks/count.py`, gated in `efficiency.yml`, with the ledger in `docs/EFFICIENCY.md`.

# Reproduce

```sh
cd Benchmarks
swift run -c release CorpusGen            # the corpus, deterministic, 81 files
swift run -c release AssayBench --list    # every arm, with a one-line summary
swift run -c release AssayBench           # all of them, about eight minutes
swift run -c release DiffFuzz             # differentials + fuzz, CI-gated
```

Never run two timing harnesses at once; they measure each other's contention.

The history of how each number got here — what was tried, what was rejected, what regressed
and was reverted — is in the git log of this file and of `Benchmarks/Sources/AssayBench`.
