# Assay

**A decoder for Swift that tells you what went wrong.**

```swift
@Schema
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var tags: [String] = []
}

let article = try Article.parse(json: data)
```

No `CodingKeys`. No `Codable`. No rules, unless you want them — zero-rule `@Schema` is a
first-class mode, and Assay is a complete serde with no validation at all rather than an
on-ramp to one.

> **Status: built, tested and measured. Not released and not API-stable.**
> The API in `docs/EXPERIENCE.md` is implemented; [`ROADMAP.md`](ROADMAP.md) lists what is
> deliberately deferred, encoding included.

---

## Why

Foundation tells you a `String` was expected and an `Int` arrived, somewhere. Assay tells you
this:

```
deploy.json:3:13: error: replicas must be at least 1
  1 │ {
  2 │ "name": "api",
  3 │ "replicas": 0,
    │             ^
  4 │ "image": "registry.internal/api"

1 error
```

That output is a golden test, not a mock-up. Decoding failures and validation failures render
identically, because to the person reading them they are the same thing: the data is wrong, and
here is where.

And it is **faster** — not despite the error reporting but alongside it. Roughly **5–9×
Foundation** on the corpus below, from scalar Swift with no SIMD and no C.

---

## Install

```swift
.package(url: "https://github.com/<owner>/assay.git", from: "0.1.0")
```

```swift
.target(name: "App", dependencies: [
    .product(name: "Assay", package: "assay"),            // core + JSON
    .product(name: "AssayYAML", package: "assay"),        // optional
    .product(name: "AssayXML", package: "assay"),         // optional
    .product(name: "AssayFoundation", package: "assay"),  // Data/URL/mmap conveniences
])
```

Four products, so a JSON-only user never links a YAML parser. The core takes bytes, not `Data`,
and imports no Foundation. Swift 6.2+.

---

## The two verbs

```swift
let user = try User.parse(json: data)      // -> User, throws AssayError, warnings discarded
let d = User.diagnose(json: data)          // -> Diagnosis<User>
```

`parse` is for when a failure is exceptional. `diagnose` is for when it is expected — a form
submission, a config file, an upload:

```swift
d.value            // User?  — nil if invalid
d.issues           // [Issue] — every problem, not the first
d.warnings         // [Warning] — things that succeeded but you should know about
d.isValid
try d.get()        // the parse behaviour, when you change your mind
d.render(.terminal)
```

Assay walks the whole document. Twelve bad fields produce twelve issues, once.

### Issues are data

An `Issue` is a code plus parameters, never a rendered string:

```swift
Issue(code: .tooSmall, path: [.key("replicas")], params: ["min": .int(1)])
```

`.message` is derived on demand, and `message(locale:)` takes an identifier — so an API can
serialise the code for a client and render English into a log from the same value. Four
renderers ship: `.terminal` (carets, colour when the terminal supports it), `.plain`, `.json`,
and `.problemDetails` (RFC 9457).

---

## Validation

```swift
@Schema(keys: .snakeCase)
struct Signup {
    @Validate(.min(3), .max(20), .regex(#"^[a-z0-9_]+$"#)) var username: String
    @Validate(.email) var email: String
    @Validate(.min(12), "must be at least 12 characters") var password: String
    @Validate(.range(13...120)) var age: Int
    @Validate(.count(1...10), .each(.email)) var recipients: [String]
}
```

`Rule` is non-generic, so leading-dot syntax works with no type context to infer from — and
because it is `ExpressibleByStringLiteral`, a bare string in the list is a message override for
that attribute. Rules compose, and they are values:

```swift
extension Rule {
    static let companySlug = Rule.all(.min(3), .max(40), .regex("^[a-z][a-z0-9-]*$"))
}
```

The macro type-checks rules against field types **at expansion**:

```
error: rule '.email' applies to String, but 'age' is declared Int
```

`.email`, `.url`, `.uuid` and `.hostname` are hand-written byte validators — no regex engine, no
ICU, no locale, identical on every platform.

### Checks: validation with a debugger attached

```swift
@Schema
struct DateRange {
    var start: Int
    var end: Int

    @Check
    static func endAfterStart(_ r: DateRange, _ issues: inout Issues<DateRange>) {
        if r.end < r.start { issues.add("must be on or after start", at: \.end) }
    }
}
```

