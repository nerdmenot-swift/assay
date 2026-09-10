# Rows

**Built 2026-09-10/11.** The generic row-shaped path: a SQL result set, a CSV record, an
Excel row, an NDJSON line — anything that arrives one row at a time — into a `@Schema` type
through the same 10 ns/row batch decode a column store gets, and the field values back out
without a tree. Nothing in it knows what SQL, CSV or Parquet are.

```swift
@Schema(keys: .snakeCase, formats: [], encodes: true, sources: true)
struct User: Equatable {
    var id: Int64
    @Validate(.email) var email: String
    var name: String
    var createdAt: Date
    var nickname: String?
}

var dec = RowDecoder<User>(columns: resultSet.columnNames)   // or plan: BoundPlan(slots: 0..<5)
for row in resultSet {
    dec.beginRow()
    for (i, cell) in row.enumerated() { … dec.append(int64: v, column: i) … }
    if dec.isFull { consume(dec.flush()) }                    // BatchDiagnosis<User>, global row indices
}
consume(dec.finish())
```

---

## 1. Why this shape, and not a row protocol

Assay's fast structured seam is `ColumnarSource`: one array per field, one batch decode,
~10 ns/row. Parquet and Arrow arrive that way. Everything else arrives as rows, and a row
protocol — decode one record at a time through something the source conforms to — was
built, measured and removed (`KEYED-SOURCE.md`). Its per-row calls went *out of* a generic
decode body through a witness table, 1.6–4.7× in a driver, and it could not hold a borrowed
row.

The lesson was about direction, not rows. Here the per-cell calls go **into** a concrete
Assay type — `append` on `RowBatch` is a direct call the driver's module inlines — and the
decode happens once per batch through the existing `_assayBatch`. The driver's loop stays in
the driver.

| piece | what it is |
|---|---|
| `RowBatch` (AssayCore) | a typed row→column accumulator that *is* a `ColumnarSource`; `~Copyable`, `@safe` |
| `RowDecoder<T>` (Assay) | one per result set: bind once, feed rows, flush every N into a `BatchDiagnosis<T>` with global row indices |
| text cells (the emitter) | a `String` column for a numeric/boolean field under `coerceScalars` / `@Coerce`, or for a `Date` always, parsed per row by the tree path's rules |
| `RowSink` + `encodeRow(into:)` | the write side: one typed call per field in manifest order, no tree |

---

## 2. `RowBatch`

Bind by name (`columns:` in the source's own order) or by position (`plan:`), then per row
`beginRow()` and one `append` per cell addressed by the **source's** column index — an
unbound column is a no-op. When the batch is full, `T.batch(from:)` decodes it like any
column store.

**Typed, not converting.** A cell is stored as what the source said it was; a text cell
appended to an `Int` field is rejected and counted (`rejectedCells`), and the decode reports
`missing_column (expected int)` once. Text → number is the schema's decision (§4), not the
buffer's.

**Presence is derived, not tracked.** Field `f` has a cell in the open row exactly when its
column is one longer than the rows completed. Nothing is written per cell but the cell; a
ragged row is *missing* what it did not supply (or nil, or the default) and later rows stay
aligned; two cells for one field in a row are rejected; a cell before `beginRow()` belongs
to the row the next finish completes. Nulls are Arrow-style masks created on the first null.

**Custom scalars** (`ColumnDecodable`: a `Timestamp`, a `Decimal128`) take their column
kind from the first cell appended and their unit from `setMetadata(_:column:)`.

### What it costs, and how that was found

The gate written before the code said "fill + decode within 1.2× of a hand-written
transpose, or refuse". It is not met — **RowBatch lands at ~1.45× (40 against 28 ns/row on
the 8-column, 4-String row)** — and shipping anyway is a decision, recorded with the numbers
that led to it. Every step was profiled, because every reasoned guess was wrong:

| ns/row (fill only) | shape |
|---|---|
| 63 | six per-field arrays, a bounds-checked load from each per cell |
| 40 | one per-field state array and a touched bitmask |
| 60 | class-boxed columns: **dynamic exclusivity** per mutation — `swift_beginAccess`, a TLS lookup, 40% of the profile. CLAUDE.md rule 3, met on the way in |
| 70 | `Unmanaged` refs to the boxes: the exclusivity, plus a retain per read |
| 51 | tail-allocated `[T]` slots in a `ManagedBuffer`, reached by pointer |
| 39 | `append(string: consuming String)` — a borrowed parameter cost a retain/release pair per string cell a hand transpose never pays |
| 26 | presence derived from column lengths — a per-cell read-modify-write of a mask through `self` serialised consecutive cells on store forwarding |
| 13 | the floor: the same appends through pointers with no bookkeeping at all |

The ~1.5 ns/cell that remains is the reload of state from `self` — an `inout` struct in
memory — that any call-per-cell API pays and a closed hand-written loop keeps in registers.
`Benchmarks/Sources/AssayBench/RowBatchBench.swift` is the arm; its header is the record.

---

