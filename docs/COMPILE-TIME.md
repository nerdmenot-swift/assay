# Assay — the compile-time budget

*Third document. `EXPERIENCE.md` settled the shape, `PERFORMANCE.md` settled the runtime
strategy. This one exists because a decoder built on a macro has a second performance
axis, and it is the one that decides whether anybody adopts the library.*

---

## 0. Why this is a gate and not a footnote

Runtime speed is what Assay is *for*. Compile time is what determines whether anyone gets
far enough to notice.

The asymmetry is worth stating plainly. A developer evaluating Assay replaces `: Codable`
with `@Schema` across their model layer in one commit — that is the whole pitch, one
attribute wide — and then waits for a build. If that build got materially slower, they
revert, and no runtime number ever gets a hearing. **The adoption decision is made at
compile time, before the first benchmark is run.**

The field reports that make this a real risk rather than a theoretical one are already
cited in `EXPERIENCE.md` §13: a 30-second build going to 5 minutes, a 44-second build
going to 338 seconds, and one developer reporting that a macro which did *nothing at all*
doubled their release build times. Every expansion is a round trip to a separate compiler
plugin process.

Swift 6.2 shipping a prebuilt swift-syntax fixed the *fixed* cost — the one-off price of
building the macro infrastructure. It did nothing for the *per-expansion* cost, which is
the one that scales with the user's model layer.

So: measured, budgeted, and gated in CI, next to the allocation gate.

---

## 1. What it actually costs

Measured, not estimated. Method and raw numbers in
`Experiments/03-compile-time/RESULTS.md`.

**~84 ms per `@Schema` type at 10 fields, in the default configuration.**

> A band rather than a figure, but a much narrower one since 2026-08-30: every timing is now
> the **minimum of three builds** rather than a single one, and consecutive runs read
> 80.0 / 83.6 / 85.0 ms. It used to be a single build, and consecutive runs read anywhere
> from 88 to 94 — with the rule-carrying arm spanning 131 to 178 and failing its budget
> twice in one afternoon on unchanged code.
>
> Build time is a floor plus contention, so noise only ever *adds*; the minimum is the
> least-contaminated sample. The runtime benchmarks have always reported minimum-of-5 for
> the same reason, and this measurement was the odd one out. The gate stays at 100 ms: a
> threshold tight enough to trip on run-to-run noise is a threshold that gets disabled, and
> the fix for noise is to measure better, not to widen until the noise fits.

```
JSON body (default)         ≈  9 ms fixed + 7.3 ms × fields   →  ~82 ms
+ RawValue body (YAML/XML)  ≈             +3.4 ms × fields    →  ~118 ms
```

The second body is emitted **only when the type opts in** with `@Schema(formats:)`. A type
that only ever parses JSON pays nothing for YAML and XML support. See §4.5.

Against the alternatives, at 100 types × 10 fields on a clean module build:

| | time | ratio |
|---|---|---|
| plain struct, no conformance | 0.83 s | 1.0× |
| `: Codable` | 2.20 s | 2.7× |
| `@Schema` (JSON + RawValue bodies) | 11.31 s | **13.6×** |

`@Schema` costs **5.1× what `Codable` costs**. That is the honest number and it belongs in
the README, not buried here.

### The finding that matters most

**Cost scales with generated *body size*, not with the number of expansions.** The plugin
round trip — the thing macro build cost is usually blamed on — is the ~9 ms fixed term.
The ~7.3 ms per field is the compiler type-checking what the macro emitted.

That inverts the obvious optimization strategy. "Call the plugin less" buys almost
nothing. "Emit less code per field" buys everything.

---

## 2. The budget

| schema types | added to a clean build | verdict |
|---|---|---|
| ≤ 50 | < 6 s | fine |
| 50–200 | 6–23 s | noticeable; isolate schemas in a rarely-changing module |
| 200–1000 | 23–116 s | measure before adopting wholesale |
| > 1000 | > 116 s | do not adopt without a plan |

`EXPERIENCE.md` §13 said "`@Schema` on forty types is fine, `@Schema` on four thousand is
something to measure." That was the right instinct; this is the number behind it. Four
thousand types is roughly **five minutes**.

**CI gate: 100 ms per type at 10 fields, measured in the default configuration, as the
minimum of three builds.** Currently ~80–85 ms; ~120–129 ms for a type carrying a rule on
nearly every field, against a 145 ms budget.

