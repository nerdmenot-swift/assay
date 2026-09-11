---
title: A CSV file
description: Split the lines yourself, hand the cells over as text, and get structs back with the row number on every failure.
---

Assay does not parse CSV. Quoting, embedded newlines and the several dialects people call
CSV are a reader's job, and a good reader already exists in whatever you are using. What
Assay does is the part after that: cells into typed fields, with your rules and your
errors.

```swift
@Schema(keys: .snakeCase, coerceScalars: true, formats: [], sources: true)
struct Sale: Equatable {
    var orderId: Int64
    @Validate(.min(1)) var sku: String
    @Validate(.range(1...999)) var quantity: Int
    var unitPrice: Double
    var note: String?
}

func decodeCSV(_ text: String) -> BatchDiagnosis<Sale> {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    let header = lines.removeFirst().split(separator: ",").map(String.init)
    // `inferColumnKinds` because every cell arrives as text: without it each column's
    // storage comes from the schema, and `"1001"` offered to an Int64 column is rejected.
    var dec = RowDecoder<Sale>(columns: header, inferColumnKinds: true)
    for line in lines {
        dec.beginRow()
        for (i, cell) in line.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            if cell.isEmpty { dec.appendNull(column: i) } else { dec.append(text: cell.utf8, column: i) }
        }
    }
    return dec.finish()
}
```

That splitter is deliberately naive — no quoting — because it is not the point. Replace it
with yours; everything below is unchanged.

```text
order_id,sku,quantity,unit_price,note
1001,WIDGET-1,2,9.99,gift wrap
1002,WIDGET-2,1,24.50,
1003,WIDGET-3,0,5.00,
1004,WIDGET-4,many,5.00,
```

```text
decoded 2 of 4 rows

  Sale(orderId: 1001, sku: "WIDGET-1", quantity: 2, unitPrice: 9.99, note: Optional("gift wrap"))
  Sale(orderId: 1002, sku: "WIDGET-2", quantity: 1, unitPrice: 24.5, note: nil)

issues:
  [[2].quantity] must be between 1 and 999
  [[3].quantity] must be an integer, found "many"
```

Two rows decoded, two rejected, and each failure carries **the row it came from**. That is
what makes a batch usable: `[3].quantity` tells someone which line of a fifty-thousand-line
export to look at.

## The three attributes, and why each

**`formats: []`** — no JSON decode body is generated. A type that only ever comes from a
CSV should not pay the build time for an entry point it never calls.

**`sources: true`** — generates the batch decoder. This is the opt-in that costs the most at
build time, which is why it is opt-in.

**`coerceScalars: true`** — every CSV cell is text, so a numeric field has to agree that
text may become a number. `"8080.5"` still does not become an integer; the rules are the
same ones the tree path uses, from one definition.

And on the decoder, **`inferColumnKinds: true`**, because your cells are not the kind the
fields declare. Without it each column's storage comes from the schema and a text cell
offered to a numeric column is a wiring error rather than a CSV. It costs about 8 ns per
row, which is why it is a flag rather than the default.

## Why it is column-shaped underneath

You hand over rows; `RowDecoder` builds one array per field and decodes the batch in one
pass per column. That is not an implementation detail you can ignore, because it is where
the speed is: row-by-row over a set of columns is a jump between allocations per cell.

You never see it. `beginRow`, append, `flush` is the whole surface.

## Streaming a large file

`isFull` and `flush()` keep memory flat no matter how long the file is:

```swift
var dec = RowDecoder<Sale>(columns: header, batchSize: 4096, inferColumnKinds: true)
for line in reader.lines {
    dec.beginRow()
    for (i, cell) in reader.split(line).enumerated() { dec.append(text: cell, column: i) }
    if dec.isFull { ingest(dec.flush()) }
}
ingest(dec.finish())
```

Row indices stay **global** across flushes, so an error on the 250,003rd line says
`[250003]`, not `[3]` of batch 61.

## Columns that are not there

`missingColumns` is known before the first row:

```swift
guard dec.missingColumns.isEmpty else {
    throw ImportError.badHeader(dec.missingColumns)
}
```

Better than decoding fifty thousand rows that each report the same absent column.

## Writing one back out

The column list is the schema's, so the header cannot drift from the rows:

```swift
let header = Sale._assayManifest.keys.joined(separator: ",")
```

and `encodeRow(into:)` hands each field to a sink you write, in manifest order, with no
tree in between. [Rows and columns](/formats/rows-and-columns/#the-write-side) has it.

## Next

- [Rows and columns](/formats/rows-and-columns/) — the full surface, including column stores.
- [A SQL result set](/recipes/sql-rows/) — the same machinery, typed cells.
- [Dates](/guides/dates/) — text timestamps in a CSV column.
