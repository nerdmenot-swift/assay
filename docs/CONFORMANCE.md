# What each parser accepts, and how that is checked

A decoder's contract is not only what it *does* with valid input. It is equally what it
refuses, and a parser that quietly accepts a document its specification forbids is wrong in a
way that is very hard to notice — nothing crashes, nothing is reported, and the bug surfaces
years later as an interoperability argument.

This document is the accept/reject contract for all three formats, and the harness that
holds it.

---

## 1. The blind spot this document exists because of

For most of its life Assay's JSON differential worked like this: read every file in the
corpus, parse it with both Assay and `JSONSerialization`, compare the values.

That is a good test. It also cannot see over-permissiveness at all. Every input is a
document *both* parsers accept, so the only question it asks is "did Assay refuse something
Foundation takes?" — never the reverse. Beside it, the fuzzer asserted that nothing crashed
or hung, which is a different property again.

Nine conformance bugs lived in that gap:

| accepted | required by |
|---|---|
| a raw tab, newline or other control byte inside a string | §7 — must be escaped |
| `01`, `007`, `-01` | §6 — `int = zero / ( digit1-9 *DIGIT )` |
| `.5`, `-.5` | §6 — the integer part is mandatory |
| `1.`, `1.e5` | §6 — `frac = "." 1*DIGIT` |

None crashed. None produced a wrong value for a valid document. They said yes where RFC 8259
says no.

**And chasing them turned up a tenth that mattered far more**, which acceptance testing could
not have found either. `scanInt64` returned nil on overflow *without rewinding the cursor*,
so the caller's fallback to `scanDouble` began in the middle of the digits and parsed
whatever was left:

```
12345678901234567890              decoded as 0.0
123456789012345678901234567890    decoded as 1234567890.0
```

No issue, no infinity — a different number, silently. A 20-digit identifier became zero. The
lesson generalises: **acceptance testing and value testing find different bugs, and neither
substitutes for the other.**

---

## 2. The harness

Four differentials, all in `Benchmarks/Sources/DiffFuzz/`, all run in CI.

| file | question |
|---|---|
| `main.swift` | do both decoders produce the same VALUE for documents both accept? |
| `RejectOracle.swift` | do they agree on what to REJECT, and are numbers bit-exact? |
| `FormatOracle.swift` | does the fast rule engine agree with the naive one it replaced? |
| `YAMLOracle` / `XMLOracle` / `DateOracle` | the same two questions per format |

### Choosing an oracle, and not obeying it

`JSONSerialization` is the reference for JSON, and it is wrong in two ways this harness had
to learn:

- **It accepts trailing commas**, which §5 forbids. Listed in `knownFoundationLaxities` so a
  *new* divergence still fails the build while a known one does not.
- **It is not correctly rounded.** `0.1234567890123456789012345` comes back as
  `0.12345678901234573`; the nearest Double is `...68`, which Assay produces. Treating
  Foundation as the judge would have filed Assay's correct answer as the bug.

So the number differential uses **the Swift stdlib** as its oracle — `Double(String)` is
correctly rounded since swiftlang/swift#85797 — and reports Foundation's divergences without
obeying them. One honest caveat: for inputs that fall through to `slowDouble`, Assay *calls*
the stdlib, so the comparison is vacuous there by construction. It is not vacuous on the
Clinger fast path or the integer path, which are Assay's own arithmetic, and the corpus
straddles both sides of that line.

The rule engine's oracle is unusual and worth copying: it is **the previous implementation,
kept verbatim**, `Array(s.utf8)` and `[[UInt8]]` and all. That version was obviously correct
and obviously slow. 40,062 generated strings × 6 checks must agree.

### Testing the test

A differential that never fails is indistinguishable from one that is not running. Both of
these were verified by deliberately breaking the thing under test:

- Removing the CR condition from `characterCount` makes the format differential fail and
  name the offending strings.
- The reject corpus caught its own oracle's trailing-comma laxity on the first run.

---

## 3. JSON — RFC 8259

77 documents in the reject corpus, each labelled with what the RFC requires.

**Refused, as required:** raw control bytes in strings (in values and in keys, on both the
fast and the escape path); lone, reversed and unpaired surrogates; bad escapes and short
`\uXXXX`; leading zeros; a missing integer part or fraction digits; an exponent with no
digits; `0x1`, `Infinity`, `NaN`; trailing and leading commas; single quotes; unquoted keys;
comments; trailing content and a second document; unterminated strings and containers.

