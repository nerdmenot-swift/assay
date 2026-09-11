---
title: A SQL result set
description: One adapter in your driver, written once, and every schema anyone declares decodes from it — with global row numbers on the failures.
---

A database driver has rows of typed cells. Assay has structs with rules. The join between
them is about twenty lines, written once in the driver, generic over every schema it will
ever see.

```swift
/// Stand-in for whatever your driver calls a cell. Every driver has this enum.
enum Cell { case null, int(Int64), double(Double), text(String), bool(Bool) }

@Schema(keys: .snakeCase, formats: [], sources: true)
struct Account: Equatable {
    var id: Int64
    @Validate(.email) var email: String
    var displayName: String
    var lockedAt: String?
}

/// The adapter a driver writes ONCE, generic over every schema anyone will declare.
func decodeRows<T: SourceDecodable>(
    _ rows: [[Cell]], columns: [String], as _: T.Type, batchSize: Int = 2
) -> [BatchDiagnosis<T>] {
    var dec = RowDecoder<T>(columns: columns, batchSize: batchSize)
    var batches: [BatchDiagnosis<T>] = []
    for row in rows {
        dec.beginRow()
        for (i, cell) in row.enumerated() {
            switch cell {
            case .int(let v):    dec.append(int64: v, column: i)
            case .double(let v): dec.append(double: v, column: i)
            case .text(let s):   dec.append(string: s, column: i)
            case .bool(let v):   dec.append(bool: v, column: i)
            case .null:          dec.appendNull(column: i)
            }
        }
        if dec.isFull { batches.append(dec.flush()) }
    }
    let last = dec.finish()
    if !last.values.isEmpty || !last.issues.isEmpty { batches.append(last) }
    return batches
}
```

That `switch` is the entire adapter. It knows nothing about `Account`, and `Account` knows
nothing about your driver.

```text
id, email, display_name, locked_at
1, jo@example.com, Jo, NULL
2, sam@example.com, Sam, 2026-01-02T03:04:05Z
3, not-an-email, Kim, NULL
4, lee@example.com, Lee, NULL
5, also-not-an-email, Max, NULL
```

```text
3 batches of 2

batch 0: 2 rows
batch 1: 1 rows
  [[2].email] must be a valid email address
batch 2: 0 rows
  [[4].email] must be a valid email address
```

`batchSize: 2` is small to make the batching visible. Note the indices: the failures say
`[2]` and `[4]`, which are positions in the **result set**, not in the batch they happened
to land in. Stream a million rows in batches of four thousand and the number still points
at the row.

## Binding by position instead of by name

Many drivers drop column names by the time you see a row. If you generated the `SELECT`
list from the schema, the columns *are* the manifest order and no names are needed:

```swift
let select = T._assayManifest.keys.joined(separator: ", ")
let plan = BoundPlan(slots: Array(0..<T._assayManifest.fields.count))
var dec = RowDecoder<T>(plan: plan)
```

## Text-mode drivers

Postgres in text mode sends `numeric`, `uuid`, `date` and `timestamptz` as strings. That
works, with the same two switches a [CSV](/recipes/csv/) needs: `coerceScalars` on the
schema, `inferColumnKinds: true` on the decoder. A `Date` field takes text either way,
since text is what a date is on every other path — add a `@DateFormat` if the column is not
ISO 8601:

```swift
@DateFormat(.pattern("yyyy-MM-dd HH:mm:ssZ")) var createdAt: Date
```

A mixed driver is fine too: `inferColumnKinds` means each column's kind comes from its
first cell, so one column arriving as `Int64` and the next as text both land correctly.

## Failing before you decode a million rows

```swift
guard dec.missingColumns.isEmpty else { throw QueryError.missing(dec.missingColumns) }
```

Known from the binding, before the first row.

## If you own the wire format

This is the generic route, and it is not the fastest one. A driver that parses the wire
protocol itself can decode straight into typed column arrays and conform *those* to
`ColumnarSource`, which is about 11 ns per row against roughly 40 for this. `RowDecoder`
exists so that the generic route is cheap, not so that a driver that wants the last 30
nanoseconds uses it.

## Writing rows back

`encodeRow(into:)` hands each field to a sink in manifest order, so the column list and the
bound parameters both come from the schema and cannot disagree:

```swift
let columns = Account._assayManifest.keys       // for the INSERT list
```

## Next

- [Rows and columns](/formats/rows-and-columns/) — the full surface and the design notes.
- [A CSV file](/recipes/csv/) — the same machinery with text cells.
- [Dates](/guides/dates/) — timestamps from columns, with units.
