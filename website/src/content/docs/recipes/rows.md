---
title: Rows and columns
description: A column store straight into structs, and getting field values back out with no tree in between.
---

A decoder does not have to read files. A Parquet file, an Arrow batch, a SQL result set and
a CSV are all the same struct with the same rules — the difference is only how the cells
arrive.

```swift
@Schema(keys: .snakeCase, formats: [], encodes: true, sources: true)
struct Row: Equatable {
    var id: Int64
    @Validate(.email) var email: String
    var active: Bool
}
```

`sources: true` adds the batch decoder. `formats: []` skips the JSON body, because a type
that only ever comes from a database should not pay the build time for an entry point it
never calls.

## A source that is already column-first

Conform it and hand over one array per field:

```swift
struct Store: ColumnarSource {
    var ids: [Int64], emails: [String], actives: [Bool]
    var rowCount: Int { ids.count }
    borrowing func int64Column(_ key: StaticString, _ f: Int) -> [Int64]? { f == 0 ? ids : nil }
    borrowing func stringColumn(_ key: StaticString, _ f: Int) -> [String]? { f == 1 ? emails : nil }
    borrowing func boolColumn(_ key: StaticString, _ f: Int) -> [Bool]? { f == 2 ? actives : nil }
    borrowing func doubleColumn(_ key: StaticString, _ f: Int) -> [Double]? { nil }
}

let batch = Row.batch(from: store)
```

```text
ids:     [1, 2, 3]
emails:  ["a@example.com", "nope", "c@example.com"]
actives: [true, false, true]
```

```text
decoded 2 of 3
  Row(id: 1, email: "a@example.com", active: true)
  Row(id: 3, email: "c@example.com", active: true)

issues:
  [[1].email] must be a valid email address
```

Two rows decoded, one rejected, and the failure carries **the row it came from**. Rules run
per row exactly as they do on a document, and so do `@Check` and `@Transform`.

About 11 nanoseconds per row, flat from 64 rows to 100,000. The win is the access pattern:
row-by-row over a column store is a jump between allocations per cell, and inverting the
loop makes each column one sequential pass.

## A source that is row-shaped

`RowDecoder` does the transpose for you, so a SQL driver or a CSV reader does not have to
write one. [A CSV](/recipes/csv/) and [a SQL result set](/recipes/sql-rows/) are the two
worked examples.

## Your own scalar type

A `Timestamp`, a `Decimal128`, a fixed-width identifier — something Assay has never heard
of can cross a column store without Assay learning its name:

```swift
struct Micros: ColumnDecodable {
    var value: Int64
    init?(assayColumn c: borrowing ColumnBuffer<Int64>, row: Int, metadata m: ColumnMetadata) {
        value = c[row] * 1_000
    }
}
```

The carrier is an associated type, so the generic call happens once per **column** and the
per-row call names a concrete type in your module. It costs about 3 nanoseconds a row over
a built-in column.

The unit arrives as **data** (`ColumnMetadata`), not as part of the type: a Parquet
timestamp column is millis or micros or nanos according to its own metadata, and a schema
that hardcodes one is wrong against files that use another.

`Date` and `UUID` already conform, in `AssayFoundation`.

## The write side

Getting field values *out* is the one thing your library cannot do itself, because only the
macro knows the fields. `encodeRow(into:)` hands each one to a sink in manifest order:

```swift
struct PrintSink: RowSink {
    var cells: [String] = []
    mutating func write(int64 v: Int64, _ f: Int) { cells.append(String(v)) }
    mutating func write(double v: Double, _ f: Int) { cells.append(String(v)) }
    mutating func write(bool v: Bool, _ f: Int) { cells.append(String(v)) }
    mutating func write(string v: String, _ f: Int) { cells.append(v) }
    mutating func write(bytes v: UnsafeRawBufferPointer, _ f: Int) { cells.append("\(v.count) bytes") }
    mutating func writeNull(_ f: Int) { cells.append("NULL") }
}
```

```swift
Row(id: 7, email: "jo@example.com", active: true)
```

```text
columns: id, email, active
cells:   7, jo@example.com, true
```

Six methods, no tree, about 1.3 nanoseconds a row against 64 for building a `RawValue` and
walking it. The column list comes from `_assayManifest.keys`, so a CSV header or an
`INSERT` list cannot drift from the values under it — which is the bug this exists to
prevent.

## Next

- [A CSV file](/recipes/csv/) — the row-shaped reader, end to end.
- [Rows and columns, explained](/formats/rows-and-columns/) — the full surface and the design notes.
