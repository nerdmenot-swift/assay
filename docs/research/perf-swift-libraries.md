# Swift Decoding Performance Audit — Where the Time Actually Goes

Research date: 2026-07-25. No Swift toolchain available; nothing here was compiled or
benchmarked locally. Every claim is labelled **VERIFIED** (I read the source, or it is a
primary published measurement I read in full) or **UNVERIFIED** (inference, secondhand, or
claim without accessible evidence).

Clones live under `/home/claude/research/` and `/home/claude/research/libs2/`.

---

## 0. Executive summary

Two findings dominate everything else, and they say the same thing from opposite directions.

1. **ZippyJSON bolted simdjson — the fastest JSON parser in existence — onto Codable and got
   1.38x average, 1.04x on the most API-shaped payload.** Not 10x. Not 4x. The parser was
   never the bottleneck; the Codable container boundary was. (§3)
2. **Foundation's JSONDecoder in 2026 is a genuinely good lazy scanner whose laziness is
   thrown away the instant Codable asks for a keyed container.** `KeyedContainer.stringify`
   eagerly builds `[String: JSONMap.Value]` — a Swift `String` allocated for every key in
   every object, read or not. Apple's own fix is not to optimise this; it is a 6x rewrite
   that replaces `Decodable`. (§1)

Assay's thesis — that a macro can beat the ecosystem by deleting the container boundary
rather than by parsing faster — is supported by the strongest available adversarial
evidence.

---

## 1. swift-foundation's JSONDecoder, 2026 state

Clone: `/home/claude/research/swift-foundation`, HEAD `af8c8086`, fetched 2026-07-24.
**Shallow clone (depth 1)** — `git rev-parse --is-shallow-repository` → `true`. No local
git archaeology was possible; PR history came from `api.github.com/search/issues` and
individual PR pages via WebFetch.

Source: `Sources/FoundationEssentials/JSON/` —
`BufferView.swift` (427 lines), `BufferViewCompatibility.swift` (59),
`BufferViewIndex.swift` (52), `BufferViewIterator.swift` (52), `JSON5Scanner.swift` (1250),
`JSONDecoder.swift` (1944), `JSONEncoder.swift` (1588), `JSONScanner.swift` (1391),
`JSONWriter.swift` (352).

### 1.1 Architecture: scanner + index, not parse-to-tree — VERIFIED

`JSONScanner.swift:14-53` documents it directly:

> "A JSONMap is created by a JSON scanner to describe the values found in a JSON payload,
> including their size, location, and contents, **without copying any of the non-structural
> data**. It is used by the JSONDecoder, which will fully parse only those values that are
> required to decode the requested Decodable types. To minimize the number of allocations
> required during scanning, the map's contents are implemented using an array of integers…"

- `JSONScanner.swift:66-100` — `internal class JSONMap`, with
  `enum TypeDescriptor: Int { case string, number, null, true, false, object, array,
  collectionEnd, simpleString, numberContainingExponent }`. Object layout is
  `[marker, nextSiblingOffset, count, <keys and values>, .collectionEnd]`. Backing store is
  `let mapBuffer: [Int]`; the source bytes sit behind
  `let dataLock: Mutex<(buffer: BufferView<UInt8>, allocation: UnsafeRawPointer?)>`.
- `JSONScanner.swift:181-197` — `offset(after:)` reads `mapBuffer[previousValueOffset + 1]`
  for collections. **O(1) subtree skip.** This is the same trick as simdjson's tape and
  IkigaJSON's `totalIndexLength`.
- `JSONScanner.swift:275-338` — `JSONPartialMapData.resizeIfNecessary` extrapolates the
  final map size from the consumption ratio every 2048 entries, so growth is amortised
  rather than doubling blindly.
- `JSONScanner.swift:377-382` — after the scan,
  `if case .number = map.loadValue(at: 0)! { map.copyInBuffer() }`. A full input copy, but
  only for top-level-number payloads, so `strtod` cannot overrun the buffer.

**Anything claiming Foundation converts JSON to `NSDictionary` via `NSJSONSerialization` is
describing a 2019 codebase.** That has not been true since ~2021 on Linux and ~2023 on
Darwin. ZippyJSON's README still says it (§3.4).

### 1.2 String handling — VERIFIED

`JSONScanner.swift:895-930`. The fast path scans for
`byte != ._backslash && _fastPath(byte & 0xe0 != 0)`, then calls `String._tryFromUTF8(...)`
over the contiguous run; `if _fastPath(index == endIndex) { return output }`. If an escape
is hit it falls into `_slowpath_stringValue`, which does `output += stringChunk` per chunk —
i.e. **escaped strings cost one String append per escape run**. `twitterescaped.json` in the
shared corpus exists precisely to exercise this.

### 1.3 Number parsing — VERIFIED

- `JSONScanner.swift:1050` `prevalidateJSONNumber` — validates shape before conversion.
- `JSONScanner.swift:1184` — `Platform.strtod_clocale(nptr, &endPtr)` for `Double`.
  **Not Eisel-Lemire.** This is the single biggest remaining algorithmic gap versus
  simdjson/yyjson on float-heavy payloads (canada.json is 111,126 numbers).
- `JSONScanner.swift:1212` — `_parseInteger<Result: FixedWidthInteger>`, hand-rolled, fine.
- `JSONDecoder.swift:964` and `:986` carry the comment: *"setting errno to 0 first and then
  check the result is surprisingly expensive."*
- `JSONDecoder.swift:1062-1067` — `_slowpath_unwrapFixedWidthInteger`: *"This is the slow
  path… For example for `"34.0"` as an integer, we try to parse as either a `Decimal` or a
  `Double` and then convert back, losslessly."*
- `JSONDecoder.swift:804` — `// TODO: Proper handling of Infinity and NaN Decimal values.`
- `JSON5Scanner.swift:1114` — `//FIXME: any reason not to add a fast-path as in
  JSONScanner's version?` (JSON5 has no string fast path at all.)

### 1.4 THE CRUX: laziness is discarded at the Codable boundary — VERIFIED

`JSONDecoder.swift:1259-1321`:

```swift
struct KeyedContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    let impl: JSONDecoderImpl
    let codingPathNode: _CodingPathNode
    let dictionary: [String:JSONMap.Value]

    static func stringify(objectRegion: JSONMap.Region, using impl: JSONDecoderImpl,
                          codingPathNode: _CodingPathNode,
                          keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy)
                          throws -> [String:JSONMap.Value] {
        var result = [String:JSONMap.Value]()
        result.reserveCapacity(objectRegion.count / 2)
        var iter = impl.jsonMap.makeObjectIterator(from: objectRegion.startOffset)
        switch keyDecodingStrategy {
        case .useDefaultKeys:
            while let (keyValue, value) = iter.next() {
                let key = try impl.unwrapString(from: keyValue, for: codingPathNode,
                                                _CodingKey?.none)
                result[key]._setIfNil(to: value)
            }
        ...
    }
    init(impl: JSONDecoderImpl, codingPathNode: _CodingPathNode,
         region: JSONMap.Region) throws {
        self.dictionary = try Self.stringify(objectRegion: region, using: impl,
                                             codingPathNode: codingPathNode,
                                             keyDecodingStrategy: impl.options.keyDecodingStrategy)
    }
    var allKeys: [K] { self.dictionary.keys.compactMap { K(stringValue: $0) } }
    func contains(_ key: K) -> Bool { dictionary.keys.contains(key.stringValue) }
}
```

