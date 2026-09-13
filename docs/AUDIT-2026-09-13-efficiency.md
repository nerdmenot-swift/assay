# Efficiency audit — 2026-09-13

Are we doing the right things algorithmically, and are we using Swift as well as it permits?
Three readers swept in parallel — algorithmic waste, ownership and copies, concurrency and
SIMD — and **every claim was re-measured here before it was acted on.** That mattered: of
the claims that arrived, one was 80× overstated, one did not reproduce at all, and one of my
own hypotheses was wrong and the measurement said so.

---

## 1. The headline

Fixing the per-element diagnostic path in the **generated decode body** moved the product's
own headline number:

| arm | before | after |
|---|---|---|
| struct decode, full corpus | 8.65× | **9.70×** |
| falsification (`apimodel`, 5 sizes) | 5.44× | **6.06×** |
| `arrays-of-structs`, 8k | — | 10.13× |

That is the fourth place this exact mistake has been found, and the first on the path the
performance thesis is actually about.

## 2. Denial of service on untrusted input — two, both fixed

**XML duplicate-attribute detection was O(a²).** `XMLParser.swift:220` scanned every
attribute appended so far, and `XML.Name ==` is a full `String ==` on two fields.

| attributes | bytes | before | after |
|---|---|---|---|
| 16,000 | 161 KB | 0.165 s | — |
| 32,000 | 332 KB | 0.663 s | 0.002 s |
| 64,000 | 676 KB | **3.267 s** | **0.004 s** |

Legal XML, one element, depth 1, no entities. `maxDepth` sees 1 and the node budget sees one
node — **both guards measure the wrong quantity, because the bomb is wide.** Extrapolated to
the 64 MB byte ceiling it is hours. Reachable from `parse(xml:)`, `parse(plist:)` and
`parse(body:accepting: [.xml])`.

The comment above it defended the linear scan for "a handful of attributes", which is
correct and had no cliff guard. The scan is kept below 16 attributes, allocation-free and
byte-for-byte as it was; above that it hands over to a `Set`.

**The YAML merge key was O(n²)** — fixed earlier the same day, and the reason the rest of
this sweep happened. 1 MB with one `<<:` went 3.498 s → 0.015 s. Same blind spot, same
shape, same two guards missing it.

## 3. Measured waste on ordinary input — fixed

| | before | after | note |
|---|---|---|---|
| Generated array-of-structs element | 77.1 ns | **30.3 ns** | `path + [...]` per element, read only on failure |
| XML → `RawValue` leaf projection, 100k leaves | 0.0123 s | **0.0030 s** | built `members`, recursed, then discarded it all |
| `MediaType` header trim, 80k spaces | 0.0307 s | linear | `removeFirst()` — the bug `Preprocess.swift` already fixed and documented |
| Binary plist `<data>`, 80k elements | ~2× a `<string>` doc | one table | the base64 reverse table was rebuilt per element |
| `unknownKeys: .warn` on 1.1 MB of unknown keys | 23 ms (30× `.ignore`) | gated | did-you-mean ran past `maxIssues`, and re-materialised the key per candidate |
| `XMLWriter.raw` | 21 ns | 6 ns | `Array(s.utf8)` per escape and per tag name |
| `Assayer` array element | 7× a path-free run | hoisted | same per-element path, fourth instance |
| `Assayer` object field lookup | O(fields × members) | indexed past 8×8 | the one place in the library that resolved keys by scanning |

## 3b. The gains are fewer allocations, not more — measured

The obvious worry about a set of "make it faster" changes is that speed was bought with
memory. It was not. Same instrument (`totalalloc`, `malloc_logger`, counts every allocate
and free exactly), same corpus, before and after today:

| items | Foundation | Assay before | Assay after |
|---|---|---|---|
| 1 | 25 | 6 | 6 |
| 10 | 94 | 55 | **37** |
| 50 | 378 | 257 | **159** |

**38% fewer allocations at fifty items**, and the ratio against Foundation went 1.47× to
2.38×. Live blocks are unchanged at 118.7 — which is the point: every allocation removed
today was transient, allocated and freed inside the decode, exactly the class the live-block
gate structurally cannot see and `totalalloc` exists for.

### And one change where I got that trade wrong

Three fixes replace a linear scan with a hash: XML attributes, the YAML merge key, and the
`Assayer` field lookup. Each buys O(n) time with O(n) memory, which is only correct when n
is large — and the first version of the YAML one built a `Set` **unconditionally**.

