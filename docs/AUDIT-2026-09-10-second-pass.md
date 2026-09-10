# Audit — 2026-09-10, second pass

The same six questions asked again of the tree at `66a5c47`, after the nine commits that
closed the first pass (`AUDIT-2026-09-10.md` §7). Same method, with the time the first pass
spent on inventory spent instead on three things a first pass skims: **every file that was
only outlined before was read**; a **54-declaration compile-probe battery** of what a
newcomer actually writes was built as a real consumer package and compiled, then a
**runtime battery** of the declarations that compiled silently was executed; and the seams
today's own changes created were checked for what they broke. Release-mode and consumer
builds were done, not just `swift build`.

**Verdict.** The first pass's fixes hold — zero warnings in library, tests, expansions and
release; 659 tests; goldens identical; gate 77.6 ms. The second pass found **four
correctness bugs, two of them mine from this morning**, a class of newcomer error the
macro could refuse but hands to the type checker as `has no member '_assay'`, and a spec
spelling (`@Check(\.field)`) that has never compiled. Nothing here is architectural; all of
it is fixable in a day, and §6 is the order.

---

## 1. Correctness

### 1.1 An element type-mismatch inside an array reports two false issues — **HIGH**

`Sources/AssayMacros/CodeGen.swift:623` and `:656`. Executed:

```
@Schema struct AI { var a: [Int] }
AI.diagnose(json: #"{"a":[1,"x",3]}"#).issues
// ["a[1] must be an integer, found \"x\"",
//  "is not a well-formed document",              ← false
//  "unexpected content after the end of the document"]   ← false
```

The element decode returns nil, the loop `break`s with the cursor still on `"x"`, the
closing-bracket check fails, and `reportMalformed` says the document is malformed. It is
not. The same input with the bad element *first* (`["x",2]`) reports one issue and
silently stops decoding the rest of the object — `b` is neither decoded nor reported
missing. Both are the same bug: an element failure must skip the element and continue, the
way a field failure inside an object does. The library's headline is "every issue, and
only real ones"; this is the one place a well-formed document is called malformed.

**Fix.** On element failure: `_ = reader.skipValue(&sink)` and continue the loop (the
scalar primitives already report before returning nil). The dictionary loop
(`dictDecode`) has the same shape and needs the same change. Then a test with a bad element
first, middle and last, asserting exactly one issue and that later fields still decode.

### 1.2 A backticked property name puts the backticks in the wire key — **HIGH**

`Sources/AssayMacros/SchemaMacro.swift:628`: `let name = pattern.identifier.text`. For
``var `default`: Int`` that text is `` `default` `` with the backticks, so the wire key is
`` `default` `` and `{"default":1}` reports `` `default` is required``. Executed. `default`,
`class`, `enum`, `protocol`, `import`, `operator`, `in`, `is`, `as`, `Type` — every
Swift keyword a JSON API might use as a key needs backticks, and every one of them decodes
nothing today. Also affects the memberwise-init argument label the macro emits.