## 3. `RowDecoder<T>`

What a driver holds: one per result set. `columns:` or `plan:`, `batchSize:` (4096),
`limits:`. `missingColumns` is known before the first row, so a driver fails fast instead of
decoding a million rows that each report it. `isFull` counts the row being built — check it
after the row's cells — and `flush()` finishes that row, decodes everything buffered, resets
the buffer and returns a `BatchDiagnosis<T>` whose issue and warning paths carry **global**
row indices: the offset is added to the few paths reported, never to the rows that are not.
`truncatedIssues` is per flush.

Deliberately not a `decodeAll(rows:)` over some row abstraction — that would be the row
protocol again.

### Validation on the batch path

Everything runs per row, as on every other path: `@Validate` rules, `@Preprocess`,
`@Fallback` (its warning carries the row), field-form and cross-field `@Check`s (which did
not run on any batch until 2026-09-10 — reported *and* appended), and `@Key(_:or:)` aliases
(tried when the primary column is absent, warned once per batch). A row that reports
anything is not in `values`. `@AsyncCheck` on a `sources: true` type is **refused at
expansion**: the batch is synchronous and skipping it silently is how bugs are made.

---

## 4. Text cells

A CSV, an Excel sheet, a Postgres text-format value: the column is strings whatever the
field declares. Under `@Schema(coerceScalars: true)` or `@Coerce` a numeric or boolean field
takes the `String` column when its own kind is absent, parsed per row by
`_assayCoerceInt64` / `Double` / `Bool` — one definition in `RawDecode.swift` that the
`RawValue` path also calls, so `"8080.5"` is not an integer on either and `"yes"` is a
boolean on both. A cell that does not parse is `type_mismatch` with the row and the text;
one that overflows the declared width is `number_overflow`, as a typed column's would be.

A `Date` field takes text **always**, because text is what a date is on every other path:
`RawValue._assayDate` does the work, so `@DateFormat` candidate chains, fallback warnings and
invalid-date reports are the tree path's exactly. It also takes a `Double` column (unix
seconds or millis, by the field's formats) and, as before, an `Int64` column with a unit from
`ColumnMetadata` — the Parquet/Postgres-binary carrier, which stays primary. A bytes carrier
(`UUID`, `[UInt8]`) takes a `String` column as its bytes, once per batch.

The emitter cost: the text branch is four generated lines per coercing field, and the
`sources` arm of the compile-time gate — `coerceScalars: true` on ten fields, the widest
this body gets — reads **164 ms/type against 80 for JSON alone** (`COMPILE-TIME.md` §5.7).
That is why `sources:` is opt-in.

---

## 5. The write side: `RowSink`

Not a CSV writer, not an `INSERT` builder. The one thing such a library cannot write: the
field values *out* of a `@Schema` value in declaration order, because only the macro knows
the fields. Until now that was `_assayEncodeRaw` — a `RawValue` tree, ~59 ns/row, which haul
measured as 50 of its CSV writer's 61 — or restating the field list by hand, which is how a
silent column-swap bug is made.

```swift
public protocol RowSink: ~Copyable {
    mutating func write(int64: Int64, _ field: Int)
    mutating func write(double: Double, _ field: Int)
    mutating func write(bool: Bool, _ field: Int)
    mutating func write(string: String, _ field: Int)
    mutating func write(bytes: UnsafeRawBufferPointer, _ field: Int)   // borrowed for the call
    mutating func writeNull(_ field: Int)
}
```

`@Schema(encodes: true, sources: true)` emits one typed `write` per field in manifest order:
nil is `writeNull`, `[UInt8]` is borrowed bytes, a `@Transform` field goes through the same
inverse the tree encoders use, a `Date` writes what its primary `@DateFormat` renders (so
§4 reads it back), and a consumer's own scalar goes through `ColumnEncodable` — one
requirement, the inverse of `ColumnDecodable`. Column names are `_assayManifest.keys`.
`RowBatch` is a `RowSink` for its own manifest, and *write → batch → decode → equal* is the
law the tests hold it to.

**1.3 ns/row** for the handoff on the 8-column row, against 59 for the tree. A real sink's
work is its own.

---

## 6. Integration: swizzle

Written against swizzle's surface as of 2026-09-10: `SQLExecutor.execute(sql:bindings:) ->
[SQLRow]`, `SQLStreamingExecutor.stream(…)`, `SQLRow { values: [SQLValue] }` (positional, no
names) and `SQLValue { null, bool, int(Int64), double, text(String), blob([UInt8]) }`.
Postgres renders `numeric`, `uuid`, `json` and every date/time type as `.text`, which is why
§4 is load-bearing. Binding by position is the natural route: the SELECT list can be
generated from `T._assayManifest.keys`, so the columns *are* the manifest and no names are
needed.

The developer's side, all of it:

```swift
@Schema(keys: .snakeCase, formats: [], sources: true, encodes: true)
struct User: Equatable {
    var id: Int64
    @Validate(.email) var email: String
    var name: String
    @DateFormat(.pattern("yyyy-MM-dd HH:mm:ssZ")) var createdAt: Date   // Postgres text form
    var nickname: String?
}

