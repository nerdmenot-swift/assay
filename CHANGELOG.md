# Changelog

Notable changes, most recent first. Assay is pre-1.0: minor versions may change API,
and every deliberate deferral lives in [`ROADMAP.md`](ROADMAP.md) with its reason.

## Unreleased (targeting 0.1.0)

The first public release. Everything below is "added" by definition; the highlights
that distinguish it:

- **`@Schema` macro decoding** for JSON (streaming), YAML and XML (via a
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

- **Encoding** for JSON, YAML and XML (`@Schema(encodes: true)`), with round-trip as a
  stated law and a closed exception list (`docs/ENCODING.md`); 2.85× `JSONEncoder`.
- **Unions** — `@Schema(discriminator: "type")` and `.untagged` — decode and encode,
  JSON only (`docs/UNIONS.md`).
- **`Assayer<T>`** runtime schemas, `@Wraps`, `@Inline`, `@Key(path:)`, `@OneOrMany`,
  `@XML` placement and `@XML(root:)`, `@Schema(context:)`, `parse(plist:)`,
  `parse(body:contentType:accepting:)`, `jsonSchema(for:)`, columnar batch decode.
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