Lookup is `dictionary[key.stringValue]` at `JSONDecoder.swift:1522` and `:1532`.

Per object decoded, unconditionally: **one Dictionary allocation, one Swift String
allocation per key present in the payload (not per key the type wants), one hash per key at
insert, one `key.stringValue` String materialisation per field read, one hash per lookup.**
A struct that reads 3 fields out of a 40-field object pays for all 40.

This is the exact structural cost Kevin Perry describes in §2, in Apple's own words, and it
is why `JSONMap`'s beautiful zero-copy design does not translate into proportional wins.

### 1.5 codingPath — VERIFIED

`Sources/FoundationEssentials/CodableUtilities.swift:32-82`:

```swift
// This construction allows overall fewer and smaller allocations as the coding path is modified.
internal enum _CodingPathNode : Sendable {
    case root
    indirect case node(CodingKey, _CodingPathNode, depth: Int)
    indirect case indexNode(Int, _CodingPathNode, depth: Int)
    var path : [CodingKey] {
        switch self {
        case .root: return []
        case let .node(key, parent, _): return parent.path + [key]
        case let .indexNode(index, parent, _): return parent.path + [_CodingKey(index: index)]
        }
    }
    @inline(__always) func appending(_ key: __owned (some CodingKey)?) -> _CodingPathNode { ... }
    @inline(__always) func path(byAppending key: __owned (some CodingKey)?) -> [CodingKey] { ... }
}
```

Foundation already optimised this from an eager `[CodingKey]` to an indirect-enum linked
list — one boxed node per level instead of an array copy per level. `parent.path + [key]` is
**O(depth²) allocations** but only fires when a path is materialised, i.e. on a thrown
`DecodingError`.

Apple still considers this insufficient. Issue **#1826 "Investigate different CodingPath
tracking implementation"** (kperryua, OPEN): *"Tracking a coding path has historically been
more expensive than desirable. In nominal cases, the coding path is never consulted on
either the encoding or the decoding side."* — VERIFIED.

**Assay lesson:** do not track a coding path eagerly. Reconstruct it only on the error path.

### 1.6 PR #1481 — the +52.6% — VERIFIED, with a correction

"Improve performance of JSONDecoder and JSONEncoder for large apps", author `ChrisBenua`,
opened 2025-08-27, merged 2025-09-30, merge commit
`97b45811ff58a3484dbde7b1d6023816bafa7a2c`, approved by `kperryua`. Companion issue #1480.
Production telemetry from ~80,000 devices:

| | p25 | p50 | p75 |
|---|---|---|---|
| JSONDecoder | 282→133 ms (52.8%) | **422→200 ms (52.6%)** | 667→322 ms (51.7%) |
| JSONEncoder | 94→30 ms (68.0%) | 159→73 ms (54.0%) | 289→135 ms (53.2%) |

**Correction to prior notes: the casts removed were not `DecodableWithConfiguration`.** They
were three private marker protocols: `T.self is _JSONStringDictionaryDecodableMarker.Type`,
`value as? _JSONStringDictionaryEncodableMarker`, and `value as? _JSONDirectArrayEncodable`.

Mechanism — this is the part that matters: the hot symbol was
**`swift_conformsToProtocolMaybeInstantiateSuperclasses`, ≥84% of decode/encode time** at
cold start. On a cache miss the runtime linearly scans every conformance descriptor in the
binary's `__swift5_proto` section. The reporting app had **>150,000 conformances**. Each
synthesized `CodingKeys` enum contributes ~1.8 KB of metadata; a 10,000-struct test binary
went 49 MB → 31.1 MB and 70,321 → 20,321 descriptors when `CodingKeys` were removed.

The fix, at `JSONDecoder.swift:673`, is to test the cheap thing first:
`if !options.keyDecodingStrategy.isDefault, T.self is _JSONStringDictionaryDecodableMarker.Type {`
(the `isDefault` helper is at `:1930`).

**Critical caveat: this is a once-per-(type, protocol)-pair cold cost, not a per-call cost.**
ChrisBenua, verbatim: *"swift_conformsToProtocol method works really slow only for the first
time for each pair of arguments."* It amortises to ~0 in a hot loop. Issue #1480 says so
about Apple's own harness: *"The Swift Foundation repository's JSONBenchmark repeats
operations 1 billion times without app restart, masking swift_conformsToProtocol overhead."*

**Assay lesson, and it is a big one:** every macro-synthesized conformance you emit adds to
`__swift5_proto` and taxes *every other* dynamic cast in the host app. A macro decoder that
emits fewer conformances than Codable (no `CodingKeys` enum, no `Decodable` witness) is
faster at cold start *for reasons unrelated to parsing*, and that win is invisible to any
steady-state benchmark. This is also a marketing angle nobody in the ecosystem has taken.

### 1.7 The rest of the Foundation perf PR history — VERIFIED

- **#30** (2023-04-14, parkera) "Use polymorphism instead of a dynamic cast" — no numbers.
- **#35** (2023-04-18, iCharlesHu) "JSON Performance Improvements" — no numbers in body.
- **#1006** (2024-10-25, kperryua) "Fix JSONEncoder performance regression in 6.0 toolchain":
  Canada-encode 15 → 13 → **20 it/s**; Twitter-encode 549 → 353 → **658 it/s**.
- **#1012** (2024-10-28, kperryua) follow-up.
- **#1481** (2025-09-30) — §1.6.
- **#1593** (2025-12-12, ChrisBenua) "JSONEncoder: fixed `_asDirectArrayEncodable`" —
  **#1481 shipped broken.** It referenced `self.array` (a `JSONFuture.RefArray`) instead of
  the `value` parameter, so every `_specialize` failed and the fast path was dead from
  2025-09-30 to 2025-12-12. The fix measured **92% time reduction, >1000% throughput**.
  *Any Assay baseline measured against a toolchain from that window is suspect.*
- **#1820** (2026-03-16, kperryua) "Un-inline `_grow`" — *"about 20 MB/s boost in the Twitter
  encode benchmark"*.
- **#1853** (2026-03-27) — SIGTRAP from stale `sharedSubEncoder` state; a correctness bug
  *caused by* the encoder-pooling optimization. Pooling decoder state is a known hazard.
- 2026 in-flight: #1913, #1912, #1930, #1963–#1973 (including **#1972 "Remove dynamic casts
  of floating point values"**, motivated by Embedded Swift rather than perf), #2072, and
  **#2074 "NewCodable runtime fails to build with swift-DEVELOPMENT-SNAPSHOT-2026-06-24-a"
  (OPEN)**.

