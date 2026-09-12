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

## 4. What I got wrong, recorded because it is the point

I predicted `.each`'s 63 ns/element was the per-element path allocation. I hoisted it and
**measured no change.** The bare `.min(3) on String` rule costs 16.1 ns, so ~47 ns of
`.each` machinery is still unexplained and is an open finding, not a fixed one. The hoist
is kept because it is strictly less work, and it is claimed as nothing.

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

## 8. `Sendable` costs nothing

Zero locks, zero atomics, zero dispatch queues in `Sources/`. Five `@unchecked Sendable`,
each justified, none on a hot path. `Assayable: Sendable` is a marker protocol — and it is
exactly what makes the caller-side parallelism in §6 free.

## 9. Still open

- `.each`'s ~47 ns/element of unexplained machinery (§4).
- `Date` decode allocates a `String` and then an `Array` per format tried; the byte-taking
  parser already exists and is internal.
- TOML basic strings accumulate byte-by-byte where `scanString` does one sized copy; TOML
  numbers re-accumulate digits rather than using `scanDouble`.
- `YAML.Node → RawValue` re-destructures the scalar payload five times per node.
- `MappedFile` exposes `UnsafeRawPointer` and `withUnsafeBytes` publicly — hard constraint 11
  says unsafe stays below the seam. Nothing outside the module uses them.
- No benchmark arm covers the XML→`RawValue` projection, which is why a 4× regression there
  could have shipped unnoticed.