A config file's mapping has a handful of keys. Measured on a realistic small config with two
merge keys: **1,954 ns/parse with the unconditional set, 1,481 without** — I had made the
common case 24% worse to fix the adversarial one. That is not a fix, and it is the same
mistake `XMLParser`'s own attribute comment warns about in the other direction.

All three are thresholded now (16 attributes, 24 merged pairs, 8×8 fields). Below the
threshold the original scan runs, allocation-free and byte-for-byte as it was; above it the
hash takes over. Both ends measured: the 1 MB merge is still 0.0094 s against the original
3.498 s, and 20,000 three-attribute elements parse in 0.0056 s.

**The general rule this leaves behind:** a hash is not free, and a fix that only measures the
input it was written for is half a fix.

## 4. What I got wrong, recorded because it is the point

I predicted `.each`'s 63 ns/element was the per-element path allocation. I hoisted it and
measured no change, and wrote down "~47 ns unexplained" as an open finding.

**The finding was my probe.** It timed `parse(json:)` end to end, so most of what it
measured was JSON-decoding every element — nothing to do with `.each`. Isolating
`_assayValidate` and calling it three ways gives the real shape:

| | ns/element |
|---|---|
| `.each(.min(1))` over the array | 29.9 |
| the same rule called once per element | 22.7 |
| `.min(1)` on the array (element count) | 0.0 |

So `.each` costs **7.2 ns of machinery**, not 47, and the other 22.7 is simply what a
`.min` on a `String` costs — which the `rules` arm already published as 16.1 ns plus a
3 ns fixed cost. Nothing was unexplained; the measurement was wrong.

Hoisting `r.message ?? override` out of the element loop as well takes it to **4.0 ns**.
The finding is closed, and the lesson is the ordinary one: an end-to-end A/B cannot
attribute a cost to a component, and I should not have written down a number it produced.

Two claims from readers were also wrong and were caught by testing rather than by reading:
unbounded XML entity recursion (did not reproduce at 200,000 chained entities or on a 512 KB
stack), and a 1.05 s did-you-mean cost (23 ms here — the reader's key lengths defeated the
cheap-reject).

## 5. SIMD: the recorded decision stands, with better evidence than it had

Not argued — **built**. A 16-wide `SIMD16<UInt8>` quote/backslash/control scanner replacing
the scalar loops in `scanString`, `scanKey` and `skipString`, in a copy of the repo, with the
full suite passing.

| | |
|---|---|
| kernel in isolation | 2.07× at 8 B, 7.02× at 32 B, 12.7× at 1024 B |
| `apimodel-8k` end to end | **−5.6%** |
| `apimodel-64k` end to end | −3.1% |
| `long-strings` tree | −17.9% |
| `short-strings` tree | **+11.8% SLOWER** |
| `floats-dense` | −0.1% |

A slice worth 21% of decode in isolation realises 3–6% end to end, and **regresses the
short-string shape by 12%**. Two reasons worth keeping: apimodel's values average 32 bytes
and its keys 7.6, so a 16-byte kernel amortises over one and a half vectors; and an isolated
microbenchmark overstates the realised win about 4× because the scalar loop is interleaved
with `String` construction and an out-of-order core hides most of it.

The UTF-8 share has **fallen** since SIMD was retired — 5.0–5.3% in August, 2.5–7.5% today —
because everything else got faster. The ceiling is lower than when the decision was made.

**Verdict: do nothing.** The one candidate with a defensible number is a whitespace skipper
for pretty-printed input (~8% there, ~40 lines); not worth it either.

## 6. Concurrency: nothing for the library

- **The caller already has it, for free.** `Assayable: Sendable`, decode is a static function
  over `[UInt8]` with no shared state. Measured across independent documents: 2.24× at 8
  docs, 3.58× at 64, 7.09× at 512. A library-provided `parseAll(concurrently:)` would buy
  nothing over three lines the caller writes, and would make Assay own a thread-pool policy.
- **A trap worth documenting:** the identical task group driven from `@MainActor` measures
  0.77× at 8 documents — a *loss*, because each result hops back to the actor. Someone
  parallelising decodes from a view model will make it slower and not know why.
  **CLOSED 2026-09-13:** `EXPERIENCE.md` §11 carries it, beside the async-check ordering,
  with the three scaling numbers and the fix (leave the actor: `nonisolated`, or a detached
  task awaited once).
- **Within one document: no.** Splitting a large array needs a structural index this library
  deliberately does not build, and the 8 MB arm is already flat at ~700 MB/s.
- **YAML `parseAll`: no.** `---` is only recognisable by parsing, so finding the split points
  is most of the parse.
