---
title: Dates
description: ISO-8601 by default, unix time, HTTP dates, patterns, candidate chains, and rules about when.
---

## The formats

```swift
@Schema(keys: .snakeCase)
struct Timestamps: Equatable {
    var iso: Date                                         // ISO-8601 by default
    @DateFormat(.unixSeconds) var epoch: Date
    @DateFormat(.rfc9110) var httpDate: Date
    @DateFormat(.pattern("yyyy-MM-dd")) var day: Date
    @DateFormat(.iso8601, .unixSeconds) var either: Date  // a candidate chain
}
```

```json
{"iso": "2026-09-11T12:00:00Z", "epoch": 1700000000,
 "http_date": "Wed, 21 Oct 2026 07:28:00 GMT", "day": "2026-01-31", "either": 1700000000}
```

```text
Timestamps(iso: 2026-09-11 12:00:00 +0000, epoch: 2023-11-14 22:13:20 +0000, httpDate: 2026-10-21 07:28:00 +0000, day: 2026-01-31 00:00:00 +0000, either: 2023-11-14 22:13:20 +0000)
```

Several formats in one attribute is a **candidate chain**: tried in order, first that
parses wins. Useful for an API mid-migration, and for a field that has always been
inconsistent.

`.unixMillis` is there too.

## When they do not parse

```json
{"iso": "yesterday", "epoch": 1700000000, "http_date": "Wed, 21 Oct 2026 07:28:00 GMT",
 "day": "31/01/2026", "either": "nope"}
```

```text
d.json:1:10: error: iso must be an ISO-8601 date — expected a 4-digit year
  1 │ {"iso": "yesterday", "epoch": 1700000000, "http_date": "Wed, 21 Oct 2026 07:28:00 GMT",
    │          ^
  2 │  "day": "31/01/2026", "either": "nope"}

d.json:2:10: error: day must be a date matching "yyyy-MM-dd" — expected a 4-digit year
  1 │ {"iso": "yesterday", "epoch": 1700000000, "http_date": "Wed, 21 Oct 2026 07:28:00 GMT",
  2 │  "day": "31/01/2026", "either": "nope"}
    │          ^

d.json:2:34: error: either must be an ISO-8601 date, or unix timestamp (seconds) — expected a 4-digit year
  1 │ {"iso": "yesterday", "epoch": 1700000000, "http_date": "Wed, 21 Oct 2026 07:28:00 GMT",
  2 │  "day": "31/01/2026", "either": "nope"}
    │                                  ^

3 errors
```

Each failure names the field and shows what was there. A chain reports once for the field
rather than once per candidate, because four messages about one value is noise.

## Rules about when

```swift
@Validate(.after("2020-01-01")) var createdAt: Date
@Validate(.between("2020-01-01", "2030-01-01")) var effective: Date
```

```json
{"created_at": "2019-06-01T00:00:00Z", "effective": "2031-01-01T00:00:00Z"}
```

```text
d.json:1:16: error: created_at must be after 2020-01-01
  1 │ {"created_at": "2019-06-01T00:00:00Z", "effective": "2031-01-01T00:00:00Z"}
    │                ^^^^^^^^^^^^^^^^^^^^^^

d.json:1:53: error: effective must be between 2020-01-01 and 2030-01-01
  1 │ {"created_at": "2019-06-01T00:00:00Z", "effective": "2031-01-01T00:00:00Z"}
    │                                                     ^^^^^^^^^^^^^^^^^^^^^^

2 errors
```

Bounds are ISO-8601 strings parsed **once, at expansion**, so a malformed bound is a build
error rather than a surprise per document.

There is no `.past` or `.future`, deliberately: they need a clock, and a rule that depends
on when you run it is a rule you cannot test.

## No ICU, and no Foundation in the core

The parsers are arithmetic and return epoch seconds; the macro emits
`Date(timeIntervalSince1970:)` into your module. That keeps `AssayCore` free of Foundation,
which is why this works the same on Linux, Windows and WebAssembly — and why it measures
about 6× `JSONDecoder` with `.iso8601`.

`.pattern` is the one to be careful with on a size budget: an arbitrary UTS-35 pattern
needs a real formatter, and on some platforms that means ICU.

## Dates from rows and columns

A `Date` field takes a text column always, since text is what a date is on every other
path, and an integer column with a unit from the source's metadata. Nothing extra to
declare — see [rows](/recipes/rows/).

## Next

- [Enums](/recipes/enums/) — the other closed vocabulary.
- [Dates, explained](/guides/dates/) — candidate chains and the ICU note in full.