Worth recording how this number moved, because it is a case study in the rule above.
Multi-format support pushed it to 118 ms and the budget was raised to 140 with a
justification. Then formats were made opt-in, and the default came back to 82 ms — so the
original budget stands and the raise was reverted. **Raising a budget should be the last
resort, not the first response to a failing gate.** Like the allocation gate, this is an *absolute* threshold with an
exact expected value, re-baselined only in a reviewed commit — not a percentage drift
against a noisy baseline.

---

## 3. Rules for the macro

These are binding on codegen in the same way the hot-path constraints are binding on the
runtime. Both of the first two were found by measuring, not by reasoning.

1. **Never emit a large array literal.** The window dispatch table is 256 bytes; emitting
   it as a 256-element `[UInt8]` literal costs 16% of total expansion time, because the
   type checker checks every element. Emit the populated entries only (≤64) and fill the
   rest at static-init time. Runtime behaviour is identical.

2. **One line of generated code per field.** Anything conditional — null handling,
   coercion, fallbacks — belongs in an `@inlinable` runtime function in `AssayCore`, not
   in an `if/else` emitted per field. Folding null handling into `decodeXOrNull` took
   per-field cost from 9.4 ms to 7.3 ms.

3. **Push work into the runtime, not the expansion.** Every construct added to
   `EXPERIENCE.md` — `@Validate`, `@Preprocess`, `@Transform`, `@Check`, `@Coerce` — will
   want to emit per-field code. Each one must be a *call* into a runtime primitive. The
   temptation to inline a rule's logic into the generated body is the temptation to make
   every user's build slower.

4. **Never mark generated bodies `@inlinable`.** It buys nothing — the body is already in
   the user's module and already concrete — and SE-0193 restricts `@inlinable` bodies to
   ABI-public declarations, which makes every *public* `@Schema` type fail to compile
   against its own internal memberwise initializer.

5. **Do the key analysis in one pass.** The window search is O(offsets × shifts × keys²)
   at expansion time, which is nothing at realistic key counts, but it must not be re-run
   per field.

6. **Measure before adding a feature to the macro.** `Experiments/03-compile-time` takes
   about a minute to run. Any change that moves per-field cost is a change that needs a
   number attached.

---

## 4. What users can do

Worth documenting for adopters rather than leaving them to discover it:

- **Put schema types in a module that changes rarely.** Expansion results cache; a module
  that does not change is not re-expanded.
- **Prefer one `@Schema` type with `@Inline` members over many small ones**, once
  `@Inline` exists. Fixed per-type cost is ~9 ms and per-field cost is ~7 ms, so
  consolidation genuinely helps.
- **Wide types are the expensive case, not numerous types.** A 40-field type costs about
  as much as four 10-field types.
- **Keep the swift-syntax pin matched to your toolchain.** `Package.swift` pins the 603
  line for Swift 6.3. A mismatched pin forfeits the Swift 6.2+ prebuilt swift-syntax and
  every developer pays a from-source build of the macro infrastructure.

---

## 4.5 Formats are opt-in, and this is why

`EXPERIENCE.md` §12 states the principle: *"JSON users never pay for XML."* That was a
**linking** claim, and it held because `AssayYAML` and `AssayXML` are separate products.

Briefly it stopped holding for **compile time**: the `RawValue` decode body was emitted for
every `@Schema` type whether or not it would ever see YAML, costing ~34 ms per type — about
41% of the total — for a capability most users do not want.

Resolved by making formats opt-in on the type, which is also §18's principle applied
("everything that affects the meaning of a struct is written on the struct"):

```swift
@Schema                                   // JSON only — the default. ~82 ms
@Schema(formats: [.json, .yaml])          // adds the RawValue body. ~118 ms
@Schema(formats: .all)
@Schema(formats: [.yaml])                 // YAML only — no JSON body at all
```

The mechanism is a protocol split: `JSONAssayable` carries the byte-decode body,
`RawDecodable` carries the `RawValue` one, and both refine the `Assayable` marker. So
calling `parse(yaml:)` on a type that did not opt in is a **compile** error naming the
missing conformance, not a runtime surprise:

```
error: referencing static method 'parse(yaml:limits:sourceName:)' on 'RawDecodable'
       requires that 'JSONOnly' conform to 'RawDecodable'
```