### 1.8 Apple's actual answer: replace Codable — VERIFIED

Kevin Perry, "New Codable prototype available for feedback", 2026-03-06,
https://forums.swift.org/t/new-codable-prototype-available-for-feedback/85186 :

> "When decoding `twitter.json`, I personally observe that `JSONDecodable` and
> `JSONParserDecoder` provide a throughput improvement of approximately **6x** over
> `Decodable` and `JSONDecoder`!"

Same parser, same payload, same machine, same team — the only variable removed is the
Codable container protocol. **~83% of current decode time on twitter.json is Codable
structural overhead.** This is the single most useful number in this entire document, and it
is Apple measuring Apple.

It lives on branch `experimental/new-codable`. VERIFIED absent from the shipping tree: no
`*NewCodable*` or `*NewJSON*` files exist anywhere in the clone. Build-broken as of #2074.

Related open issues, all kperryua, all OPEN:
- **#1826** — coding path tracking (quoted §1.5).
- **#1827 "Break assumptions on full input residency"** — no streaming today; cites serde's
  `DeserializeOwned` as prior art.
- **#1823 "Figure out NewJSON*/Foundation relationship/split"** — the overlay-module
  alternative was rejected because it *"lacks encoder/decoder-global strategy storage without
  introducing type-erasure and dynamic casts—problematic for Embedded Swift and
  performance."*
- Plus #1832, #1833, #1834, #1835, #1837, #1838, #1839, #1849.

### 1.9 The remaining known-slow parts of Foundation's JSONDecoder in 2026

Ranked, all VERIFIED as present in source; relative magnitudes UNVERIFIED:

1. `KeyedContainer.stringify` eager String+Dictionary materialisation (§1.4). Structural,
   cannot be fixed without changing Codable — which is why Apple is changing Codable.
2. Existential boxing of `Decoder`/`KeyedDecodingContainer` and dynamic dispatch per field.
3. `strtod_clocale` instead of Eisel-Lemire for `Double` (`JSONScanner.swift:1184`).
4. **`.iso8601` date decoding — `JSONDecoder.swift:707` builds a full Swift `String` then
   calls `Date.ISO8601FormatStyle().parse(string)` per value.** For realistic API payloads
   full of timestamps this is plausibly the largest *unmeasured* cost in the whole decoder;
   no benchmark in any harness surveyed (§7) contains a single date. **Highest-value target
   nobody has measured.**
5. `_slowpath_unwrapFixedWidthInteger` round-tripping `"34.0"` through Decimal/Double.
6. `_slowpath_stringValue` String append per escape run.
7. Cold-start `swift_conformsToProtocol` residue (§1.6) — reduced, not eliminated.

---

## 2. The Codable tax, quantified

### 2.1 The primary source — VERIFIED, verbatim

Kevin Perry, "The future of serialization & deserialization APIs", 2025-03-17,
https://forums.swift.org/t/the-future-of-serialization-deserialization-apis/78585

> "Even with all of its strengths, the existing API's design has some unavoidable
> performance penalties. For instance, its use of existentials implies additional runtime
> and memory costs as existential values are boxed, unboxed, retained, released, and dynamic
> dispatch is performed."

> "because a client can decode dictionary values in arbitrary orders, a
> `KeyedDecodingContainer` is effectively required to proactively parse the payload into some
> kind of intermediate representation, necessitating allocations for internal temporary
> dictionaries, and `String` values."

> "ALL containers need to do this because some `Decodable` types retain the decoder or one of
> its containers after `init(from:Decoder)` returns to perform deferred decoding — which was
> not an intended usage of the interface."

> "Dynamic casting is prevalent in both Property List and JSON encoders and decoders… These
> dynamic casts are unavoidable with the existing design and have a measurable impact on
> performance."

The second and third quotes are the load-bearing ones: Apple states that the eager
stringification in §1.4 is **required by the protocol contract**, not a Foundation
implementation choice. A macro that generates a direct `init` from a scanner index is not
bound by that contract, because there is no container to hand out and nothing for a client
type to retain.

### 2.2 What I could NOT verify

I searched that thread for "module boundary", "resilien", "inlinable", and "witness table".
**None appear.** kperryua's use of "specialization" throughout means *format*-specialization
(a decoder specialized to JSON), not generic specialization across a resilience boundary.

**The claim "`Decodable.init(from:)` is non-specializable across module boundaries" is
therefore UNVERIFIED and must not be asserted.** It is plausible from first principles (a
non-`@inlinable` protocol witness in a resilient module cannot be specialized by the
optimizer), but I found no measurement isolating it and no Apple statement making it.

### 2.3 The Vapor comment — VERIFIED verbatim

`/home/claude/research/libs/vapor4/Sources/Vapor/Validation/Validations.swift:91-94`
(repo HEAD `3636f443`, 2025-07-14):

```swift
/// N.B.: The only reason we need all this is that "top-level" decoders like JSONDecoder etc. do not actually conform to
/// Decoder, so we can only invoke our logic from the other end of Codable. And the only way to pass the validation set
/// through is via Codable's oft-ignored userInfo mechanism. (Ideally, we'd flip things around and do some magic with
/// _En_coder instead, but we can't do that without breaking public API.)
```

This is load-bearing for Assay's argument in a way that has nothing to do with speed. The
largest server framework in the Swift ecosystem cannot hook the top of a decode. `JSONDecoder`
is not a `Decoder`; `Decoder` only exists *inside* a decode, handed to `init(from:)`. So
Vapor smuggles a validation set through `userInfo` — an untyped `[CodingUserInfoKey: Any]`
dictionary, i.e. existential boxing on every access — and wraps the real type in a
`ValidationsExecutor: Decodable` shim purely to get a callback at the right moment.

**Every validating decoder in Swift is built on this workaround.** Assay, by owning both
ends, does not need it. This is a correctness/ergonomics argument, and it is stronger than
the perf argument because it is not a matter of degree.

### 2.4 The "Codable is slow" threads — mostly not usable as evidence

https://forums.swift.org/t/rearchitecting-jsonencoder-to-be-much-faster/28139 (2019) is
**weak evidence and should not be cited for structural claims.** VERIFIED contents:

- Michael Eisel: "ZippyJSON *decodes* at 4-5x the speed of JSONDecoder", and elsewhere "at
  least 3x". No payload sizes, no methodology, no allocation counts.
- David Smith (Apple): "roughly a 1.5x speedup" attributed to Swift/ObjC bridging.
- Jon Shier: "embarrassingly slow". Qualitative.

Eisel's three named bottlenecks — intermediate ObjC structures, a `String` conversion per
key, libc number formatting — are all artifacts of the pre-2021 `NSJSONSerialization`
architecture and are **all obsolete**. Critically: **no participant in that thread discussed
existentials, codingPath, dynamic casts, or `KeyedDecodingContainer`'s contract.** The
modern understanding of the Codable tax dates from Perry's 2025 post, not from 2019.

