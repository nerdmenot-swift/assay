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

**~82 ms per `@Schema` type at 10 fields, in the default configuration.**

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

**CI gate: 100 ms per type at 10 fields, measured in the default configuration.**
Currently ~82 ms.

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

## 5. What is not yet measured

Stated because an unmeasured axis should never read as a measured one.

1. **Incremental builds.** This is what developers feel all day, and it is not measured
   here at all. A one-type edit should re-expand only that type; unverified.
2. **Release configuration.** Debug only so far. Optimizer time on generated bodies is
   additional and may scale differently.
3. **Xcode / SwiftUI previews.** Anecdotally the most sensitive environment to macro cost;
   no data.
4. **Cross-compilation.** Macro cross-compilation to Android was fixed in SwiftPM #8670,
   but its cost is unmeasured.
5. **Linux.** One arm64 macOS machine.
6. **Type-checker pathologies.** Nothing here explores whether a generated expression can
   trip exponential inference. Worth `-Xfrontend -warn-long-expression-type-checking`.

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
