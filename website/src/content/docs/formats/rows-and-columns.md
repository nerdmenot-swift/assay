---
title: Rows and columns
description: SQL result sets, CSV, Parquet — the same struct, the same rules, row numbers instead of byte offsets.
---

A decoder does not have to read files. A database row is a set of typed cells with names, a
CSV record is the same thing in text, and a Parquet file is the same thing transposed. All
three decode into your `@Schema` type.

```swift
@Schema(keys: .snakeCase, formats: [], sources: true)
struct User {
    var id: Int64
    @Validate(.email) var email: String
    var name: String
    var createdAt: Date
    var nickname: String?
}
```

Note `formats: []` — a type that only ever comes from a database does not need a JSON body
generated for it. `sources: true` is what adds the batch decoder.

## From a row source: SQL, CSV, anything

```swift
var dec = RowDecoder<User>(columns: resultSet.columnNames)
for row in resultSet {
    dec.beginRow()
    for (i, cell) in row.enumerated() {
        switch cell {
        case .int(let v):    dec.append(int64: v, column: i)
        case .double(let v): dec.append(double: v, column: i)
        case .text(let s):   dec.append(string: s, column: i)
        case .blob(let b):   dec.append(bytes: b, column: i)
        case .bool(let v):   dec.append(bool: v, column: i)
        case .null:          dec.appendNull(column: i)
        }
    }
    if dec.isFull { consume(dec.flush()) }
}
consume(dec.finish())
```

That switch is the whole adapter. Write it once in your driver and every schema anyone ever
declares works with it.

`flush()` returns a `BatchDiagnosis<User>`: the rows that decoded, the issues, the warnings,
and whether the issue list was capped. Issues carry **global** row indices — an error on the
250,003rd row says `[250003].email`, not `[3].email` — so streaming a million rows in
batches of 4,096 still gives you findable failures.

`missingColumns` is known before the first row, so a driver can fail fast rather than
decoding a million rows that each report the same absent column.

## From a column store: Parquet, Arrow

If your source is already column-first, skip the transpose entirely: conform it to
`ColumnarSource` and hand over one array per field.

```swift
let batch = User.batch(from: store)
```

About 11 ns per row — flat from 64 rows to 100,000, because the win is the access pattern
rather than cache residency. Row-by-row over a column store is strided by construction: N
records over M columns is N×M jumps between M separate allocations. Inverting the loop makes
each column one sequential pass, which is what the format was laid out for and what the
hardware wants.

## Text cells

CSV gives you strings for everything, and so does a database in text mode. Two switches
make that work, and you need both.

The schema says text is acceptable, with `coerceScalars` or `@Coerce` per field. A numeric
or boolean field then takes the string column and parses it per row, by exactly the same
rules the tree path uses, from one shared definition — so `"8080.5"` is not an integer on
either.

```swift
@Schema(coerceScalars: true, formats: [], sources: true)
struct CSVRow {
    var id: Int
    var ratio: Double
    var active: Bool
    var when: Date
}
```

The decoder says the cells are not the kind the fields declare:

```swift
var dec = RowDecoder<CSVRow>(columns: header, inferColumnKinds: true)
```

Without that second switch each column's storage comes from the schema, so `"8080"`
offered to an `Int` field is a wrong-kind cell and the field reports `missing_column`
instead. Each column's kind then comes from its first cell, which also handles a mixed
source: a driver sending a real `Int64` for one column and text for the next gets the
right storage for both.

It is a flag rather than the default because it costs about 8 ns per row, and a driver
that sends typed cells should not pay for one that does not.

A `Date` field takes text **always** — text is what a date is on every other path — so
`@DateFormat` chains, fallback warnings and invalid-date reports behave identically here.
A cell that does not parse reports `type_mismatch` with the row and the text; one that
overflows the declared width reports `number_overflow`.

## Validation runs

Everything runs per row: `@Validate`, `@Preprocess`, `@Fallback` (its warning carries the
row), `@Check` in both forms, and `@Key(_:or:)` aliases — an alias column is tried when the
primary is absent, and the warning is filed once for the batch rather than once per row.

A row that reports anything is not in `values`, the same as on every other path.

`@AsyncCheck` with `sources: true` is **refused at expansion**: a batch decode is
synchronous, so the check could only be skipped, and skipping it silently is how bugs are
made.

## Your own scalar types

A `Timestamp` with a unit, a `Decimal128`, a `UUID` from raw bytes — Assay should not have
to learn their names. One conformance:

```swift
struct Micros: ColumnDecodable {
    var value: Int64
    init?(assayColumn c: borrowing ColumnBuffer<Int64>, row: Int, metadata m: ColumnMetadata) {
        guard m.unit == -6 else { return nil }
        value = c[row]
    }
}
```

The carrier is an associated type, so the per-row call is concrete in your module and there
is no witness table. That is the shape that matters: the generic call happens once per
*column*, and the per-row work is direct.

It is not quite free. Your own type costs about **3 ns per row** over a built-in column, at
these absolute numbers 1.7–2.0×, because the generated loop reads the validity mask and the
metadata off the column for every row where a built-in column has them hoisted. Worth
knowing and small enough to stop worrying about: the alternative shape, a protocol call per
row, measured 1.6–4.7× and was deleted for it.

The unit arrives as **data** (`ColumnMetadata`), not as part of the type. A Parquet
timestamp column is millis or micros or nanos according to its own metadata, and a schema
that hardcodes one is wrong against files that use another.

`Date` and `UUID` already conform, in `AssayFoundation`.

## The write side

For a CSV writer or an `INSERT` binder, building a value tree per row is waste. With
`encodes: true` as well as `sources: true`:

```swift
struct CSVSink: RowSink {
    var out: [UInt8] = []
    mutating func write(int64 v: Int64, _ field: Int) { … }
    mutating func write(string v: String, _ field: Int) { … }
    // …four more
}

var sink = CSVSink()
for user in users { user.encodeRow(into: &sink) }
```

One typed call per field in manifest order, no tree — about 1.3 ns per row for the handoff
against 64 for the tree route. The column names are `T._assayManifest.keys`, so the header
row and the field list come from the same declaration as the properties. That last point
is the real one: restating the field list is how a writer ends up emitting columns in a
different order than its header claims.

`ColumnEncodable` is the inverse of `ColumnDecodable`, for your own scalars on the way out.

## What this is not

Assay does not ship a CSV parser, a SQL driver or a Parquet reader, and will not. Those are
formats with their own edge cases and belong to the libraries that own them. What is here is
the seam: the transpose, the batch decode, the diagnostics with row numbers, and the write
side — the parts that need to know your schema.

There is also no row-at-a-time *protocol*, and that is a decision rather than an omission.
One was built, measured and removed: its per-row calls went out of a generic decode body
through a witness table, costing 1.6–4.7× in a driver, and it could not hold a borrowed row.
The direction is what matters — here the per-cell calls go *into* a concrete type and the
generic call happens once per batch.

## What it costs

`sources: true` roughly doubles a type's expansion cost — about 164 ms per type at the
widest (ten fields, `coerceScalars` on, so every field carries both the typed and the text
branch), against 80 for JSON alone. That is why it is opt-in.

## Next

- [Errors](/guides/errors/) — including what a batch's issues look like.
- [Performance](/reference/performance/) — the row and column numbers with their caveats.