let users = try await db.from(u).where(u.score > 100).fetch(as: User.self)         // [User]
let admins = try await db.raw("SELECT id, email, name, created_at, nickname FROM users WHERE role = $1", "admin")
                         .fetch(as: User.self)
for try await batch in try await db.from(u).stream(as: User.self, batchSize: 4096) {
    if !batch.isValid { log(batch.issues) }        // "[250003].email must be an email address"
    ingest(batch.values)
}
try await db.insert(into: u, User.self, rows: newUsers)   // columns and parameters from the schema
```

Swizzle's side, once, generic over every schema it will ever see:

```swift
extension SQLValue {
    @inlinable func append<T>(to dec: inout RowDecoder<T>, column i: Int) {
        switch self {
        case .int(let v):    dec.append(int64: v, column: i)
        case .double(let v): dec.append(double: v, column: i)
        case .text(let s):   dec.append(string: s, column: i)   // dates, uuid, numeric: §4 parses them
        case .blob(let b):   dec.append(bytes: b, column: i)
        case .bool(let v):   dec.append(bool: v, column: i)
        case .null:          dec.appendNull(column: i)
        }
    }
}

extension SQLExecutor {
    public func fetch<T: SourceDecodable>(_ sql: String, bindings: [SQLValue] = [],
                                          as _: T.Type, limits: Limits = .default) async throws -> [T] {
        var dec = RowDecoder<T>(plan: BoundPlan(slots: Array(0..<T._assayManifest.fields.count)), limits: limits)
        for row in try await execute(sql: sql, bindings: bindings) {
            dec.beginRow()
            for (i, cell) in row.values.enumerated() { cell.append(to: &dec, column: i) }
        }
        let d = dec.finish()
        guard d.isValid else { throw AssayError(issues: d.issues, source: .empty, sourceName: "<rows>") }
        return d.values
    }
}

extension SQLStreamingExecutor {
    public func stream<T: SourceDecodable>(_ sql: String, bindings: [SQLValue] = [],
                                           as _: T.Type, batchSize: Int = 4096) async throws
        -> AsyncThrowingStream<BatchDiagnosis<T>, any Error> {
        let rows = try await stream(sql: sql, bindings: bindings)
        return AsyncThrowingStream { continuation in
            Task {
                var dec = RowDecoder<T>(plan: BoundPlan(slots: Array(0..<T._assayManifest.fields.count)),
                                        batchSize: batchSize)
                do {
                    for try await row in rows {
                        dec.beginRow()
                        for (i, cell) in row.values.enumerated() { cell.append(to: &dec, column: i) }
                        if dec.isFull { continuation.yield(dec.flush()) }
                    }
                    continuation.yield(dec.finish())
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}

// The write side: `T._assayManifest.keys` is the column list; a RowSink that appends
// SQLValues is the parameter list — `write(int64: v, f)` → `params.append(.int(v))`.
```

The name-keyed form (`raw(…).fetch(as:)`) needs swizzle to carry the column names it already
has at driver level (`PostgresRowSchema`) up to the executor result; the positional form
needs nothing. Two honest caveats: Postgres text timestamps (`2026-09-10 12:34:56.123+00`)
are not ISO-8601, so a `@DateFormat(.pattern(…))` is needed until the driver uses the binary
wire format (int64 micros → `append(int64:)` + `setMetadata(unit: -6)`, the primary carrier)
or adds a timestamp case; and **the fastest route is not `RowBatch`** — a driver that
controls its wire parsing can decode wire bytes straight into typed column arrays and
conform *that* to `ColumnarSource` for the 11 ns/row floor. `RowBatch` is what makes the
generic route cost ~40 instead of ~70; it is not what a driver that wants the last 30 uses.

### CSV, for contrast

`RowDecoder<T>(columns: headerRow)`, every cell `append(text:)` from the field's byte slice,
schema `coerceScalars: true`. That is the whole reader-side adapter; the parser stays the
library's. The writer: `T._assayManifest.keys` for the header, a `RowSink` that appends
delimited bytes.

---

## 7. The numbers

```
$ swift run -c release AssayBench rowbatch        2026-09-11, arm64, -O, min of 5

Row-shaped sources — rows in, structs out (200k rows, 8 columns, 4 of them String)
     RawValue per row, tree path (the old route)      70.5
   hand transpose + batch (what a driver writes)      28.0
                           RowBatch fill + batch      40.4
   RowDecoder, flush every 4096 (the driver API)      42.3
                    fill only: RowBatch, 8 cells      26.2
              fill only: hand transpose, 8 cells      16.9
          fill only: bare pointer-to-[T] appends      13.4
               direct ColumnarSource (the floor)      11.0

The write side: field values out of a @Schema value, 200k rows
       _assayEncodeRaw (a RawValue tree per row)      59.3
                  encodeRow into a counting sink       1.3
```

Run to run these drift by ±5; the shape does not.
