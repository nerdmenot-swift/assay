---
title: Dates
description: ISO-8601 by default, four other formats, candidate chains — and no ICU anywhere.
---

`Date` is a field type. No strategy to configure on a decoder, no formatter to hold.

```swift
import Foundation          // a `Date` field needs it; the core is Foundation-free

@Schema(keys: .snakeCase)
struct Event {
    var name: String
    var createdAt: Date              // ISO-8601, the default
}
```

## The formats

```swift
@DateFormat(.iso8601) var createdAt: Date        // the default; you can omit it
@DateFormat(.unixSeconds) var recordedAt: Date   // a number, or an all-digit string
@DateFormat(.unixMillis) var loggedAt: Date      // the same, in milliseconds
@DateFormat(.rfc9110) var lastModified: Date     // HTTP dates
@DateFormat(.pattern("yyyy-MM-dd")) var day: Date
```

**`.iso8601`** takes offsets as `±hh:mm`, `±hhmm` or `±hh`, optional fractional seconds, and
`T`, `t` or a space as the separator. Fractional seconds survive.

**`.unixSeconds` / `.unixMillis`** accept a JSON number or an all-digit string, so a source
that quotes its timestamps still works.

**`.rfc9110`** accepts all three HTTP date forms the RFC requires a parser to handle:
IMF-fixdate, the obsolete RFC 850 form, and asctime.

**`.pattern`** is a fixed field subset — `yyyy MM dd HH mm ss SSS Z` plus literal
characters, with `'` to quote a literal letter (`"yyyy-MM-dd'T'HH:mm:ss"`). It is not
UTS-35: month names, eras and week-based years are deliberately absent, because those need
a locale and a locale-dependent decoder is a decoder that behaves differently on your
colleague's machine. A pattern that cannot name an instant — no `yyyy`, `MM` and `dd` — is
rejected when you build.

## Candidate chains

When a source is inconsistent, list what you will accept, best first:

```swift
@DateFormat(.iso8601, .unixSeconds) var at: Date
```

The first format that parses wins. If it was **not** the first one, you get a warning:

```
warning: at matched unix timestamp (seconds), not the preferred ISO-8601 date
```

Which is how a data-quality problem shows up in your logs instead of quietly not existing.
Same idea as `@Key(_:or:)` warning about aliases.

## Rules on dates

```swift
@Validate(.after("2020-01-01")) var createdAt: Date
@Validate(.before("2030-01-01T00:00:00Z")) var expiresAt: Date
@Validate(.between("2020-01-01", "2030-01-01")) var effective: Date
```

Bounds are ISO-8601 strings, parsed once at expansion — a malformed bound is a build error,
not a runtime one.

**`.past` and `.future` do not exist.** They need a clock, and a rule whose result depends
on when it runs makes a test that passes today fail next year. If you want it, a `@Check`
with your own clock is three lines and puts the dependency where you can inject it.

## No ICU, no Foundation in the core

The parsers are pure arithmetic and return epoch seconds. The macro emits
`Date(timeIntervalSince1970:)` into *your* module, which resolves to whatever `Date` means
there.

Three things follow. The core has no Foundation dependency. The behaviour is bit-identical
on macOS, Linux and Windows — no ICU version to differ. And it is fast: about 6× Foundation's
`.iso8601` strategy, verified exact against Foundation on 2,279 instants.

## Your own date type

If you have a `Timestamp` of your own, `Date` is not special — the macro keys on the type
*name* and emits an initializer call. A type named `Date` in scope gets the date treatment;
anything else goes through [`@Transform`](/guides/advanced/#transform).

## Next

- [Encoding](/guides/encoding/) — dates on the way out.