Use §2.1 and §1.8. Discard §2.4.

---

## 3. ZippyJSON — simdjson + Codable, and why it did not win

Clone: `/home/claude/research/libs2/ZippyJSON`, HEAD `420517819`, 2025-09-07
("Faster protocol conformance (#72) — From #71 by Chris Benua").
C family: `/home/claude/research/libs2/ZippyJSONCFamily`.

**This is the most important section in the document.** ZippyJSON is the perfect natural
experiment: hold the Codable interface constant, swap in the fastest JSON parser on Earth,
and measure. If parsing were the bottleneck, ZippyJSON would have won by an order of
magnitude and Foundation would have adopted it. Neither happened.

### 3.1 The measured result — VERIFIED

`/home/claude/research/libs2/ReerJSONBenchmark/Benchmark/results/macOS_15.6.1_Apple_M4_Pro_24G_mac_mini.txt`,
1000 iterations per dataset:

| Dataset | Size | ReerJSON | ZippyJSON | Foundation | IkigaJSON |
|---|---|---|---|---|---|
| GitHub Events | 65,132 B | 0.630 ms **1.24x** | 0.750 ms **1.04x** | 0.779 ms 1.00x | 5.047 ms 0.15x |
| Twitter | 631,515 B | 0.996 ms **2.26x** | 1.359 ms **1.65x** | 2.246 ms 1.00x | 5.251 ms 0.43x |
| Apache Builds | 127,275 B | 0.406 ms **1.95x** | 0.558 ms **1.42x** | 0.791 ms 1.00x | 1.681 ms 0.47x |
| Random Data | 510,476 B | 2.764 ms **1.91x** | 3.547 ms **1.49x** | 5.285 ms 1.00x | 10.240 ms 0.52x |
| Canada | 2,251,051 B | — | fastest (32.9 ops/s) | — | — |

**Overall: ReerJSON 1.71x avg, ZippyJSON 1.38x avg, Foundation 1.00x, IkigaJSON 0.43x.**

Note the shape of the result: ZippyJSON's advantage *shrinks as payloads get more
API-shaped and smaller*. On GitHub Events — 63.6 KB, 114 unique keys, the most realistic
API response in the corpus — simdjson buys **4%**.

Harness caveats (VERIFIED by reading it): built on the unmaintained google/swift-benchmark
plus hand-rolled `CFAbsoluteTimeGetCurrent()` deltas; in-source comment *"Same timing logic
as SwiftYYJSONBench — no warmup, simple loop."* Mean only, no percentiles, no malloc counts.
Smallest payload 64 KB. So treat the absolute milliseconds loosely — but the *ordering* and
the *magnitude of the ratio* are robust, and they are corroborated by ZippyJSON's own README
(§3.4).

### 3.2 Why it did not win — visible in source, VERIFIED

`Sources/ZippyJSON/ZippyJSONDecoder.swift` (1069 lines):

**(a) A String and a C string materialised at every single field access.** Line 882-886 and
every `decode(_:forKey:)` from `:901`:

```swift
func contains(_ key: K) -> Bool {
    return key.stringValue.withCString { pointer in
        return JNTDocumentContains(value, pointer, &iterator)
    }
}
@inline(__always) fileprivate func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 {
    let subValue: Value = try key.stringValue.withCString(fetchValue)
    return try decoder.unbox(subValue, as: UInt8.self, key: key)
}
```

`key.stringValue` on a synthesized `CodingKeys` enum returns a fresh `String`;
`withCString` then produces a NUL-terminated buffer. Per field. simdjson underneath cannot
help with work done above it.

**(b) The lookup is a linear scan.** `ZippyJSONCFamily/Sources/ZippyJSONCFamily/JSONSerialization.mm:479-510`:

```cpp
simdjson_result<dom::element> JNTDocumentFindValue(JNTDecoder decoder, const char *cKey,
                                                   JNTDictionaryIterator *iteratorPtr) {
    auto iterator = *iteratorPtr;
    std::string_view key = cKey;
    const auto searchStart = iterator;
    const dom::object &object = decoder.element;
    const auto &end = object.end();
    ...
    while (iterator != end) { if (key == iterator.key()) { child = iterator.value(); found = true; break; } ++iterator; }
    if (!found) { iterator = object.begin(); while (iterator != searchStart) { ... } }
    if (!found) { return simdjson_result<dom::element>(NO_SUCH_FIELD); }
```

A rotating linear probe — start where the last hit left off, wrap around. Same idea as
IkigaJSON's last-hit cache. No hashing. O(fields²) per object when the payload order does not
match the declaration order.

**(c) `codingPath` is a real array.** `ZippyJSONDecoder.swift:298-329`,
`final private class __JSONDecoder: Decoder` with `var codingPath: [CodingKey] = []`,
pushed and popped per nesting level. Foundation's `_CodingPathNode` is strictly better.

**(d) The container cache was turned off.** `ZippyJSONDecoder.swift:328`, immediately above
`return KeyedDecodingContainer(try JSONKeyedDecoder<Key>(...))`:

```swift
// Disable caching for now
```

