I have the full picture. Here is the synthesis.

---

# Cross-platform Swift in July 2026 — and what it forces on Assay's API

**Method note first, because it changes what you can trust:** your premise that swift.org returns 403 was only half right. `curl` through the proxy is blocked, but **WebFetch reaches swift.org, forums.swift.org and developer.apple.com fine**, and `git clone` works. So most of what follows is read out of actual cloned sources (`swift-foundation` @ `af8c8086`, 2026-07-24; `swift-corelibs-foundation` @ `8f61c745`; `swiftlang/swift` @ `386aeb5`; plus ~20 ecosystem packages) or from swift.org's own YAML data files — not from mirrors or inference.

---

## 0. The three findings that should change the document

Before the systematic answer, the three things that actually bite:

1. **`.url` is a worse portability problem than `.regex`.** `URL(string:)` accepts `"hello"`. It accepts `"path space"`. It accepts `"Encoding a relative path! 😎"` — swift-foundation's own test suite asserts all of these are non-nil, because invalid characters get silently percent-encoded. The strict initializer `URL(string:encodingInvalidCharacters: false)` is `@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)` — **a higher floor than Swift `Regex`.** Your `.url` rule, as written, is either wrong or gated harder than `.regex`.

2. **`@DateFormat(.custom("yyyy-MM-dd"))` is the single most expensive line in the document.** A UTS-35 pattern string means `DateFormatter` or `Date.FormatStyle`, both of which live behind ICU. On Android that is `lib_FoundationICU.so` at **~40 MB per architecture** ([forums.swift.org/t/78399](https://forums.swift.org/t/android-app-size-and-lib-foundationicu-so/78399), June 2026, unresolved). On Wasm it's the dominant term in a ~50 MB binary. ISO 8601 is free — `Date.ISO8601FormatStyle` is in `FoundationEssentials` and is genuinely ICU-free (two files, **zero import statements**, hand-rolled parser). Arbitrary format strings are not.

3. **`Regex` is not what the ecosystem uses, and the reason is instructive.** Vapor 5's deployment floor is **macOS 26.2** — thirteen major versions above the `Regex` floor — and its `.email` validator still uses `String.range(of:options: .regularExpression)`. SwiftLint's floor is exactly macOS 13, it is the ecosystem's heaviest regex user, and it uses `NSRegularExpression` exclusively. Nobody puts `Regex` in a public API surface.

---

## 1. The platform matrix as it really is

### CONFIRMED

**Latest release: Swift 6.3.3, 2026-06-29**, with Xcode 26.6. 6.3 shipped 2026-03-24. **6.4 is not released** — branch cut 2026-05-04, snapshots only. Source: `_data/builds/swift_releases.yml` in `swiftlang/swift-org-website`, read in full.

**There is a new tier policy, and it has not been applied.** `SP-0001: Swift Platform Support Tiers` — https://github.com/swiftlang/swift-evolution/blob/main/policies/0001-platform-support-tiers.md — is **Accepted** (reviewed Jan–Feb 2026) and is the first entry in a brand-new `policies/` document class. It defines Tier 1 Supported / Tier 1 Toolchain Host / Tier 2 Experimental / Tier 3 Exploratory. Verbatim grandfather clause:

> The following existing platforms are in Tier 1 regardless of any text in this document: All Apple platforms (macOS, iOS and so on). Linux. Windows.

**Android and WebAssembly are not named anywhere in SP-0001.** Meanwhile https://www.swift.org/platform-support/ still publishes the *old* two-category model and is partly stale (visionOS is absent from every table; Ubuntu 20.04 is listed but has no 6.3.3 build). So: anyone who tells you "Android is Tier 2" is using real terminology that has not been assigned. The honest statement is **three tiers exist; Apple + Linux + Windows are Tier 1; everything else is formally unassigned.**

The Tier 1 substance is worth knowing because it's what "supported" buys you: *"There is a presumption that a release of Swift will be blocked if a Tier 1 platform is currently broken."* For Tier 2/3, explicitly: *"the Swift project does not assume collective responsibility."*

**Linux — exact list for 6.3.3**, all x86_64 + aarch64: Ubuntu 22.04 (jammy), Ubuntu 24.04 (noble), Debian 12, Fedora 39, Fedora 41, Amazon Linux 2, Amazon Linux 2023, RHEL UBI 9. **No Alpine, no Arch, no Ubuntu 20.04.** The **Static Linux SDK (musl)** is a first-class release artifact (still versioned 0.1.0), triples `x86_64-swift-linux-musl` / `aarch64-swift-linux-musl`; no dynamic linking at all, not even `dlopen`, but *"Swift packages that make use of Foundation or SwiftNIO should just work."*

**Android — real, official, and one release old.** Workgroup announced 2025-06-25 (13 members, chaired by Joannis Orlandos). **"Swift 6.3 includes the first official release of the Swift SDK for Android"** (https://www.swift.org/blog/swift-6.3-released/). Install is `swift sdk install <url> --checksum <...>` **plus a mandatory NDK r27d+ post-step** (`./scripts/setup-android-sdk.sh`). Triples generated for API 28–36, archs aarch64/armv7/x86_64. `.android` is a first-class `PackageDescription` platform. **Note: `github.com/swiftlang/swift-android-sdk` does not exist (404)** — the SDK is built out of `swiftlang/swift-docker`. Macro cross-compilation, which used to be the blocker, **is fixed** (SwiftPM PR #8670).

**WebAssembly — upstreamed in Swift 6.2 (2025-09-15).** Official `.artifactbundle` from swift.org, two SDK IDs: `swift-<version>_wasm` (all features) and `swift-<version>_wasm-embedded`. Triple is `wasm32-unknown-wasip1`. **`wasip1-threads` is built upstream but deliberately excluded from the official bundle** (WasmKit can't execute it yet — verbatim TODO in `utils/swift_build_support/.../wasiswiftsdk.py`). `wasip2` does not exist anywhere in the tree. **There is no WebAssembly workgroup** (verified by directory listing of `_data/` in swift-org-website) — just an accepted vision doc. Wasm was not mentioned in the 6.3 release post at all. **`carton` is deprecated**; JS interop is now JavaScriptKit's `@JS`/BridgeJS macros.

**Embedded Swift — still `EXPERIMENTAL_FEATURE(Embedded, true)`** in `include/swift/Basic/Features.def:459`. Targets: Cortex-M (armv6m/7m/7em), aarch64 bare metal, RISC-V 32, and **wasm32** via the official `-embedded` SDK. Binary sizes are genuinely tiny — `print("Hello, Embedded Swift 😊")` at `-Osize -dead_strip` is **176 bytes of `__text`**.

### DISCREPANCY I need to flag

The Embedded DocC catalogue still says *"Public releases of Swift do not support Embedded Swift, yet"* — but the official `<tag>_wasm-embedded` SDK ships for **released 6.3**, and both `apple/swift-collections` and `apple/swift-http-types` run `enable_embedded_wasm_sdk_build: true` against it in CI. **My read: that sentence is stale for the Wasm-embedded path, accurate for bare-metal (which still wants a `main` snapshot).** Treat with care.

### Realistic-to-claim verdict for a decoding library

| Platform | Claimable? | What it costs you |
|---|---|---|
| macOS / iOS / tvOS / watchOS / visionOS | **Yes** | Nothing, except that visionOS is undocumented on swift.org |
| Linux (jammy/noble/bookworm/AL2023/UBI9) | **Yes** | Nothing |
| Static Linux / musl | **Yes** | No `dlopen`; historically `_StringProcessing` duplicate-symbol breakage under `--static-swift-stdlib` |
| Windows | **Yes** | Foundation is complete; CI has real footguns (§7) |
| Android | **Yes, with CI evidence** | ~40 MB ICU per arch if you touch localized Foundation |
| Wasm/WASI | **Yes, and it's the ideal workload** | Single-threaded; no networking/dispatch; needs a stack-size bump |
| Embedded Swift | **No — say so** | See §5 |

---

## 2. Foundation's split

### CONFIRMED — the architecture

Three things, and the naming is confusing:
- **swift-foundation** — the Swift rewrite. Vends **exactly two public library products**: `FoundationEssentials` and `FoundationInternationalization`. (Also `FoundationMacros`, a macro plugin, and two C shim targets.)
- **swift-corelibs-foundation** — non-Darwin only. Vends `Foundation` (umbrella), `FoundationNetworking`, `FoundationXML`. Its `Foundation` module re-exports the other two — `Sources/Foundation/Essentials.swift` is literally four lines: `@_exported import FoundationEssentials` / `@_exported import FoundationInternationalization`.
- **Foundation.framework** on Darwin — compiles swift-foundation's sources into one `Foundation` module.

Corelibs is *partly* a shim. `JSONDecoder.swift` there is now **25 lines**; `UUID.swift` is 63; `ProcessInfo.swift` is 17. But 133 files remain, and the NS-era layer is still real: `NumberFormatter.swift` 1426 lines, `NSData.swift` 1254, `DateFormatter.swift` 781, `NSRegularExpression.swift` 353.

### ⚠️ `import FoundationEssentials` still does NOT work on Darwin

This is the answer you flagged as important, and **it has not changed.** `https://developer.apple.com/documentation/foundationessentials` → 404. Tony Parker (Apple, Foundation lead), [forums.swift.org/t/74856/49](https://forums.swift.org/t/foundationessentials-on-darwin/74856/49), **April 2026**, thread still open:

> "A really simple-sounding solution would be to create modules with these module names on Darwin that re-export Foundation. It will compile, but I think it will be more confusing than helpful… **So the right answer on Darwin *is* actually to just `import Foundation`.**"

And the payoff wouldn't exist anyway — same thread, post #57: a `print("Hello")` binary is **52,448 bytes without Foundation vs 55,824 with**. ~3.3 KB, which is just Mach-O load commands.

**The blessed idiom, as of Feb 2026 formal Ecosystem Steering Group guidance** ([forums.swift.org/t/84112](https://forums.swift.org/t/the-adoption-of-import-foundationessentials-throughout-the-package-ecosystem/84112), post #16):

```swift
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
```

The ESG explicitly warns this is **potentially source-breaking for your downstream clients**, because your module previously re-leaked all of Foundation's extensions on stdlib types. Ship it as a minor version with release notes.

⚠️ **Documentation bug:** https://www.swift.org/documentation/core-libraries/ says "If your app is particularly sensitive to binary size, you can import the `FoundationEssentials` library" with **no platform caveat**. That's wrong on Darwin and is a common source of exactly this confusion.

### The module membership table you asked for

Verified by grep against the clones.

| Type | Module | ICU? |
|---|---|---|
| `Date` | **FoundationEssentials** | no |
| `Data` | **FoundationEssentials** | no |
| `UUID` | **FoundationEssentials** | no |
| `URL` | **FoundationEssentials** | **no** (IDNA upgrades if FI is loaded) |
| `Decimal` | **FoundationEssentials** | no |
| `JSONDecoder`/`JSONEncoder` | **FoundationEssentials** | **no** |
| `PropertyListDecoder`/`Encoder` | **FoundationEssentials** | no |
| **`Date.ISO8601FormatStyle`** | **FoundationEssentials** | **NO** ⭐ |
| `Date.HTTPFormatStyle` (RFC 9110) | **FoundationEssentials** | no |
| `FormatStyle` / `ParseStrategy` protocols | FoundationEssentials | no |
| `AttributedString`, `Predicate`, `NotificationCenter`, `FileManager` | FoundationEssentials | no |
| `Locale`, `Calendar`, `TimeZone` | **FoundationEssentials (type) / FoundationInternationalization (real engine)** | **conditionally — see below** |
| `Date.FormatStyle` (localized) | FoundationInternationalization | **YES** |
| `IntegerFormatStyle`/`FloatingPointFormatStyle` | FoundationInternationalization | **YES** |
| `DateFormatter`, `ISO8601DateFormatter`, `NumberFormatter` | **corelibs `Foundation` only** | **YES** |
| `NSRegularExpression` | **corelibs `Foundation` only** | **YES** |
| `JSONSerialization`, `PropertyListSerialization` | **corelibs only** | via CF |
| `CharacterSet`, `Bundle`, `NSObject` | corelibs only | via CF |
| `URLSession` | FoundationNetworking | no (libcurl) |
| `XMLParser` / `XMLDocument` | **FoundationXML** | no (libxml2) |

### ⚠️ The `Locale`/`Calendar`/`TimeZone` silent-degradation trap

`Locale`, `Calendar` and `TimeZone` are **public types in FoundationEssentials whose engines are swapped in at load time by `@_dynamicReplacement`** if `FoundationInternationalization` happens to be loaded. Nine such hooks exist (`_localeICUClass`, `_calendarICUClass`, `_timeZoneICUClass`, `_uidnaHook`, `_localizedCompare_platform`, …).

Essentials-only, you silently get:
- `Locale` → `_LocaleUnlocalized(identifier: "en_001")`. Source comment: *"The `Locale` initializers are not failable, so we just fall back to the unlocalized type when needed without failure."*
- `Calendar` → native Swift Gregorian and Hebrew only; `nil` for every other identifier.
- `TimeZone` → reads system tzdata directly, plus GMT.

**No compile error. Just different behaviour.** This is directly relevant to your §3 `func message(for locale: Locale) -> String`.

### ⭐ ICU-free ISO 8601 is real

`Sources/FoundationEssentials/Formatting/Date+ISO8601FormatStyle.swift` (528 lines) and `DateComponents+ISO8601FormatStyle.swift` (820 lines): **zero import statements in either file**, zero ICU references (the only hit for "ICU" is a comment about matching ICU's whitespace behaviour). Both format *and* parse are hand-rolled Swift. Availability `macOS 12 / iOS 15`.

So `ISO8601DateFormatter` (ICU) and `Date.ISO8601FormatStyle` (not ICU) do the same job with wildly different costs. **Never touch the former.**

### Can the core be Foundation-free?

**`Data` is Foundation.** `Sources/FoundationEssentials/Data/Data.swift:155`. There is no stdlib `Data`, `UUID`, `URL`, `Date`, `Decimal`, or `JSONDecoder`. `Encodable`/`Decodable` are stdlib protocols; **every concrete coder is Foundation.**

So "Foundation-free core" realistically means: stdlib-only types, public API over `[UInt8]` / `RawSpan` / `some Collection<UInt8>`, with `Data` conveniences in a guarded adapter.

**On `Span`** — `Span`, `RawSpan`, `MutableSpan`, `OutputSpan` all shipped in **Swift 6.2** and **back-deploy on Darwin to macOS 10.14.4 / iOS 12.2** via a real `swiftCompatibilitySpan` shim. But there's a split you must know:

| | Toolchain floor | Darwin OS floor |
|---|---|---|
| `Span`/`RawSpan`, `.span` on `ContiguousArray`/`ArraySlice`/**`Data`** | 6.2 | **macOS 10.14.4** |
| **`Array.span`**, `String.utf8.span`, `UTF8Span` | 6.2 | **macOS 26** |
| **`InlineArray`**, `[N of T]` | 6.2 | **macOS 26** |
| `Atomic`/`Mutex` (Synchronization) | 6.0 | **macOS 15** |

Reason `Array.span` can't back-deploy (Guillaume Lessard, [forums.swift.org/t/80513](https://forums.swift.org/t/using-span-on-pre-26-apple-os-versions/80513)): NSArray bridging has to materialize a contiguous buffer. **Consequence: source your spans from `ContiguousArray`/`ArraySlice`/`Data`, never from `Array` or `String`.**

⚠️ **Do not author `@_lifetime` in public signatures.** Still `SUPPRESSIBLE_EXPERIMENTAL_FEATURE(Lifetimes, true)` on `main`; the un-underscored spelling is only at [Pitch #3 (2026-02-25)](https://forums.swift.org/t/pitch-3-compile-time-lifetime-dependency-annotations/84968). Consuming spans is free; *returning* one borrowed from your own type needs the flag.

---

## 3. Regex — the availability cliff is real, and the workaround is not what you'd guess

### CONFIRMED — the exact floor

`_StringProcessing/Regex/Core.swift:18` annotates `Regex` as `@available(SwiftStdlib 5.7, *)`. That macro resolves in `swiftlang/swift/utils/availability-macros.def`:

```
SwiftStdlib 5.7:macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0
```

**Your belief is exactly right: macOS 13 / iOS 16 / tvOS 16 / watchOS 9.** (visionOS is absent from the 5.7 line, meaning it's unconditionally available there — so it's a four-platform annotation, not five.) Steve Canon confirms the mechanism on the forums: *"The Regex type is in the standard library, which is distributed as part of the OS, so it's available only when targeting macOS 13."*

**Nothing has changed by 2026, and there is no escape hatch:**
- No back-deployment shim (no entry in `FeatureAvailability.def`; grep for `regex|StringProcessing` → 0 hits).
- No experimental feature flag for availability — the only regex flag is `UPCOMING_FEATURE(BareSlashRegexLiterals, 354, LanguageMode::v6)`, which governs `/.../ ` *syntax*.
- **The standalone package is a dead end.** `swift-experimental-string-processing`'s `Package.swift` builds every product with `.unsafeFlags(...)`, and SwiftPM forbids `unsafeFlags` in version-pinned dependencies — **transitively**, so your package could never be tagged and published. It also has no semver tags (1831 tags, 1795 of them dev snapshots) and would collide with the toolchain's own `_StringProcessing`.

**On Linux / Windows / Wasm: works, no OS floor.** `stdlib/public/StringProcessing/CMakeLists.txt` builds it with per-platform module deps (`Glibc`, `Musl`, `Android`, `CRT`, …); on non-Darwin the stdlib ships with the toolchain so `@available(macOS 13, *)` is inert. Historical wart: duplicate `_swift_stdlib_getScript` symbols between `libswiftCore.a` and `libswift_StringProcessing.a` under `--static-swift-stdlib`, fixed in 5.7.2, **regressed in 5.9.1** ([swiftlang/swift#62034](https://github.com/swiftlang/swift/issues/62034)).

**In Embedded Swift: no, structurally.** `stdlib/public/StringProcessing/CMakeLists.txt` and `RegexBuilder/CMakeLists.txt` contain **zero** mentions of "embedded" (Concurrency's has 46). There are **zero** regex tests in `test/embedded/`, and zero `@_unavailableInEmbedded` markers in the whole SESP tree. The engine is `AnyRegexOutput` + existentials + `swift_getTupleTypeMetadata()` + heap-allocated bytecode — every one of those is on the forbidden list. This is not "not yet ported."

**Code size cost: UNKNOWN.** No published number. It is a separate library carrying Unicode script tables (which is *why* the duplicate-symbol collision happened). Don't quote a figure you haven't measured.

### `NSRegularExpression`

Umbrella `Foundation` only — **zero hits** across the entire `swift-foundation` repo. It's a thin shim over `_CFRegularExpression*` → `uregex_open` → ICU. Works on Darwin/Linux/Windows/Android; WASI compiles but CoreFoundation is still marked `isOptional` in the Wasm SDK recipe. **Not deprecated, not even soft-deprecated** — grep for `deprecated` on the file returns nothing, and there is no "use Regex instead" note anywhere.

### ⭐ The finding that resolves your problem

**`String.range(of:options: .regularExpression)` is now implemented on top of Swift `Regex` — and carries no availability annotation.**

`swift-foundation/Sources/FoundationEssentials/String/String+Comparison.swift:602-617`:

```swift
func _range(of strToFind: Substring, options: String.CompareOptions) throws -> Range<Index>? {
    #if !NO_REGEX
    if options.contains(.regularExpression) {
        guard let regex = try RegexPatternCache.cache.regex(for: String(strToFind), caseInsensitive: options.contains(.caseInsensitive)) else { return nil }
```

with `RegexPatternCache.swift` doing `try Regex(pattern).wordBoundaryKind(.simple)` inside a `Mutex<[Key: Regex<AnyRegexOutput>]>`.

This is a **de-facto availability-erasing shim**. On new OSes it *is* `Regex`; on old OSes the system Foundation services it via NSString/ICU. Either way **no `@available` propagates to your API.** This is precisely why Vapor and Peppermint have zero availability attributes despite doing regex matching.

Two risks that come with it, both confirmed:
- **Two engines behind one API.** Corelibs `NSString.range(of:options:)` → ICU; swift-foundation `String.range(of:options:)` → `Regex`. They don't agree on all patterns. swift-foundation pins `.wordBoundaryKind(.simple)` as a compat hack but leaves grapheme-cluster matching semantics, whereas swift-format explicitly opts into `.matchingSemantics(.unicodeScalar)`.
- `#if !NO_REGEX` means there is a supported config where `.regularExpression` **silently degrades to literal substring search**. Which platforms define it is **UNKNOWN** (zero hits in any Package.swift or CMakeLists — externally supplied).

### What the ecosystem actually does

| Library | Apple floor | Regex mechanism | `@available`? |
|---|---|---|---|
| **vapor** main (v5) | **macOS 26.2** | `range(of:options:.regularExpression)` | **No** |
| **SwiftLint** | **macOS 13** | **`NSRegularExpression`** | **No** |
| swift-openapi-generator | macOS 10.15 | `NSRegularExpression` ×1 | No |
| swift-format | macOS 13 | native `Regex`, built from a `String` (never a literal) | No — **floor raised instead** |
| swift-syntax | macOS 10.15 | **hand-rolled UTF-8 byte cursor, zero Foundation** | — |
| Yams | none | `NSRegularExpression` | No |
| swift-argument-parser | none | scalar-range predicates | — |

Vapor's `.email`, verbatim (`Sources/Vapor/Validation/Validators/Email.swift`), identical in v4 and v5:

```swift
guard
    let range = $0.range(of: regex, options: [.regularExpression]),
    range.lowerBound == $0.startIndex && range.upperBound == $0.endIndex,
    $0.count <= 320,
    $0.split(separator: "@")[0].count <= 64
else { return ValidatorResults.Email(isValidEmail: false) }
```

`regex` is a `private let regex: String` — the emailregex.com RFC-5322 monster stored as a plain String. **Zero `@available` in all of `Sources/Vapor/Validation/`.** Note the anchoring idiom: the pattern is *not* `^…$`-anchored; they range-check that the match spans the whole string.

**Vapor's `.pattern(_ pattern: String)` has a bug worth not copying:** it cannot distinguish "invalid pattern" from "no match" — both yield `nil`. **SwiftLint's wrapper is the one to steal**: a `RegularExpression` struct that is `ExpressibleByStringLiteral + Hashable + Sendable`, a lock-guarded compile cache, and a typed-throws constructor `static func from(pattern:options:for ruleID:) throws(Issue)` producing `.invalidRegexPattern(...)`.

**Pure-Swift alternatives: there is no maintained one.** `DavidSkrundz/Regex` is a genuine pure-Swift NFA with zero Foundation imports — **last commit 2018-07-14**. `crossroadlabs/Regex` (2019) and `sharplet/Regex` (2020) are both `NSRegularExpression` wrappers, both abandoned, the former with an open *"500x performance drop"* issue.

### Hand-rolling the named rules

- **`.uuid` — hand-roll it.** `UUID(uuidString:)` has **two different C implementations** split at `Sources/_FoundationCShims/uuid.c:39` by `#if TARGET_OS_MAC`: Darwin delegates to libsystem `uuid_parse(3)`, everything else uses a vendored `sscanf` with `%2hhx`. `sscanf` `%x` has libc-dependent edge cases. Both reject bare 32-hex, braces, and `urn:uuid:`; neither validates version/variant. ~15 lines of your own gets you bit-identical behaviour everywhere plus a decision about which forms you accept.
- **`.url` — see §0.** `URL(string:encodingInvalidCharacters: false)` + `scheme != nil` + a scheme allow-list + `host() != nil` for hierarchical schemes. Floor: macOS 14 / iOS 17. Also note **host IDNA is unavailable off-Darwin** (`_uidnaHook()` returns nil unless `FOUNDATION_FRAMEWORK && canImport(_FoundationICU)`).
- **`.hostname` — nothing exists in Foundation.** The only host validation is `internal func validate(span:component:)` in `URL_Validation.swift`, not exported. Hand-roll: ≤253 total, labels 1–63, `[A-Za-z0-9-]`, no leading/trailing `-`, optional trailing dot, reject all-numeric TLD.
- **`.email` — nothing in Foundation or stdlib** (`grep -ril email Sources/` over swift-foundation → **zero files**). Best option: **split on the last `@`**, validate local-part charset + ≤64, run your hostname validator on the domain. **This needs no regex engine at all** — which is the only version that survives on Wasm-minimal and Embedded.

---

## 4. XML — your assumptions are all correct, plus one you missed

### CONFIRMED via Apple's DocC JSON API (the HTML pages are JS-rendered and unfetchable)

- `.../documentation/foundation/xmldocument.json` → `[{"name":"Mac Catalyst","introducedAt":"13.0"},{"name":"macOS","introducedAt":"10.0"}]`. Same for `xmlnode`, `xmlelement`, `xmldtd`. **macOS + Mac Catalyst only. Confirmed.**
- `.../xmlparser.json` → iOS 2.0, iPadOS 2.0, Mac Catalyst 13.0, macOS 10.0, tvOS 9.0, visionOS 1.0, watchOS 2.0. **All seven. Confirmed.**
- Linux: corelibs README:40 — *"It installs the `Foundation` umbrella module, `FoundationXML`, and `FoundationNetworking`."* **Confirmed.**

### ⚠️ The nuance you missed

**`XMLParser` is also in `FoundationXML` on non-Darwin.** On Darwin it comes from `Foundation`; on Linux/Windows/Android you must `import FoundationXML` to get **`XMLParser` too**, not just the DOM types. This is the single most common portability trap. `Sources/FoundationXML/XMLParser.swift:1-7` confirms.

Second nuance: corelibs' DOM is **feature-degraded** — `@available(*, unavailable, message: "XSLT application is not currently supported in swift-corelibs-foundation")` and the same for XQuery.

### Windows / Android / Wasm

- **Windows: CONFIRMED SHIPPED.** `swift-installer-scripts/.../windows.wxs:1216-1263` installs `FoundationXML.swiftmodule` + `.lib` + `libFoundationXML.lib` for arm64/x64/x86. **No libxml2 DLL is installed** → statically linked. Manifest confirms: `.linkedLibrary("libxml2s.lib", .when(platforms: [.windows]))` (the `s` suffix is MSVC static naming), and `cmake/modules/WindowsSwiftPMDependencies.cmake` builds libxml2 v2.11.5 from source as an ExternalProject with `BUILD_SHARED_LIBS=NO`.
- **Android: CONFIRMED SHIPPED.** `android.wxs:1617+` installs `libFoundationXML.so` and `.a` for aarch64/armv7/x86_64. On Android the dependency is **visible to the end user** — finagolfin's README: *"The libcurl and libxml2 packages are only needed for the FoundationNetworking and FoundationXML libraries respectively"*, and libxml2 transitively drags **liblzma + libiconv** from Termux.
- **Wasm: build-system support confirmed, shipped artifact UNKNOWN.** `Sources/CMakeLists.txt` adds FoundationXML **unconditionally** while FoundationNetworking is gated `if(FOUNDATION_BUILD_NETWORKING)` — and the top-level CMakeLists turns networking OFF for WASI with a comment but has **no equivalent switch for XML**. WASI accommodations exist (`.target(name: "BlocksRuntime", condition: .when(platforms: [.wasi]))`). But `grep -r "FoundationXML|libxml"` across all of `swift-sdk-generator` returns **nothing** — it rsyncs whole directories without enumerating. Verify by listing a nightly Wasm SDK bundle.

### libxml2: system dependency, not vendored

```swift
.systemLibrary(name: "Clibxml2", pkgConfig: "libxml-2.0",
               providers: [.brew(["libxml2"]), .apt(["libxml2-dev"])]),
```

`Sources/Clibxml2/module.modulemap` is **0 bytes** — it exists purely so SwiftPM runs `pkg-config` and feeds flags to the C target. Every Dockerfile in `swiftlang/swift-docker` installs `libxml2-dev`/`libxml2-devel`. For *consumers* of a released toolchain this is invisible because the toolchain statically links it (`build-script-impl` lists `libxml2` in `components=(...)` and passes `-DLIBXML2_DEFINITIONS="-DLIBXML_STATIC"`).

### swift-foundation has reimplemented ZERO XML

`grep -ril "XMLDocument\|XMLParser\|libxml" Sources/` over swift-foundation @ `af8c8086` → **no matches**. `#if canImport(FoundationEssentials)` and `#if canImport(FoundationXML)` are **orthogonal axes**. FoundationEssentials will never give you XML.

### The pure-Swift XML landscape

| Package | Pure Swift? | Last commit |
|---|---|---|
| XMLCoder | **No** — wraps `XMLParser` | 2026-05-13 |
| SWXMLHash | **No** — wraps `XMLParser` | 2026-04-30 |
| AEXML | **No** — wraps `XMLParser` | 2024-01-16 |
| Fuzi | **No** — binds libxml2 directly | 2023-02-21 |
| XMLParsing | **No**; dead; no `canImport(FoundationXML)` guard → likely broken on Linux | 2018-10-07 |
| **xylem** (compnerd) | **YES** | 2026-05-07 |

**`compnerd/xylem` is the one genuinely pure-Swift XML parser, and it has exactly the design Assay needs.** Announced [forums.swift.org/t/85754](https://forums.swift.org/t/xylem-a-pure-swift-xml-parser/85754) (2026-04-01, Saleem Abdulrasool). Purity verified independently by grepping all imports: **only** `import XMLCore`/`DOMParser`/`SAXParser`. Zero Foundation, zero libc, zero `#if canImport`, zero `#if os()`.

`Sources/XMLCore/Location.swift` and `SourceRange.swift`:

```swift
public struct Location: Equatable { public let line: Int; public let offset: Int }
package struct LocationTracker { package var line = 1; package var offset = 0 ... }
public struct SourceRange: Equatable { public let bounds: Range<Int> ... }
package struct Located<Value>: ~Escapable where Value: ~Escapable {
  package let value: Value
  package let source: SourceRange
```

That is *precisely* the "carets pointing into the bytes" shape §3 of your document promises.

**Caveats:** requires Swift 6.2+, uses `~Escapable`/`@_lifetime`, declares `platforms: [.macOS(.v26)]`, and **has no `.github/workflows` directory at all** — the "runs anywhere" claim is entirely untested by CI. Explicitly unsupported: DTD validation, external entities, XML 1.1, non-UTF-8 encodings, XInclude, streaming/pull reader, XSLT, XSD.

**Verdict: a library wanting (a) all Apple platforms, (b) Linux/Windows/Android/Wasm, (c) no system library, and (d) source-location errors must vendor or write its own XML parser.** Foundation cannot deliver (a)+(c)+(d) on any platform set — `XMLParser`'s `lineNumber`/`columnNumber` are only valid *during* delegate callbacks, with no byte ranges and no way to attach a span to a decoded value after the fact.

---

## 5. Embedded Swift — be honest, say "not a target"

### Where the docs actually are

⚠️ **`swiftlang/swift/docs/EmbeddedSwift/UserManual.md` is now a 3-line redirect stub** — all 7 files in that directory are. **Do not cite them.** The real DocC catalogue is `Sources/EmbeddedSwift/EmbeddedSwift.docc/` in **`swiftlang/swift-embedded-examples`**. Secondary: the compiler's `EmbeddedRestrictions` diagnostic group, published at https://docs.swift.org/compiler/documentation/diagnostics/embedded-restrictions/.

⚠️ **The vision doc `swift-evolution/visions/embedded-swift.md` is substantially obsolete** — `Introduction.md` says so outright. It forbids existentials, `Any`, metatypes and untyped throws; **all four now work on `main`.**

### ⚠️ The version cliff — this matters most

**The published docs describe Swift 6.4, which is not released.** Latest `-RELEASE` tag is `swift-6.3.3-RELEASE`.

| Feature | 6.3 (shipping) | 6.4 / main (docs) |
|---|---|---|
| existentials `any P` | **class-bound only** | **fully supported** |
| `Any` | **forbidden** | **supported** |
| metatypes / `T.self` | type hints only | **supported** |
| untyped `throws` / `any Error` | **forbidden** (typed throws only) | **supported** |

### The restriction matrix

| Feature | Status |
|---|---|
| **`Mirror` / reflection** | ❌ **"intentionally unsupported long-term"** |
| **`Codable`/`Encodable`/`Decodable`** | ❌ **"intentionally unsupported long term"** (wording added 2026-07-14). Reason: built on `any Encoder`/`any Decoder` existentials *with generic requirements* — the exact forbidden shape |
| **`Foundation`** | ❌ unavailable, no timeline, no owner. Philippe Hausler, Feb 2026: *"Data would require an allocator… JSON would face some issues around existentials."* Only **2** `#if !hasFeature(Embedded)` sites exist in all of swift-foundation |
| **Regex** | ❌ permanently (§3) |
| **Casting *to* an existential** (`x as? any P`) | ❌ permanent |
| **Opening an existential** (passing `any P` to `func f<T: P>`) | ❌ permanent |
| **Calling an unbounded generic method on an existential** | ❌ permanent |
| **Parameter packs / variadic generics** | ❌ "not yet" — ⚠️ often load-bearing in macro-generated code |
| `weak`/`unowned` | ❌ ("not yet"); `unowned(unsafe)` allowed |
| Library Evolution / non-WMO / `@objc` | ❌ permanent |
| **`String` + interpolation** | ✅ **works** — but `==`, `.count`, hashing, `.split()`, indexing all require manually linking `libswiftUnicodeDataTables.a`. `assert`/`precondition`/`fatalError` take **`StaticString` only** |
| **KeyPath** | ⚠️ default: hard error `embedded_swift_keypath`. **But** `EXPERIMENTAL_FEATURE(EmbeddedKeyPaths, true)` on main gives full `KeyPath`/`WritableKeyPath`/`PartialKeyPath`/`AnyKeyPath` with **get and set**, emitted as **immortal constant globals — zero allocation**. Double-experimental, main-only, `Status.md` stale, multi-component `\A.b.c` **unverified** |
| **Typed throws** `throws(E)` | ✅ works even on 6.3 |
| **Macros** | ✅ **FULLY SUPPORTED** |
| Generics, `some P`, `Array`/`Dictionary`, enums w/ payloads, `Hashable` synthesis | ✅ |
| async/await | ⚠️ single-threaded mode; ~25 tests cover Task/TaskGroup/AsyncStream |
| heap allocation | ✅ by default; `-no-allocations` mode rejects classes, `Array`, escaping closures, **and `_read`/`_modify` coroutine accessors** |

**Macros working is the one genuinely good piece of news.** Verified two ways: the compiler test `test/Macros/macro_unique_name_embedded.swift` builds a `PeerMacro` plugin and type-checks the client with `-enable-experimental-feature Embedded -wmo`; and `swiftlang/swift-embedded-examples` uses `apple/swift-mmio`'s attached macros in production under SwiftPM. It works because macros are compile-time source expansion — the *plugin* is a host dylib linked against SwiftSyntax; Embedded restrictions apply only to the *output*. (The pessimistic [forums thread 72650](https://forums.swift.org/t/swift-macros-with-embedded-swift-and-make-as-build-system/72650) is June 2024 and obsolete — a hand-rolled Makefile problem.)

### Verdict — say "not a target," honestly

Assay as written cannot run in Embedded Swift, and the regex half never will. `Codable`, `Mirror`, `Foundation`, existential casts, and `.regex` are all permanent blockers. **The correct thing to write in the document is "Embedded Swift is not a target."**

But there's a subtlety worth one sentence: the *architecture* Embedded forces — macro-generated static code instead of reflection, hand-rolled character scanning instead of regex, typed throws, `StaticString` diagnostics — **is the architecture you should want anyway**, because it's also what makes you fast on Wasm and small on Android. If you keep `AssayCore` free of `any`-typed rule storage and reflection, an Embedded subset becomes a *future* possibility rather than a rewrite. Don't promise it; just don't foreclose it.

One CI trick worth stealing regardless: **`-Wwarning EmbeddedRestrictions`** surfaces Embedded diagnostics as warnings during a **non-Embedded** build.

---

## 6. Wasm — realistic, and it's the best-fit workload

**Foundation on Wasm, from corelibs' own CMakeLists:**
```cmake
if(CMAKE_SYSTEM_NAME STREQUAL "WASI")
    # Networking is not supported on WASI
    set(FOUNDATION_BUILD_NETWORKING_default OFF)
...
# We know libdispatch is always unavailable on WASI
```

So: `Foundation` ✅, `FoundationEssentials` ✅, `FoundationXML` ✅ (probably — §4), **`FoundationNetworking` ❌, `Dispatch` ❌.** ICU **is** linked in (`wasmswiftsdkhelpers.py` passes `_SwiftFoundationICU_SourceDIR`). swift-foundation has ~30 files with `os(WASI)` conditionals and a `wasiLibcCSettings` block.

**Every confirmed Wasm blocker lies outside what a bytes-in/structs-out library touches:** no sockets, no libdispatch, no networking, no threads, no dynamic linking, no process spawning, no pipes. This is precisely the shape that works today.

**Threading: treat Wasm as single-threaded.** The official SDK has no threads triple; `wasip1-threads` requires a third-party swiftwasm SDK; and WasmKit can't execute it, so you can't test it with the toolchain's own runner. Swift Concurrency itself works on a single-threaded cooperative executor.

**Code size — three published data points spanning two orders of magnitude:** Embedded hello-world **~9.7 kB** ([forums 80405](https://forums.swift.org/t/80405)); a **no-Foundation** pure-Swift JSON library **~360 KB** ([forums 88365](https://forums.swift.org/t/88365)); a full Foundation-using app **~50 MB raw / ~12 MB Brotli** (Goodnotes). **Foundation, chiefly via ICU, is the dominant size term.** That third data point is the single strongest argument for a Foundation-free `AssayCore`.

**Testing genuinely works.** swift-testing's `Documentation/WASI.md`: *"In Swift 6.3 and later, running `swift test --swift-sdk <wasm_swift_sdk_id>` builds and runs your tests."* WasmKit ships **inside the toolchain** and SwiftPM auto-registers it as `.testRunner` and `.debugger` for wasm triples.

### ⭐ The one thing you must copy

`swiftlang/swift-syntax` is the only first-party package that actually *runs* its tests on Wasm, and its `Toolsets/wasi-test-toolset.json` bumps the stack:

```json
{ "linker": { "extraCLIOptions": ["-z", "stack-size=16777216"] },
  "testRunner": { "path": "/usr/bin/env",
    "extraCLIOptions": ["wasmkit","run","--dir",".build","--dir","/","--stack-size","16777216"] } }
```

**The default Wasm stack is too small for recursive-descent parsers.** A decoding library must do this.

Most other packages only *build* on Wasm, scoped to one leaf target — swift-nio does `--target NIOCore` only, because NIO proper doesn't build on Wasm.

---

## 7. Windows — more real than its reputation, with sharp CI edges

**Foundation is complete.** The decisive evidence is the installer manifest, `swift-installer-scripts/platforms/Windows/RuntimeLibraries.props`:

```xml
<Module Include="Foundation" LibraryName="Foundation"
        StaticDependencies="CoreFoundation;brotlicommon;brotlidec;curl;libxml2;zlib;_FoundationCShims;_FoundationInternationalizationData" />
<Module Include="FoundationEssentials" ... />
<Module Include="FoundationInternationalization" ... />
<Module Include="FoundationNetworking" ... />
<Module Include="FoundationXML" ... />
<Library Include="_FoundationICU" ... />
<Module Include="Testing" Group="DeveloperTools" />
```

Reading precisely: both Foundations ship; **URLSession on Windows is curl-based, not WinHTTP**; libdispatch is a real DLL; ICU ships vendored; CoreFoundation/curl/libxml2/zlib/brotli are all **statically linked into `Foundation.dll`**; the `import FoundationNetworking`/`FoundationXML` split applies identically to Linux. Official installers for **x86_64 and ARM64** (ARM64 since 6.0.3). swift-testing is first-class — there's a dedicated `_Testing_WinSDK.dll`.

One confirmed build wart, in corelibs' CMakeLists on `main`: `# Don't enable WMO on Windows due to linker failures`.

### ⚠️ The CI trap that will cost you an afternoon

**`swift-actions/setup-swift` v3 does NOT support Windows.** `src/windows/windows.ts` on `main` is, in its entirety:

```typescript
export async function setupWindows(version: string) {
  throw Error("Windows is not supported yet");
}
```

The v3 rewrite pivoted to Swiftly, and **Swiftly has no Windows support** (its README: "swiftly is supported on Linux and macOS"). Working alternatives: **`compnerd/gha-setup-swift`** (the only one confirmed for Windows ARM64; requires PowerShell, bash unsupported; needs a separate `gha-setup-vsdevenv` step) and **`SwiftyLab/setup-swift`** (what Yams uses; note "Swift 5.10 and after does not support caching on Windows").

**The dominant pattern is Docker on `windows-2022`** via `swiftlang/github-workflows`, whose defaults are `windows_swift_versions: ["5.9","6.0","6.1","6.2","6.3","nightly-main","nightly-6.4.x"]` — note the comment `# "5.10" is omitted for Windows because the container image is broken` — and `windows_build_command: "Invoke-Program swift test"`.

**PowerShell does not propagate exit codes**, which is why that helper exists:
```yaml
function Invoke-Program($Executable) { & $Executable @args; if ($LastExitCode -ne 0) { exit $LastExitCode } }
```
The same file carries `# Running in script mode fails on Windows (https://github.com/swiftlang/swift/issues/77263)`.

Also: **Windows has no rpath**, so the toolchain `bin` directory must be on `PATH` or the test DLLs won't load. And "static" Swift on Windows still requires two DLLs (`BlocksRuntime.dll`, `dispatch.dll`) — single-binary deployment is not achievable.

**UNKNOWN, and I refuse to guess:** the current Foundation-on-Windows defect inventory, particularly **file path handling** (backslash/drive letters/UNC/`\\?\` long paths/`FileManager` case-insensitivity). GitHub issue search was blocked. Historically these were the roughest edges; there is **no 2026 evidence either way**. Given `parse(contentsOf: URL)` is in your API, this is worth a Windows CI test with a `C:\` path and a path containing spaces before you ship.

Also **UNKNOWN**: `winget install Swift.Toolchain` — no manifest found, no reference in `swift-installer-scripts`, no CI using it. Every install path observed downloads the `.exe`.

---

## 8. Efficiency parity — the honest answer

### The historical gap was real and enormous — CONFIRMED

- **JSON:** swift-extras-json's README benchmarked the same machine, Swift 5.1 — Foundation encode **macOS 2.61s vs Linux 13.03s**; decode **2.72s vs 10.27s**. ~5x and ~3.8x.
- **String:** [corelibs#3694](https://github.com/swiftlang/swift-corelibs-foundation/issues/3694) — `replacingOccurrences` on 1M chars, **Linux "over 20s" vs Darwin "0.1s"** (~200x), cause quoted as *"O(n^2)… O(m*n)"*.
- Tony Parker on why: *"On Darwin, the ObjC implementation of `JSONSerialization` is actually pretty fast… on Linux there has not been as much effort put into optimization."*

### ⚠️ Two corrections to figures you'll see quoted

The famous numbers come from [swift.org/blog/foundation-preview-now-available](https://www.swift.org/blog/foundation-preview-now-available/) (April 2023): *"over a 20% improvement in some benchmarks"* (Calendar), *"a massive 150% improvement"* (date formatting), *"improvements in decode time from 200% to almost 500%."*

1. The Calendar figure is *"in **some** benchmarks"* — heavily hedged.
2. **The 150% figure carries no platform attribution.** The stated comparison is *"over the previous C and Objective-C versions"* — it reads as Darwin-vs-Darwin. **Do not cite it as a Linux number.** No hardware, no baselines, no benchmark source was ever published for any of the four claims, and none has been reproduced.

`swift-foundation/Benchmarks/` exists (23 files, `ordo-one/package-benchmark`, including a Swift port of nativejson-benchmark with `canada.json`/`twitter.json`) and its `Package.swift` supports `.useToolchain` so cross-platform comparison is *designed for*. **Zero baselines are committed and there is no benchmark job in `.github/workflows/`. No such run has ever been published.**

### Real measured numbers, from PRs

- **JSON, production telemetry across 80k devices** ([PR #1481](https://github.com/swiftlang/swift-foundation/pull/1481)): JSONDecoder median **+52.6%**, JSONEncoder **+54%**. Root cause was `T.self is _JSONStringDictionaryDecodableMarker.Type` dynamic casts scaling with binary size (150k+ conformance descriptors). ⚠️ **Directly relevant to you** — a macro-driven decoder that avoids dynamic casts entirely dodges this whole class of problem.
- **URL, measured on Ubuntu 24.04** ([PR #1844](https://github.com/swiftlang/swift-foundation/pull/1844), merged 2026-03-26, `FOUNDATION_SWIFT_URL_V2`): **5–8x** for path-component ops, **2–3x** for parsing. One of very few figures **explicitly measured on Linux**.
- **Hebrew calendar, native Swift replacing ICU C++** ([PR #2028](https://github.com/swiftlang/swift-foundation/pull/2028)): enumerating 1000 Hanukkahs **55 µs → 167 ns (325x)**, zero divergences vs ICU across 392 rule shapes. *The direction of travel is replacing ICU, not wrapping it faster.*

### ⭐ The asymmetry has inverted — Darwin is now the slow one for `Data`

`DATA_LEGACY_ABI` is defined **only for `.macOS, .iOS, .tvOS, .watchOS, .visionOS`**. Linux/Windows/Wasm/Android get the **new** `Data` representation; Darwin is held back by ABI stability.

Jeremy Schonfeld (Apple), [forums.swift.org/t/86983](https://forums.swift.org/t/discussion-bag-of-bytes-types/86983), **May 2026**:

> "**`Data.bytes` is 787% faster** and produces significantly smaller client binaries **with the new ABI**, and **147% faster with the existing ABI**"
> "**In common cases, I've found that the throughput performance of `Data` is now comparable to the performance of `Array<UInt8>` for equivalent operations when using the new ABI.**"

And, June 2026: *"we've done a lot of work in Swift 6.4 to improve this (a decent amount on Darwin while maintaining ABI stability but **significantly more on non-Darwin**)."*

**Consequence: the old "avoid `Data`, use `[UInt8]`" folklore is now largely obsolete on Linux/Windows and only partly true on Darwin — and the remaining gap is a Darwin penalty.** If Assay's design was built on the assumption that Linux is the slow platform, that assumption is inverted for byte handling.

### ARC and allocators — **no published cross-platform data exists**

I want to be blunt here because it's tempting to assert something.

- **There is no published Darwin-vs-Linux retain/release measurement.** I searched forums.swift.org exhaustively (threads 4732, 31185, 17205, 53567, 54206, 37870, 5211). Do not claim one.
- What *is* confirmable from source: a Darwin-arm64-only ARC fast path exists (`stdlib/public/runtime/HeapObject.cpp`, gated `#if __arm64__ && __LP64__ && defined(__APPLE__)`, delegating to `swiftSwiftDirectRuntime` which is **not in the open-source tree**). No performance figure published. But the `SWIFT_CC_PreserveMost` refcount calling convention is set for **all aarch64 including Linux**, and `_swift_retain_impl` is platform-neutral.
- **INFERENCE from source:** native Swift classes take the **identical `swift_retain` path** on Darwin and Linux. `objc_retain` only enters via `swift_unknownObjectRetain` for bridged objects, which don't exist on Linux. **So the historical corelibs slowness is not an "ARC is slower on Linux" story — it's the same code.** The gap was algorithmic (O(n²) string search) and architectural (CF/ObjC bridging round-trips), which is exactly what the rewrite removed.
- **Allocators: weakest evidence area, do not assert a direction.** https://www.swift.org/documentation/server/guides/allocations.html's only platform statement is *"If your production workloads run on Linux instead of macOS, **the number of allocations** can differ significantly depending on your setup"* — about **counts, not per-allocation cost**. The jemalloc-on-Linux advice in the server ecosystem is about **RSS/memory-return behaviour, not throughput**, with no numbers in the thread. Counter-evidence: Michael Eisel (https://eisel.me/devtool-allocators) reports swapping macOS's *default* allocator gives *"10% or more"* on Swift/C++ builds — people replace Darwin's allocator for wins too.
- **Windows: nothing published at all.** The [Windows Workgroup announcement](https://www.swift.org/blog/announcing-windows-workgroup/) (Jan 2026) has no performance statements. PR #1844 lists Windows as *tested* but publishes numbers only for Ubuntu. This is a genuine gap in the public record, not a search failure.

### What "efficient on all platforms" actually means for you

The published record supports one clear strategy: **the platform asymmetries live in Foundation's platform-variable paths, not in the language.** ARC is the same code. The allocator question is unanswered. `Data` is now fine and its residual penalty is on Darwin. What genuinely differs across platforms is (a) ICU's presence and size, (b) which Foundation implementation services a call, and (c) `Data`'s ABI. **A parser that works on `RawSpan`/`UTF8` bytes with a macro-generated, dynamic-cast-free decode path has near-identical performance everywhere by construction** — and that is a far stronger claim than benchmarking your way to parity through Foundation.

⚠️ And note: `package-benchmark`'s metric sets are **asymmetric** (`syscalls`/`contextSwitches` macOS-only; `readSyscalls`/`writeBytesPhysical` Linux-only). That's a real obstacle to publishing apples-to-apples cross-platform numbers, and likely part of why Foundation never has.

---

## 9. What the community actually does

### ⭐ Finding 1: modern Apple core libraries omit `platforms:` entirely

Confirmed absent from **swift-nio, swift-log, swift-collections, swift-crypto, swift-argument-parser, swift-algorithms, swift-http-types, swift-service-lifecycle, Yams**. swift-collections' README says it outright: *"the package has no minimum deployment target."*

This matters because **SwiftPM `platforms:` only constrains Apple platforms** — declaring it raises your Apple floor and buys nothing on Linux/Windows/Android/Wasm. The replacement idiom is **availability macros**:

```swift
.enableExperimentalFeature("AvailabilityMacro=hummingbird 2.0:macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, Android 28")
```

(hummingbird, guarded `#if compiler(>=6.3)`; swift-http-types defines a whole ladder `"HTTPTypes 1.0"` … `"HTTPTypes 1.7"`.) Where `platforms:` survives it's for a reason — swift-syntax pins **5.9** deliberately because it's a compiler dependency; vapor v5 sets **macOS 26.2**; corelibs-foundation sets `.macOS("99.9")` as a deliberate poison pill.

### ⭐ Finding 2: the dependency-free-core pattern, and its canonical form

**swift-http-types is the cleanest template and it's exactly your shape:**
```swift
.target(name: "HTTPTypes")                                  // zero deps, zero Foundation, Embedded-capable
.target(name: "HTTPTypesFoundation", dependencies: ["HTTPTypes"])
```

**swift-nio** is the deeper version: `NIOCore` (portable protocols + `ByteBuffer`, **zero `import Foundation`**), `NIOPosix` (syscall-backed), `NIOEmbedded` (deterministic in-memory), `NIO` (legacy umbrella re-exporting all three). Others with genuinely dependency-free cores: **swift-log** (`Logging`, zero deps, zero Foundation), **swift-syntax** (the `dependencies:` array is *entirely absent*), **swift-service-lifecycle** (no Foundation at all), **xylem**.

**swift-nio's C-shim technique is worth copying:** `CNIODarwin`, `CNIOLinux`, `CNIOWindows`, `CNIOWASI`, `CNIOFreeBSD`, `CNIOOpenBSD` are all **unconditional dependencies with no `.when(platforms:)`**. Gating happens inside the C sources, with a no-op symbol so the file is never empty:

```c
// Xcode's Archive builds with Xcode's Package support struggle with empty .c files (SR-12939).
void CNIOLinux_i_do_nothing_just_working_around_a_darwin_toolchain_bug(void) {}
#ifdef __linux__
```

### The 2026 libc ladder — canonical form (swift-log `Sources/Logging/Locks.swift`)

```swift
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Android)
@preconcurrency import Android
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#if canImport(wasi_pthread)
import wasi_pthread
#endif
#else
#error("The concurrency lock module was unable to identify your C library.")
#endif
```

Load-bearing details: **`canImport(Darwin)` first**; **`os(Windows)` not `canImport`, and it needs *two* imports**; **`Android` before `Musl`/`Bionic`** (Bionic satisfies multiple checks — ordering matters); `wasi_pthread` nested and separately guarded; a trailing `#error`. swift-argument-parser adds module-qualified calls (`ucrt._exit(code)`) to disambiguate.

### `FoundationEssentials` adoption is real but not universal

Present in swift-crypto (**141 occurrences**), hummingbird (15 files), swift-http-types, swift-nio (one target), swift-argument-parser. **Absent from** vapor (plain `Foundation` unconditionally), swift-syntax, swift-log, swift-collections, swift-service-lifecycle.

The most sophisticated form stacks four conditions and uses `public import` — swift-http-types `HTTPRequest+URL.swift`:
```swift
#if FoundationURL && !hasFeature(Embedded)
#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#endif
```

⚠️ **FoundationEssentials is not a drop-in subset.** swift-argument-parser's `Utilities/Foundation.swift` uses `internal import` on both branches and then **branches behaviourally**, because `NSError` doesn't exist in Essentials.

### Traits (SwiftPM 6.1+) are the newest structural tool

**vapor uses traits *instead of* `.when(platforms:)` entirely** (zero platform conditions in its manifest): `WebSockets`, `TLS`, `bcrypt`, `HTTPClient`, `Multipart`, `MacroRouting`, all default-on, with `.target(name: "CVaporBcrypt", condition: .when(traits: ["bcrypt"]))`. Vapor even CI-tests `swift test --disable-default-traits`. swift-http-types has `FoundationURL` (default-on); swift-log has seven `MaxLogLevel*` traits.

**For Assay: `.trait(name: "Foundation")` default-on, gating `Data`/`URL`/`Date` conveniences, is now the idiomatic way to stay Embedded/Wasm-friendly without a separate target** — exactly what `FoundationURL` does.

### ⭐ Yams — the vendored-C template, and the Windows trap

```swift
.target(name: "CYaml", exclude: ["CMakeLists.txt"], cSettings: [.define("YAML_DECLARE_STATIC")]),
.target(name: "Yams", dependencies: ["CYaml"], exclude: ["CMakeLists.txt"], cSettings: [.define("YAML_DECLARE_STATIC")]),
```

Layout uses SwiftPM's **default `include/` convention** — no `publicHeadersPath:`, no `headerSearchPath` — plus a hand-written `module.modulemap`.

**The whole trick is `yaml.h:30-40`:**
```c
#elif defined(_WIN32)
#   if defined(YAML_DECLARE_STATIC)
#       define  YAML_DECLARE(type)  type
#   else
#       define  YAML_DECLARE(type)  __declspec(dllimport) type
```

`YAML_DECLARE_STATIC` must be defined on **both** the C target *and* the Swift target — because the Swift target re-parses `yaml.h` through the modulemap and would otherwise see `__declspec(dllimport)` and emit import thunks for a DLL that doesn't exist. **That's why the define appears twice.** Any vendored C library hits this.

Other vendoring discipline worth copying: **swift-crypto** vendors BoringSSL pinned by commit hash recorded in both a manifest comment and `hash.txt`, refreshed by `scripts/vendor-boringssl.sh` which sed-mutates `Package.swift` between `MANGLE_START`/`MANGLE_END` markers, and **prefixes every vendored header** (`CCryptoBoringSSL_*.h`) to avoid collisions.

Note: **`.systemLibrary` is essentially extinct in modern packages** — zero occurrences across the entire survey except corelibs-foundation's `Clibxml2`. **`.binaryTarget`: zero occurrences anywhere.** Modern practice is vendor, don't system-depend.

### CI reality

**`swiftlang/github-workflows/.github/workflows/swift_package_test.yml`'s out-of-the-box default is Linux + Windows only.** Every exotic platform is opt-in: `enable_linux_static_sdk_build`, `enable_wasm_sdk_build`, `enable_embedded_wasm_sdk_build`, `enable_android_sdk_build`, `enable_android_sdk_checks`, `enable_macos_checks`, `enable_ios_checks`, `enable_freebsd_checks` — **all default false**.

Actual coverage:

| Repo | Linux | Win | macOS | Android | Wasm | Emb-Wasm | musl |
|---|---|---|---|---|---|---|---|
| swift-nio | ✓ | ✓ | ✓ | ✓ | ✓ (`--target NIOCore`) | ✗ | ✓ |
| swift-log | ✓ | ✓ | ✓ (+ios/tvos/watchos/visionos) | ✓ | ✓ | ✗ | ✓ |
| **swift-collections** | ✓ | ✓ | ✓ | ✓ (+emulator) | ✓ | **✓** | ✗ |
| **swift-http-types** | ✓ | ✓ | ✓ | ✗ | ✓ | **✓** | ✓ |
| swift-syntax | ✓ | ✓ | ✗ | ✗ | ✓ (**runs tests** via wasmkit) | ✗ | ✗ |
| swift-crypto | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✓ |
| Yams | ✓ (5.7→6.3.2) | ✓ (SwiftyLab) | ✓ ×3 | ✓ (skiptools) | ✗ | ✗ | ✗ |
| vapor | ✓ (one image) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |

**Embedded Swift is tested by exactly two repos**, both with the identical recipe — a separate job with everything else disabled, scoped to the portable core target:
```yaml
  embedded-swift:
    uses: swiftlang/github-workflows/.github/workflows/swift_package_test.yml@0.0.13
    with:
      enable_linux_checks: false
      enable_macos_checks: false
      enable_windows_checks: false
      enable_embedded_wasm_sdk_build: true
      swift_flags: --target Collections
```

**The single most useful CI flag in the whole survey: `--explicit-target-dependency-import-check error`** (swift-nio, swift-syntax, swift-service-lifecycle, swift-openapi-generator). It catches accidental transitive imports — the exact bug class that makes a package silently un-portable. If `AssayCore` must stay Foundation-free, **this flag is how you enforce it mechanically instead of by discipline.**

Android has an easy path too — `skiptools/swift-android-action@v2` is a one-step emulator test (Yams uses it), far lighter than the swiftlang reusable workflow.

---

## 10. What this forces on the developer-facing API

Concrete edits to EXPERIENCE.md, in rough order of how much they change the document.

### Must change

**1. `.regex` — keep the `String`, never expose `Regex`.**
`@Validate(.regex(#"^[a-z0-9_]+$"#))` already takes a String literal. Keep it that way and **never put a `Regex` value in a rule case, a stored property, or any public signature** — that's what leaks `@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)` onto every call site. Two viable internals: (a) `String.range(of:options:.regularExpression)` — zero annotation, what Vapor and Peppermint do, but two engines behind one API and a `NO_REGEX` degradation path; or (b) build a `Regex` lazily from the String behind a cache, which requires a macOS 13 floor but keeps you off Foundation entirely (better for Wasm). **Validate the pattern at rule-construction time and throw** — copy SwiftLint's `throws(Issue)` model, don't copy Vapor's `nil`-conflates-both bug. And document that `.regex` is unavailable in Embedded, if you ever mention Embedded.

**2. `.url` needs rewriting, and it's a harder gate than `.regex`.**
`URL(string:)` accepts `"hello"`. The strict form is `macOS 14/iOS 17`. Either raise the Apple floor to 14/17, or hand-roll (scheme + authority + host syntax check), or state plainly that `.url` means "parses as a URL reference," not "is a valid absolute URL." Also: **host IDNA is unavailable off-Darwin**, so `.url` on an internationalized domain behaves differently on Linux than on macOS. That's a cross-platform correctness bug waiting to be filed against you.

**3. `@DateFormat(.custom("yyyy-MM-dd"))` must not mean UTS-35.**
As written it implies `DateFormatter`/`Date.FormatStyle` → ICU → FoundationInternationalization → ~40 MB on Android, dominant term on Wasm. Options: drop `.custom` to a small hand-parsed subset (`yyyy`, `MM`, `dd`, `HH`, `mm`, `ss`, literals — a few hundred lines, ICU-free, identical everywhere); or keep the full UTS-35 escape hatch but **put it in the Foundation-dependent target/trait** and say so in the docs. `.iso8601` and `.unixSeconds` are free — `Date.ISO8601FormatStyle` is genuinely ICU-free and `Date.HTTPFormatStyle` (RFC 9110) comes along with it. **This is the cheapest big win available to you.**

**4. `.uuid` — hand-roll, don't call `UUID(uuidString:)`.**
Two different C implementations split by `#if TARGET_OS_MAC`; the non-Darwin one is `sscanf`-based with libc-dependent edge cases. ~15 lines gets you bit-identical behaviour on every platform, plus an explicit decision about braces/URN/bare-32-hex.

**5. `.email` and `.hostname` — hand-roll, no regex.**
Split on the last `@`, validate local-part charset and ≤64, run a hostname validator on the domain. Nothing in Foundation or the stdlib does this (`grep -ril email` over swift-foundation → zero files). **This version needs no regex engine, which means `.email` keeps working on Wasm-minimal and would keep working in Embedded** — unlike `.regex`. That asymmetry is worth stating in the doc: some rules are portable, `.regex` is the one that isn't.

**6. XML must be a separate product, and it should not use `XMLParser`.**
Two independent reasons, and both hold:
- **Packaging:** `import FoundationXML` pulls `_CFXMLInterface` → libxml2, which on Android transitively drags liblzma + libiconv. JSON-only users must not link it. Given §13 says "JSON users never pay for it," a separate `AssayXML` product is the only way that sentence is literally true.
- **Capability:** `XMLDocument` is macOS+Catalyst only, so a cross-Apple-platform library can't use it at all; `XMLParser` gives you `lineNumber`/`columnNumber` **only during delegate callbacks**, with no byte ranges — which cannot produce the caret output §3 promises. And swift-foundation has reimplemented **zero** XML, so this will not improve.

**The realistic answer is vendoring a pure-Swift parser.** `compnerd/xylem` already has exactly your design (`Located<Value>` + `SourceRange` + `LocationTracker` producing 1-based line + UTF-8 byte offset, matching libxml2's convention). Costs: Swift 6.2, `~Escapable`/`@_lifetime`, `platforms: [.macOS(.v26)]`, **no CI at all** — if you depend on it, you become its cross-platform CI. Vendoring/forking is probably safer than depending.

**7. YAML has the same shape.** If you go the Yams/libyaml route, copy Yams' vendoring exactly — default `include/` convention, hand-written modulemap, and **define the static macro on both the C and the Swift target** (the `__declspec(dllimport)` trap). If you want `AssayCore` truly dependency-free, YAML needs to be a separate product too. Multi-document `parseAll(yaml:)` and anchors/aliases/merge keys are all fine either way.

**8. `func message(for locale: Locale)` in §3 needs a caveat.**
Essentials-only, `Locale` silently degrades to `_LocaleUnlocalized("en_001")` with no compile error. If localisation is a headline feature, either require `FoundationInternationalization` for the localisation path (separate target/trait), or take a locale *identifier* `String` and let the caller own the lookup. The second is more portable and fits "no global configuration."

**9. `parse(contentsOf: URL)` belongs in the Foundation-dependent layer.** File I/O, extension sniffing, and `FileManager` are all Foundation. On Wasm you need `--dir` mounts; on Windows the path-handling story is **unverified in 2026**. Keep the byte-taking overloads in the core.

### Should change

**10. Take bytes, not `Data`, in the core.** Public API over `some Collection<UInt8>` / `RawSpan` / `[UInt8]`, with `Data` overloads in the Foundation adapter. Two reasons: `Data` *is* Foundation, and the `Data`-vs-`[UInt8]` performance story now has a **Darwin penalty** (`DATA_LEGACY_ABI`), so a `Data`-typed hot path is the one place your performance genuinely differs by platform. If you use `Span` internally, source it from `ContiguousArray`/`ArraySlice`/`Data` — **never `Array` or `String`**, which are macOS-26-only.

**11. `report.render(.terminal(color: .auto))` needs the libc ladder.** TTY detection is `isatty` — Darwin/ucrt+WinSDK/Glibc/Android/Musl/Bionic/WASILibc, with a trailing `#error`. And there is no TTY on Wasm; `.auto` must resolve to "no colour" there rather than misbehave.

**12. KeyPaths in `@Check(at: \.end)` are fine everywhere that matters.** Darwin, Linux, Windows, Android, Wasm — no issue. Embedded is the only exception (hard error by default; `-enable-experimental-feature EmbeddedKeyPaths` on `main` gives full read/write keypaths as zero-allocation immortal globals, but multi-component `\A.b.c` is unverified). Since you're saying "Embedded is not a target," **keep the keypaths — they're the best part of §10** and the reason cross-field checks can produce carets.

**13. Say "Embedded Swift is not a target" explicitly in §13.** It belongs in the refusals list, with the one-line reason: no `Codable`, no `Mirror`, no Foundation, no regex, and casting *to* an existential is permanently forbidden.

**14. Package shape.** `platforms:` omitted (or availability macros if you need them); `AssayCore` (zero deps, zero Foundation, `--explicit-target-dependency-import-check error` enforced in CI) + `AssayFoundation` (or a default-on `.trait(name: "Foundation")`, per swift-http-types' `FoundationURL`) + `AssayXML` + `AssayYAML` as separate products. Macros are a `.macro` target and work everywhere including Embedded and cross-compilation to Android (SwiftPM #8670 fixed that).

**15. CI matrix that would let you honestly claim the platform list:** `swiftlang/github-workflows@0.0.13` with `enable_macos_checks`, `enable_ios_checks`, `enable_wasm_sdk_build`, `enable_android_sdk_build`, `enable_android_sdk_checks`, `enable_linux_static_sdk_build` all explicitly `true` (none are on by default). Wasm **must** use swift-syntax's `wasi-test-toolset.json` with `stack-size=16777216` — a recursive-descent parser will blow the default Wasm stack. On Windows, avoid `swift-actions/setup-swift@v3` entirely and add a test that reads a `C:\` path with a space in it.

### One internal inconsistency, unrelated to platforms

§13 says **"It doesn't encode."** §9 says XML attributes are *"symmetric (an attribute on the way in is an attribute on the way out)"*, and §9 mentions `@XML(.namespace(...))` matching on URI. "On the way out" is encoding. Either soften the §9 phrasing to "the annotation describes the wire shape, which `Encodable` conformance can reuse," or soften §13. Worth resolving before someone else notices.

---

## Explicitly not confirmed — do not assert these

1. **Any Darwin-vs-Linux ARC measurement.** None exists publicly.
2. **Any Swift-specific ptmalloc2-vs-magazine_malloc measurement.** None found.
3. **Any Windows Swift performance data at all.** Genuine gap in the record, not a search failure.
4. **The "150% date formatting" figure as a Linux number** — no platform attribution.
5. **Whether the shipped Wasm SDK bundle contains `FoundationXML`** (or `libswift_StringProcessing`). Build system says yes; no artifact listing found. Verify by unpacking a nightly bundle.
6. **Whether `import FoundationEssentials` alone avoids the ICU size cost on Wasm/Android.** This is the highest-value open question for anyone size-constrained on either platform.
7. **Foundation-on-Windows file-path behaviour in 2026** (`FileManager`, drive letters, UNC, long paths, case-insensitivity). GitHub issue search was blocked throughout.
8. **`winget` distribution of the Swift toolchain.** No evidence found; not asserting it doesn't exist.
9. **Published byte-size figures for `_StringProcessing`.** None exist; measure it yourself.
10. **Which platforms define `NO_REGEX`.** Zero hits in any manifest or CMakeLists — externally supplied.
11. **Swift 6.4's release date**, and whether `EmbeddedKeyPaths` merges into `Embedded`.
12. **Nothing was compiled.** Every conclusion here is from source reading and published documents.

**Local clones remain at `/home/claude/research/`** — `swift-foundation`, `swift-corelibs-foundation`, `swiftsrc` (blobless `swiftlang/swift`), `sesp`, `swift-installer-scripts`, `swift-sdk-generator`, `xylem`, and ~20 ecosystem packages under `libs/` — if you want any of this re-verified or dug into further.