**Fix.** `identifier.text.trimmingCharacters(in: "`")` — or `pattern.identifier
.identifier?.name` on newer swift-syntax. One line, plus a test with a keyword property.

### 1.3 `Assayer.map` returning nil yields a `Diagnosis` that is valid and has no value — **HIGH**

`Sources/Assay/Assayer.swift:` `diagnose(_ raw:)`. Executed:

```
let s = Assayer.string.map { (_: String) -> Int? in nil }
let d = s.diagnose(json: Array("\"x\"".utf8))
// valid=true value=nil issues=0 ; try d.get() throws an AssayError with ZERO issues
```

`guard let out = plan.run(...), sink.isValid, let value = build(out) else { return
Diagnosis(value: nil, issues: sink.issues …) }` — when `build` is what failed, `sink` is
empty. `AssayerBacked` handles the identical situation correctly by adding
`.assayerConversionFailed`; `Assayer.diagnose` does not. A `Diagnosis` with `isValid ==
true` and `value == nil` violates the type's own contract.

**Fix.** Add `.assayerConversionFailed` at `path` when `build` returns nil (as
`AssayerBacked.swift:63` does), and a test. The same case in `diagnose(json:)` is covered
by the fix since it delegates.

### 1.4 `@Preprocess` on a `@Transform`ed field is now refused — my regression — **HIGH**

`Sources/AssayMacros/SchemaRefusals.swift`, this morning. The check compares the DECLARED
type to `String`; a field like

```swift
@Preprocess(.trim) @Transform({ (s: String) in s.count }) var a: Int
```

has a `String` wire type and an `Int` declared type, is legitimate, and is now refused.
The refusal must test `SchemaField.decodedType` (the transform's wire type when there is
one), which is what every other emitter uses. One line, and the golden `rules-checks-async`
shape should gain exactly this field so it cannot regress silently.

### 1.5 A UTF-8 BOM is a type mismatch — **MEDIUM**

Executed: `STR.diagnose(json: "\u{FEFF}{\"s\":\"x\"}")` → "must be an object, found ﻿{…".
RFC 8259 §8.1 says a parser MAY ignore a leading BOM; `JSONDecoder` does; every file
saved by Notepad has one. Three bytes to skip at `_decode`, one test.

### 1.6 A lone surrogate escape reports as a type mismatch plus "not well-formed" — **LOW**

`"\ud800"` → `s must be a string, found "` and `is not a well-formed document`. One issue
(`invalid_escape` or the existing string mismatch with a `reason`) and a clean skip.

### 1.7 Duplicate keys in JSON are silently last-wins; in XML they are `.duplicateKey` — **LOW**

`{"a":1,"a":2}` → `a == 2`, no issue, no warning, under every `unknownKeys` policy.
`XMLParser.swift:227` raises `.duplicateKey` for the same situation. Neither is wrong on
its own, but the two formats disagree and the JSON behaviour is undocumented. Either
document last-wins in `CONFORMANCE.md` or warn under `.warn`/`.reject`.

---

## 2. Developer experience

### 2.1 The most common newcomer error is `type 'X' has no member '_assay'` — **HIGH**

The probe battery's largest class. Each of these compiles to a type-checker error inside
the expansion, naming an underscored internal, at a line the user never wrote:

| declaration | error the user sees |
|---|---|
| `var a: Set<String>` | type 'Set<String>' has no member '_assay' |
| `var a: [Int?]`, `var a: Int??` | type 'Int?' has no member '_assay' |
| `var a: (Int, Int)` | value of tuple type '(Int, Int)' has no member '_assay' |
| `var a: Character`, `Data`, `URL`, `Decimal` | type 'Data' has no member '_assay' |
| `var a: Any` | (plus a Sendable error) |
| `enum E: String { … }` then `var e: E` — no conformance | type 'E17' has no member '_assay' |
| `struct N { … }` not `@Schema`, then `var n: N` | type 'N19' has no member '_assay' |
| `final class Ref: Sendable`, `var r: Ref` | type 'Ref34' has no member '_assay' |
| `@Fallback("x") var a: Int` | cannot assign value of type 'String' to type 'Int' |
| `var a: Int!` | using '!' is not allowed here |
| `@Schema struct G<T> { … }` | static stored properties not supported in generic types |
| `@Extras var r: [String: Int]` | requires that 'Int' conform to 'JSONCollectible' |

Two fixes, of different sizes:

- **Syntactic shapes the macro can see** — `Set<…>`, `Optional<Optional<…>>`/`T??`,
  `[T?]`, tuples, function types, `Character`, `Data`, `URL`, `Decimal`, `Any`, `T!`,
  generic type parameters, a non-`RawValue` `@Extras` value — go in `SchemaRefusals` with
  a message naming the alternative (`[String]` + `@Transform` for a `Set`; `Int?` for
  `Int!`; `AssayFoundation` for `UUID`/`Date`). One table, an hour.