**(e) It silently falls back to Foundation on a surprising set of inputs.**
`ZippyJSONDecoder.swift:70-106` bails on simulators without vector extensions (`:71-73`) and
on `.custom` key strategy (`:74-76` — *"Custom key decoding is not supported, because it is
uncommon and makes efficient parsing difficult"*), constructing a fresh `Foundation.JSONDecoder()`
at `:108-120` and printing a one-time warning. `JSONSerialization.mm:278-292` adds three more:
`:281` "The length of the JSON data is too long (see kDataLimit for the max)"; `:287` "Either
the JSON is malformed, e.g. passing a number as the root object, or an integer was too large";
and **`:292` "One or more keys had non-ASCII characters"** — a single non-ASCII key downgrades
the entire document to Foundation.

### 3.3 The convergence that proves the point — VERIFIED

ZippyJSON's last commit (2025-09-07) changed:

```swift
} else if let stringKeyedDictType = type as? DictionaryWithoutKeyConversion.Type {
```
to
```swift
} else if keyDecodingStrategy.isNotDefault, let stringKeyedDictType = ... {
```

**This is the identical optimization as swift-foundation PR #1481, by the same author
(ChrisBenua), in the same month.** A simdjson-backed decoder and a hand-rolled Swift scanner
converged on the same fix, because the cost being removed lives in *neither parser* — it
lives in the Codable plumbing they share.

### 3.4 The README concedes it — VERIFIED

`README.md:7`:

> "### Note: JSONDecoder is faster than ZippyJSON for iOS 17+. The rest of this document
> describes the performance difference pre-iOS 17."

The rest of the README still claims "ZippyJSON is 3x+ faster for all 3 files on both
platforms" and tells readers to "divide its current time taken by 4". Those numbers are from
2019 and were measured against the `NSJSONSerialization`-backed decoder. The README's stated
*reason* Apple was slow — "Apple's version first converts the JSON into an `NSDictionary`
using `NSJSONSerialization`" — has been false since 2021/2023.

Also VERIFIED, and worth knowing before citing anyone's ZippyJSON numbers:
`Tests/ZippyJSONTests/ZippyJSONDecoderTests.swift:82-108`, `averageTime` takes 10 samples
then computes `times.dropFirst(count / 3).reduce(0, +) / CFTimeInterval(times.count)` — it
**sums 7 samples and divides by 10**, understating every measured time by 30%. It cancels in
the ratio, and it is only used for `XCTAssert(zippyTime < appleTime / 3)`, so no published
number is wrong because of it. But it tells you how carefully the numbers were produced.

### 3.5 The conclusion Assay should build on

Someone attached the fastest JSON parser in the world to Codable and got **1.38x average,
1.04x on the most API-shaped payload**. Independently, Apple removed Codable while keeping
its own parser and got **6x** (§1.8).

Those two facts, together, are the entire justification for a macro-based decoder. Parsing
is not where the time goes. The container boundary is. Assay does not need to beat simdjson;
it needs to not have a `KeyedDecodingContainer`.

---

## 4. IkigaJSON and swift-extras-json

### 4.1 IkigaJSON — scan-then-index CONFIRMED, and it is the best key-matching in Swift

Clone under `/home/claude/research/libs/`. Last commit 2026-06-29; actively maintained.

**Architecture — VERIFIED.** `Sources/IkigaJSON/Core/JSONDescription.swift:48-57` documents
the record layout: `Element := Type Size Offset Length ChildrenLength`. Records are packed
into a flat `[UInt8]` at 17/9/5 bytes depending on kind, with `Int32` fields.
`totalIndexLength` at offset 13 gives **O(1) subtree skip**, same as Foundation's
`nextSiblingOffset` and simdjson's tape.

**The key idea worth stealing — VERIFIED.** `JSONDescription.swift:895-917` and `:975`
compare the *CodingKey's* `.utf8` bytes directly against the source buffer, with a length
precheck first. **No Swift `String` is ever allocated for a JSON key.** Foundation allocates
one per key per object (§1.4); ZippyJSON allocates one per key per *access* (§3.2a).
IkigaJSON allocates zero. On top of that, `Sources/IkigaJSON/Codable/JSONDecoder.swift:344-374`
keeps a rotating last-hit offset so sequential field access is O(1) amortised.

`Sources/IkigaJSON/SIMD/FastScanner.swift:1-2` — despite the directory name, this is **SWAR
(64-bit word tricks), not true SIMD**. No `simd` import, no intrinsics.

**Weaknesses — all VERIFIED, and instructive because Assay will face the same choices:**

- `JSONDescription.swift:12-25` and `:83-92` — `getInteger`/`setInteger` reconstruct every
  `Int32` **byte-by-byte in a loop** rather than via an unaligned load. Every index read pays
  4 shifts and 4 ORs.
- `Sources/IkigaJSON/Core/Bounds.swift:11-20` — hex digit decode uses `firstIndex(of:)`, a
  linear search over a 16-element array, per nibble.
- `Bounds.swift:280-364` — `strtodSpan` is hand-rolled and does
  `result *= pow(10, Double(exponent))`. **Not correctly rounded**; double-rounding; `&*=`
  silently overflows on long mantissas. This is a correctness bug, not just a speed one.
- Snake-case conversion allocates a candidate `String` per key per lookup.
- The `decodeUnicode` setting is a **no-op**.

**Its own published numbers — VERIFIED** (README, M4 Max, macOS 26, package-benchmark p50):

| payload | Foundation | IkigaJSON | delta |
|---|---|---|---|
| small ~100 B | 3.88 µs | 3.79 µs | +2% |
| medium ~400 B | 8.26 µs | 9.05 µs | **−10%** |
| large ~27 KB | 381 µs | 556 µs | **−46%** |

malloc counts do favour Ikiga (decode small 15→10, medium 33→26). And ReerJSONBenchmark puts
it at **0.43x** on 64 KB–630 KB payloads (§3.1) — dead last, behind Foundation on everything.

The old "IkigaJSON is ~4x faster than Foundation" claim survives only on stale mirrors and
should not be repeated. Foundation caught up and passed it.

It also **defines but does not publish** partial-decode benchmarks —
`Benchmarks/.../JSONBenchmark.swift:52-68` and `:242-263`. That is exactly the case where an
index-based decoder should win biggest, and nobody has published it.

Full Foundation Codable parity, including `superDecoder`.

### 4.2 swift-extras-json — abandoned, eager tree, one wrong behaviour

Last commit **2020-11-14**, v0.6.0. Effectively dead.

**Architecture — VERIFIED.** Eager `JSONValue` enum tree at `Sources/.../JSONValue.swift:14-22`,
with `.number(String)` — numbers are kept as Strings and converted later. Each object becomes
a `[String: JSONValue]` with a hardcoded `reserveCapacity(20)`
(`Sources/.../JSONParser.swift:390-391`). A `String` is allocated and hashed per key at parse
time, regardless of what the Decodable type wants. `DocumentReader.swift:10-14` copies any
input that is not already `[UInt8]`.

**`superDecoder()` is wrong** — `JSONKeyedDecodingContainer.swift:113-119` returns
`self.impl`, ignoring the key entirely. No Date strategies, no Data strategies, no key
strategies.

**Its README's headline numbers are not usable.** "1.5x on macOS, 7-8x on Linux" was measured
against a 2020 swift-corelibs-foundation that **the same author (Fabian Fett) then fixed** in
apple/swift-corelibs-foundation PR #2985, merged 2021-03-04. The payload was ~8 KB of 6×22-field
records, timed with un-warmed `Date()` deltas, n=1.

**Worth stealing anyway — VERIFIED:** a strict RFC 8259 number state machine; explicit
control-character rejection; and a branch-free `hexAsciiTo4Bits` at
`DocumentReader.swift:209-222` (compare IkigaJSON's `firstIndex(of:)`, §4.1). Its numbers are
*correct* (validated → String → stdlib `LosslessStringConvertible`), they just allocate.

---

## 5. Yams / YAML — the bridging layer dominates libyaml

Clone under `/home/claude/research/libs/`, HEAD `df801bc`, 2026-05-26.
**Verdict: the Swift bridging layer dominates, not libyaml. Confidence HIGH.** This is the
largest easy win available to Assay in the whole survey.

### 5.1 Per-scalar and per-node allocations — VERIFIED

- **A `String` per scalar, eagerly.** `Sources/Yams/Parser.swift:444-450` —
  `String(bytes: buffer, encoding: .utf8)!`, called unconditionally from `loadScalar` at
  `:349`. Every scalar in the document becomes a Swift String whether the Decodable type
  wants it or not. Compare IkigaJSON, which allocates zero Strings for keys (§4.1).
- **A `Tag` class allocation per node.** `Parser.swift:410-413` —
  `return Tag(tagName, resolver, constructor)`. `Sources/Yams/Tag.swift:10` is a
  `final class`, and each instance holds strong refs to the Resolver and the Constructor,
  so **+2 atomic retains per node** on top of the allocation.
- **An `Event` class per libyaml event.** `Parser.swift:328` — `let event = Event()`;
  `private class Event` at `:417`. libyaml's `yaml_event_t` is a C struct on the stack; Yams
  wraps each one in a heap-allocated Swift class.
- `Sources/Yams/Node.swift:12-21` — `Node` is **not** `indirect`, which is good, but
  `Sources/Yams/Node.Scalar.swift:27` declares `public weak var anchor: Anchor?` — **weak
  reference side-table traffic on every copy** of every scalar.
- **Fully eager tree.** `Sources/Yams/Decoder.swift:141-165` calls `parser.singleRoot()` and
  then walks the whole thing. No laziness anywhere.

### 5.2 The duplicate-key check is the sleeper cost — VERIFIED

`Parser.swift:385-386` and `:397-408`. Per mapping, Yams does `pairs.map { $0.0 }` and then
`Dictionary(grouping: mappingKeys) { $0 }` — **~5 + N heap allocations per mapping**. Worse,
`Dictionary(grouping:)` must hash every key `Node`, and `Node.hash` combines `resolvedTag`.
**This is what forces the resolver to run at parse time on every mapping key**, even when the
decoder would never have needed a resolved tag.

### 5.3 The regex nuance — state it precisely or not at all — VERIFIED

`Sources/Yams/Resolver.swift:87-92` runs up to **7** `NSRegularExpression` rules per scalar.
**But only on the `load()` / `compose()` / `node.any` path.**
`Decoder.swift:147` constructs `Resolver([.merge])` — so **the `YAMLDecoder` path pays 1
regex rule, not 7** — and `Tag.swift:56-63` memoizes the resolved name in the Tag instance.

Do not claim "7 regexes per scalar" for `YAMLDecoder`. It is wrong and checkable.

Also: **Yams PR #455 "Replace NSRegularExpression with Regex" reports merged 2025-06-10, yet
`main` still declares `NSRegularExpression`.** Status unclear. This talking point could
evaporate; verify before publishing.

### 5.4 The biggest algorithmic win — VERIFIED

`Sources/Yams/Node.Mapping.swift:12` stores `private var pairs: [Pair<Node>]` — an array,
not a dictionary. `subscript(string:)` at `:194-197` **allocates a fresh `Tag` per lookup**
and then `:204-207` does `pairs.reversed().first(where:)`. **O(N·K) with K Tag allocations**
for K field reads on an N-key mapping. On top of that, `Decoder.swift:184` calls
`mapping.flatten()` on *every* keyed container construction, ~4 more array allocations.

Two more fixed costs:
- `Sources/Yams/Constructor.swift:71` — `Constructor.default` is a **computed var** that
  allocates 3 Dictionaries of 12 closures on every access. It is the default argument of
  `Tag.init`, so §5.1's per-node Tag allocation can drag this in.
- `Parser.swift:135-145` — `Parser.Encoding.default` is a computed static var that reads
  `ProcessInfo.processInfo.environment`. On corelibs this **materialises the entire
  environment dictionary per parser construction**.

### 5.5 What to steal, and what not to claim

**Steal:** the zero-copy ingest at `Parser.swift:181-190`,
`yaml.utf8.withContiguousStorageIfAvailable` — Yams gets the input into libyaml without a
copy. That part is right.

**Null result worth knowing:** I found **no** Yams or SwiftLint issue blaming Yams for
performance. SwiftLint #5207 blames glob enumeration, not YAML. Yams #485 (open, 2026-07-22)
is a cross-language benchmark invitation with no numbers in it. So there is no community
grievance to point at — Assay would be making a novel claim.

**In-repo baseline is weak:** `Tests/YamsTests/PerformanceTests.swift`, six `XCTest.measure`
cases over a single 74,307-byte fixture. No allocation counts, no percentiles.

**A 5–20x Assay win over Yams is plausible but UNVERIFIED.** Given the per-node Tag class,
the per-scalar String, the O(N·K) mapping lookup, and the per-mapping `Dictionary(grouping:)`,
the headroom is clearly large — but do not publish a multiple without measuring it.

---

## 6. XML — one hypothesis PARTLY REFUTED

### 6.1 Foundation XMLParser: allocation-heavy, yes; bridge-heavy, no (on Linux)

`/home/claude/research/swift-corelibs-foundation/Sources/FoundationXML/XMLParser.swift:700`
— the delegate signature is
`elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String]`.
Conversion happens in `_NSXMLParserStartElementNs` at `:237-317` via the `UTF8STRING` helper
(`:39-48`, `String.decodeCString`).

**Per element: 1 Swift String, or 4 when namespaces are in play. Per attribute: 2–4 Strings
plus a Dictionary insert.** VERIFIED. Line `:248` even builds `"xmlns:" + namespaceNameString!`
and then **discards it**.

**REFUTED for Linux:** grepping that file for `NSDictionary`, `CFDictionary`, `_SwiftValue`,
`__SwiftValue`, `_bridgeToObjectiveC`, and `NSString` returns **zero matches**. It is a native
Swift `Dictionary` passed through a non-`@objc` protocol witness. So: allocation-heavy, yes;
*catastrophically bridge-heavy*, no. Do not assert the bridging claim.

Darwin's `XMLParser` is closed-source Objective-C over libxml2 — **UNVERIFIED**, and the
bridging cost there may well be real. But I could not read it, so it cannot be claimed.

### 6.2 XMLCoder builds the tree twice — VERIFIED

HEAD 2026-05-13. `Sources/XMLCoder/Auxiliary/XMLStackParser.swift:26-42` builds a complete
`XMLCoderElement` tree, and then line 42 is `return node.transformToBoxTree()`, which builds
a **second** tree out of 18 different Box types.

Rough allocation budget per element: ~6 in the transform, plus a `SharedBox` class per keyed
container (`Sources/XMLCoder/Decoder/XMLDecodingStorage.swift:37`), plus
`keyed.elements.map(SingleKeyedBox.init)` per unkeyed access
(`Sources/XMLCoder/Decoder/XMLKeyedDecodingContainer.swift:158`) — call it **~8–10
allocations plus ~1 String per element and ~2 Strings per attribute**.

`XMLStackParser.swift:180-184` calls `trimmingCharacters(in:)` on every `foundCharacters`
callback **purely to test for emptiness, then discards the result** — an allocation per text
node to answer a question that a byte scan answers for free.

Three filed performance issues to cite: **#206** and **#198** (both open), **#251** (closed).

### 6.3 The best idea in Swift XML — VERIFIED

**Fuzi's `lazy var` string materialisation** — `Sources/Node.swift:126` and
`Sources/Element.swift:34-40`. Untouched subtrees cost zero Swift Strings; the libxml2 tree
is the storage and Strings appear only on demand. This is the XML analogue of what Assay
should do for JSON. Fuzi has been dormant since 2023-02-21, so the idea is available and
unclaimed.

SWXMLHash's lazy mode (`Source/LazyXMLParser.swift:33`) also defers materialisation.
AEXML (last release 2024-01) and XMLParsing (2018-10) are not competitive.

---

## 7. The benchmark corpus — and the gap Assay should exploit

**Headline finding: of seven harnesses surveyed, exactly two touch a 1–10 KB Codable decode,
and neither does it the way Assay needs.** The small-payload API-response case — Assay's
actual workload — is essentially unmeasured in the Swift ecosystem. VERIFIED by reading each
harness.

### 7.1 Harness-by-harness

| Harness | Smallest payload | Tooling | Small-payload coverage |
|---|---|---|---|
| swift-foundation `Benchmarks/` | 47.7 KB (bare int array, **encode-only**) | package-benchmark, `.cpuTotal`+`.throughput` only | **none** |
| ReerJSONBenchmark | 64 KB | google/swift-benchmark + `CFAbsoluteTimeGetCurrent()`, no warmup | **none** |
| ZippyJSON tests | ships 1.3 KB + 3.7 KB and **benchmarks neither** | XCTest, the /10-vs-/7 bug (§3.4) | **none** |
| IkigaJSON `Benchmarks/` | ~120 B and ~400 B | package-benchmark ≥1.27.0, `warmupIterations: 10`, **includes `.mallocCountTotal`** | partial; 3–10x below the band; **hoists the decoder out of the loop** |
| ChrisBenua/JSONDecoderEncoderBenchmarks | 319 B | `run_bench.py` relaunches the binary 100x, p25/p50/p75 | best methodology; varies model count, not payload size |
| swift-extras-json PerfTests | ~8 KB / 22 fields | `Date()` deltas, no warmup, n=1 | abandoned 2020 |
| swift-yyjson (mattt, HEAD 2026-05-31) | — | **no benchmark target at all** | none |

Dead or irrelevant: SwiftBenchmarkJSON (2019), ZippyJSONBenchmarks repo (**404**),
GLD.SerializerBenchmark (**.NET, not Swift**).

**swift-foundation's own harness in detail — VERIFIED.**
`Benchmarks/Benchmarks/JSON/JSONBenchmark.swift`, described in-file as a "Swift port of
Native-JSON Benchmark". `maxIterations = 1_000_000_000`, `maxDuration = .seconds(3)`,
`scalingFactor = .kilo`, `metrics = [.cpuTotal, .throughput]` — **no `.mallocCountTotal`**.
Only five benchmarks exist: `Canada-decodeFromJSON`, `Canada-encodeToJSON`,
`Twitter-decodeFromJSON`, `Twitter-encodeToJSON`, `IntArray-encodeToJSON`. Payload sizes
verified by `ls`: `canada.json` 2,251,051 B; `twitter.json` 631,514 B; `array.json` 48,891 B
(a flat `[Int]` of 9,999 elements, added by PR #1593). **`citm_catalog.json` is not present.
There is nothing between 0 and 48 KB.**

**ChrisBenua's harness is the most intellectually serious in the ecosystem — VERIFIED.**
319-byte `A1_Hierarchy.json`, 2,500 distinct Codable types, a binary with **70,320
conformance descriptors**, and a Python driver that relaunches the process 100 times to
capture cold-start cost. Results: standard 5.826 s → optimized 2.65 s (↑55%) → optimized plus
String `CodingKey` **0.114 s (↑98%)**. That last number is the §1.6 conformance effect in
isolation. Its limitation: the payload has zero strings, and it varies model count rather
than payload size.

### 7.2 The corpus shapes, measured

canada.json 2,198 KB / depth 7 / **111,126 numbers** / 0 non-ASCII;
marine_ik 2,913 KB / depth 11 / 245,175 numbers; mesh 706 KB;
twitter 616 KB / 4,754 strings / 95,406 non-ASCII bytes;
twitterescaped 549 KB / 0 non-ASCII (**pure `\uXXXX` unescaping**);
random 498 KB / one key reused 1,429x;
apache_builds 124 KB / **only 2 numbers**;
github_events 63.6 KB / 114 unique keys — **the most realistic API shape in the corpus**;
twitter2 3.7 KB; entities 1.3 KB; A1_Hierarchy 0.3 KB.

**Nothing in the entire corpus contains a date.** See §1.9 item 4.

### 7.3 What a 2 KB benchmark exposes that a 2 MB benchmark hides

Fixed per-decode costs, invisible at 2 MB, dominant at 2 KB:

- `swift_conformsToProtocol` — scales with `__swift5_proto` size, **not** with payload size.
- `Decoder` existential box + one container box allocation per nesting level.
- `codingPath` construction.
- `Data` → contiguous-buffer bridging.
- `JSONDecoder()` construction and `_Options` setup (this is why hoisting the decoder out of
  the loop is a methodological choice, not a detail).
- `JSONMap` buffer allocation and growth.
- Cold-vs-warm type metadata.

**This is the gap. A small-payload, malloc-counted, cold-start-inclusive benchmark suite
would be a genuine contribution to the ecosystem independent of Assay, and Assay would
almost certainly win it.**

### 7.4 Recommended suite for Assay

**ordo-one/package-benchmark. Non-negotiable** — it is what swift-foundation and IkigaJSON
both use, so the numbers are comparable and the tooling is not contestable.

Publish `.wallClock` **p50 and p90**, `.cpuTotal`, **`.mallocCountTotal` as the headline
metric**, `.instructions`, `.throughput`.

- **Tier A — the gap.** 6 new payloads in the 1–10 KB band, plus reuse ZippyJSON's
  `twitter2.json` (3.7 KB) and `entities.json` (1.3 KB) so the comparison is on files that
  already exist in the ecosystem. Include at least one date-heavy payload (§1.9 item 4).
- **Tier B — the classic corpus, unmodified, published even where Assay loses.** canada.json
  is 111,126 float parses; a macro decoder without SIMD number parsing will lose there.
  Publishing that loss is what makes Tier A credible.
- **Tier C — cold start.** Process relaunch per the ChrisBenua protocol, publishing the
  `otool -l | grep __swift5_proto` descriptor count alongside. This is the axis where a
  macro that emits fewer conformances wins structurally (§1.6).

Orthogonal axes worth varying: decoder-per-call vs hoisted; `Data` vs `[UInt8]` vs
`ByteBuffer`; `.useDefaultKeys` vs `.convertFromSnakeCase`; full decode vs partial decode
(the case IkigaJSON defined but never published, §4.1).

Baselines: Foundation (**always state the OS version**), IkigaJSON, ReerJSON, and
**Ananda + AnandaMacros — the other macro-driven decoder. Omitting it would be the single
most damaging omission Assay could make**, because it is the only true peer.

**Cherry-picking to avoid** (each of these is something a reader could catch):
omitting canada.json; reporting means instead of percentiles; hoisting the decoder for Assay
but not for baselines; using a toy binary with few conformances (**which flatters
Foundation**, so disclose the count either way); comparing against an unlabelled old OS;
using only synthetic payloads; omitting encode entirely; omitting Ananda.

---

## 8. Verdict — per library, one line each

| Library | Steal | Beat |
|---|---|---|
| **swift-foundation JSONDecoder** | The `JSONMap` index: flat `[Int]`, `nextSiblingOffset` for O(1) subtree skip, zero copies of non-structural data; `_CodingPathNode` as a linked list rather than an array; the adaptive map-growth extrapolation. | `KeyedContainer.stringify` — never allocate a `String` for a key, never build a Dictionary per object. This is the whole game. Also: `.iso8601` date decoding, and `strtod` for Doubles. |
| **Apple's `new-codable`** | The premise: 6x comes from deleting `Decodable`, not from a faster parser. | Ship first. It is on an experimental branch and currently build-broken (#2074). |
| **ZippyJSON** | Nothing architectural — but study `JNTDocumentFindValue`'s rotating-start linear probe as the *cheap* answer to field lookup. | Its ceiling. simdjson + Codable = 1.38x. A macro must clear that trivially or the thesis is wrong. Also beat its silent-fallback surface: non-ASCII keys, custom key strategy, size limits, simulators. |
| **IkigaJSON** | **Its key matching: compare the CodingKey's UTF-8 bytes against source bytes with a length precheck, never allocating a String.** Plus the rotating last-hit cache and the packed `[UInt8]` index. | Its `Int32` byte-by-byte index reads, its `firstIndex(of:)` hex decode, and above all its incorrect `strtodSpan` — Assay must be correctly rounded. And it is 0.43x vs Foundation at scale; beat Foundation, not Ikiga. |
| **swift-extras-json** | The strict RFC 8259 number state machine, control-character rejection, and the branch-free `hexAsciiTo4Bits`. | Its entire architecture (eager `JSONValue` tree, `.number(String)`, String-keyed dictionaries) and its broken `superDecoder`. Dead since 2020; not a competitor, only a source of correctness tests. |
| **Yams** | The zero-copy ingest via `withContiguousStorageIfAvailable`. | Everything else: a Tag class per node, a String per scalar, an Event class per event, `Dictionary(grouping:)` per mapping for duplicate detection, and O(N·K) mapping lookup with a Tag allocation per probe. Largest available headroom in the survey. |
| **Foundation XMLParser** | Nothing. | The SAX contract itself — 1–4 Strings per element and 2–4 per attribute, unavoidable while the delegate signature takes Strings. |
| **XMLCoder** | Nothing. | The double tree build (`XMLCoderElement` → `transformToBoxTree`), ~8–10 allocations per element, and `trimmingCharacters` called just to test emptiness. Three open perf issues (#206, #198, #251) show users have noticed. |
| **Fuzi** | **`lazy var` string materialisation — untouched subtrees cost zero Strings.** The single best idea in Swift XML. | Nothing; it is dormant since 2023 and not a competitor. |
| **Ananda / AnandaMacros** | Whatever it does well — it is Assay's only true peer. | It is the benchmark Assay must not omit. |

---

## 9. Do not assert these

Every item below was checked and failed, or is true only in a narrower form than commonly
stated. Asserting any of them is a factual error a reader can catch.

1. **"`Decodable.init(from:)` is non-specializable across module boundaries" — UNVERIFIED.**
   I searched Perry's 2025 thread for "module boundary", "resilien", "inlinable", and
   "witness table". None appear. His "specialization" means *format*-specialization. Plausible
   from first principles; not supported by any source I could read.
2. **"Yams runs 7 regexes per scalar"** — true only for `load()`/`compose()`/`node.any`.
   `Decoder.swift:147` uses `Resolver([.merge])`, i.e. **one** rule, memoized per node at
   `Tag.swift:56-63`. The `YAMLDecoder` path does not pay 7.
3. **"Foundation's `XMLParser` bridges through `NSDictionary`/`NSString`"** — grep returns
   zero matches on Linux corelibs. Darwin is UNVERIFIED and unreadable. Say "1–4 String
   allocations per element" instead; that part is verified.
4. **"ZippyJSON is 3–4x faster than Foundation"** — its own README concedes Foundation is
   faster on iOS 17+, and ReerJSONBenchmark measures **1.38x average, 1.04x on GitHub
   Events**. The 3–4x figure is from 2019 against `NSJSONSerialization`.
5. **"IkigaJSON is ~4x faster than Foundation"** — survives only on stale mirrors. Its own
   current README shows Foundation ahead on medium (−10%) and large (−46%), and
   ReerJSONBenchmark puts it at 0.43x.
6. **"swift-extras-json is 7–8x faster on Linux"** — measured in 2020 against a corelibs
   Foundation that **the same author then fixed** (swift-corelibs-foundation PR #2985, merged
   2021-03-04). Not current.
7. **"PR #1481 made JSONDecoder 52.6% faster"** — as stated this implies a steady-state
   per-call gain. It is a **cold, once-per-(type, protocol)-pair** cost that amortises to ~0
   in a hot loop. Always say "at cold start, in a binary with >150,000 conformances".
8. **"Foundation's JSONDecoder uses `NSJSONSerialization`/`NSDictionary`"** — false since
   ~2021. It is a lazy scanner over a flat integer map. This is ZippyJSON's README's error;
   do not inherit it.
9. **"Apple measured 6x from removing Codable, so Codable costs 83% today"** — the 6x is
   real and VERIFIED, but it is on `experimental/new-codable`, absent from the shipping tree,
   and build-broken (#2074). Cite it as a prototype measurement, not as shipping behaviour.
10. **"Yams uses `NSRegularExpression`"** — `main` still declares it, but PR #455 ("Replace
    NSRegularExpression with Regex") reports merged 2025-06-10. Status contradictory. Re-check
    before publishing; this talking point may already be gone.
11. **Any specific Yams speedup multiple (e.g. "10x")** — the headroom is clearly large and
    the mechanisms are verified, but no multiple has been measured. Do not publish one.
12. **The 2019 "Rearchitecting JSONEncoder" thread as evidence for Codable's structural
    cost** — no participant there discussed existentials, `codingPath`, dynamic casts, or
    `KeyedDecodingContainer`'s contract, and the bottlenecks they did name are obsolete. Use
    Perry's 2025 post instead.
13. **Any Foundation encode baseline measured between 2025-09-30 and 2025-12-12** — PR #1481
    shipped with `_asDirectArrayEncodable` referencing the wrong variable, so the fast path
    was dead for that whole window (fixed by #1593, which measured a 92% time reduction).
14. **"Foundation's `JSONMap` makes decoding lazy"** — the *scan* is lazy; the *decode* is
    not, because `KeyedContainer.stringify` materialises every key of every object it
    touches. State it as "lazy scanner, eager container".
