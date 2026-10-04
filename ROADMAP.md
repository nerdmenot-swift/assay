# Roadmap

What is not built, what is only half built, and what was decided against. Everything that
shipped is in [`CHANGELOG.md`](CHANGELOG.md) and described in `docs/`; this file is only the
remainder. The record of how each item got here is in this file's git history.

---

## Not built

### Index segments in `@Key(path:)`

`@Key(path: "meta.tags[0]")` is refused at expansion with a diagnostic naming the
alternative; the dot form ships. It is not a missing segment type, it is a different
operation. Walking a key asks a mapping for a name; indexing asks an array for its *n*-th
element, which means counting during the array's own decode loop. And the caret rules need a
fourth answer — "the array was shorter than that" — which is neither absence nor a type
mismatch. Until then: declare the array and take the element in Swift, or use a nested
`@Schema` type.

### `message(locale:)`

Every issue code is a named constant with documented parameters
(`Sources/AssayCore/IssueCode+Names.swift`), and the `.json` renderer emits both, so a
consumer localises today by branching on `code` and formatting `params`. What is not built is
the library-side catalogue. It belongs in `AssayFoundation`, and nobody has asked for a
translation yet. The settled parts of the design: an identifier `String`, not a `Locale`, and
English derived from `code` + `params` as the fallback. A stub that took the parameter and
returned English was considered and refused — it is the "accepted and ignored" shape
`SchemaRefusals.swift` exists to remove.

### `StandardSchema`

Blocked on a repository, not a design. "Assay conforms to it" and "Assay does not depend on
it" cannot both hold inside one package: if `Assay` declares the dependency, every Assay user
resolves and links it. The resolution is a third package — `StandardSchema` (the protocol,
zero dependencies), `Assay` (unchanged), and an adapter depending on both that holds the
one-line conformance. That is two more repositories. The half that was load-bearing, a
machine-readable description of a schema, is `jsonSchema(for:)` and ships.

### Record streams and large top-level arrays

NDJSON / JSON Lines, and iterating the elements of a `[{…}, {…}, …]` document one record at
a time. Both fit the design, because both keep exactly one record resident: the async
boundary goes at the record boundary, never inside a decode. Multi-document YAML already
works this way (`parseAll(yaml:)`). Neither JSON form is built.

For a single document larger than memory, the answer already exists and is better than
streaming would be: `parse(mmapped:)`.

### `parse(bytes, as:)` and `parse(contentsOf:)`

`docs/EXPERIENCE.md` §12 names a format-as-a-value door and a file-URL door that sniffs the
extension. Neither exists. `parse(body:contentType:accepting:)` covers the first where a
media type is in hand, and `parse(mmapped:)` reads a file; nothing chooses a parser from a
file name.

### Smaller things

- **`.past` / `.future` date rules.** They need "now", the core has no clock, and a clock
  seam (injected? ambient? testable how?) is a design decision of its own.
- **Full UTS-35 date patterns** — locale month names, eras. Excluded from the core for good;
  unbuilt in the Foundation layer, where it would be opt-in.
- **Writing property lists.** No subtlety; not asked for.
- **YAML tags in flow style** (`[!!str 1]`). Consuming them changes how documents that
  currently read `!!str x` as a plain scalar behave, which is its own change.
- **`Assayer.schema(_:)`** — a `@Schema` type as a leaf of a runtime schema. The plan
  interprets to `RawValue` and `build` converts, so the leaf either decodes twice or `build`
  takes the sink and the path. The second is right and is a signature change.
- **A type-erased runtime context for `Assayer<T>`.** The macro half
  (`@Schema(context:)`) ships; this would be designing for an imagined user.

---

## Half built

### Carets on the `RawValue` path

A schema issue always carries a caret on the JSON path. On YAML, XML and TOML a caret appears
only where the macro captured a span: a field with rules, checks, or a built-in scalar type.
On property lists no schema issue carries a caret at all — neither flavour records a span.
These report with a caret from JSON and without one elsewhere:

| field | example |
|---|---|
| `Date`, with or without rules | `iso must be an ISO-8601 date` |
| an array or dictionary, no rules | `tags must be an array` |
| an enum, no rules | `colour "chartreuse" is not a recognised value` |
| a `@Wraps` scalar | `contact must be a valid email address` |
| any nested `@Schema` type | whatever it reports |

