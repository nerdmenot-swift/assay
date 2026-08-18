# The third decode path: what it cost to find out it was wrong

Assay decodes from two shapes.

| path | input | who uses it |
|---|---|---|
| **bytes-direct** | a contiguous UTF-8 buffer | JSON. The fast path; the `Codable` boundary is deleted here |
| **`RawValue` tree** | a materialised, format-neutral tree | YAML, XML, and anything already parsed |

A third was designed, built, measured and **removed**. What survives is one narrow piece of
it — a columnar batch path — plus a separate entry point that solves the problem the third
path was actually reaching for. This document is the record, because the idea is attractive
enough to be reinvented and the argument against it is entirely empirical.

- **The removal and why:** §1–§3 below.
- **What survives:** §4, `ColumnarSource`.
- **What you want instead:** [`docs/VALIDATE.md`](VALIDATE.md).

---

## 1. The idea, and the premise that justified it

A large class of data arrives **already parsed into fields**: database rows, CSV records,
Parquet, plists, form posts, env blocks. Reaching it meant building a `RawValue` tree first.
So: a `KeyedSource` protocol, with the schema pulling each declared field out of the source
by key, no tree in between.

The premise, written into the first version of this document, was that the `RawValue` path
"costs an allocation per value per record."

**That was false, and nobody checked it before building.** `RawValue.mapping` is *one*
allocation for the whole record, and short keys do not allocate at all — a fact this
repository's own `CLAUDE.md` already recorded under "corrected premises." The measurement
that should have come first came last.

---

## 2. Three findings that closed it

### It lost to the path it was invented to beat

Starting from the same native row and decoding into the same struct:

| approach | ns/record |
|---|---|
| build a `RawValue.mapping`, decode through the tree path | **95** |
| `KeyedSource`, addressing the row in place | **311** |

The row protocol was 3.3× *slower* than the thing it existed to replace, once its presence
semantics were correct. There is a narrow shape where it wins — a source much wider than the
schema, where the tree materialises columns nobody asked for — but "your table has 48
columns and your struct has 8" is not a foundation for a decode path.

### It could not accept the borrowed rows it existed for

The whole appeal was zero-copy: a row view pointing into a page the driver already has. A
genuinely zero-copy row view is `~Escapable`, and `AssayReader` already faced this exact
question and refused it.

**The reason recorded at the time — that it would put an experimental-feature gate on the
whole library — is measurably wrong**, and the correction is worth having because the real
reason is stronger. As of Swift 6.3.3 a client consumes a `~Escapable` public type with no
feature flag at all. What actually binds is value semantics: `Array` requires `Escapable`, so
a `~Escapable` row cannot be an element of anything, cannot be stored in an escapable struct,
cannot be `Equatable`, and cannot outlive the scope that made it. A protocol whose associated
values are `~Escapable` constrains every caller to one closure.

So the protocol was `~Copyable` only, and the sources that most wanted it structurally could
not conform. It was designed for a caller it could not accept.

### Its cost landed worst exactly where a driver lives

The generic entry point specialises within a module. The arrangement that matters is
`db.query(as: User.self)` — a loop **in the driver**, generic over a schema in someone
else's module. `@inlinable` is forbidden on generated bodies (SE-0193 makes every public
`@Schema` type fail against its own internal memberwise init), so the witness-table call
stands and is paid **per row**: 1.6–4.7×.

The module boundary itself was not the problem — being generic over the schema was, and
only per-row.

---

## 3. What the removal was not

Not a retreat from the goal. A specialised reader wanting Assay's rules is a real need, and
`validate` serves it better than a decode path ever could:

```swift
let trips = try Table("trips.parquet").rows(of: Trip.self)   // their decoder, their speed
try Trip.validate(trips)                                     // our rules
```

Neither side pays for the other, and neither has to know the other's memory model — which is
precisely what the `~Escapable` collision above proved they cannot share. See
[`docs/VALIDATE.md`](VALIDATE.md).

### A trap worth keeping

`RawValue` conforms to `ExpressibleByNilLiteral` — `let v: RawValue = nil` means `.null`.
In a function returning `RawValue?`, a bare `nil` resolves to **`.some(.null)`**, not to
absence:

```swift
return i == absent ? nil : values[i]                        // WRONG: absent reads as null
return i == absent ? Optional<RawValue>.none : values[i]    // right
```

The consequence is quiet and specific: an **absent** column reports as a **present null**, so
a field with a default reports a type mismatch instead of taking its default. It cost a
debugging round while writing this document's own examples, and it applies to anyone
building a `RawValue` from a source that distinguishes absent from null.

---

## 4. What survives: `ColumnarSource`

Opt in with `@Schema(sources: true)`.

A column store — Parquet, Arrow, a column database — hands over one array per field. Decoding
it record-by-record is strided by construction: N records over M columns is N×M jumps between
M separate allocations. Inverting the loop makes each column one sequential pass.

**Every reason the row path failed is absent here.** Whole arrays cross the boundary, so
there is no per-row borrow to escape, no per-row dispatch to pay, and no per-row presence
ambiguity to translate.

```swift
let (values, issues, truncated) = Trip.batch(from: store)
```

Measured on this machine, against the honest baseline — a `RawValue` per row through the tree
path, which is what a caller does today:

| rows | row-wise ns | batch ns | per row | batch wins |
|---|---|---|---|---|
| 64 | 4,117 | 3,245 | 51 | 1.27× |
| 1,000 | 68,325 | 53,123 | 53 | 1.29× |
| 20,000 | 1,363,879 | 1,056,638 | 53 | 1.29× |
| 100,000 | 6,918,521 | 5,441,729 | 54 | 1.27× |

Flat at ~53 ns/row across a 1,500× size range: the win is the access pattern, not cache
residency. And the arrangement that killed the row path is a non-issue here — the same batch
called from another module, generic over the schema, costs **1.03×**, because the per-row
loop lives inside a function concrete in the schema's own module. **A driver API should be
batch-shaped.**

### Scope

**Flat scalar columns only.** An array, dictionary or nested `@Schema` field on a
`sources: true` type is a **compile error** naming the field, rather than a runtime surprise.
`RawValue` remains the answer for anything tree-shaped.

**Two-phase binding.** `FieldManifest` is what a `@Schema` type declares, in order, resolved
at compile time; `BoundPlan` resolves it against one source's column names, once, for a whole
batch. A missing required column is reported **once for the batch** — it is a property of the
source, and a reader over a million rows should not be told a million times.

**No carets.** A columnar source has no byte offsets, so issues carry paths and no location.
Issues over a batch carry `[i]` for the row.