- **Batch `validate`: no.** 72 ns/value against ~400 ns of task overhead.
- **`DiffFuzz`: the one worthwhile change.** 22,914 documents in 1.6 s wall at 66% CPU. The
  argument is not the 1.4 s of CI saved; it is that the same CI second buys ~10× the
  mutations. ~20 lines.
- **Benchmarks must stay serial**, and macro expansion is not the term worth attacking.

## 7. Async: right, with one documentation gap

`@AsyncCheck` is the only async surface and its shape is correct — full sync pass, early
return unless clean, then a task group. Constraint 7 is honoured and nothing on the decode
path is async.

**The gap:** `parse(mmapped:)` is synchronous and page-faults on first touch of every page.
Called from an async function it blocks a cooperative thread for the file's entire I/O —
measurable at 8 MB, a liveness problem on a multi-gigabyte mapping. Swift has no
blocking-I/O executor, so the honest answer is a documented `Task.detached`, not an API.
**CLOSED 2026-09-13:** `diagnose(mmapped:)`'s doc comment carries it, with the reason
`Task.detached` and not `Task { }` (a child task inherits the executor and blocks the same
pool).

## 8. `Sendable` costs nothing

Zero locks, zero atomics, zero dispatch queues in `Sources/`. Five `@unchecked Sendable`,
each justified, none on a hot path. `Assayable: Sendable` is a marker protocol — and it is
exactly what makes the caller-side parallelism in §6 free.

## 9. Still open

- `.each`'s ~47 ns/element of unexplained machinery (§4).
- ~~`Date` decode allocates a `String` and then an `Array` per format tried~~ — **FIXED
  2026-09-13.** The date parsers are generic over `RandomAccessCollection<UInt8>` with
  `Index == Int` now, and `parse(_ text: String, as:)` hands them the String's own
  contiguous UTF-8 through `withContiguousStorageIfAvailable` instead of copying it into an
  `Array`. An ISO-8601 timestamp is ~20 bytes, past the 15-byte small-string limit, so both
  allocations were real. **The `dates` arm went 6.05× → 8.04×** (8k: 8,291 → 6,148 ns for 92
  dates), the 2,279-instant differential against Foundation is unchanged, and the allocation
  gate is unmoved.
- ~~TOML basic strings accumulate byte-by-byte~~ — **FIXED 2026-09-13.** A single-line basic
  string with no escape in it — very nearly every one anyone writes — now reaches the closing
  quote and takes one sized `String` copy out of the source, building no `[UInt8]` at all;
  and the general loop copies RUNS of ordinary bytes rather than appending one at a time.
  **Struct decode 1.96× → 2.30× over TOMLKit, the tree 1.18× → 1.42× over toml++** (8k:
  77,182 → 66,397 ns). 218 documents still agree with toml++.
- ~~TOML numbers re-accumulate digits~~ — **FIXED 2026-09-13**, after the local
  `toml-test` checkout that the first pass lacked turned up. The decimal fast path decides
  an integer without an accumulator and hands a float its own source text; it may only
  DECLINE, never accept, so the general path still owns every diagnostic. **Struct decode
  1.96× → 2.41×, node parse 1.18× → 1.51×** (both including the string work). Validated by
  710/710 on the official suite plus a new `toml-numbers` oracle — ~4,900 documents, 4,227
  agreeing, 687 rejected by both, none disagreeing — which also surfaced a pre-existing
  float range divergence against toml++ that is now documented as an open question.
- ~~`YAML.Node → RawValue` re-destructures the scalar payload five times per node~~ — **done
  2026-09-13, and it bought nothing measurable.** The projection read `isNull`,
  `resolvedBool`, `resolvedInt`, `resolvedDouble` and `content` in turn, each re-matching
  `case .scalar(let s)` and re-retaining the payload; there is one destructure and one
  `RawValue(resolving:)` now. **The YAML struct-decode arm did not move**: 11.20× → 11.36×
  mean, 8k 41,770 → ~41,350 ns, against a run-to-run spread of ±2.3% measured over three
  runs on unchanged code. The change is kept because it is less work and simpler, not
  because it is faster — five enum matches and five ARC pairs per scalar turn out not to be
  where YAML decode time goes. Recorded this way on purpose: an unmeasured "optimisation"
  that is really a refactor should not be filed as a win.
- `MappedFile` exposes `UnsafeRawPointer` and `withUnsafeBytes` publicly — hard constraint 11
  says unsafe stays below the seam. Nothing outside the module uses them.
- No benchmark arm covers the XML→`RawValue` projection, which is why a 4× regression there
  could have shipped unnoticed.