A real static function: real types, real breakpoints, its own unit tests. The keypath does real
work — the issue lands on `end`, carrying `end`'s path. There is a field form
(`@Check(\Signup.workEmail) static func f(_ email: String) -> String?`) and an `@AsyncCheck` for
database and network round trips, which makes `parse` async **by a compile-time count**, so
schemas that never need it never see an `await`.

> A `@Check` in an extension is a **compile error**. An attached macro cannot see extension
> members, so the check would silently never run; the attribute detects the placement and says
> so, rather than letting you find out in production.

### The five presence states

Missing, null, defaulted, salvaged and ignored are five different things, and Assay spells all
five:

```swift
var required: String              // must be present
var optional: String?             // may be absent or null
var withDefault: Int = 3          // absent -> 3, still validated
@Fallback(0) var salvaged: Int    // absent OR INVALID -> 0, with a warning, not re-validated
@Ignore var derived: String = ""  // never touched by decoding
```

### Preprocess and transform

```swift
@Preprocess(.trim, .lowercase) @Validate(.email) var email: String
@Transform({ (a: [String]) in Set(a) }) var tags: Set<String>
```

Preprocess normalises before rules run; transform changes the type after they pass. The order is
fixed and total: preprocess → coerce → decode → field rules → cross-field checks → transform →
async checks.

---

## Keys

```swift
@Schema(keys: .snakeCase, unknownKeys: .warn)
struct User {
    var displayName: String                                // display_name
    @Key("id") var identifier: String
    @Key("email", or: "email_address") var email: String    // warns which alias matched
    @Extras var rest: [String: RawValue]
}
```

Key conversion happens **at compile time, from the declared identifier**, so it round-trips
exactly. Foundation's `.convertFromSnakeCase` is lossy at runtime — `avatarURL` becomes
`avatar_url` becomes `avatarUrl`, and the field silently goes missing.

Unknown keys are a policy, not a fixed behaviour: `.ignore`, `.warn`, `.reject`, `.collect`. The
message carries a did-you-mean, using Damerau-Levenshtein distance so that transpositions — the
commonest typo there is — actually get suggested.

---

## One struct, several formats

Formats are opt-in per type, so nothing links a parser it does not use:

```swift
@Schema(formats: [.json, .yaml, .xml])
struct Config {
    var name: String
    var replicas: Int
}

try Config.parse(json: bytes)
try Config.parse(yaml: text)
try Config.parse(xml: bytes)
```

The YAML and XML parsers are hand-written, and each format keeps its own value model —
`JSON.Value`, `YAML.Node`, `XML.Node`. They are deliberately not unified behind one type: a
YAML scalar's resolution and an XML element's namespace are not the same kind of thing, and
pretending otherwise loses information. XXE is refused by construction; billion-laughs and alias
bombs are capped by budget.

---

## Performance

The design staked itself on a falsification condition written down in advance
(`docs/PERFORMANCE.md` §14): *if scalar Swift does not comfortably clear ZippyJSON's 1.38× over
Foundation, the thesis is wrong and the SIMD work is moot.*

| pass | vs Foundation | files |
|---|---|---|
| Struct decode (`@Schema` vs `Codable`) | **9.17×** mean | 25 |
| Prefix decode + unknown-key skip | **6.43×** mean | 45 |
| Generic value model (`JSON.Value` vs `JSONSerialization`) | **1.49×** mean | 75 |
| Falsification arm (API-shaped, 512 B – 64 kB) | **5.44×** mean | 5 |
| Float-dense (canada.json-shaped) | **8.64×** mean | 5 |

The thesis in one line: **the parser was never the bottleneck; the `Codable` container boundary
was.** ZippyJSON bolted simdjson — the fastest JSON parser in existence — onto `Decodable` and
got 1.38×. Apple's own prototype changes nothing about parsing, deletes only the container
protocol, and reports ~6×. Assay's macro deletes that boundary at compile time.

The generic-value row is the honest floor: a value model has no `Codable` boundary to remove, so
1.49× is what the scanner is worth on its own.

**Compile cost: ~84 ms per `@Schema` type** at 10 fields — 83–87 ms across runs, so it is a band
rather than a figure — gated in CI at 100 ms. `@Schema` is not free, and the number is published
rather than buried. It scales with generated body size, not with plugin round-trips.

