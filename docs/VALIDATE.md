# Validating a value you already have

Assay fuses validation into decoding. That is the right default, and it is most of what
makes it fast: rules run against the wire value, in the same pass, with the byte offsets
still in hand, so `replicas: 0` renders with a caret under the `0`.

It also left a hole, and the hole was load-bearing. If something *else* produced your
value, there was no way to ask the schema whether it is legal. The rules were declared on
the type and reachable only through a decode.

```swift
let trips = try Table("trips.parquet").rows(of: Trip.self)   // someone else's decoder
// ... and now what? Trip's @Validate rules are unreachable.
```

`validate` closes it.

```swift
try Trip.validate(trips)                    // throws AssayError with every issue
let v = Trip.diagnose(trips)                // or: issues, warnings, isValid, render
```

---

## 1. The API

Conformance to `Validatable` is generated for any `@Schema` type that declares a
`@Validate` or a `@Check`. It is not behind a flag like `encodes:` or `sources:`, because a
type with no rules gets no body and pays nothing — there is nothing to opt out of.

```swift
static func validate(_ value: Self, limits: Limits = .default) throws(AssayError)
static func diagnose(_ value: Self, limits: Limits = .default) -> Validation

static func validate(_ values: some Sequence<Self>, ...) throws(AssayError)
static func diagnose(_ values: some Sequence<Self>, ...) -> Validation
```

`Validation` carries `issues`, `warnings`, `truncatedIssues`, `isValid`, `check()` and
`render(_:)`. It is deliberately **not** `Diagnosis`: there is no `value` — you already have
it — and no source bytes, and a result type carrying two empty fields would be advertising
a caret it cannot draw.

The batch forms put `[i]` at the head of every issue path, so a million-row report still
says which row. They share **one** `IssueSink`, so `Limits.maxIssues` bounds the report
rather than each element; a per-element limit over a file where every row is bad produces a
million issues and protects nothing.

`@AsyncCheck` gets `async` overloads with the same ordering the decode paths use: the
synchronous pass collects everything first, async checks run only if it was clean, and over
a batch they run concurrently. A round trip to a database to see whether a slug is taken is
wasted work on a value that already failed `.min(1)`.

### Why `validate` came back

`docs/EXPERIENCE.md` §2 records `validate` being **cut**: it collided with
`ParsableArguments.validate()` and Vapor's `Validatable.validate()`, and two of the three
verbs had the same shape anyway. That decision stands for what it was about — a third
*parse* verb, `T.validate(json:)`, alongside `parse` and `diagnose`.

This is a different function. It is static, takes the value as its argument, and does not
decode anything, so it does not collide with an instance `validate()` on either of those
protocols. A type conforming to both `Assay.Validatable` and `Vapor.Validatable` resolves by
argument type; the protocols are reachable as `Assay.Validatable` and `Vapor.Validatable`
when the bare name is ambiguous.

---

## 2. The law

> `T.validate(try T.parse(json: d))` never reports an issue, for any `d` that parses
> cleanly.

A value the decoder **accepted** must not be rejected by the validator. Two entry points
that disagree about whether the same value is legal would be worse than having only one,
because a caller cannot tell which answer is real.

`Tests/AssayTests/ValidateValueTests.swift` checks this by *generating* inputs rather than
listing them: 600 documents with values in and out of every declared range, round-tripped
through JSON, with a guard that the generator actually produced valid ones. The interesting
failures are the combinations nobody thinks to write down.

Everything in the next section is a consequence of the law, not an independent preference.

---

## 3. What does not run, and why

### `@Preprocess`

Does not run. It normalises **wire** text before decoding — `.trim` on a string that
arrived with spaces. The value in hand is already decoded, and `validate` reports rather
than mutates, so there is nothing for it to do.

### `@Fallback`

A `@Fallback` field's rules do not run. This is the law in its sharpest form: at decode
time a violation there is **swallowed** — the field takes its fallback and records a
warning — so re-reporting it against the constructed value would reject the exact value
decoding just produced.

```swift
@Validate(.range(1...10)) @Fallback(5) var level: Int
```

`{"level": 999}` decodes to `level == 5` with a warning. `validate` on that value must
report nothing, and it does. The honest consequence is that `Salvaged(level: 999)` — a value
decoding could never have produced — also passes. That is the price of the law, and it is
named in the generated doc comment rather than left to be discovered.

### `@Transform`

A `@Transform` field's rules do not run. Rules are type-checked against the **wire** type
and the transform runs after them, so the property holds a different type than the rules
were checked against:

```swift
@Validate(.min(2)) @Transform({ (s: String) in s.count }) var width: Int
```

`.min(2)` was checked against `String`. The property is an `Int`. There is nothing here to
re-run.

### How you find out

The macro lists every excluded field, with its reason, in the doc comment it generates on
`_assayCheck` — so it appears in quick-help and autocomplete.

It is deliberately **not** an expansion-time warning. `@Validate` beside `@Fallback` is a
perfectly good decode-time combination, and putting a diagnostic on correct code because a
*different* entry point cannot re-check it is how a project ends up with a warning everyone
has learned to scroll past.

### No carets

Issues carry a path and no location, because there is no source document to point at. The
renderer has always handled that — a missing-field issue has never had a span either.

---

## 4. Cost

Measured on this machine; see `Benchmarks/RESULTS.md` for the tables and the honesty rules
that apply to every ratio in this repository.

**Validating costs what the rules cost, and nothing else.** Decoding a six-field document
through a schema with rules and through the same schema without them differ by 94 ns;
`validate` on the constructed value takes 79. The seam adds nothing of its own — it is the
rule engine, called from a second place.

