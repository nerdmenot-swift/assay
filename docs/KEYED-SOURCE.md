# The third decode path: `KeyedSource`

Assay decodes from two shapes today. This adds a third.

| path | input | who uses it |
|---|---|---|
| **bytes-direct** | a contiguous UTF-8 buffer | JSON. The fast path; the `Codable` boundary is deleted here |
| **`RawValue` tree** | a materialised, format-neutral tree | YAML, XML. A DOM hop, accepted because those formats need their own node model first |
| **`KeyedSource`** | *already parsed*, addressable by key | database rows, CSV/Parquet, plists, `[String: Any]`, form data, env vars, `Assayer<T>` |

The third exists because a large class of data arrives **already parsed into fields**, and
reaching it today means building a `RawValue` tree first — an allocation per value, per
record, and the source's own layout thrown away. A CSV reader doing millions of rows cannot
pay that.

---

## Three collisions with settled decisions, and how each is resolved

The proposal that started this asked for things that conflict with rules this repository
already made deliberately. Writing the conflicts down is the point; silently picking one
side is how a codebase stops meaning what its documents say.

### 1. `~Escapable` would gate the entire library on an experimental feature

**Asked for:** `protocol KeyedSource: ~Copyable, ~Escapable`, so a source can be a borrowed
zero-copy view that provably cannot escape.

**The conflict:** `AssayReader` already faced this and refused it. Its header records why —
`@_lifetime` is `SUPPRESSIBLE_EXPERIMENTAL_FEATURE(Lifetimes)` with no accepted proposal, and
a `~Escapable` type in the public surface "would put an experimental-feature gate on the
whole library." The reader uses a raw pointer behind a safe façade instead, with the seam
shaped so it can move to `RawSpan` later without a source break.

**Resolution: `~Copyable` only, with `borrowing` accessors.** That already gives
non-copyability, no retain traffic, and no accidental storage. It does *not* give the
compile-time proof that a borrowed view outlives its use — the source author carries that,
exactly as `AssayReader` does today. The protocol is shaped so `~Escapable` can be added when
`Lifetimes` ships un-gated, and that is the same bet the reader already placed rather than a
new one.

### 2. A generic entry point reintroduces the thing the macro exists to delete

**Asked for:** `static func _assay<S: KeyedSource>(from source: borrowing S, …) -> Self?`

**The conflict:** hard constraint 6 — *"Generated per-field code is concrete and monomorphic.
No generic parameter to specialize is the whole reason a macro decoder can be fast in
Swift."* And the escape hatch that would normally fix it is closed: `@inlinable` on a
generated body is forbidden (SE-0193 makes every `public @Schema` type fail against its own
internal memberwise initializer — a trap already found by the compile-time harness). So a
generic entry point specialises fine **within** a module and falls back to witness-table
dispatch **across** one, which is precisely the arrangement a CSV or Postgres driver in
another package would hit.

**Resolution: ship the generic entry point, and publish the FIELD MANIFEST that makes the
non-generic path possible.** The generic form is the ergonomic API and is honest about its
cost. The manifest — an ordered, compile-time description of every field — is what lets a
source resolve keys **once per stream** instead of once per record, and it is the piece the
positional/bound path is built from. Getting the manifest right matters more than getting the
generic call fast, because the manifest is what removes the per-record work entirely.

### 3. A fourth generated body against a compile-time budget with 15 ms of headroom

**The conflict:** `@Schema` costs ~85 ms per type against a 100 ms CI gate, and the cost model
is *generated body size*, not expansion count. JSON, `RawValue`, and the three encoders are
already opt-in for exactly this reason.

**Resolution: `@Schema(sources: true)`, opt-in like every other body, and the gate is the
check.** A type that never decodes from a row pays nothing.

---

## Scope of the first increment

**Flat records only.** A database row, an env block and a form post have no nested arrays;
`RawValue` remains the right answer for anything tree-shaped. An array or dictionary field on
a `sources: true` type is a **compile error** naming the field, rather than a runtime surprise
or a silent tree materialisation. Nested `@Schema` values are likewise out of the first
increment: a row addresses one flat namespace, and prefix-addressing (`user.name`) is a
design question of its own.

**Diagnostics are identical or absent, never wrong.** A source that can report a span gets
carets exactly as JSON does. A source that cannot returns `nil` and gets position-free
diagnostics — which the renderer has always handled, because a missing-field issue has never
had a location.

## Deliberately deferred

- **The bound/positional path.** The manifest ships now; the generated positional initializer
  that consumes a resolved plan does not. It is the second increment, and the first one has
  to prove the protocol shape before it is worth building against.
- **Columnar/batch fill.** Inverting the loop so Parquet or Arrow fills a batch column-by-
  column needs the positional initializer first.
- **Typed throws at the boundary.** Deferred rather than guessed: `_assay` returns an
  Optional and reports into a sink, which is how every other path works, and changing that
  for one path would be the inconsistency.
