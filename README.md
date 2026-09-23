# Assay

**A decoder for Swift that tells you what went wrong.**

Foundation tells you it expected an `Int` and found a `String`. Somewhere. Good luck.

Assay tells you this:

```
deploy.json:3:15: error: replicas must be at least 1
  1 │ {
  2 │   "name": "api",
  3 │   "replicas": 0,
    │               ^
  4 │   "image": "registry.internal/api"

1 error
```

That is real output, not a mock-up — this repository's CI regenerates every render in its
documentation from the library and fails if one drifts. Decode failures and validation
failures look identical on purpose: to the person reading them, they are the same problem.

> **0.1.0 — built, tested, measured, released for early adopters.** A `0.x` minor may change
> the API and [`CHANGELOG.md`](CHANGELOG.md) says when. [`ROADMAP.md`](ROADMAP.md) lists what
> is deliberately not here, with reasons.

📖 **[assay.nerdmenot.in](https://assay.nerdmenot.in)** — guides, recipes, and a page per
format. This file is the version for people who would rather stay in the terminal.

---

## Install

```swift
.package(url: "https://github.com/nerdmenot-swift/assay.git", from: "0.1.0")
```

```swift
.target(name: "App", dependencies: [
    .product(name: "Assay", package: "assay"),     // the macro + JSON
])
```

`AssayYAML`, `AssayXML`, `AssayTOML`, `AssayPlist` and `AssayFoundation` are separate
products, so a JSON-only app never links a YAML parser. Swift 6.2+, no runtime dependencies.

## Sixty seconds

Mark a struct. That is the setup.

```swift-check
@Schema
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var tags: [String] = []
}

let article = try Article.parse(json: data)
```

No `CodingKeys`. No `init(from:)`. No conformance to write. Zero-rule `@Schema` is a
first-class mode — Assay is a complete serde that happens to do validation, not a validator
that grudgingly decodes.

Two verbs, and which you want depends on who reads the failure:

```swift-check
@Schema struct User { var id: Int }

// Throws. For code that wants a value or an error.
let user = try User.parse(json: data)

// Never throws. For code that wants to SHOW someone what happened.
let d = User.diagnose(json: data)
if let value = d.value { _ = value }
for issue in d.issues { print(issue.message) }
```

`parse` belongs in a network layer. `diagnose` belongs behind a form, a config loader or a
CLI — anywhere a human reads the result.

### Issues are data, not strings

```swift-check
@Schema struct Signup { @Validate(.min(3)) var username: String }

for issue in Signup.diagnose(json: data).issues {
    _ = issue.code        // .tooSmall — stable, matchable, never a sentence
    _ = issue.path        // [.key("username")]
    _ = issue.params      // ["minimum": .int(3), "unit": .string("characters")]
    _ = issue.location    // the byte span, for the caret
    _ = issue.message     // derived when you ask, never stored
}
```

Match on the code, render your own words, interpolate the params. The English is a
convenience, not the API.

## What you stop writing

| Codable | Assay |
|---|---|
| `enum CodingKeys: String, CodingKey` | `@Schema(keys: .snakeCase)` — at compile time, losslessly |
| `init(from:)` for one default | `var retries: Int = 3` |
| `decodeIfPresent` | `var nickname: String?` |
| A validation pass after decoding | `@Validate(.email)`, `@Check` — same pass, same errors |
| A second model for YAML | `@Schema(formats: .all)` |
| `try/catch` around the first failure | every failure at once, each at its byte |

Five presence states, five spellings, and three of them need no attribute at all:

```swift-check
@Schema
struct Account {
    var id: Int                     // required — absent is an error
    var nickname: String?           // absent → nil
    var retries: Int = 3            // absent → 3; present is still validated
    @Fallback(0) var score: Int     // absent OR invalid → 0, with a warning
    @Ignore var cache: String?      // not a field
}
```

## Not only JSON

One declaration, five formats, one set of rules, one kind of error:

```swift-check
@Schema(keys: .snakeCase, formats: .all)
struct Config {
    var name: String
    @Validate(.min(1)) var replicas: Int
}
```

| Format | Product | Notes |
|---|---|---|
| JSON | `Assay` | straight from bytes into your struct — the fast path |
| YAML 1.2 | `AssayYAML` | hand-written, anchors and aliases, no libyaml to vendor |
| XML | `AssayXML` | XXE refused by construction, not by a flag |
| TOML 1.0.0 | `AssayTOML` | 710/710 on the official test suite |
| Property lists | `AssayPlist` | binary and XML |
| HTTP bodies | — | `parse(body:contentType:accepting:)`, RFC 9110 negotiation |

Carets work on all of them, because the spans come from the parsers.

## Speed, with receipts

The thesis in one line: **Assay does not need to beat simdjson, it needs to not have a
`KeyedDecodingContainer`.** Roughly 83% of a Swift decode is the Codable boundary, and a
macro deletes it at compile time.

| Arm | Against | |
|---|---|---|
| Struct decode, 25 files | `JSONDecoder` | **9.14×** |
| YAML struct decode | Yams `YAMLDecoder` | **18.20×** |
| Encoding, 50 items | `JSONEncoder` | **8.75×** |
| vs ZippyJSON (simdjson + Codable) | ZippyJSON | **3.61×** |
| `T.validate(_:)` | — | **37 ns**, one allocation |
| Compile time, 10 fields | `Codable` | 81 ms/type, ~4× |

One arm64 Mac, warm, `-O`, minimum of five rounds. **Where it loses is published too**:
0.69× yyjson on the use-case shape, 0.16× building a tree, and XML is 2.47× Foundation on
macOS but 0.96× on Linux where `FoundationXML` is libxml2. A benchmark page that lists only
its wins is an advertisement.

Full table, method and caveats: [`Benchmarks/RESULTS.md`](Benchmarks/RESULTS.md).

## How it is checked

This is the part the author enjoys more than is strictly healthy.

- **825 tests**, 141 suites, 87% line coverage.
- **Differential oracles** — every format decoded twice, once by Assay and once by the
  incumbent: `JSONSerialization`, Yams/libyaml, Foundation's `XMLParser`, toml++,
  `PropertyListDecoder`. Disagreement fails the build. Two real parser bugs found on the
  first run.
- **710/710** on the official `toml-test` suite; 2,279 instants bit-exact against Foundation
  for dates.
- **A fuzzer that asserts laws**, not just the absence of crashes: 12,680 mutated and
  truncated documents, 55,905 generated decodes checked against three invariants.
- **Exact counters.** Every matrix cell runs under Callgrind and DHAT on x86-64 and arm64,
  every push, counting instructions, retains, releases, allocations and uniqueness checks per
  call. An allocation that appears where there was none fails CI. Wall clock is never gated —
  it is a flaky test with extra steps.
- **A static ARC audit** comparing retain/release *sites* against a golden, because a release
  on an error path costs nothing at run time and still costs code size.
- **Amplification tests** with stated budgets: billion laughs, alias bombs, plist reference
  cycles, 10<sup>30</sup>-node shared-object graphs under a kilobyte.

If that sounds excessive for a decoder: a decoder is a thing that reads bytes an attacker
chose.

## Platforms

| | |
|---|---|
| Test suite runs | macOS, Linux (x86-64 + aarch64), Windows |
| Builds | iOS, tvOS, watchOS, visionOS, static-musl Linux, wasm32 |

Every libc call is behind `canImport`, and the parsers are hand-written Swift with nothing to
vendor — which is why that list is as long as it is. Android is not a target.

## Documents

Start at the [website](https://assay.nerdmenot.in) if you want prose and examples. These are
the ones worth reading in the repository:

| | |
|---|---|
| [`docs/EXPERIENCE.md`](docs/EXPERIENCE.md) | the API, and the argument for every part of it |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | the strategy, and what was retired unbuilt |
| [`docs/EFFICIENCY.md`](docs/EFFICIENCY.md) | the ledger: one row per idea, decided by a counter |
| [`docs/COMPILE-TIME.md`](docs/COMPILE-TIME.md) | why build time is a gate and not a footnote |
| [`docs/ENCODING.md`](docs/ENCODING.md) | round-trip as a law, with a closed exception list |
| [`docs/VALIDATE.md`](docs/VALIDATE.md) · [`UNIONS.md`](docs/UNIONS.md) · [`TOML.md`](docs/TOML.md) · [`PLIST.md`](docs/PLIST.md) · [`ASSAYER.md`](docs/ASSAYER.md) | one feature each, in depth |
| [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md) | what each parser accepts and refuses, and how that is held |
| [`docs/VALUE-MODELS.md`](docs/VALUE-MODELS.md) | five value models and why they are not one |
| [`docs/STREAMING.md`](docs/STREAMING.md) | why streaming is out of scope, in full |
| [`Benchmarks/RESULTS.md`](Benchmarks/RESULTS.md) | every measurement, with the mistakes made getting there |
| [`ROADMAP.md`](ROADMAP.md) | what is deferred, what was removed, and why |

`docs/research/` holds the seven pre-implementation research passes. They are a historical
record, each ending in an explicit "do not assert these" list, and several of their premises
have since been measured false — read them as archaeology, not as documentation.

## Reproduce anything

```sh
swift test                                    # 825 tests
cd Benchmarks
swift run -c release CorpusGen                # the corpus, deterministic
swift run -c release AssayBench --list        # every arm
swift run -c release DiffFuzz                 # oracles + fuzz
./count.sh                                    # exact counters, in a container
```

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md) has the shape of a change that gets merged. The short
version: a claim needs a number, a bug needs a failing test first, and if you make something
faster the counters have to agree with you.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