`Date` is the cheap one: `_assayDate` takes no span, so threading one through touches
`DateDecode.swift` and the emitted call (and so the goldens). The enum, wrapper and nested
rows report from inside
`_assay(from: RawValue, into:, at:)`, a protocol requirement, so giving it a span changes a
signature every conforming type uses; measure it first.

Three related limits:

- **Elements of a sequence or dictionary value have no span.** `RawValue.Member.span` is per
  mapping member. A rule on an array element reports with a path and no caret.
- **A caret lands under the value, never the key.** For an unknown key the JSON path points
  at the key; the tree path cannot without a second span per member.
- **XML's `xml_bad_character_reference` and `xml_undeclared_entity` carry no location at
  all.** The entity resolver works on extracted text with no offsets.

---

## Decided against

These are settled. They are recorded so they stay decided.

### Incremental parsing of a single document

Feeding bytes as they arrive and getting a partial value back. It breaks four commitments at
once: whole-buffer UTF-8 validation up front, zero-copy string slices into the input, byte
offset source spans (line and column are derived later, from the buffer), and synchronous
decode. Record streams keep all four by scoping residency to the record; this cannot.

### SIMD and C

Retired unbuilt, on a measurement: UTF-8 validation, which is what a SIMD kernel replaces, is
about 5% of decode on the API-shaped payload, and the gap to hand-tuned C (yyjson) is about
1.5×. A 5% slice does not close it. `Benchmarks/RESULTS.md` publishes the yyjson losses.

### Decoding from rows and column stores

Built twice, removed twice — do not rebuild either inside Assay. A row protocol lost to the
path it was meant to beat. A columnar path won every technical argument (11 ns/row) and was
removed for a product reason: nothing depended on it, the audience is small, and a decoder
that also owns column stores is two libraries wearing one name. It cost about 1,900 lines and
doubled expansion for types that used it.

What serves the use case is [`T.validate(_:)`](docs/VALIDATE.md): a specialised reader
decodes at its own speed in its own module, and Assay runs the rules afterwards. If a
columnar decoder comes back, it is a separate package that depends on Assay.

### `@PickFirst`

Cut. The macro would need the branches of a type it sees only as a token. The sound spelling
is an untagged union — `@Schema(discriminator: .untagged)` — which is pick-first by
definition, and ships.

---

## Contracts worth knowing

- **A skipped value's contents are not validated.** `skipValue` checks extent — brackets,
  string state, depth — not what is inside. `{"known": 1, "unknown": NaN}` decodes through a
  schema that does not declare `unknown`; `JSON.Value.parse` refuses it. Deliberate: skipping
  is what makes the prefix path fast. `T.parse(json:)` validates the structure and the fields
  it declares, not the whole document.
- **XML internal entities are expanded recursively, under a budget.** `<!ENTITY a "&b;">`
  resolves `b`. A self-referential entity is `xml_recursive_entity`, and the budget (32× the
  input, 64 KB floor) is what stops a billion-laughs document. Parameter entities are skipped;
  external entities and external DTDs are never fetched.
- **Text is checked against a decimal-float grammar before `Double(String)` sees it**
  (`Sources/AssayCore/DecimalText.swift`), on every path that takes a number from text: YAML
  scalar resolution, `@Coerce`, a plist `<real>`. So `0x1p3` and `infinity` are strings in
  YAML, and a malformed literal cannot reach the standard library's parser — which, on the
  nightly-main toolchain of 2026-10-04, traps on `12e3-4` instead of returning nil.
- **The XML parser is recursive.** At the default `maxDepth` of 64 it has headroom on a
  512 KB worker-thread stack in a debug build; a raised `maxDepth` needs a larger stack.

---

## Not yet measured

| | |
|---|---|
| **Compile time: previews, cross-compilation, absolute Linux timings** | Three of [`docs/COMPILE-TIME.md`](docs/COMPILE-TIME.md) §5's six axes. Incremental builds, release configuration and type-checker pathologies are measured. |
| **simdjson, directly** | Needs a C++ interop shim. yyjson (hand-tuned C) and ZippyJSON (simdjson under `Codable`) are both measured. |
| **Total allocation counts on Linux** | `mallinfo2` gives bytes, not counts; the arm prints "unavailable". Exact counts exist there under Valgrind (`Benchmarks/count.py`). |
| **Wasm `simd128`** | Not run; needs the SDK, and gates nothing with SIMD retired. |
