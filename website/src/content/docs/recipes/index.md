---
title: Recipes
description: Every feature as a small runnable example. A declaration, a document, the output. Scan it, copy it, move on.
---

One page per topic, one short example per thing you might want. Each is a declaration, a
document and what the library printed for it — nothing else, because a reader looking up
"how do I do X" should not have to read a paragraph first.

The [guides](/guides/presence/) are where the reasoning lives. These are where the shape
lives.

## The map

| | |
|---|---|
| [Shapes](/recipes/shapes/) | Nested types, arrays, dictionaries, integer widths, bytes, inlining |
| [Presence](/recipes/presence/) | Required, optional, default, salvaged, ignored, null versus absent |
| [Names](/recipes/names/) | Key styles, renaming, aliases, paths, extras, unknown keys |
| [Rules](/recipes/rules/) | Every validator, custom messages, normalising, coercion |
| [Checks and transforms](/recipes/checks/) | Your own logic, cross-field, changing the type |
| [Dates](/recipes/dates/) | Formats, candidate chains, date rules |
| [Enums](/recipes/enums/) | Closed, open, one-or-many, wrapping a scalar |
| [Unions](/recipes/unions/) | Tagged and untagged |
| [Encoding](/recipes/encoding/) | Writing all four formats, round-trip, JSON Schema |
| [Unknown shapes](/recipes/unknown-shapes/) | Value models, and schemas with no declaration |

Then, when you want a whole job rather than one feature:

| | |
|---|---|
| [A JSON API endpoint](/recipes/api-endpoint/) | Negotiation, rules, problem details, status codes |
| [An application config file](/recipes/config-file/) | Defaults, typos, carets at boot |
| [An API that keeps changing](/recipes/moving-api/) | Aliases, fallbacks, open enums, extras |
| [A form with errors on the fields](/recipes/form-errors/) | Paths to field names, your own wording |
| [A file you do not trust](/recipes/untrusted-input/) | Limits, and what each one stops |

## Everything here ran

Every example on these pages is a real program in this site's build: it compiles against
the package, runs, and the page shows what it printed. Nothing is illustrative.

That is not only a promise about accuracy. It has found four bugs so far — a handler
answering 415 with a body claiming 422, a documented path that did not work, a caret that
went missing on four formats, and an example in the guides that does not compile. Examples
that have to run are a test suite with a readership.