- **Nominal types it cannot see** (a plain enum, a non-`@Schema` struct, a class) — emit,
  once per distinct nested type per schema, a zero-cost static assertion
  `Assay._assayRequire(N19.self)` where `@inlinable func _assayRequire<T: JSONAssayable>(_:
  T.Type) {}`. The type checker then says *"global function '_assayRequire' requires that
  'N19' conform to 'JSONAssayable'"* — which names the protocol to adopt — instead of *"has
  no member '_assay'"*. The function is empty and specialised away; the per-field code is
  unchanged (hard constraint 6 holds: the decode call is still the concrete one). One line
  per nested type, so the compile-time cost is bounded by the number of distinct types, not
  fields; measure it on the `arrays` arm, which has the most nested calls.

### 2.2 `@Check(\.field)` — the documented spelling — has never compiled — **HIGH**

`docs/EXPERIENCE.md:394`, `:1332`, `CLAUDE.md:159` and this morning's golden source all
write `@Check(\.workEmail)`. The macro is declared `Check<Root, Value>(_ keyPath: KeyPath<Root,
Value>)`, and an attached-macro argument cannot infer `Root` from its attachment, so every
one of those fails with *"cannot infer key path type from context"* — before the macro runs,
which is also why the purpose-written "not in an extension" diagnostic (`MarkerMacros.swift:86`)
is unreachable from that spelling. The tests all write `\Signup.workEmail`, which works.

**Fix.** The docs (three places) and the golden source say `\Type.field`. A shorter spelling
is not available: `PartialKeyPath` still needs `Root`, and a `String` field name would give
up the type check that `\Type.field` provides for free.

### 2.3 Three `@Check` mistakes the macro could catch, handed to the type checker — **MEDIUM**

Executed with the qualified spelling: a field check whose parameter type does not match the
field (`@Check(\P.a) static func f(_ a: String)` on `var a: Int`) → *"cannot convert value
of type 'Int' to expected argument type 'String'"* inside the expansion; a cross-field check
with the wrong shape (`static func cross(_ v: P) -> String?`, missing the `inout Issues<P>`)
→ *"extra argument in call"*; a key path to a property that does not exist → the right
error, plus two more from the expansion. `ChecksGen` checks only `static`; it has the field
list and the function signature in hand and can say which of the three it is.

### 2.4 Three error types that are the same type, and cannot render — **MEDIUM**

`YAMLParseError`, `XMLParseError` and `JSONValueError` (`YAMLParser.swift:108`,
`XMLParser.swift:79`, `JSONValueDecode.swift:194`) are identical — `public var issues:
[Issue]` — thrown by `YAML.parse`, `XML.parse` and `JSON.Value.parse`. None carries the
source, so none can render a caret; none is `CustomStringConvertible`, so `print(error)` on
the value-model paths is back to a reflection dump — the first pass fixed `AssayError` and
missed these. `docs/ENCODING.md` Q4's principle is "one error vocabulary across every
format".

**Fix.** Move `AssayError` from `Assay/Entry.swift` to `AssayCore` (it depends only on
`Issue`, `SourceBytes`, `Renderer`, all core) and throw it from all three, source retained.
`Assay` re-exports `AssayCore`, so no caller changes. Delete the three.

### 2.5 `Assayer` has no `parse(json: String)` — **LOW**

Every `@Schema` type takes `[UInt8]` or `String`; `Assayer.parse(json:)` takes bytes only.
The probe `try s.parse(json: "\"x\"")` fails to compile. Two overloads.

### 2.6 `@Key("")` is accepted — **LOW**

Executed: decodes `{"":1}`, and the missing-key message is `" is required"`. Refuse.

### 2.7 A mismatch on a container prints the raw bytes — **LOW**

`STR.diagnose(json: "[1]")` → *must be an object, found `[1`*; a deeply nested input → *found
`[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[`*. `describeCurrentValue` (`AssayReader.swift`) also cuts
at 32 bytes without respecting UTF-8 boundaries, so a long non-ASCII value renders with a
replacement character. Summarise containers as "an array"/"an object" and cut on a scalar
boundary.

### 2.8 Documentation coverage — **MEDIUM**

Doc-comment coverage of public declarations (runtime primitives excluded):