**Accepted, as required:** `0x20` and `0x7F` raw; every legal escape; `-0`; `0.5`, `0e0`,
`1E5`, `1e+5`; empty containers; an empty key; all four whitespace bytes.

### Left open by the RFC, and what Assay chose

The RFC permits implementations to differ here. Each is reported by the harness and never
failed, so the choice stays visible rather than drifting.

| case | Assay | Foundation |
|---|---|---|
| duplicate keys | last wins | last wins |
| a leading byte-order mark | **reject** | accept |
| nesting past `Limits.maxDepth` (64) | **reject** | accept |
| `1e400` | accept, as `+∞` | reject |
| integers past Int64 | accept, as the correctly-rounded Double | accept |

### The one deliberate laxity

**A structurally skipped value has its extent checked and its contents ignored.**

```swift
{"known": 1, "unknown": NaN}     // a schema decodes this
```

`JSON.Value.parse` refuses it. `skipValue` finds where the value ends — matching brackets,
string state so a `}` inside a string does not close an object, refusing an unterminated
container, charging nesting against `maxDepth` — and never looks at what it skipped.

This is what makes the prefix path 6.3×, and validating a value in order to discard it spends
exactly what skipping saves. simdjson's On-Demand API documents the same property for the
same reason. The consequence is worth stating plainly:

> **`T.parse(json:)` is not a JSON validator.** It validates the document's structure and
> every value the schema declares. A caller who needs the whole document checked wants
> `JSON.Value.parse`.

---

## 4. YAML — 1.2 core schema

Checked against Yams/libyaml on hand-written documents and on the whole JSON corpus rendered
to YAML, plus the JSON corpus read *as* YAML, since YAML 1.2 defines JSON as a strict subset.

**Supported, with semantics verified rather than merely parsed:** block and flow collections;
anchors and aliases, including aliases to collections; merge keys (`<<`) actually merged;
literal and folded block scalars with all three chomping indicators; explicit keys (`?`);
multi-document streams; `!!str`/`!!int` and custom tags; single and double quoting with
escapes; comments; every null spelling; indentation indicators; `%YAML` directives; complex
flow keys.

**The Norway problem is avoided by construction.** A plain scalar keeps its text until
something asks a typed question, so `NO` is the string `"NO"` and `12:30` is the string
`"12:30"`, per the 1.2 core schema.

**Not supported:** see `ROADMAP.md`'s known-gaps table — plain multiline scalars, and anchors
declared in flow style.

**Security:** alias expansion is charged against a node budget, with an anchor's cost counted
as its whole expanded subtree. A 331-byte alias bomb that once produced 11.4M nodes is a
regression test.

---

## 5. XML — 1.0, UTF-8

Checked against Foundation's `XMLParser` for the accept/reject verdict.

**Supported:** namespaces, including the rule that an unprefixed attribute is *not* in the
default namespace; CDATA; comments; processing instructions; character and predefined entity
references; the DOCTYPE internal subset as declarations to skip; line-ending and
attribute-value normalisation.

**Refused, agreeing with Foundation:** mismatched, unclosed and multiple root tags; unquoted
and duplicate attributes; `<` in an attribute value; a raw `&`; undefined entities; bad
character references; unclosed comments and CDATA; a digit-leading name; text before or after
the root.

**Known divergences, all over-permissive** — see `ROADMAP.md`:

- `]]>` accepted in character data
- `--` accepted inside a comment
- an XML declaration accepted when it is not the first thing in the document

**Security.** External entities are refused outright — no network, no filesystem, ever. A
billion-laughs document does not expand: 290 bytes in, 30 bytes out against the 1,000,000 a
full expansion would produce. Note *why*, because the mechanism is not the one you would
guess: nested entities are never re-expanded at all, so the expansion budget is not what
saves you. That is also a correctness gap — the value comes back as the literal text
`&e;&e;…` rather than resolving — and it is tracked in `ROADMAP.md`.

---

## 6. Where this is enforced

- `Tests/AssayTests/ConformanceTests.swift` — the JSON grammar and the overflow-rewind
  property, in `swift test`.
- `Tests/AssayTests/SpanTests.swift` — that carets point at the right bytes.
- `Benchmarks/Sources/DiffFuzz` — the four differentials plus 9,680 mutated and truncated
  inputs per run, in CI.
- `Experiments/03-compile-time/gate.sh` — two compile-time budgets.

Every ratio quoted anywhere in this repository is one arm64 Mac, warm, minimum of five
rounds, and says so. See `CLAUDE.md`'s honesty rules.
