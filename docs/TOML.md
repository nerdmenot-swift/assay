# TOML

**Built 2026-09-10.** The fourth text format, as a separate `AssayTOML` product on the
`RawValue` projection path YAML and XML use. TOML 1.0.0, complete: **210/210 valid and
501/501 invalid documents of the official [toml-test](https://github.com/toml-lang/toml-test)
suite**, run in CI, and a differential against toml++ (via TOMLKit) on the hand-written
cases and the whole JSON corpus rendered twice.

```swift
import AssayTOML

@Schema(keys: .snakeCase, formats: [.json, .toml])
struct Config {
    var title: String
    @Validate(.min(1), .max(65535)) var port: Int
    var servers: [Server] = []
}

let c = try Config.parse(toml: text)
```

---

## 1. Why it is small, and why it is not trivial

TOML is the smallest of the four formats and the only one **typed on the wire**: `1` is an
integer, `"1"` is a string, `1979-05-27` is a date, and the parser does not guess. That is the
opposite of YAML's Norway problem, and it is why `TOML.Node` resolves scalars at parse time
where `YAML.Node` deliberately keeps the text.

The whole difficulty is the redefinition rules. A TOML document is not a tree written down; it
is a *sequence of edits* to a tree — `[a.b]` opens a table, `c.d = 1` reaches into it, `[[a]]`
appends — and the specification states, in prose scattered across five sections, which edits
are legal after which. `TOMLParser.swift`'s header collects them in one place; the
implementation is one fact and one table:

> Every value except an **open table** is closed the moment it is parsed.

and each open table remembers how it came to exist:

| origin | created by | a later `[a]` | a later `a.x = 1` in scope |
|---|---|---|---|
| `header` | `[a]` | error | fine |
| `dotted` | `a.b = 1` | error | fine |
| `implicit` | `[a.b]` created `a` | **fine** — defines it | error |

Inline tables, arrays, and scalars are closed values; extending one — `a = {b = 1}` then
`a.c = 2` — is an error with its own code (`toml_inline_table_closed`), because "is not a
table" would be a lie about the one thing the reader can see it is.

---

## 2. The projection

```
bytes → TOML.Node → RawValue → your struct
```

`TOML.Node` is the full-fidelity model: `bool`, `int(Int64)`, `double`, `string`,
`dateTime(DateTime)`, `array`, `table([Member])` — tables ordered, members carrying a
`SourceSpan` on the value so a schema issue gets a caret.

The projection to `RawValue` is **total** — every TOML key is a string, so there is no
unrepresentable-key case as YAML has — and lossy in exactly one place: the four date-time
kinds all become `.string` in RFC 3339 spelling with a `T` separator. That text is what the
schema's `Date` path already parses, so

```toml
when = 1979-05-27 07:32:00Z
day = 1979-05-27
```

decodes into `var when: Date` with no new code, and `@DateFormat(.pattern("yyyy-MM-dd"))`
takes the local date. A caller who needs to know *which* kind a value was parses to
`TOML.Node` and reads `.dateTime`.

Numbers are typed on the wire and the projection keeps that: a TOML integer decodes into a
`Double` field (widening is safe), a TOML float does **not** decode into an `Int` field —
that is `type_mismatch`, with the caret on `80.5`. The narrow widths (`UInt8`, `Int16`, …)
range-check as on every path.

---

## 3. What is refused, and how it is reported

First error stops. A TOML document is line-structured, but a header or a dotted key changes
the meaning of every line after it, so there is no honest way to resume; the parser reports one
issue with a caret and returns nil. Schema issues on a parsed document are still collected in
full, as on every format.

Sixteen `toml_*` codes, each a sentence, each pinned by a test against the specification's own
invalid examples. The ones a reader will meet:

| code | when |
|---|---|
| `toml_expected_newline` | `a = 1 b = 2` — two things on one line |
| `duplicate_key` (shared) | `a = 1` twice, in any spelling (`"a"`, `'a'`) |
| `toml_redefined_table` | `[a]` twice; `[a]` after `a.b = 1`; `[a.b]` after `[a] b.c = 1` |
| `toml_not_a_table` | `[a.b]` where `a` is a string; `[[a]]` where `a = []` |
| `toml_inline_table_closed` | extending an inline table |
| `toml_bad_number` | `01`, `1_`, `1__2`, `+0x1`, `1.`, `.5`, `infinity` |
| `number_overflow` (shared) | outside `Int64`, in any base |
| `toml_bad_date_time` | month 13, Feb 30, hour 25, `07:32` (1.0 requires seconds) |
| `toml_control_character` | a raw control byte in a string or comment; a bare CR |
| `toml_bad_escape` | `\q`, `\uD800`, `\U00110000`, `\u12` |

Limits apply: `maxDepth` to arrays, inline tables and header paths; `maxBytes` before the
first byte is read.

Two decisions where the specification leaves room, both stated so they are not rediscovered:

* **A leap second (`23:59:60`) is accepted.** The TOML ABNF says `time-second … 00-60`;
  toml++ refuses it; toml-test has no case either way. The library follows the grammar.
* **CRLF inside a multi-line string becomes LF.** The specification permits normalisation;
  toml++ and BurntSushi/toml both do it; a config edited on Windows should yield the same
  strings everywhere.

Nothing from TOML 1.1 is accepted (newlines in inline tables, `\e`, `\x`, optional seconds),
so a document that parses here parses everywhere.

---

## 4. Encoding

`@Schema(encodes: true)` gives `encodedTOML()`, `diagnoseEncodeTOML()` and `tomlText()`,
through the same `RawValue` seam as YAML. The layout is the one every TOML serialiser
converges on: a table's scalar members as `key = value` lines, sub-tables as `[a.b]` sections,
arrays of tables as `[[a.b]]` sections, anything else inline.

**TOML has no null**, and that is the one place encoding can fail:

* a nil **member of a table is omitted** — the reader sees an absent key, an optional field
  decodes nil from it, the round trip holds;
* a nil **anywhere else** (an array element, a dictionary value, the root) has no spelling
  that reads back as nil and is reported as `toml_no_null` with its path rather than
  silently substituted;
* a root that is not a table is `toml_root_not_a_table`.

Strings are always basic single-line strings with escapes. Doubles print through the
stdlib's shortest round-trip form, which always carries a `.` or an `e`, so `2.0` reads back as
a float and not an integer. Every document the writer produces is read back by toml++ in
`DiffFuzz toml` (75/75 corpus files).

---

## 5. Verification

| | |
|---|---|
| toml-test | **210/210 valid** parse to the expected tagged-JSON value; **501/501 invalid** refused. CI clones the suite; `TOML_TEST_DIR=… swift run -c release DiffFuzz toml-test` locally |
| toml++ differential | 35 hand-written feature cases agree, 33 documents both refuse, 150 generated documents (the JSON corpus, inline and `[[sectioned]]`) agree |
| encode round trip | 75/75 corpus documents Assay wrote, read back by toml++ to the same value |
| fuzz | TOML is a fourth parser in the deterministic fuzz arm — 10,680 mutations per run, no crash, no hang |
| unit tests | the specification's own examples, 76 invalid documents each asserting its code, limits, spans, the schema door against JSON, encoding |

Tables are compared **sorted by key** against toml++ (it stores a `std::map`); document order
is pinned by the library's own tests, not by an independent reader.

---

## 6. Speed

A tree decoder, like YAML and XML: no `Codable` boundary is deleted, so the JSON thesis does
not apply and JSON-sized ratios are not expected. Against toml++ reached through TOMLKit, on
the apimodel ladder rendered with `[[items]]` sections (one arm64 Mac; `AssayBench toml`):

| | baseline | mean |
|---|---|---|
| node parse | toml++ (`TOMLTable(string:)`) | **1.09×** |
| struct decode | TOMLKit `TOMLDecoder` (Codable) | **1.81×** |

Parity with a C++ parser on the tree, and the `Codable` decoder's cost on top of it is what the
second row measures.