**Allocations** are gated on absolute live-block thresholds: `arrays-of-scalars-8k` decodes to
exactly one exactly-sized `[Int]` with no doubling, and a six-field struct of short strings
allocates nothing at all, because those `String`s are small-form and immortal. The counter's
three limitations are documented at the top of
`Benchmarks/Sources/AssayBench/Allocations.swift` rather than hidden — read them before quoting
a number from it.

### What is *not* claimed

- Not "the fastest JSON decoder." Unqualified, unprovable, and false on some axis.
- Not compared against a SIMD decoder. Beating Foundation on float-dense input says nothing
  about simdjson or yyjson, which carry Eisel-Lemire. That comparison is owed, and it is where a
  loss is genuinely expected.
- Every number above is one arm64 macOS machine, warm, minimum of five rounds. None of them is a
  claim about another platform.
- Multi-megabyte documents are outside the target band and unmeasured.

---

## Correctness

| | |
|---|---|
| Unit tests | **196** in 25 suites |
| Differential | `JSON.Value` agrees with `JSONSerialization` value-for-value on all **75** positive corpus files |
| Fuzz | **9,680** deterministic mutations and truncations through all three parsers per run — no crash, no hang |
| Macro tests | expansion and diagnostic assertions, without XCTest |

The fuzzer earns its place: it found a YAML flow-collection hang (`[}]` looped forever appending
empty scalars, until the OOM killer arrived) within its first 466 inputs. Seeds and mutations are
SplitMix64 with a fixed seed, so any finding reproduces exactly, and
`DiffFuzz --probe yaml '<input>'` shrinks it.

---

## Platforms

| platform | status |
|---|---|
| macOS (arm64) | tested, benchmarked |
| Linux (x86-64, aarch64) | built and tested in CI |
| Static Linux SDK (musl) | cross-compiles clean, both architectures |
| WASI (wasm32) | cross-compiles clean |
| Windows | CI leg **enabled** (swiftlang's reusable workflow), never actually run — no remote yet, and it cannot be built from macOS |
| Android | not verified |

No `platforms:` clause, so no artificial floor. Embedded Swift is explicitly not a target. Every
build in CI passes `--explicit-target-dependency-import-check error`, which is how an undeclared
cross-module import gets caught rather than accidentally working.

---

## Documents

| file | what it is |
|---|---|
| [`docs/EXPERIENCE.md`](docs/EXPERIENCE.md) | the developer experience, end to end — the API spec |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | the runtime strategy and the falsification condition |
| [`docs/COMPILE-TIME.md`](docs/COMPILE-TIME.md) | the second performance axis, and the CI gate |
| [`docs/VALUE-MODELS.md`](docs/VALUE-MODELS.md) | why JSON, YAML and XML keep separate value types |
| [`docs/STREAMING.md`](docs/STREAMING.md) | why streaming is out of scope, and what it would cost |
| [`ROADMAP.md`](ROADMAP.md) | what is deferred, and why |
| [`CLAUDE.md`](CLAUDE.md) | settled decisions and hard constraints on generated code |
| [`LICENSE`](LICENSE) / [`NOTICE`](NOTICE) | Apache 2.0, and third-party attribution |
| [`docs/research/`](docs/research/) | the seven research passes the above were built from |

Every research file ends with an explicit **"do not assert these"** section. Where a research
file and an experiment disagree, the experiment wins.

---

## Reproduce

```sh
swift test                                          # 196 tests

cd Benchmarks
swift run -c release CorpusGen                      # 81-file corpus, deterministic
swift run -c release AssayBench                     # full sweep + allocation gate
swift run -c release DiffFuzz                       # differential + fuzz

Experiments/01-jump-table/sweep.sh                  # does dispatch reach a jump table?
Experiments/03-compile-time/gate.sh                 # compile-time budget gate
```

---

## Licence

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

Apache 2.0 rather than MIT for one reason that matters to anyone shipping this inside a product:
**it grants patent rights explicitly, and terminates them for anyone who sues over them.** MIT is
silent on patents, which leaves a downstream user relying on an implied licence that has never
been tested. Apache also requires that modified files say they were modified, which keeps
provenance intact when a file is copied out of the tree rather than depended on.

Contributions are inbound=outbound under section 5 of the licence: anything you submit is offered
under the same terms, and there is no separate CLA to sign.

The one dependency, `swift-syntax`, is Apache 2.0 with the Runtime Library Exception, and is a
build-time dependency of the macro plugin only — it is not linked into a client binary.
