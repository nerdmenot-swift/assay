# Changelog

Notable changes, most recent first.

**Versioning.** Semantic versioning, with the pre-1.0 reading: a `0.x` minor version may
change public API, a patch version never does. Every public-API break is caught by
`swift package diagnose-api-breaking-changes` in CI and must be listed here under
**Breaking** with its reason; a deliberate deferral lives in [`ROADMAP.md`](ROADMAP.md)
with its reason. `1.0.0` will be tagged when the API in `docs/EXPERIENCE.md` has been
stable for two minor versions with no entry under **Breaking**.

## Unreleased

### Breaking

- **`AssayReader.reportMalformed(_:_:)` gained an `expected:` parameter** (defaulted, so
  every existing *source* call still compiles — but the mangled symbol changes, so this is
  an ABI break and `diagnose-api-breaking-changes` reports it). It is public because
  generated code calls it, and the parameter is what lets a syntax error say what it was
  expecting instead of the bare `is not a well-formed document`. A caller with no single
  expected token passes nothing and gets the old sentence.

### Changed

- **Malformed JSON says what was expected and where the input ended.** `is not well-formed:
  expected ':' after the key` rather than `is not a well-formed document`; truncated input
  now carries a caret (it pointed one byte past the end, which renders as nothing).
- **One syntax error is one issue.** `trailing_content` no longer fires as a redundant
  second error beside a syntax failure — it is reported only when a complete value parsed.

### Added

- **Four attribute combinations are now refused** instead of being silently ignored:
  `@Key` on an `@Extras` bag, `@Key(path:)` beside `@Inline`, `@Coerce` on a non-scalar,
  and `@XML(.attribute)`/`@XML(.text)` on an array or dictionary in a decode-only schema
  (that last diagnostic existed but ran only under `encodes: true`).

## 0.1.0 — 2026-09-10

The first public release. Everything below is "added" by definition; the highlights
that distinguish it:

- **`@Schema` macro decoding** for JSON (streaming), YAML, XML and TOML (via a
  format-neutral `RawValue` projection) — no `Codable`, no `CodingKeys`, measured at
  5–9× Foundation on the published corpus (`Benchmarks/RESULTS.md`; one arm64 Mac,
  stated as such).
- **Errors that name the byte**: every decode and validation failure carries a code,
  structured params, a path, and a source span; four renderers including terminal
  carets and RFC 9457 problem details. All the errors are collected, not just the
  first — and the error path is *faster* than Foundation's throw-on-first.
- **Validation** (`@Validate`, `@Check`/`@AsyncCheck`, `@Preprocess`, `@Transform`,
  `@Fallback`) type-checked at macro expansion with purpose-written diagnostics.
- **`Date` + `@DateFormat`**: hand-written ISO-8601 / unix / RFC 9110 / fixed-pattern
  parsers (pure arithmetic, no ICU, Foundation-free core), ordered candidate chains
  with warnings on fallback matches, 6.06× Foundation's `.iso8601` strategy, verified
  exact against Foundation on 2,279 instants.
- **`[String: T]` dictionary fields**, fully recursive, with the "worst case"
  measured at 6.95× rather than assumed.
- **Key handling**: compile-time key conversion (`.snakeCase` and friends), aliases
  that warn which one matched, `@Extras` open maps, unknown-key policies with
  Damerau–Levenshtein did-you-mean.
- **Security by construction**: XXE unfetchable, expansion bombs budget-capped,
  limits first-class (see `SECURITY.md`).
- **Verification as a feature**: differential oracles against JSONSerialization,
  Yams/libyaml, and Foundation's XMLParser; deterministic fuzzing; live-allocation
  gate; compile-time budget gate (~87 ms per type against a 100 ms ceiling).

- **Rows and column stores are not part of Assay** (2026-09-11). `ColumnarSource`,
  `ColumnDecodable`, `RowBatch`, `RowDecoder<T>`, `RowSink` and `@Schema(sources: true)`
  were built, measured and removed before release. Not for being slow — the columnar path
  was the fastest thing here at 11 ns/row — but because nothing depended on it, the audience
  is small, and a decoder that also owns column stores is two libraries wearing one name.
  It cost ~1,900 lines and doubled the expansion cost of any type that used it.
  `T.validate(_:)` is the answer for a fast external reader: it decodes at its own speed in
  its own module, and Assay runs the rules afterwards. `ROADMAP.md` has the full record; if
  it returns it will be a separate package.
- **The value model is 2.1× faster** (2026-09-11): `JSON.Value.parse` allocated a path
  array per value in the document, for a diagnostic path nothing reads unless the document
  is malformed. The corpus-wide sweep goes 1.51× → **3.11×** over `JSONSerialization`, and
  the DOM-vs-DOM gap against yyjson closes from 16× to 7×.
- **A type mismatch on the YAML/XML/TOML/plist path now carries a caret** even when the
  field has no rules; previously only JSON did.
- **`@Key(_:or:)` now actually warns which alias matched** (2026-09-10) — `alias_matched`,
  on the JSON and YAML/XML/TOML paths. Three documents had promised it and no code did.
- **TOML** (`AssayTOML`, 2026-09-10): a hand-written TOML 1.0.0 parser passing all
  710 documents of the official toml-test suite in CI, differential against toml++,
  `parse(toml:)`/`diagnose(toml:)`, `SchemaFormats.toml`, `WireFormat.toml`, and
  `encodedTOML()` with nil members omitted and every other null reported
  (`docs/TOML.md`).
- **Encoding** for JSON, YAML, XML and TOML (`@Schema(encodes: true)`), with round-trip as a
  stated law and a closed exception list (`docs/ENCODING.md`); 2.85× `JSONEncoder`.
- **Unions** — `@Schema(discriminator: "type")` and `.untagged` — decode and encode,
  JSON only (`docs/UNIONS.md`).
- **`Assayer<T>`** runtime schemas, `@Wraps`, `@Inline`, `@Key(path:)`, `@OneOrMany`,
  `@XML` placement and `@XML(root:)`, `@Schema(context:)`, `parse(plist:)`,
  `parse(body:contentType:accepting:)` and `jsonSchema(for:)`.
- **Collections report one issue per bad element** and continue; a dictionary value's
  issue names its key (`m.j`, `d.a[1]`). A backticked property name (`` `default` ``)
  decodes. A UTF-8 BOM is skipped. `@Check` misuse, undecodable field types (`Set`,
  tuples, `Data`, `URL`, `T!`, generic structs…) and a non-`@Schema` nested type all get
  purpose-written diagnostics instead of `has no member '_assay'`.
- **One error type.** `JSON.Value.parse`, `YAML.parse` and `XML.parse` throw `AssayError`
  like every other entry point, with the source retained, so their failures render carets
  too. `JSONValueError`, `YAMLParseError` and `XMLParseError` are gone.
- **Errors print.** `print(error)`, `"\(diagnosis)"` and (with `AssayFoundation`)
  `localizedDescription` show the caret render; they used to show a reflection dump.

Renamed before release, no deprecation shims: `Discriminator.none` → `.untagged` (the
old spelling warned on every use — it resolved to `Optional.none`), and the assertion
rules `.trimmed`/`.lowercased` → `.isTrimmed`/`.isLowercase` (they never normalised;
`@Preprocess` does). Every message-less rule now has an `(or:)` overload.

Known limitations at this release, deliberately deferred with reasons in
`ROADMAP.md`: unions have no YAML/XML path, `@Key(path:)` refuses index segments,
`StandardSchema` waits on a third package, no streaming (a decision, not a gap —
`docs/STREAMING.md`), `.past`/`.future` date rules pending a clock seam.
