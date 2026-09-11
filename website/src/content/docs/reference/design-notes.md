---
title: Design notes
description: Why any of this is shaped the way it is. Nothing here is needed to use the library.
---

Short answers to "why is it like that", for people who care. If you just want to decode
something, you are in the wrong place — [start here](/start/first-schema/).

## Why a macro instead of Codable

Because ~83% of a Swift decode is the `KeyedDecodingContainer` boundary, and a macro is the
only thing that can delete it. ZippyJSON put simdjson under `Decodable` and got 1.38× over
Foundation; Apple's own prototype changed nothing about parsing, deleted only the container
protocol, and reported about 6×.

The generated code is concrete and monomorphic, emitted into your module. There is no
generic parameter to specialise, which is the whole reason a macro decoder can be fast in
Swift.

## Why errors are codes and not strings

Ecto's `{template, params}` model. An issue is a code plus parameters; the sentence is
derived on demand. That is the difference between a library you can translate, branch on and
map onto form fields, and one that only ever speaks English.

It also keeps messages *predicate-shaped* — `must be at least 3 characters` — so a renderer
can prefix the path and you can prefix a form label instead.

## Why `Rule` is not generic

Leading-dot syntax has no type context to infer a generic parameter from, so `.min(1)` could
not be written that way if `Rule` were `Rule<T>`. And `.min(1)` is the entire ergonomic
point. The type check happens at expansion instead, which catches the same mistakes earlier.

For the same reason there is no `.custom { … }`: a closure inside an attribute has no type
context either. `@Check` is a real function with a real signature.

## Why `@Check` needs `\Type.field`

An attached macro's argument has no contextual root type to infer from, so `\.field` has
never compiled. This is a Swift limitation rather than a choice, and it was documented
wrongly in three places until somebody tried it.

## Why key conversion happens at compile time

`.convertFromSnakeCase` is lossy at runtime: `avatarURL` → `avatar_url` → `avatarUrl`, and
now the property is unreachable. Converting *from* the declared identifier round-trips
exactly, because the declaration is the source of truth rather than a guess about one.

## Why formats are opt-in

A YAML/XML decode body costs about 34 ms per type at build time — roughly 41% of the
expansion. "JSON users never pay for XML" is a linking claim everywhere else; making it
opt-in is what makes it a *compile-time* claim too.

The same reasoning covers `encodes:` and `describes:`.

## Why the parsers are hand-written

Vendoring C means vendoring the Windows `__declspec(dllimport)` trap, the static-musl
breakage and the WASM problems that come with it. It also means a class allocation per node
in most Swift wrappers — a survey found one YAML library allocating a `Tag` class per node,
a `String` per scalar eagerly, and doing O(N·K) mapping lookup with an allocation per probe.

Hand-written is why the same code runs on macOS, Linux and Windows, why the carets work
everywhere, and why XXE is refused *by construction* rather than by configuration.

## Why each format keeps its own value model

A YAML scalar's resolution and an XML element's namespace are not the same kind of thing.
`YAML.Node` keeps text, style, tag and anchor so the Norway problem stays *your* decision;
`XML.Node` keeps mixed content and namespaces; `TOML.Node` keeps which of four date-time
kinds a value was. A single unified tree would lose all of that.

`RawValue` is the narrow intersection, and every projection into it documents its losses.
Being explicitly lossy is what makes it honest: declaring `RawValue` says "I want
portability more than fidelity", and that sentence is now true rather than a compromise the
library imposed.

## Why unions are JSON-only

The tagged form scans for the tag, rewinds, and decodes the branch over the whole object —
a byte reader's operation. The `RawValue` path is a tree that has already been built, and
the mechanism does not transfer. Refusing at expansion beats silently omitting the body.

## Why Assay does not decode rows or column stores

Two paths for this were built and both were removed.

A row-at-a-time protocol went first, on its own numbers. Its justifying premise — that the
`RawValue` path costs an allocation per value per record — was never measured and was false;
it is one allocation per record. It then lost to the path it was meant to replace, 311
nanoseconds against 95, could not accept the borrowed rows it existed for, and its cost
landed worst exactly where a driver lives, generic over the schema where `@inlinable` is
forbidden on generated bodies so the witness call stands.

A column-store path replaced it and **won** every one of those arguments: whole arrays
rather than rows means no per-row borrow, no per-row dispatch, no per-row presence
ambiguity. It measured 11 nanoseconds per row.

It was removed anyway, and the reason is not technical. Nothing depended on it, the audience
for Parquet and Arrow decoding in Swift is small, and a decoder that also owns column stores
is two libraries wearing one name. It cost about 1,900 lines and doubled the expansion cost
of any type that used it.

What serves that need is [`validate(_:)`](/guides/rules/#validating-something-you-already-have).
A specialised reader decodes at its own speed in its own module, and Assay runs the rules
afterwards. Neither side pays for the other, and neither has to know the other's memory
model. It was always the better seam; it is now the only one, which makes the answer
unambiguous.

## Why streaming is out of scope

A `@Schema` type is a fixed-size struct; a partially-decoded one is not a thing that exists.
`parse(mmapped:)` covers the case people usually mean by "the file is too big".

## Things that were built and thrown away

Worth knowing because they are attractive enough to be proposed again:

- **`KeyedSource`**, above.
- **A 256-element key table per type.** Emitting the array literal cost 16% of expansion
  time; computing it at runtime from a smaller description cost nothing measurable.
- **A "move the diagnostic path into the failure branch" optimisation**, made, reverted as a
  no-op with a confident commit message, and then found to have been real all along when
  someone measured the shipped body rather than a hand-rolled reproduction. The
  reproduction needed `@inline(never)` to be measurable at all, and `@inline(never)` is
  precisely what stops the optimiser doing the thing being tested.

That last one is in the repository with its full history rather than quietly fixed, because
the methodological mistake is more useful than the patch.

## Where the long versions live

The repository carries the engineering record these pages are drawn from —
`docs/EXPERIENCE.md` (the API design), `docs/PERFORMANCE.md` (the strategy),
`docs/COMPILE-TIME.md`, `docs/UNIONS.md`, `docs/ROWS.md`, `docs/CONFORMANCE.md`,
`Benchmarks/RESULTS.md` (every number with its journal), and `docs/research/` (seven
research passes, each ending in an explicit "do not assert these" section).

They are written for maintainers, not for a first read. This site is the first read.
