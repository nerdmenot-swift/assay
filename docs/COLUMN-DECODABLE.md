# The columnar extension point

*Built and measured 2026-08-30.*

`@Schema(sources: true)` lets a type be filled from a column store — Parquet, Arrow, a
column database, anything that hands over one array per field. This document is about the
seam that lets a type Assay has never heard of come across it.

## The problem it solves

Before this, the macro mapped exactly eight spellings to four column accessors:

```swift
case "String":                        return "stringColumn"
case "Bool":                          return "boolColumn"
case "Double", "Float":               return "doubleColumn"
case "Int", "Int64", "Int32", "UInt": return "int64Column"
default:                              return nil
```

and refused everything else at expansion. A consumer with a `Timestamp`, a `Decimal128`, a
`CalendarDate` had no route at all.

**The gap was not "N missing types". It was "no extension point."** Adding four more
accessors would have been the wrong fix twice over: a protocol that grows one member per
type never stops growing, and the types being added would have been one caller's file-format
vocabulary, which does not belong in a general library. Assay must not learn the name
`Decimal128`, and it has not.

## The shape

Three pieces, and the split between them is the whole design.

```swift
public protocol ColumnDecodable {
    associatedtype Column: ColumnStorage
    init?(assayColumn column: borrowing Column, row: Int, metadata: ColumnMetadata)
}
```

`Column` is one of `ColumnBuffer<Int64>`, `ColumnBuffer<Double>`, `ColumnBuffer<Bool>`,
`ColumnBuffer<String>` or `BytesColumn`. Conform, and any `@Schema(sources: true)` type may
declare a field of that type:

```swift
struct Instant { var epochNanoseconds: Int64 }

extension Instant: ColumnDecodable {
    init?(assayColumn c: borrowing ColumnBuffer<Int64>,
          row: Int, metadata m: ColumnMetadata) {
        let scale: Int64
        switch m.unit {
        case -9: scale = 1
        case -6: scale = 1_000
        case -3: scale = 1_000_000
        default: return nil
        }
        let (n, overflow) = c[row].multipliedReportingOverflow(by: scale)
        guard !overflow else { return nil }
        epochNanoseconds = n
    }
}
```

Returning `nil` reports the row as missing, with the field's path and row index, exactly as
a null or a short column does. It is the right answer for a value the column can hold and
this type cannot represent — including an overflow, which is why the example checks one.

### The unit is data, not type

`ColumnMetadata` carries `unit`, `scale` and `flags`, and it comes from the **source**, not
from the schema. A Parquet timestamp column declares milliseconds or microseconds or
nanoseconds in its own metadata, and two files with the same logical schema are allowed to
disagree — so a Swift type that fixes the unit is wrong against half of them.

This is also why `AssayCarrier` includes `Int64` rather than making everything numeric a
`Double`. A `Double` carries 2^53 nanoseconds, about 104 days; it cannot hold a modern
instant at nanosecond resolution at all.

The fields are deliberately untyped. Giving `ColumnMetadata` an enum of time units would be
Assay learning one caller's vocabulary through the back door.

## Why this does not repeat the `KeyedSource` mistake

`docs/KEYED-SOURCE.md` records a row-at-a-time decode path that was built, measured and
removed. One of its three fatal problems was dispatch: a call through a generic parameter
inside Assay, in a loop the *consumer* drives, cannot be inlined away, because `@inlinable`
is forbidden on generated bodies (SE-0193 — a public `@Schema` type fails against its own
internal memberwise init). It cost 1.6–4.7× per row.

That objection is real, and the obvious version of this feature would have walked straight
into it. Measured across a real module boundary, converting one `Int64` per value:

| shape | ns/value |
|---|---|
| baseline — copy `Int64`, no conversion | 0.34 |
| concrete `init`, as the macro emits it | **0.35** |
| through a generic parameter in the library | **21.35** |
| through an existential | 3.74 |
| this design — generic fetch per column, concrete `init` per row | **0.47** |

The generic call is `Column._assayFetch`, made **once per column**, so its cost divides by
the row count. The per-row call names a concrete type in the module that declares the
schema, exactly as the macro already emits `Date(timeIntervalSince1970:)`. There is no
witness table to go through.

Confirmed in the library itself, which is the number to quote — same store, same column,
same two-field schema, 100k rows, the only difference being how the field is declared:

| field type | ns/row |
|---|---|
| `Int64`, built in | 42.65 |
| `Micros`, `ColumnDecodable` | 42.29 (0.99×) |

