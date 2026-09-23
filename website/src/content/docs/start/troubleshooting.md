---
title: Troubleshooting
description: The errors that look like bugs and are not, with the fix for each — and the runtime surprises that are Assay doing exactly what you told it.
---

Most of Assay's errors tell you the fix in the message. This page is for the ones where the
*reason* is worth knowing, and for the behaviour people report as a bug before they find the
sentence that explains it.

Headings are the error text. Paste yours into the browser's find.

## It does not compile

### `parse(yaml:)` / `parse(xml:)` / `parse(toml:)` does not exist

Your type did not ask for that format:

```swift
@Schema                              // JSON only
@Schema(formats: [.json, .yaml])     // now parse(yaml:) exists
```

You need the product too — `AssayYAML` in `Package.swift`, `import AssayYAML` in the file.

This is a compile error on purpose. Every format you list costs generated code, so a
JSON-only type does not carry a YAML decoder it never calls. Ask for the format and the
method appears.

### "this schema does not encode. Add `encodes: true` to its @Schema"

```swift
@Schema(encodes: true) struct Article { … }
```

Writing is opt-in because it roughly doubles the generated code, and most types only ever
read. It costs about 5% of the type's compile time.

`jsonSchema(for:)` works the same way and wants `describes: true`.

### "content negotiation chooses a parser at run time…"

`parse(body:contentType:accepting:)` needs `formats: .all`, or at least one non-JSON format —
**even if you only ever pass `accepting: [.json]`**.

That looks silly until you remember who picks the parser. Negotiation reads the
`Content-Type` while your program is running. The compiler never sees your array, so it
cannot know it holds only `.json`, and the door has to work for whichever branch turns up.

### "@Check must be declared in the body of the @Schema type, not in an extension"

Move the function inside the type's braces.

A macro only sees the declaration it is attached to. Put a `@Check` in an extension and
`@Schema` cannot see it — not "sometimes", ever. Your check would simply never run, and
nothing would say so. Hence the error.

### "@Schema cannot infer a type from an initializer alone"

```swift
var retries = 3            // ✗ what type? the macro reads source, not a type checker
var retries: Int = 3       // ✓ absent → 3, and a present value is still validated
let created: Date = .now   // ✗ a decoded field cannot be a let with a value
@Ignore var cache: Cache?  // ✓ when it is not a field at all
```

[Presence](/guides/presence/) has all five states and what each one means.

### `Set`, `Data`, `URL`, `Decimal`, a tuple, a generic — "cannot be decoded"

These are refused as **field types**, and the message names the alternative. There is no one
honest wire shape for them: a `Set` is an array that lost its order, a `Data` is base64 or
bytes or hex depending who wrote it, a `URL` is a string somebody validated.

Convert one you own:

```swift
@Transform({ (a: [String]) in Set(a) }) var tags: Set<String>
```

Generics are refused for a duller reason: the dispatch tables are static stored properties,
and a generic type cannot have those. [Advanced](/guides/advanced/#types-the-macro-refuses)
lists every refusal with its reason.

One thing that trips people: a `Data` *field* is refused, but `parse(json: data)` takes a
`Data` document and is the fastest way to hand one over. Different things, same type name.

### `@Schema` and SwiftData both export `Schema`

They do, and it does not matter. Macro lookup takes a different path from type lookup, so a
`struct Schema` in scope — SwiftData's included — cannot shadow the macro. If you want to be
explicit anyway, Swift 6.3 spells it `@Assay::Schema`.

### `parse` suddenly needs `await`

One `@AsyncCheck` anywhere on the type makes that type's `parse` and `diagnose` async. The
decode itself stays synchronous; only your checks suspend, and they run only after a clean
synchronous pass. [Checks](/guides/checks/) has the ordering.

### The first build takes minutes

SwiftPM is building `swift-syntax` to run the macro. Once.

Swift 6.2 and later ship a prebuilt copy that skips it, but only when the version Assay
resolves matches the one your toolchain ships — Assay pins the 603 line for exactly that
reason. If you see it on every clean checkout, something else in your dependency graph has
pulled a different major line.

## It compiles, and does something I did not expect

### `enabled: no` is an error, not `false`

YAML 1.1 said `no` was false. YAML 1.2 does not, and neither does Assay.

A plain scalar keeps its text until something asks it a typed question, so your `Bool` field
sees the string `"no"` and says so rather than guessing. That is
[the Norway problem](/formats/yaml/#the-norway-problem-and-why-you-do-not-have-it), solved by
not having an opinion. Write `true` or `false`, or declare the field as `String`.

### Every XML field says "must be an integer, found …"

Add `coerceScalars: true`.

XML has no types — every leaf is text — so `8080` arrives as `"8080"`. XML is the one format
that makes you say you want coercion, because everywhere else it is a real choice.

### A scalar decoded into an array I declared

From YAML, XML or TOML, `tags: swift` gives you `["swift"]`. That is deliberate: XML spells a
list as repeated sibling elements, which is indistinguishable from one element at that layer.

From JSON it is a mismatch unless you ask for it with `@OneOrMany`, because there the
difference is genuine.

### The document was refused for its size

`maxBytes` defaults to 64 MB and is checked before the first byte is read. If you meant it,
say so:

```swift
try Report.parse(json: bytes, limits: Limits(maxBytes: 512 << 20))
```

[Limits and security](/reference/limits-and-security/) has all four and what each one stops.

### A `@Fallback` swallowed my bad data

It did, and that is its job: absent **or invalid** becomes the fallback, and the violation
becomes a warning rather than an error.

If you wanted the failure, use a default instead — `var retries: Int = 3` applies only when
the key is absent, and still validates a value that is present. And read `d.warnings` in
development; all four renderers include them.

### `d.isValid` is true but something is clearly wrong

`isValid` is about issues. A `@Fallback` that fired, an alias that matched, an unknown key
under `.warn` — those are **warnings**, and the value is real. `parse` discards them by
design: you asked for a value or an error. `diagnose` hands them to you.

### `d.source` is empty after decoding from `Data`

Only after a clean decode, and only from the `Data` door.

`Diagnosis` keeps the input so it can draw a caret later, but a `Data`'s bytes are only valid
for the duration of the call — so Assay copies them just when an issue or warning needs
rendering. You passed the `Data` in, so you still have it. Failures render identically either
way; tests pin that.

### TOML and property-list dates arrive as strings

RFC 3339 strings, specifically, so your `Date` field decodes through the same `@DateFormat`
machinery on every format instead of each one inventing its own date rules. `.iso8601` reads
them unchanged.

## Still stuck

- [Issue codes](/reference/issue-codes/) — every code Assay can produce, and what it means.
- [Errors](/guides/errors/) — the anatomy of an issue, and the four renderers.
- [GitHub issues](https://github.com/nerdmenot-swift/assay/issues) — and `ROADMAP.md` for the
  honest list of what is deferred and why.