The same split makes a nested-type mismatch catchable too: a `.yaml` parent containing a
`.json`-only child fails to compile, rather than failing at parse time on a payload.

## 4b. Array fields cost more than rules, and nothing measured that until now

**~102 ms per type at 10 array fields, against ~70 for the same fields as scalars** — so an
array-heavy type is roughly **1.4×** a scalar one, and *more expensive than a `@Validate` on
every field* (~97 ms). Measured 2026-09-08; before that every arm of the harness declared
scalars only, so this shape had never been near the budget.

That gap mattered because `arrayDecode` is the one generator that does not follow the rule
this document sets out in §3: per-field generated code should be **one line calling an
`@inlinable` runtime primitive**, with anything conditional living in `AssayCore`. An array
field instead emits an inline decode loop — brackets, element scan, append, terminator — per
field, per type. Two changes in one week touched that loop (element indices, `@OneOrMany`)
without any way to see what they cost.

**Reported, not gated.** The 100 ms budget was calibrated on the default scalar shape, and
holding a second shape to a number calibrated for the first is how a budget stops meaning
anything. What the number is for is watching it: if it grows, the fix is known — move
scalar-element array decode to monomorphic runtime primitives, one per element type, exactly
as `scalarCall` already does for plain fields. That would make `@OneOrMany` free instead of
costly and would very likely *lower* per-field cost for every existing `[String]` and `[Int]`
field. `ROADMAP.md` §5 records it.

## 5. The other axes

Six were listed here as unmeasured. **Three were measured on 2026-09-09** and are below;
three remain open and say so.

### 5.1 Incremental builds — MEASURED, and the answer is the good one

`Experiments/03-compile-time/incremental.sh`. This was the one that mattered: a clean build is
the *adoption decision*, made once, while an incremental build is what a developer feels all
day. The risk was concrete rather than formal — a macro plugin is a separate process, and if
one edited file invalidated every expansion in its module, `@Schema` would turn a one-line
change to a model layer into a whole-module re-expansion that no clean-build number would ever
show.

Four scenarios, one type per **file** (a module compiled as one file has nothing to be
incremental about), median of 3, debug:

| scenario | 15 types | 45 types |
|---|---|---|
| `no-op` (nothing changed) | 1.03× | 1.00× |
| `touch-plain` (an ordinary struct in the module) | 1.06× | 1.19× |
| `touch-consumer` (a file that *uses* the schemas) | 1.06× | 1.19× |
| `touch-schema` (one `@Schema` file of N) | 1.13× | 1.17× |

All ratios are against the identical `Codable` module.

**`touch-schema` ≈ `touch-plain`, and the gap does not grow with module size** — 0.03 s at 15
types, nothing measurable at 45. Editing one schema costs what editing any file costs. If
expansion were module-wide the gap would scale with the type count; it does not.

**`touch-consumer` ≈ `touch-plain`** — merely *using* a schema does not re-expand it, which was
the expensive failure mode.

What a schema-heavy module does cost is a flat ~1.2× on any incremental edit at 45 types,
including edits to files with no schema in them. That is the module having more code in it,
not the edit being expensive.

### 5.2 Release configuration — MEASURED, and it is the expensive one

`CONFIG=release Experiments/03-compile-time/measure.sh`, medians of 3, same machine and same
types as the debug table above.

| types | plain | codable | schema | validated | arrays | paths | vs-codable |
|---|---|---|---|---|---|---|---|
| 1 | 0.41 | 0.45 | 0.74 | 0.75 | 1.16 | 0.87 | 1.64× |
| 10 | 0.43 | 0.66 | 2.89 | 2.58 | 6.39 | 3.84 | 4.38× |
| 25 | 0.43 | 0.99 | 6.34 | 5.66 | 15.29 | 9.20 | 6.40× |
| 50 | 0.43 | 1.57 | 12.38 | 10.91 | 30.01 | 17.49 | 7.89× |
| 100 | 0.47 | 2.69 | 25.57 | 21.35 | 60.48 | 33.03 | **9.51×** |

**Release costs about 3.4× debug per type: ~245 ms against the ~72 ms the gate holds.** The
`arrays` arm reaches ~600 ms/type. Nothing here was previously known, and the debug budget does
not describe release builds even approximately — that is the point of writing it down.

Two things about the shape, not just the size.