Three runs: 0.99×, 0.99×, 1.02×. The hook is free; the spread is the measurement.

## Why the carrier is an associated type and not a field attribute

A macro is **syntactic**. It sees `var takenAt: Timestamp` as an identifier and cannot see
conformances, associated types, or anything else the type checker knows — because the type
checker has not run and will not run until after expansion. So the macro cannot work out
whether to ask the source for an integer column or a binary one.

The alternative is to make the author say so at the use site:

```swift
@Column(.int64) var takenAt: Timestamp     // rejected
```

which puts an annotation on every field, forever, for a fact that belongs to the type and
never varies. `associatedtype Column` states it once, on the type, and lets the macro emit
one uniform line for a type it knows nothing about:

```swift
let __c1 = Assay._assayFetchColumn(Timestamp.self, from: source, "taken_at", 1)
...
__f1 = Timestamp(assayColumn: __col1, row: __r, metadata: __col1.metadata)
```

`_assayFetchColumn` is a free function rather than `T.Column._assayFetch(...)` written
inline, purely for the error a non-conforming type gets. Spelling `T.Column` directly
produces *"'Column' is not a member type of struct 'Timestamp'"*, which names neither the
protocol nor the fix; the free function produces *"requires that 'Timestamp' conform to
'ColumnDecodable'"*, which names both.

## Bytes columns

`BytesColumn` is Arrow's varbinary layout: every row's bytes concatenated into one buffer,
plus `count + 1` offsets into it. **Not `[[UInt8]]`**, and that was a deliberate decision
rather than an analogy with `stringColumn`.

`[[UInt8]]` is one heap allocation per row, charged to every reader whether or not it wants
a copy — and a Parquet or Arrow reader already *has* the flat buffer and the offsets,
because that is how the format stores them. Measured over identical arithmetic on identical
bytes, at only 16 bytes per row:

| access | ns/row |
|---|---|
| `range(at:)` into the flat buffer | 54.93 |
| `bytes(at:)`, one `Array` per row | 84.23 (1.53×) |

27–29 ns/row across runs, and it grows with the blob. The analogy with `stringColumn`
returning `[String]` does not carry: short strings ride in small-string form and never touch
the heap, and a blob never does.

Three ways to read a row, cheapest first:

```swift
if let r = column.range(at: row) { ... column.bytes[i] ... }  // free
column.slice(at: row)                                          // ArraySlice, no copy
column.bytes(at: row)                                          // [UInt8], copies
```

`slice(at:)` returns `ArraySlice` rather than `Span` because `Array.span` is macOS 26 and
this package's floor is macOS 11 — a `Span` accessor would be available to a fraction of
callers and absent for the rest.

The offsets come from the source, so they are **input, not an invariant**. Non-monotonic,
negative or out-of-range offsets yield `nil` rows; a reader with a bug must never trap
inside somebody else's decode loop.

## What a conforming type still needs

`ColumnDecodable` is the **columnar** half only. A field type also needs a tree path —
`_assay(from:)` for JSON and for `RawValue` — because a `@Schema` type's standing promise is
`T.parse(json:)`, and that has to mean something for every field. Annotating the type with
`@Schema` supplies it. The two halves are independent and both required.

## Not built

**`[UInt8]` as a field type.** It looks like the natural client of the bytes column and it
does not work, for a reason upstream of all of this: `UInt8` is not a scalar on the tree
path, so `var payload: [UInt8]` cannot appear in *any* `@Schema` type. Making it work means
adding the small integer widths to the decoder, the encoder and the rule engine — six files
and a set of range-checked primitives — which is a separate change with its own tests.
`ROADMAP.md` carries it. Binary data reaches a schema today through a consumer type whose
`Column` is `BytesColumn`, which is what the bytes column is for.

**`Date` and `UUID` conformances.** Deliberately not shipped in `AssayCore`, which is
Foundation-free by design. They belong in `AssayFoundation`, and `Date` in particular must
not become a native columnar type: `Date` is seconds-as-`Double`, so a native `Date` column
would bake in a unit and lose precision in exactly the nanosecond case that motivated
`ColumnMetadata`. `ROADMAP.md`.

## The generality test

Everything above was written against one question: would this also serve a SQLite driver, a
Postgres driver, a DuckDB binding, an Arrow reader, or a CSV library written by someone
else? `ColumnDecodable` is `stringColumn`/`int64Column` with the type-to-column mapping
lifted out of the macro and handed to the consumer. Every one of those gets it, at the same
measured zero cost, and Assay learns none of their type names.