| module | public | undocumented |
|---|---|---|
| `Assay` | 142 | 45 (31%) |
| `AssayCore` | 475 | 305 (64%) |
| `AssayYAML` | 52 | 27 (51%) |
| `AssayXML` | 57 | 36 (63%) |
| `AssayPlist` | 12 | 6 (50%) |
| `AssayFoundation` | 21 | 5 (23%) |

`Rule` is 41 of 50 undocumented — every `.min`/`.max`/`.regex`/`.oneOf` constructor is a
bare signature on its DocC page. And `.spi.yml` lists `Assay`, `AssayYAML`, `AssayXML`,
`AssayFoundation` as documentation targets: **not `AssayCore`**, where `Rule`, `Issue`,
`Limits`, `RawValue` and `IssueCode` live, and **not `AssayPlist`**. On Swift Package
Index the type a user reaches for first is undocumented and the plist product is absent.

### 2.9 `ContextEntry.swift` duplicates `Entry.swift` — **LOW**

263 lines that are `Entry.swift`'s `_decode`/`parse`/`diagnose` with a `context:`
parameter threaded through. An internal generic `decodeDocument(_:limits:sourceName:
body:)` taking the per-document decode as a closure removes the copy; the closure is called
once per document, not per field, so hard constraints 3 and 9 are not in play. Contextual
types also have no `parse(mmapped:)` and no `parse(body:contentType:accepting:)` — the
duplication is where that gap comes from.

### 2.10 `Hashable` — **LOW**

`Issue`, `Warning`, `IssueCode`, `PathComponent`, `IssueValue`, `SourceSpan` are
`Equatable` and not `Hashable`, so `[IssueCode: Int]` (count issues by code) and
`Set<Issue>` (dedupe) do not compile. The synthesized conformance is one word each.

---

## 3. Tests

### 3.1 Three tests written this morning break the Windows CI leg — **HIGH** (mine)

`GoldenExpansionTests.swift:58`, `RenderTests.swift:230`, `:263` compute a repository path
with `#filePath.split(separator: "/")`. On Windows `#filePath` uses backslashes; the split
finds one component, the goldens directory resolves to `/Goldens`, and every golden test
plus the message-coverage suite fails on the `Test (Windows)` job. `MappedFileTests.swift`
in the same directory has a Windows shim for exactly this. Use `URL(fileURLWithPath:
#filePath).deletingLastPathComponent()` — Foundation is already imported in both files.

### 3.2 A golden source that does not compile — **MEDIUM** (mine)

The `rules-checks-async` shape in `GoldenExpansionTests.swift` writes `@Check(\.a)`
(§2.2). `expandSchemaForTesting` does not type-check, so the golden "passes" on an
expansion of a declaration no user can write. Goldens should be compiled once: a test
that writes each shape into a temporary package and builds it would catch this, but is
slow; cheaper is to keep every golden source also present as a real fixture in a test file,
which the compiler then checks. Do the second.

### 3.3 The assertion-less scan — **none**

A scan for `@Test` bodies without `#expect`/`#require`/`Issue.record` found seven; all
seven assert through a shared helper or by `try`. No weak assertions to report.

---

## 4. Organisation

- `LineIndex` is `public` and lives in `UTF8Validation.swift` (`:118`); its only user is
  `Render.swift`. Internal, and moved. — **LOW**
- `SchemaConfig.isUnion` (this morning) has no reader. — **LOW**
- `Decode.swift` is still 728 lines of 15 × 3 near-identical primitives; the first pass's
  suggestion (a checked-in generator, like `gen_types.sh`) stands. — **LOW**
- `DiffFuzz/main.swift` is the same shape `AssayBench/main.swift` was: fourteen oracles run
  unconditionally, no arm selection, one `--probe` flag. Same fix, same reason. — **LOW**

---

## 5. Benchmarks and build health

- Release build: zero compiler warnings. Two **linker** warnings — *"building for
  macOS-11.0, but linking with dylib … built for newer version 13.0"* — from the toolchain's
  own dylibs against the `platforms:` floor. Not actionable in this repository; noted so
  nobody chases it. — **none**