**The ratio against `Codable` grows with type count in release and stays flat in debug** (1.64×
at one type, 9.51× at a hundred; debug goes 1.14× to ~3.9×). That is the cost model in §4
behaving exactly as stated (§2, ~9 ms fixed + 7.3 ms per field): cost tracks **generated body size**, and the optimizer is a second
pass over that same body. Debug pays for the body once; release pays for it twice, with the
second pass superlinear in places.

**`validated` is CHEAPER than `schema` in release** — 21.35 against 25.57 at a hundred types —
having been *more* expensive in debug. The rule arrays are `static let` constants the optimizer
folds, and the `_assayCheck` body they feed is straight-line; meanwhile the extra work makes no
new inlining decisions. It is a small inversion, but it is the sort of thing that makes "add a
rule, pay a compile-time cost" the wrong intuition to carry around.

**Why the gate stays on debug.** Debug is what an incremental edit-build-run cycle uses (§5.1),
which is the thing a developer feels, and it is what CI can run in a minute rather than ten.
Release is now measured and reported; it is not gated, because a wall-clock gate on a hosted
runner is what `CLAUDE.md`'s honesty rules forbid, and the release numbers are four times more
exposed to runner contention than the debug ones.

The number to carry: **a release build of a large model layer is where `@Schema` is most
expensive relative to `Codable`**, and a project with a hundred schema types should expect to
pay roughly twenty seconds of optimizer time for them.

### 5.3 Type-checker pathologies — MEASURED, nothing found

`-Xfrontend -warn-long-expression-type-checking` at 100 ms, 50 ms, 20 ms and **10 ms**, at
`-O`, over the rule-heavy arm (a `@Validate` on nearly every field, the worst generated
`_assayCheck` body): **zero expressions at every threshold.**

That is a consequence of rules 4 and 6 rather than luck. Per-field generated code is one line
calling a concrete, monomorphic runtime primitive with the field's type already fixed — there
is no overload set to explore and no generic parameter to solve, so there is nothing for
inference to go exponential on. The property is worth keeping: an emitter that started
producing multi-term expressions with inferred literals would be where this changes.

### 5.5 `describes: true` — a predicted HIGH risk that did not arrive

`ROADMAP.md` §11 flagged `jsonSchema(for:)` as high compile-time risk before it was built, on
the explicit grounds that a per-field descriptor is "an array literal, the exact shape rule 1
was written about". Measured with a `describes` arm added to `gen_types.sh` for the purpose —
`describes: true` on top of the rule-carrying arm, which is the shape the feature is for:

**94.6 ms/type against `validated`'s 90.0 — about 5%.**

The prediction was reasonable and the design is why it did not come true, so it is worth being
precise about which choice did the work:

1. The macro emits a **descriptor**, not JSON Schema text. The rule-to-keyword mapping — one
   `Rule` case becoming `minLength`, `minimum` or `minItems` depending on the field's type —
   is ~120 lines and lives once in `AssayCore`, not once per type in every user's build.
2. The descriptor **references** `Self.__assayRules_i_j`, the `static let` the validator body
   already holds. A field with three rules contributes one identifier to the descriptor, not
   three rule literals. This is why the arm is measured on top of `validated` rather than
   `schema`: on a rule-free type the saving would not be visible.

Rule 1 remains right; the descriptor simply is not the shape it warns about.

### 5.4 Still unmeasured

- **Xcode / SwiftUI previews.** Anecdotally the most sensitive environment to macro cost; no
  data, and no way to get any from a command-line harness.
- **Cross-compilation.** Macro cross-compilation to Android was fixed in SwiftPM #8670, but its
  cost is unmeasured. Android is not a target (`CLAUDE.md`), so this is unlikely to move.
- **Linux.** The compile-time harness has still only run on one arm64 macOS machine. The
  *test* suite gates on Linux and Windows; the compile-time budget does not.

---

## 6. The claim Assay can defend

> `@Schema` costs about 80 ms per type at 10 fields, roughly 3.6× what `Codable` costs, on
> a clean build. For a typical model layer of 40 types that is under 4 seconds. Here is
> the harness; run it on your own types.

Checkable, falsifiable, survives CI, and does not decay. The same standard the runtime
claims are held to.

And the refusal, in the same spirit as the runtime one: **do not claim `@Schema` is
"free", "zero-cost at compile time", or "as cheap as Codable".** It is none of those. It
is a real cost, it is bounded, it is measured, and it buys a 5× runtime decode.