| | ns |
|---|---|
| decode, schema with rules | 444 |
| decode, same schema no rules | 350 |
| **validate a constructed value** | **79** |

Over a batch it is **87 ns/row**, flat from 64 rows to 100,000 — 79 for the rules plus the
array element copy. That is 1.6× this machine's columnar batch decode (53 ns/row), which is
the honest way to read the seam: validating a row costs somewhat more than the fastest
decode Assay has, and is not in the same universe as decoding it twice.

Two things had to be right for that number, and neither was obvious:

- **`@inlinable` on all four entry points.** They are generic over `Self` and over the
  sequence, they live in a source package, and the call site is in the user's module —
  hard constraint 5's exact case. Without it the per-element loop runs through witness
  tables: **176 ns/row**, more than double, and the gap was the loop rather than the rules.
- **One `[PathComponent]` array for the whole batch**, rewritten in place. The obvious
  `[.index(i)]` inside the loop allocates per row.

**Compile time.** `_assayCheck` is one line of generated code per rule attribute, reusing
the `__assayRules_i_j` arrays the decode bodies already share. It costs nothing for a type
with no rules, and about 25 ms/type for one carrying a rule on nearly every field — the
per-field cost paid once more over the same fields, which is what `docs/COMPILE-TIME.md`
§2's 7.3 ms/field model predicts. `Experiments/03-compile-time/gate.sh` holds both arms:
100 ms for a rule-free type, 145 ms for a rule-carrying one.

### The rule costs, and what they bought

| rule | before | after |
|---|---|---|
| `.range(13...120)` on `Int` | 8.9 | 8.6 |
| `.min(3)` on `String` | 22.4 | 14.0 |
| `.max(64)` on `String` | 22.4 | 14.2 |
| `.min(1)` on `[String]` | 9.9 | 11.0 |
| `.email` | **178.8** | **25.1** |
| `.url` | 42.0 | 21.4 |
| `.uuid` | 50.5 | 28.5 |

Nanoseconds, one rule per type against the same value, minus a measured fixed cost for the
call itself.

Building this entry point is what first put the rule engine under a microscope, because a
rule that is 4% of a decode is invisible and the same rule called per row over a million
rows is not. `.email` measured **179 ns** against 9 ns for `.range` — an 8× gap over the
next most expensive rule. The algorithm was not the problem:

- `isEmail` built `Array(s.utf8)`, then `Array(domain)`.
- `isHostname` split the domain into `[[UInt8]]` — one array per label, plus reallocating
  appends — then checked each label separately.
- `isTrimmed` built a `Set<UInt8>` per call.

Roughly six heap allocations to check fifteen bytes.

The *obvious* fix — walk `String.utf8` directly with indices — removed every allocation and
made `.uuid` **slower**, 50 to 61 ns. `String.UTF8View.Iterator` carries a representation
check per byte that `Array` iteration does not, and over 36 bytes that outweighed the malloc
it saved. So the shape is neither: take the contiguous buffer once with `withUTF8`, convert
it to a `Span` at that single seam — hard constraint 11, unsafe only below the seam and the
seam expressible in `Span` and values — and walk that. Every validator below the seam is
ordinary safe Swift, and the file now emits *fewer* strict-memory-safety warnings than the
allocating version it replaced.

`.min`/`.max` on a `String` had a second, subtler cost. They use `String.count`, which is
grapheme-cluster segmentation — the correct meaning for a rule whose message says
"characters", and what Swift's own `count` returns. `FormatValidators.characterCount` takes
the shortcut: if every byte is ASCII **and none is CR**, each byte is its own grapheme
cluster and the count is the byte count. CR is the only exception and the reason this
cannot simply be "is it ASCII" — `"\r\n"` is a *single* cluster spanning two ASCII bytes.

All of it is checked against a naive oracle. `Benchmarks/Sources/DiffFuzz/FormatOracle.swift`
keeps the previous implementation verbatim — `Array(s.utf8)`, `[[UInt8]]` and all — and
requires the fast one to agree with it over 40,000 generated strings plus a table of corner
cases: empty labels, boundary hyphens, the legal trailing dot, an all-numeric TLD, CR, and
combining marks. `characterCount` is checked against `String.count` itself. That is what
makes this a speedup rather than a behaviour change nobody noticed; deliberately breaking
the CR condition makes the differential fail, which is how the check was checked.

---

## 5. Why this and not a decode path

The obvious answer to "a Parquet reader wants Assay's rules" is a third decode path — a
protocol for decoding one record at a time out of anything already parsed and addressable
by key. That was built, measured, and removed. `Sources/AssayCore/ColumnarSource.swift`
carries the full reasoning; in short:

- It lost to the path it was invented to beat. Building a `RawValue` and decoding through
  the tree path cost 95 ns per row; the row protocol cost 311 ns once its presence
  semantics were correct. The premise that justified it — "an allocation per value per
  record" — was false.
- It could not accept the borrowed rows it existed for. A genuinely zero-copy row view is
  `~Escapable`, and Assay refuses to put an experimental-feature gate on its public
  surface.
- Its cost landed worst exactly where a driver lives: a `rows(of: T.self)` loop is generic
  over the schema, `@inlinable` is forbidden on generated bodies (SE-0193), and the
  witness-table call is paid per row — 1.6–4.7×.

`validate` has none of those problems because it is not trying to decode. The specialised
reader does what it is good at, at its own speed, in its own module; Assay does what it is
good at afterwards. Neither side pays for the other, and neither has to know the other's
memory model.

The columnar half of that design survives, for the symmetric reason: a column store hands
over whole arrays, so there is no per-row borrow, no per-row dispatch, and no per-row
presence ambiguity. See `docs/KEYED-SOURCE.md`.