- `Benchmarks/Package.resolved` is tracked and `.gitignore`d correctly (checked).
- The `AssayBench` arm selector and the `RESULTS.md` table are as the first pass left
  them; nothing further.

---

## 7. Resolution

All of it landed the same day, in the order §6 gives. Two findings turned out smaller
than written and one larger: `MediaType` was already directly tested (§4.1 of the first
pass over-counted it), the duplicate-key behaviour was already in `CONFORMANCE.md`'s
table (only the BOM row needed changing), and `_assayRequire` had to exempt `UUID`, whose
decode body `AssayFoundation` adds without a `JSONAssayable` conformance — found by the
benchmark package, which is the only target that compiles a `UUID` field; the golden
fixtures now carry one so the test target does too.

| finding | commit | what landed |
|---|---|---|
| §1.1 array/dict cascade | `25d858d` | elements skip and continue; dictionary values carry the entry key at the right depth (`m.j`, `d.a[1]`, `e.p.q`) |
| §1.2 backticks | `25d858d` | `SchemaField.name`; fields, enum cases, init labels |
| §1.3 `Assayer.map` | `25d858d` | `assayer_conversion_failed` |
| §1.4 `@Preprocess` regression | `25d858d` | wire type; golden gained the pairing |
| §3.1 Windows paths | `25d858d` | `URL(fileURLWithPath:)` in three tests |
| §2.2 `@Check(\.field)` | `25d858d` | three documents; golden shapes are compiled fixtures, which caught four uncompilable `@Schema` argument orders on the spot |
| §2.1 `has no member '_assay'` | `25d858d` | 12 syntactic refusals + `_assayRequireJSON`/`Raw`; probe battery re-run, every row names what to do |
| §2.4 three error types | `4a094e0` | `AssayError` in AssayCore, thrown by the value models with the source; twins deleted |
| §2.3 `@Check` shapes | `e06fa0f` | parameter type, cross-field shape, unknown property |
| §1.5 BOM, §1.6 lone surrogate, §2.7 snippets, §2.10 `Hashable`, §2.5 `Assayer` text, §2.6 `@Key("")` | `e06fa0f` | all as specified; `invalid_escape` is a new named code |
| §1.7 duplicate keys | `e06fa0f` | already documented; the BOM row of the same table updated |
| §2.8 documentation | Phase F/G | `.spi.yml` lists AssayCore and AssayPlist; `Rule`, `RawValue` and all 102 issue codes documented (the codes from the message table: sentence + params) |
| §2.9 `ContextEntry` | Phase G | `Diagnosis(sink:value:source:sourceName:)` replaces 29 hand-spelled constructions; contextual `parse(mmapped:)` and `parse(body:)` added. `_decode` stays twice, with its recorded reason |
| §4 tidy-ups | Phase G | `LineIndex` internal in `Render.swift`; `isUnion` gone; `DiffFuzz [oracle…] \| --list`; the six narrow widths generated by `gen-decode-widths.sh` and diffed in CI |

683 tests; zero warnings; every gate passed.

## 6. Order of work (as written before the work)

1. §1.1 array/dictionary element cascade, §1.2 backticks, §1.3 `Assayer.map`, §1.4 my
   `@Preprocess` regression, §3.1 my Windows paths — **the bugs, half a day, one commit
   each or one commit together.**
2. §2.2 + §3.2 — the `@Check` spelling in three documents and the golden, with each golden
   source mirrored as a compiled fixture.
3. §2.1 — the refusal table for syntactic shapes, then `_assayRequire` for nominal types
   (measure the `arrays` arm before and after).
4. §2.4 — `AssayError` into `AssayCore`, three error types deleted.
5. §2.3, §2.5, §2.6, §2.7, §2.10, §1.5, §1.6 — an afternoon of small ones.
6. §2.8 — `.spi.yml`, then doc comments on `Rule` and `RawValue` first (the two types a
   user meets first), the rest as touched.
7. §2.9, §4 — the duplication and the tidy-ups.
