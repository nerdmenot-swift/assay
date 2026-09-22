---
title: Troubleshooting
description: The compile errors and the runtime surprises, with the fix for each — including the ones that are Assay working as designed.
---

Assay's diagnostics are written to name the fix, so most of the time the error text is the
answer. This page is for the cases where the *reason* is worth a paragraph: the errors that
look like bugs and are not, and the behaviours people report as wrong before they find the
sentence that explains them.

## It does not compile

### `parse(yaml:)` / `parse(xml:)` / `parse(toml:)` does not exist

The type did not ask for that format:

```swift
@Schema                              // JSON only
@Schema(formats: [.json, .yaml])     // now parse(yaml:) exists
```

This is a **compile** error rather than a runtime one on purpose — the conformance that entry
point needs is simply not there. Each format costs generated code, so a JSON-only type does
not pay for a YAML body it never calls. You also need the product: `AssayYAML` in
`Package.swift` and `import AssayYAML` in the file.

### "this schema does not encode. Add `encodes: true` to its @Schema"

`encodedJSON()`, `jsonText()` and their siblings come with `@Schema(encodes: true)`. The
writer is opt-in because it roughly doubles the generated code for a type that may never
encode anything; it costs about 5% of the type's compile time.

The same shape applies to `jsonSchema(for:)`, which needs `describes: true`.

### "content negotiation chooses a parser at run time, so this door needs the RawValue projection"

`parse(body:contentType:accepting:)` needs `formats: .all` (or at least one non-JSON format)
**even when you pass `accepting: [.json]`**. Negotiation picks the parser while the program
is running, and the compiler cannot see that your runtime array holds only `.json`, so the
door requires the projection every branch might use. It is a real constraint rather than an
oversight.

### "@Check must be declared in the body of the @Schema type, not in an extension"

A `@Check` in an extension is *permanently* invisible to `@Schema`: an attached macro sees
only the declaration it is attached to, so members added elsewhere do not exist as far as
expansion is concerned. Rather than silently never running your check, Assay makes it a
compile error. Move the function inside the type's own braces.

### "@Schema cannot infer a type from an initializer alone"

```swift
var retries = 3            // ✗ the macro cannot infer Int from an initialiser
var retries: Int = 3       // ✓ a default: absent → 3, and a present value is still validated
let created: Date = .now   // ✗ a decoded field cannot be `let` with a value
@Ignore var cache: Cache?  // ✓ if it is not a field at all
```

The macro reads your source, not a type-checked AST, so `= 3` alone tells it nothing about
the wire shape. [Presence](/guides/presence/) has the five states and what each one means.

### A type the macro refuses: `Set`, `Data`, `URL`, `Decimal`, a tuple, a generic

Every one of these is a build error that names the alternative, because there is no single
honest wire shape for them — a `Set` is an unordered array, a `Data` is base64 *or* bytes
*or* hex, a `URL` is a validated string. Use `@Transform` for a conversion you own, or
`@Wraps` for a type that *is* a constrained scalar:

```swift
@Transform({ (a: [String]) in Set(a) }) var tags: Set<String>
```

Generic types are refused for a mechanical reason: the dispatch tables are static stored
properties, which a generic type cannot have. [Advanced](/guides/advanced/#types-the-macro-refuses)
has the full table with the reasoning.

### `@Schema` is ambiguous with SwiftData

It is not, even though it looks like it should be: macro lookup uses a separate name-lookup
path that rejects non-macro candidates, so a `struct Schema` in scope — SwiftData exports
one — cannot shadow the macro. If you want to be explicit anyway, Swift 6.3 module
selectors spell it `@Assay::Schema`.

### `parse` suddenly needs `await`

One `@AsyncCheck` on a type makes that type's `parse` and `diagnose` async, by a
compile-time count. The decode itself stays synchronous; only the checks suspend, and they
run only after a clean synchronous pass. [Checks](/guides/checks/) has the ordering.

### The first build takes minutes

SwiftPM is building `swift-syntax` to run the macro, once. Swift 6.2 and later ship a
prebuilt copy that skips it, but only when the version Assay resolves matches the one your
toolchain ships — Assay pins the 603 line for exactly that reason. If it happens on every
clean checkout, something else in your dependency graph has pulled a different major line.

## It compiles, and does something I did not expect

### `enabled: no` in YAML is an error, not `false`

YAML 1.1 said `no` is false; YAML 1.2 does not, and neither does Assay. A plain scalar keeps
its text until something asks a typed question, so a `Bool` field sees the string `"no"` and
reports a mismatch instead of guessing. That is [the Norway problem](/formats/yaml/#the-norway-problem-and-why-you-do-not-have-it)
solved by not having an opinion. Write `true`/`false`, or declare the field as `String`.

### Every XML field fails with "must be an integer, found …"

XML has no types — every leaf is text — so a struct decoding from XML needs
`coerceScalars: true`. It is the one format that makes you say it, because coercion is a
real decision and XML is the one place it is unavoidable.

### A field decoded from a scalar where I declared an array

The `RawValue` path is tolerant of this by nature: XML spells a sequence as repeated
siblings, which is indistinguishable from a single scalar at that layer. So `tags: swift`
decodes as `["swift"]` from YAML, XML and TOML, and is a mismatch from JSON unless you ask
for it with `@OneOrMany`. The asymmetry is a stated contract rather than an accident.

### The document was refused for its size

`maxBytes` defaults to 64 MB and is checked before the first byte is read. A caller who
means to read something bigger says so:

```swift
try Report.parse(json: bytes, limits: Limits(maxBytes: 512 << 20))
```

[Limits and security](/reference/limits-and-security/) has all four and what each one
bounds.

### `d.value` is nil but `d.issues` is empty

That combination means the decode produced no value *and* nothing to report, which should
not happen — if you can reproduce it, it is a bug worth an issue. The ordinary shapes are
`value` present with an empty `issues`, or `value` nil with at least one issue. Note that
`d.isValid` is about issues, not about warnings: a `@Fallback` that fired leaves a **warning**
and a perfectly valid value.

### A `@Fallback` hid my bad data

That is what it is for: absent **or invalid** becomes the fallback value, and the violation
becomes a warning rather than an error. If you want the failure, use a default (`= 3`),
which applies only when the key is absent and still validates a value that is present.
Read `d.warnings` in development — the four renderers include them.

### `d.source` is empty after decoding from `Data`

Only after a **clean** decode, and only from the `Data` door. `Diagnosis` retains the input
so a caret can be drawn later, but a `Data`'s bytes are valid only for the duration of the
call, so Assay keeps a copy only when an issue or warning needs rendering. You passed the
`Data` in, so you still hold it. Failures render identically to the `[UInt8]` door — that
equality is pinned by tests.

### TOML and property-list date-times arrive as strings

They project to RFC 3339 strings so that a `Date` field decodes through the same
`@DateFormat` machinery on every format, instead of one format having its own date rules.
`.iso8601` reads them unchanged.

### Two issues for one syntax error, or an issue at the wrong byte

Both were real bugs and both are fixed: `trailing_content` no longer fires beside a syntax
failure, and truncated input now carries a caret rather than pointing one byte past the end.
If you see either on a current version, that is worth reporting.

## Still stuck

- [Issue codes](/reference/issue-codes/) — every code Assay can produce, with what it means.
- [Errors](/guides/errors/) — the anatomy of an issue and the four renderers.
- [GitHub issues](https://github.com/nerdmenot-swift/assay/issues) — including the honest
  list of what is deferred and why, in `ROADMAP.md`.
