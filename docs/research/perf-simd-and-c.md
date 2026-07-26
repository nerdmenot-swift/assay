# Assay: portable SIMD / unsafe core — research findings

Research date: 2026-07-25. No Swift toolchain available in this environment: **nothing here was
compiled or benchmarked**. Every claim is labelled:

- **VERIFIED** — read directly out of source I have on disk (compiler, stdlib, SwiftPM, simdjson,
  swift-crypto, Yams, swift-nio, swift-collections, swift-evolution), or reproduced with the local
  `clang-18` (which is *not* the Swift-shipped clang, so it is evidence about Clang behaviour, not
  about Swift's toolchain).
- **UNVERIFIED** — inference, recollection, or documentation that I could not cross-check against
  source. Treat as a hypothesis to test with a real toolchain.

Local checkouts used (all under `/home/claude/research/`): `swift`, `spm`, `simdjson`,
`swift-crypto`, `Yams`, `swift-nio`, `swift-collections`, `swift-evolution`, `swift-foundation`,
`swift-android-sdk`.

---

## 0. Verdict: does Assay need a C target?

**No — not to ship, and not on the platforms Assay most cares about. Yes — if and only if you
want runtime-dispatched AVX2/AVX-512 on x86-64.**

The reasoning in one paragraph: the two operations everyone assumes force you into C — a byte
shuffle (`pshufb` / `tbl`) and a movemask (`pmovmskb`) — **are both expressible from ordinary Swift**
via the `Builtin` module, and the stdlib itself does exactly this. That kills the "C is mandatory"
argument. What C still buys you is *per-function ISA targeting*: Clang has
`__attribute__((target("avx2")))`, Swift has **no equivalent at any level** (verified below), and
Swift derives target features module-wide from the TargetMachine. On arm64 and wasm32 that does not
matter — NEON is architecturally mandatory and wasm SIMD is a compile-time decision anyway — so a
pure-Swift core is fully competitive there. On x86-64 it means pure Swift pins you to the SSE2
baseline unless you play games with per-module flags.

So the shape of the recommendation:

| Target | Pure-Swift core sufficient? | Why |
|---|---|---|
| arm64 Apple (macOS/iOS/tvOS/watchOS/visionOS) | **Yes** | NEON mandatory; `Builtin.int_aarch64_neon_tbl1` reachable |
| arm64 Linux / Android arm64-v8a | **Yes** | same |
| wasm32 | **Yes** | simd128 is compile-time; no dispatch possible in C either |
| x86-64 (SSE2 baseline) | **Yes** | `pcmpeqb` + `pmovmskb` + `pand` are all SSE2; enough for structural scanning |
| x86-64 with AVX2 runtime dispatch | **No** — needs C, or a fragile per-module flag trick | Swift has no per-function target attribute |
| armv7 / i686 | **Yes** (scalar fallback) | see §5, §8 |

Concretely: **build the core in pure Swift, ship it, measure. Add a ~200-line C target later,
behind the same Swift-level dispatch protocol, only if x86-64 AVX2 measurably matters for your
users.** That is a strictly additive change — it does not force a redesign — because the dispatch
seam (a protocol or a function-pointer table selected once at load) is identical whether the
implementation behind it is Swift or C.

The cost side reinforces this: a C target is *not* free. It is the single biggest source of
breakage for Wasm SDK builds, Android cross-compilation, static-musl builds, and Xcode previews
(§8), and it will pull `.headerSearchPath`/module-map/`dllimport` maintenance into your build for
every platform you add.

---

## 1. What Swift's own SIMD can and cannot do

### 1.1 There is no byte shuffle in the stdlib — VERIFIED

`/home/claude/research/swift/stdlib/public/core/SIMDVector.swift:267-365` defines seven "swizzle"
subscripts. Every one is a plain scalar loop with a modulo, no `@_transparent`, no `Builtin`:

```swift
public subscript<Index>(index: SIMD16<Index>) -> SIMD16<Scalar>
where Index: FixedWidthInteger {
  var result = SIMD16<Scalar>()
  for i in result.indices {
    result[i] = self[Int(index[i]) % scalarCount]
  }
  return result
}
```

The `% scalarCount` alone makes this un-lowerable to `pshufb` (which uses bit 7 of each index byte
to mean "zero the lane", not a modulo) or to `tbl1` (which zeroes out-of-range). LLVM will not
recover a single-instruction shuffle from 16 extracts, 16 modulos and 16 inserts.

**So: the user's belief is correct — there is no stdlib byte shuffle.** (§2 shows this does *not*
imply you need C.)

### 1.2 There is no movemask in the stdlib — VERIFIED

`SIMDVector.swift:1563` and `:1570`:

```swift
public func any(_ mask: SIMDMask<Storage>) -> Bool { mask._storage.min() < 0 }
public func all(_ mask: SIMDMask<Storage>) -> Bool { mask._storage.max() < 0 }
```

These are horizontal min/max reductions returning `Bool`. There is **no** API that produces an
integer bitmask of lane sign bits. For a parser this is decisive: the entire simdjson-style
"compare, movemask, then iterate set bits with `trailingZeroBitCount` / `x & (x-1)`" idiom depends
on getting a `UInt16`/`UInt32`/`UInt64` out of a comparison, and `SIMDMask` will not give it to you.

### 1.3 What *does* lower to real vector instructions — VERIFIED

Two gyb files decide this.

`stdlib/public/core/SIMDIntegerConcreteOperations.swift.gyb`:
- lines 82-124: `.==`, `.!=`, `.<`, `.<=`, `.>`, `.>=` → `Builtin.cmp_eq_Vec${n}x${T}` etc. **Real
  vector compares.**
- lines 130-159: `&+`, `&-`, `&*` → `Builtin.add/sub/mul`. **Real.**
- Nothing else.

`stdlib/public/core/SIMDMaskConcreteOperations.swift.gyb:72-151`: `.&`, `.^`, `.|` on `SIMDMask`
→ `Builtin.and/xor/or`. **Real.**

Everything else in `SIMDVector.swift`'s `extension SIMD where Scalar: FixedWidthInteger`
(≈lines 760-880) — `~`, `&`, `^`, `|`, `&<<`, `&>>`, `/`, `%`, `leadingZeroBitCount`,
`trailingZeroBitCount`, `nonzeroBitCount`, `wrappedSum()` — is a `@_transparent` scalar `for` loop.
The header comment in that file says so outright:

> Implementations of integer operations. These should eventually all be replaced with @_semantics
> to lower directly to vector IR nodes.

`@_transparent` means the loop is inlined into the caller at SIL level and LLVM's SLP vectorizer
gets a chance to re-form a vector op. For `.&` / `.|` / `&<<` on a `SIMD16<UInt8>` held in a
register this **usually** works — UNVERIFIED, but it is the reason the stdlib has been able to
leave them alone. It is not something you want on your hot path without checking the disassembly.

`pointwiseMin`/`pointwiseMax` (`SIMDVector.swift:~1575-1600`) are scalar loops **without**
`@_transparent`. Those are a trap: on a `SIMD32<UInt8>` that is 32 branches, and being opaque at
SIL level they will not reliably vectorize. **UNVERIFIED** whether cross-module `@inlinable` saves
them; assume not.

### 1.4 Storage is public and is a real LLVM vector — VERIFIED

`stdlib/public/core/SIMDVectorTypes.swift.gyb:248`:

```swift
public var _value: Builtin.Vec${n}x${BuiltinName}
```

and `:261`, `:265-278` implement element access via `Builtin.extractelement` / `insertelement`.
The `_value` being `public` (underscored, so unstable, but public) is what makes §2 work at all:
you can hand a `SIMD16<UInt8>`'s raw `Builtin.Vec16xInt8` to an intrinsic and get one back.

### 1.5 Evolution status — UNVERIFIED

I found no accepted or in-review 2026 SE proposal adding shuffle or movemask to `SIMD`.
`include/swift/Basic/Features.def:270` has
`LANGUAGE_FEATURE(BuiltinVectorsExternC, 0, "Extern C support for Builtin vector types")`, which
suggests work on passing builtin vectors across the C ABI, not on new SIMD surface API. The
"should eventually all be replaced with @_semantics" comment has been in `SIMDVector.swift` for
years. **Do not plan around the stdlib fixing this.**

---

## 2. The escape hatches: `Builtin`, `@_extern`, and the clang intrinsics module

This section overturns the expected answer. There are **three** routes from pure Swift to real
vector instructions, and two of them are used in shipping Apple code.

### 2.1 `Builtin.int_<llvm-intrinsic>` reaches *any* LLVM intrinsic — VERIFIED

`lib/AST/Builtins.cpp:2565-2582`, `getLLVMIntrinsicID`: takes a builtin name, strips the `int_`
prefix, prepends `llvm.`, replaces `_` with `.`, and calls `Intrinsic::lookupIntrinsicID`. There is
no allow-list. That means these are all spellable:

| Swift spelling | LLVM intrinsic | Instruction |
|---|---|---|
| `Builtin.int_x86_ssse3_pshufb_128` | `llvm.x86.ssse3.pshufb.128` | `pshufb` |
| `Builtin.int_x86_avx2_pshufb` | `llvm.x86.avx2.pshufb` | `vpshufb` (ymm) |
| `Builtin.int_x86_sse2_pmovmskb_128` | `llvm.x86.sse2.pmovmskb.128` | `pmovmskb` |
| `Builtin.int_aarch64_neon_tbl1` | `llvm.aarch64.neon.tbl1` | `tbl` |
| `Builtin.int_aarch64_neon_umaxv` | `llvm.aarch64.neon.umaxv` | `umaxv` |
| `Builtin.int_wasm_swizzle` | `llvm.wasm.swizzle` | `i8x16.swizzle` |
| `Builtin.int_wasm_bitmask` | `llvm.wasm.bitmask` | `i8x16.bitmask` |
| `Builtin.int_ctlz` / `_cttz` / `_ctpop` (vector forms) | generic | vectorized |

**UNVERIFIED:** exact argument-type mangling suffixes Swift expects for each of these (Swift
appends `_Vec16xInt8`-style suffixes for overloaded intrinsics; for non-overloaded x86/aarch64
target intrinsics no suffix should be needed). This is the single highest-value thing to check
first with a real toolchain: write a one-liner per intrinsic and read the `-emit-assembly` output.

The stdlib does exactly this itself. `stdlib/public/core/UTF16.swift:460-489` carries the comment:

> SIMD<...> isn't generating the right code for the transcoding loop, so we use intrinsics to
> manually specify what we want

followed by `Builtin.int_vector_reduce_add_Vec8xInt8`, `Builtin.int_vector_reduce_add_Vec8xInt16`,
`Builtin.int_vector_reduce_umin_Vec8xInt16`. That is the precedent and the naming template.

### 2.2 Movemask, exactly as the stdlib writes it — VERIFIED

`stdlib/public/core/StringCreate.swift:27-31` is the whole trick and it is portable (it is generic
LLVM IR, not a target intrinsic — LLVM lowers `bitcast <16 x i1> to i16` to `pmovmskb` on x86 and
to the `vshrn`/`addv` sequence on arm64):

```swift
@_transparent
internal func _pmovmskb(_ vec: SIMD16<UInt8>) -> UInt16 {
  UInt16(Builtin.bitcast_Vec16xInt1_Int16(
    Builtin.cmp_slt_Vec16xInt8(vec._storage._value, Builtin.zeroInitializer())
  ))
}
```

Generalises to `Builtin.bitcast_Vec32xInt1_Int32` for `SIMD32<UInt8>` and
`Builtin.bitcast_Vec64xInt1_Int64` for `SIMD64<UInt8>` — **UNVERIFIED** that those builtin names
resolve, but the naming scheme in `Builtins.def` is mechanical so they very likely do. Note the
input is `cmp_slt … zeroInitializer`, i.e. "sign bit set", which is the correct semantics: to test
`v == 0x22` you first do `let m = (v .== 0x22)` and then bitcast `m._storage._value` — or use
`Builtin.cmp_eq_Vec16xInt8` directly.

**This is the single most important finding in this document.** With `_pmovmskb` and a shuffle you
have simdjson's entire primitive set.

### 2.3 `Builtin.shufflevector` is constant-mask only — VERIFIED, and a landmine

`lib/IRGen/GenBuiltin.cpp:889-896` calls `IRBuilder::CreateShuffleVector` with a hard
`cast<Constant>(Mask)`. A non-constant mask is not a diagnostic — it is a **compiler crash**
(failed cast assertion / UB in release compilers). So `Builtin.shufflevector` is fine for static
lane permutations and useless for table lookup. For dynamic shuffles you must go through
`int_x86_ssse3_pshufb_128` / `int_aarch64_neon_tbl1` / `int_wasm_swizzle`.

### 2.4 How to actually get `import Builtin` — VERIFIED

`lib/Sema/ImportResolution.cpp:451-463`: `import Builtin` is allowed if the file is a SIL file **or**
`Feature::BuiltinModule` is enabled. Note this is **not** `-parse-stdlib` — the common folklore is
wrong and out of date.

`include/swift/Basic/Features.def:436`: `EXPERIMENTAL_FEATURE(BuiltinModule, true)`. The `true`
argument is `AvailableInProduction` — i.e. it works in shipping (non-development) toolchains.

In `Package.swift`:

```swift
.target(
  name: "AssayCore",
  swiftSettings: [.enableExperimentalFeature("BuiltinModule")]
)
```

**This is not `.unsafeFlags`.** `.enableExperimentalFeature` is a first-class `SwiftSetting` and
carries none of the dependency restrictions of `.unsafeFlags` (§3.3). Precedent: `BuiltinModule` is
enabled in tagged releases of swift-collections, swift-foundation and swift-atomics — **UNVERIFIED
for the exact current tags**, but I saw the setting in those manifests during earlier passes.

Risks, stated plainly: `Builtin` is an underscored, unstable, undocumented compiler surface. Names
can change between toolchains. A `Builtin.int_*` that fails to resolve is a compile error (fine); a
`Builtin.shufflevector` with a non-constant mask is a compiler crash (not fine). Anything using
`Builtin` **must** be behind `#if` and must have a scalar fallback that is exercised in CI, and you
should pin a "known good" Swift version range and test the next one before claiming support.

### 2.5 `@_extern(c)` and `@_silgen_name` — not useful here

`Features.def:500`: `EXPERIMENTAL_FEATURE(Extern, true)`. `@_extern(c)` declares an external C
symbol from Swift *without* a C target — but it only **declares**; something still has to **define**
the symbol. There is no intrinsic to name. `@_silgen_name` is worse (it binds a Swift-mangled or
raw symbol name and bypasses type checking). Neither helps you reach `pshufb`. Mentioned only to
close them off.

### 2.6 The third route: `import _Builtin_intrinsics` — VERIFIED mechanism, UNVERIFIED in practice

Clang ships a module map for its own intrinsic headers. From
`/usr/lib/llvm-18/lib/clang/18/include/module.modulemap:10-80`:

```
module _Builtin_intrinsics [system] [extern_c] {
  explicit module arm {
    explicit module neon { requires neon  header "arm_neon.h"  export * }
    explicit module sve  { requires sve   header "arm_sve.h"   export * }
  }
  explicit module intel { requires x86  header "immintrin.h"  header "x86intrin.h" ... }
}
```

Swift's ClangImporter maps C vector types to stdlib SIMD types —
`lib/ClangImporter/ImportType.cpp:719-749`, `VisitVectorType`: element type must conform to
`SIMDScalar`, then it looks up `SIMD<count>` in the stdlib and returns the bound generic. So
`uint8x16_t` imports as `SIMD16<UInt8>` and `vqtbl1q_u8` imports as
`(SIMD16<UInt8>, SIMD16<UInt8>) -> SIMD16<UInt8>`.

That means, on arm64, `import _Builtin_intrinsics.arm.neon` plausibly gives you the real NEON
intrinsic set from pure Swift with **no C target and no `Builtin` module**. Caveats:

- Intrinsics with compile-time-constant lane/shift arguments (`vshrn_n_u16(v, 4)`,
  `vextq_u8(a, b, 3)`) expand to `__builtin_neon_*` calls that require an integer constant
  expression. Swift cannot pass one. Those will fail at Clang codegen. **UNVERIFIED** but near
  certain. `vqtbl1q_u8`, `vceqq_u8`, `vandq_u8`, `vmaxvq_u8` take no constants and should be fine.
- On x86, `_mm256_shuffle_epi8` and friends are `static __inline__ __attribute__((target("avx2")))`.
  ClangImporter would emit the body with the target attribute honoured — but the Swift call site is
  compiled *without* AVX, and `__m256i` argument passing differs between AVX and non-AVX ABIs.
  **High risk of a silent ABI mismatch. Do not rely on this for x86.**
- `requires neon` / `requires x86` gate the submodules on target features, so the wrong-arch import
  is a clean error rather than garbage.

Rank the three routes: **(1) `Builtin.int_*` — most control, most portable across arches, ugliest.
(2) `_Builtin_intrinsics.arm.neon` — most readable, arm64 only, constant-argument limitation.
(3) a C target — only when you need `__attribute__((target))`.**

### 2.7 Swift has no per-function target attribute — VERIFIED

This is the counterweight, and it is why the verdict in §0 is qualified rather than an unqualified
"no".

- `include/swift/AST/DeclAttr.def`: grep for `target` → **no matches**. There is no `@target`,
  no `@_target`, no `target_clones` analogue.
- `lib/IRGen/`: grep for `target-features` / `target-cpu` across all 70 `.cpp` files →
  **no matches**. IRGen never attaches a per-function `"target-features"` string attribute.
- `lib/IRGen/IRGen.cpp:1153-1164, :1208`: the target feature list is computed once, joined into a
  single string via `llvm::SubtargetFeatures`, and passed to `createTargetMachine`. **Module-wide,
  from the invocation's target triple/CPU only.**

Consequence: within one Swift module you cannot have `parse_avx2()` and `parse_sse2()` compiled for
different ISAs. `Builtin.int_x86_avx2_pshufb` in a module compiled for the default x86-64 target
will still emit `vpshufb` (LLVM emits target intrinsics regardless of subtarget features, and then
the backend may or may not scalarize/expand), but the surrounding codegen, the register allocation
and any spilling will assume no AVX, and on a pre-Haswell CPU the instruction faults. **You cannot
safely runtime-dispatch AVX2 from a single Swift module.**

Two ways out, both with caveats:

1. **Separate Swift modules per ISA.** `AssayX86Baseline` and `AssayX86AVX2` as distinct SwiftPM
   targets, the latter with `swiftSettings: [.unsafeFlags(["-Xllvm", "-mattr=+avx2,+bmi,+bmi2"])]`,
   dispatching between them via a protocol existential or function-pointer table resolved once.
   Since tools-version 6.2, `.unsafeFlags` no longer poisons a version-pinned dependency (§3.3), so
   this is *permitted*. It is still bad: `-Xllvm -mattr` is an internal LLVM `cl::opt`, unsupported
   and version-fragile; and you must ensure nothing in `AssayX86AVX2` is `@inlinable` or
   `@_transparent`, or AVX2 code leaks into the baseline module's compilation and you get a fault on
   old CPUs anyway. **UNVERIFIED that `-Xllvm -mattr` even affects Swift codegen** — it may be
   overridden by the TargetMachine construction at `IRGen.cpp:1208`. Test before believing.
2. **A small C target.** `__attribute__((target("avx2")))`, which Just Works (§4). ~200 lines.

Option 2 is the honest answer if AVX2 matters. Option 1 is a trap dressed as a shortcut.

---

## 3. Vendoring C into SwiftPM correctly, cross-platform

### 3.1 Target layout — VERIFIED from swift-crypto and Yams

The convention SwiftPM's `ModuleMapGenerator` expects, and which both packages follow:

```
Sources/CAssayCore/
  include/
    module.modulemap        # hand-written, or omit and let SwiftPM synthesize
    assay_core.h            # public header
  assay_core.c
  assay_avx2.c
  internal.h                # private headers live outside include/
```

- `include/` is the default `publicHeadersPath`. Do not set `publicHeadersPath` unless you deviate.
- If you write your own `module.modulemap`, put it in `include/`. swift-crypto hand-writes four of
  them (`Sources/*/include/module.modulemap`).
- Private headers must **not** be under `include/`, or they become part of the public module and
  leak into every Swift file that imports it.

`swift-crypto/Package.swift` (tools-version 6.1) — the `CCryptoBoringSSL` target uses **only**
`.define(...)` in `cSettings`. Nothing else. That is the model:

```swift
cSettings: [
  .define("_HAS_EXCEPTIONS", to: "0", .when(platforms: [.windows])),
  .define("WIN32_LEAN_AND_MEAN", .when(platforms: [.windows])),
  .define("NOMINMAX", .when(platforms: [.windows])),
  .define("_CRT_SECURE_NO_WARNINGS", .when(platforms: [.windows])),
  .define("OPENSSL_NO_ASM", .when(platforms: [.wasi])),
  .define("OPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_IF_THREADED",
          .when(platforms: [.wasi])),
]
```

plus `exclude:` for three BIO socket files on WASI. `CXKCP` in the same package uses six
`.headerSearchPath(...)` entries. `swift-nio/Package.swift:149-228` defines ten separate `CNIO*`
targets and uses only `.define("_GNU_SOURCE")` and similar. **Zero `.unsafeFlags` across all three
packages.**

### 3.2 The Windows `dllimport` trap — VERIFIED

`Yams/Package.swift:11-22` is the canonical fix, and the important detail is that the define goes
on **both** targets:

```swift
.target(name: "CYaml", cSettings: [.define("YAML_DECLARE_STATIC", .when(platforms: [.windows]))]),
.target(name: "Yams",  dependencies: ["CYaml"],
        cSettings:     [.define("YAML_DECLARE_STATIC", .when(platforms: [.windows]))]),
```

Note `cSettings` on the **Swift** target `Yams`. That is not a typo in their manifest — the
ClangImporter re-preprocesses `CYaml`'s headers when compiling the Swift target, and if
`YAML_DECLARE_STATIC` is not defined there, the header decorates every declaration with
`__declspec(dllimport)`, and you get link errors like `__imp_yaml_parser_initialize` unresolved.
**If Assay vendors any C with a `FOO_API`-style export macro, define its "static" variant on both
the C target and every Swift target that imports it.** Simplest alternative: don't use export
macros at all in your own C.

### 3.3 `.unsafeFlags` in version-pinned dependencies — VERIFIED, and the premise has changed

The received wisdom is that a package using `.unsafeFlags` cannot be depended on by version
(only by branch/path). That was true. **It is no longer true at tools-version ≥ 6.2.**

`spm/Sources/PackageLoading/PackageBuilder.swift:1024-1025` (and identically at `:1071-1072`):

```swift
// unsafe flags check disabled in 6.2
usesUnsafeFlags: manifest.toolsVersion >= .v6_2 ? false : manifestTarget.usesUnsafeFlags,
```

The producer of that flag is `PackageBuilder.swift:1938-1942`:

```swift
usesUnsafeFlags = settings.filter(\.kind.isUnsafeFlags).isEmpty == false
```

and the consumer is `Sources/PackageGraph/Resolution/ResolvedProduct.swift:180`, emitting
`Sources/PackageGraph/Diagnostics.swift:20-22` ("the target … in product … contains unsafe build
flags"). With `usesUnsafeFlags` hard-coded to `false` for 6.2+, that diagnostic is now unreachable
for modern manifests.

The doc comment at `spm/Sources/Runtimes/PackageDescription/BuildSettings.swift:186-192` still says
unsafe flags block version-based dependency resolution. **It is stale.** So is most of the
docs.swift.org text on this.

**But the design conclusion does not change.** `-mavx2` applied module-wide is *still* wrong: it
tells LLVM the whole translation unit may use AVX2, so the compiler will emit `vpxor`/`vmovdqu`
anywhere it likes, and the module faults with SIGILL on a Sandy Bridge or an older Atom. Being
*allowed* to write `.unsafeFlags(["-mavx2"])` does not make compile-time ISA selection correct for a
published library. **Runtime dispatch is still the right design; it is now a correctness argument
rather than a packaging argument.** (It also still matters for consumers who use `--disable-sandbox`
policies or vendor-audit build flags, and for anyone still on tools-version 6.1 or earlier.)

### 3.4 Checklist

- [ ] `Sources/CAssayCore/include/` holds exactly the public headers + optional `module.modulemap`.
- [ ] No `.unsafeFlags`. `cSettings` = `.define` and `.headerSearchPath` only.
- [ ] `.headerSearchPath` paths are **relative to the target directory**, not the package root.
- [ ] Windows: define the `_STATIC` variant of any export macro on the C target **and** every
      importing Swift target.
- [ ] WASI/Android: `.when(platforms:)`-guard anything touching threads, sockets, `dlopen`, or asm.
- [ ] Public header includes only freestanding C: `<stdint.h>`, `<stddef.h>`, `<string.h>`. No
      `<stdlib.h>`, no `<pthread.h>`, no `<immintrin.h>` in the *public* header (put ISA headers in
      the `.c` files so the Swift ClangImporter never sees them).
- [ ] `swift build --triple` smoke-tested for: `aarch64-unknown-linux-gnu`,
      `x86_64-unknown-linux-musl`, `wasm32-unknown-wasi`, `aarch64-unknown-linux-android24`,
      `x86_64-pc-windows-msvc`, plus macOS/iOS.

### 3.5 Mixed-language targets — VERIFIED as not-yet-available

SE-0403 (mixed-language source in one target) was **Returned for Revision** and has not been
re-proposed. As of 6.4 there is an `experimentalMultiLang` flag. Do not plan on it. If you vendor C
it is a **separate target**. (Also relevant: Swift Build becomes the default build engine in 6.4,
which changes some `.headerSearchPath` edge behaviour — **UNVERIFIED**, worth a smoke test.)

---

## 4. Runtime CPU dispatch without unsafe flags

### 4.1 `__attribute__((target("avx2")))` needs no `-mavx2` — VERIFIED

Reproduced locally with `clang-18`: a function annotated `__attribute__((target("avx2")))` using
`_mm256_shuffle_epi8` and `_mm256_movemask_epi8` compiles cleanly with **no** `-m` flags on the
command line, and the emitted assembly contains `vpshufb` and `vpmovmskb`. The rest of the
translation unit remains at the default x86-64 (SSE2) baseline. This is the entire mechanism.

(Caveat: this is `clang-18` from the system, not the clang inside a Swift toolchain. Swift 6.x
ships clang 17-19-era; `__attribute__((target))` has been stable since clang 3.8, so the risk is
negligible. **UNVERIFIED** for the exact Swift-bundled clang.)

### 4.2 simdjson's mechanism — VERIFIED

`simdjson/include/simdjson/portability.h:148-166` defines the region macro:

```c
#define SIMDJSON_TARGET_REGION(T) \
  _Pragma(SIMDJSON_STRINGIFY(clang attribute push(__attribute__((target(T))), apply_to=function)))
#define SIMDJSON_UNTARGET_REGION _Pragma("clang attribute pop")
```

and it is **only** defined for x86_64 and LoongArch LSX — on ARM it is a no-op, confirming that ARM
needs no dispatch (§5).

`simdjson/include/simdjson/haswell/begin.h:10`:

```c
SIMDJSON_TARGET_REGION("avx2,bmi,bmi2,pclmul,lzcnt,popcnt")
```

The `clang attribute push` form is much more ergonomic than annotating every function, and it is
what you want if the C target ever grows past a few functions.

### 4.3 simdjson does **not** use `__builtin_cpu_supports` — VERIFIED, and copy them

`simdjson/src/internal/isadetection.h:53-170` implements detection with raw `cpuid`:
`__get_cpuid` / `__cpuidex` on the respective compilers, plus `xgetbv` to confirm the OS has
enabled YMM state (`XCR0` bits 1 and 2) before claiming AVX2 — a step `__builtin_cpu_supports`
handles but which people writing their own detection routinely forget.

Why avoid `__builtin_cpu_supports`: it compiles everywhere but emits a reference to `__cpu_model`,
which lives in compiler-rt / libgcc. On a static-musl link, on Windows/MSVC, or in a
`-nostdlib`-ish embedded configuration that becomes an unresolved symbol. Raw `cpuid` has no runtime
dependency at all. **Use `__cpuidex`/`__get_cpuid` + `xgetbv`, exactly as simdjson does.**

`__cpuidex` is the MSVC/clang-cl spelling (`<intrin.h>`); `__get_cpuid`/`__get_cpuid_count` is the
GCC/Clang-GNU spelling (`<cpuid.h>`). Both are available in clang targeting
`x86_64-pc-windows-msvc`. Note the clang module map gates `cpuid.h` behind
`requires gnuinlineasm` (modulemap line ~78), so on MSVC-mode clang take the `<intrin.h>` path.

### 4.4 `target_clones` and ifunc — VERIFIED as unsuitable

`__attribute__((target_clones("avx2","default")))` generates an ifunc resolver. ifunc requires
glibc's dynamic-linker support. It does **not** work on musl (no ifunc for static binaries and
patchy otherwise), does not exist on Windows/PE-COFF, and is not supported on Darwin/Mach-O.
Given Assay's platform matrix (static Linux, Windows, Android, Wasm), `target_clones` is
disqualified. **Use an explicit function-pointer table or a `static const impl *`, resolved lazily.**

simdjson's registry — `atomic_ptr<const implementation>` with a lazy resolver — is the pattern:
detect once, store an atomic pointer, dereference thereafter. In Swift terms: a `let` global holding
an existential or a struct of function pointers, initialized by a `static let` (Swift's lazy global
init is thread-safe via `swift_once`).

### 4.5 Baseline choice

simdjson's minimum x86 implementation is `westmere` (SSE4.2 + PCLMUL), because it needs
`carry-less multiply` for the quote-masking prefix-XOR. If Assay avoids the prefix-XOR trick (there
are SSE2-only alternatives that are slightly slower), the SSE2 baseline is viable and is what pure
Swift gives you for free — a meaningful argument for the pure-Swift-first plan.

---

## 5. ARM and the Apple-silicon reality

**NEON is architecturally mandatory on AArch64 — VERIFIED** (ARM ARM: the Advanced SIMD and
floating-point extension is required in all A-profile AArch64 implementations; a compliant
AArch64 core without NEON does not exist in any Swift-supported configuration). Concretely:

- Apple silicon (all of macOS arm64, iOS, iPadOS, tvOS, watchOS arm64_32? — see below, visionOS):
  NEON always present.
- Linux aarch64: NEON always present.
- **Android `arm64-v8a`: NEON always present.** The NDK's arm64-v8a ABI mandates it; there is no
  no-NEON arm64 Android device.
- Windows on ARM (arm64): NEON always present.

**Therefore: no runtime dispatch is needed on any arm64 target. The pure-Swift `Builtin` route is
fully sufficient there, and this is the majority of Assay's likely traffic** (all Apple devices,
Android phones, Graviton/Ampere servers).

This is corroborated by simdjson: `SIMDJSON_TARGET_REGION` is not even defined on ARM
(`portability.h:148`), and there is exactly one arm64 implementation with no CPU detection.

### 5.1 ARM movemask replacements — VERIFIED from simdjson

There is no `pmovmskb` on NEON. simdjson uses two techniques; steal both.

`simdjson/include/simdjson/arm64/simd.h:137-142` — the "shift-narrow" trick, 16 lanes → 64-bit mask
with 4 bits per lane:

```cpp
uint64_t to_bitmask64() const {
  return vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(*this), 4)), 0);
}
```

Then `trailingZeroBitCount / 4` gives the lane index. This is 2 instructions vs x86's 1, and it is
what makes arm64 competitive.

`simdjson/include/simdjson/arm64/simd.h:463-481` — for the 64-byte block, a `vpaddq_u8` reduction
tree that packs four 16-byte vectors into a genuine 64-bit 1-bit-per-byte mask (multiply each vector
by a `[0x01,0x02,0x04,...,0x80]` pattern, then three rounds of pairwise add).
`simdjson/include/simdjson/arm64/stringparsing_defs.h:40-42,54` uses the same.

**Important design consequence:** the natural Assay bitmask width on arm64 is either 64-bits-for-16-
bytes (shift-narrow) or 64-bits-for-64-bytes (pairwise-add tree), whereas on x86 it is
16-bits-for-16-bytes or 32-bits-for-32-bytes. Design the *interface* between the SIMD layer and the
consuming parser loop so the bit-per-lane ratio is a property of the implementation, not baked into
the caller. Getting this wrong is the most common reason a "portable" SIMD parser ends up with two
completely separate parser loops.

**In pure Swift**, note that `vshrn_n_u16(_, 4)` needs a compile-time constant, which rules out the
`_Builtin_intrinsics.arm.neon` route (§2.6) for that specific function. Alternatives:
`Builtin.int_aarch64_neon_shrn` — **UNVERIFIED** that the constant can be passed. Falling back to
the `Builtin.bitcast_Vec16xInt1_Int16` movemask (§2.2) and letting LLVM lower it is the safer
choice: LLVM's AArch64 backend has a dedicated pattern for `bitcast <16 x i1> to i16` and produces
a reasonable sequence. **UNVERIFIED how good** — this is the second thing to check on real hardware.

### 5.2 SVE / SVE2 / SME — not worth it

SVE uses sizeless vector types (`svuint8_t`) that cannot be stored in structs, cannot be members,
and have no fixed `sizeof`. **Swift cannot import them at all** — `ImportType.cpp:719`'s
`VisitVectorType` needs `getNumElements()`, which sizeless types do not have. Even from C they are
awkward. Availability is also poor: no Apple silicon core implements SVE (Apple implements SME/SME2
on M4+ but not SVE for general use); Graviton3/4 and Neoverse V-series do. For a byte-level parser
the wins over NEON are small (SVE's strength is long-vector float/HPC work, not 16-byte structural
scanning). **Skip SVE. Skip SME.**

### 5.3 32-bit ARM / armv7 — a NEON assumption **does** break

armv7 NEON is optional (it is mandatory on Cortex-A8+ in practice but not architecturally, and
armv7 without NEON exists — some Cortex-A5/A9 configurations, and the Raspberry Pi 1/Zero is armv6
with no NEON at all). Android's `armeabi-v7a` ABI historically allowed no-NEON devices; the NDK
now defaults `-mfpu=neon` for API 21+, but that is a toolchain default, not a guarantee. Also
`watchOS` `arm64_32` is arm64 ILP32 — NEON present, but pointer size 32, so any code assuming
`UInt.bitWidth == 64` for mask arithmetic breaks.

**Recommendation: do not ship a SIMD path for 32-bit ARM. `#if arch(arm64) || arch(x86_64) ||
arch(wasm32)` gates the vector core; everything else takes the scalar path.** This is also what
simdjson does (it has `fallback`). The scalar path must exist and must be CI-tested regardless,
because it is also your correctness oracle.

---

## 6. WebAssembly SIMD

### 6.1 simd128 is **not** on by default — VERIFIED (as a Clang/LLVM property), UNVERIFIED for the Swift SDK specifically

The `wasm32` target's default feature set in LLVM does not include `simd128`; it must be enabled
with `-msimd128` (clang) / `+simd128` (LLVM feature string). The WebAssembly SIMD proposal is
standardised and shipped in all major engines, but the toolchain still gates it because the
resulting module will not load on an engine without SIMD support.

For SwiftPM with the Swift SDK for WebAssembly you would need something like:

```swift
swiftSettings: [.unsafeFlags(["-Xcc", "-msimd128"], .when(platforms: [.wasi]))],
cSettings:     [.unsafeFlags(["-msimd128"],         .when(platforms: [.wasi]))]
```

for the C route — and note this **is** `.unsafeFlags`, which per §3.3 is now permitted at
tools-version 6.2+ but is still ugly. **UNVERIFIED** whether recent Swift SDK for WebAssembly
releases enable simd128 in the SDK's own `swift-sdk.json` `swiftCompilerFlags`/`cCompilerFlags`,
which would make this unnecessary. **Check `swift-sdk.json` in the SDK bundle before adding flags.**

For the **pure-Swift** route this problem largely evaporates: `Builtin.int_wasm_swizzle` and
`Builtin.int_wasm_bitmask` name `llvm.wasm.*` intrinsics that the backend lowers to `i8x16.swizzle`
/ `i8x16.bitmask`. Whether they require `+simd128` on the TargetMachine to be selectable rather than
expanded is **UNVERIFIED** — likely yes, in which case you need `-Xllvm -mattr=+simd128` or the SDK
default, and are back to the same flag question. **Test this early**; it is the one place where the
pure-Swift route may not dominate.

### 6.2 There is no `__builtin_cpu_supports` for Wasm — VERIFIED by construction

Wasm has no runtime feature detection available to the module itself. Feature detection happens on
the **host** side (JS `WebAssembly.validate()` on a probe module) *before* instantiation. A Wasm
binary either uses simd128 or it does not; there is no dispatch. Practical consequence: **either
build two `.wasm` artifacts (SIMD and non-SIMD) and let the host pick, or just require simd128** —
which is reasonable in 2026, as Chrome/Firefox/Safari/Node/wasmtime/wasmer have all shipped it for
years.

### 6.3 The stack-size issue — VERIFIED as a known Swift-on-Wasm requirement

Swift on Wasm defaults to a small linear-memory stack and deeply recursive or large-frame code traps.
The standard fix is a linker flag:

```swift
linkerSettings: [.unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=16777216"],
                              .when(platforms: [.wasi]))]
```

This matters for Assay specifically: a **recursive-descent** JSON/YAML decoder will blow the default
stack on deeply nested input far sooner on Wasm than anywhere else. Two consequences: (a) document
the flag for Wasm users; (b) **prefer an explicit-stack / iterative parser over recursion** in the
decoder core — which is good practice anyway for depth-limit DoS resistance, and which you should
do regardless of Wasm.

### 6.4 Can vendored C using `wasm_simd128.h` build through SwiftPM for the Wasm SDK?

**Yes — UNVERIFIED but structurally sound.** `wasm_simd128.h` is a clang builtin header and the Wasm
SDK's clang is the Swift toolchain's clang. swift-crypto already compiles a large C corpus for WASI
(`Package.swift` has WASI-specific `.define`s and `exclude`s), which proves the C-through-SwiftPM
path works for `wasm32-unknown-wasi`. The `-msimd128` flag question of §6.1 applies.

Also note: `wasm32-unknown-wasip1` vs `wasm32-unknown-wasip1-threads` are distinct triples with
distinct SDKs; anything you `.when(platforms: [.wasi])` applies to both, but thread-related C
(pthreads, atomics) only links on the `-threads` variant. Keep the C core thread-free.

---

## 7. The safety boundary — how to wrap an unsafe core in a safe API

This is the part the author cares most about, and the 2026 answer is clear and good.

### 7.1 The types

`Span<T>` and `RawSpan` (SE-0447, plus SE-0456 stdlib properties, SE-0464 `UTF8Span`,
SE-0467 `MutableSpan`, SE-0485 `OutputSpan`, SE-0525 `RawSpan` loading API) are
`Copyable, ~Escapable` views over contiguous memory:

```swift
public struct Span<Element: ~Copyable>: Copyable, ~Escapable { ... }
public struct RawSpan: Copyable, ~Escapable { ... }
```

`~Escapable` is the whole point: **a `Span` cannot be stored in a property, captured by an escaping
closure, put in an array, or returned without a declared lifetime dependency.** The compiler
enforces that it cannot outlive the storage it views. This is exactly the guarantee
`UnsafeRawBufferPointer` never had.

`RawSpan` is explicitly designed for your use case — SE-0447:

> `RawSpan` is a specialized type that is intended to support **parsing and decoding applications**,
> as well as applications where heavily-used code paths require concrete types as much as possible.

`RawSpan` is `Sendable`; `Span<T>` is `Sendable` when `T` is.

### 7.2 The lifetime attribute

The non-underscored `@lifetime` is proposed but not yet accepted as a standalone SE proposal
(SE-0446:18 defers it: "these types will support lifetime-dependency constraints (**being tracked in
a future proposal**)"; SE-0446:210, :223, :310-312 repeat this). **Shipping code today uses the
underscored `@_lifetime`** — VERIFIED in both swift-nio and swift-collections. `@lifetime`
(unprefixed) appears in SE-0474, SE-0476, SE-0527, SE-0532 as the assumed future spelling.

Forms: `@_lifetime(borrow x)`, `@_lifetime(&x)` (exclusive/mutable borrow), `@_lifetime(copy x)`
(inherit x's dependencies), and `@_lifetime(result: borrow x)` for naming a specific result.

### 7.3 The idiomatic pattern, verbatim from shipping code — VERIFIED

`swift-collections/Sources/BasicContainers/RigidArray/RigidArray.swift:176-198`:

```swift
public var span: Span<Element> {
  @_lifetime(borrow self)
  @inlinable
  get {
    let result = unsafe Span(_unsafeElements: _items)
    return unsafe _overrideLifetime(result, borrowing: self)
  }
}

public var mutableSpan: MutableSpan<Element> {
  @_lifetime(&self)
  @inlinable
  mutating get {
    let result = unsafe MutableSpan(_unsafeElements: _items)
    return unsafe _overrideLifetime(result, mutating: &self)
  }
}
```

`swift-nio/Sources/NIOCore/ByteBuffer-core.swift:814-844` is the identical shape on a
copy-on-write, reference-counted, sliced buffer:

```swift
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
public var readableBytesSpan: RawSpan {
    @_lifetime(borrow self)
    borrowing get {
        let range = Range<Int>(uncheckedBounds: (lower: self.readerIndex, upper: self.writerIndex))
        return _overrideLifetime(RawSpan(_unsafeBytes: self._slicedStorageBuffer[range]),
                                 borrowing: self)
    }
}
```

The whole file is gated `#if compiler(>=6.2)` — worth copying.

`_overrideLifetime` is `stdlib/public/core/LifetimeManager.swift:300-360`, four overloads, each:

```swift
@unsafe
@_unsafeNonescapableResult
@export(implementation)
@_transparent
@_lifetime(borrow source)
public func _overrideLifetime<T: ~Copyable & ~Escapable, U: ~Copyable & ~Escapable>(
  _ dependent: consuming T, borrowing source: borrowing U
) -> T { dependent }
```

It is a no-op at runtime; it exists purely to re-attach a lifetime dependency that the compiler
cannot infer (typically because you built the `Span` from a pointer whose provenance the compiler
has lost, e.g. through a managed buffer). Note swift-collections vendors its own copy at
`Sources/InternalCollectionsUtilities/LifetimeOverride.swift:36-88` for availability reasons —
Assay may want to do the same.

### 7.4 Can a C pointer+length function be wrapped so the pointer cannot outlive the buffer?

**Yes — VERIFIED that the pieces exist.** The wrapper looks like:

```swift
// C: size_t assay_scan(const uint8_t *p, size_t n, uint64_t *out);

@inlinable
public func scan(_ bytes: RawSpan, into out: inout MutableSpan<UInt64>) -> Int {
  bytes.withUnsafeBytes { buf in            // RawSpan.swift:600-604
    out.withUnsafeMutableBufferPointer { o in
      Int(assay_scan(buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                     buf.count, o.baseAddress!))
    }
  }
}
```

The pointer is scoped to the closure by `withUnsafeBytes`
(`stdlib/public/core/Span/RawSpan.swift:600-604`: `try unsafe body(.init(start: _pointer,
count: byteCount))`), and the `RawSpan` itself is `~Escapable`, so the *caller* also cannot have
smuggled a dangling view in. **The unsafety is confined to exactly the lines between
`withUnsafeBytes` and its closing brace, and the C function is incapable of storing the pointer
because nothing in its signature lets it escape** — that last part is a discipline requirement on
your C, not a compiler guarantee. Keep the C stateless and pure.

The caller-facing API should then take `RawSpan` / `Span<UInt8>` / `UTF8Span`, not
`UnsafeRawBufferPointer`. Sources are cheap to obtain:

- `Array.span` — `stdlib/public/core/Array.swift:1758`
- `ContiguousArray.span` — `ContiguousArray.swift:1302`
- `ArraySlice.span` — `ArraySlice.swift:1238`
- `String.utf8.span` — `StringUTF8View.swift:360` (**note**: `@available(SwiftStdlib 6.2, *)`; and
  `StringUTF8View.swift:387-395` shows it is **unavailable on 32-bit watchOS**, where it
  `fatalError`s. Guard accordingly.) On Apple platforms a bridged UTF-16 `String` transcodes on
  first access and caches — amortized O(1), not free.
- `InlineArray.span`, `CollectionOfOne.span`, `Substring.span`, `UTF8Span.span`
- `Foundation.Data` — **UNVERIFIED** whether `Data.span` / `Data.bytes` exists in the shipping
  swift-foundation; check, because it is your most likely input type in practice.

**Availability is the real constraint.** `Span`/`RawSpan` are
`@available(SwiftCompatibilitySpan 5.0, *)` with
`@_originallyDefinedIn(module: "Swift;CompatibilitySpan", SwiftCompatibilitySpan 6.2)`
(`RawSpan.swift:25-26`) — i.e. back-deployed via a compatibility shim, but the shim itself has an OS
floor. On non-Apple platforms this is a non-issue. On Apple platforms you will need either a
deployment-target floor or a dual API surface. **UNVERIFIED** exactly which OS versions
`SwiftCompatibilitySpan 5.0` resolves to; check the availability macro definitions in your
toolchain. This is the single biggest practical friction in adopting `Span` for a library that wants
broad Apple back-deployment.

### 7.5 SE-0458: does unsafety leak to clients? **No.** — VERIFIED

`swift-evolution/proposals/0458-strict-memory-safety.md`. `Features.def:337` confirms it shipped:
`MIGRATABLE_OPTIONAL_LANGUAGE_FEATURE(StrictMemorySafety, 458, "Strict memory safety")`.

The three facts that matter:

1. **Opt-in, per-module.** Enabled with `-strict-memory-safety` (SwiftPM: `.strictMemorySafety()`).
   SE-0458:147 — an `@unsafe` declaration has **no effect on clients that have not opted in**.
2. **Warnings, not errors.** For opted-in clients the diagnostics live in the `StrictMemorySafety`
   diagnostic group, i.e. warnings, suppressible/escalatable via `-Wwarning`/`-Werror`.
3. **`@safe` is the escape valve.** SE-0458:328-420 — you annotate a declaration `@safe` to assert
   that its implementation, though internally unsafe, presents a memory-safe interface. That is
   precisely what Assay's public API should do.

C interop specifics (SE-0458:236-330): pointer-bearing C declarations are implicitly `@unsafe`;
pointer-free C functions are **safe**; C enums are never unsafe. So even the C-target variant of
Assay does not force unsafety on clients — provided no C pointer type appears in Assay's public
signatures.

**Conclusion for Assay: if the public API is `func decode<T: Decodable>(_: T.Type, from: RawSpan)
throws -> T` and similar — pure Swift types, no pointers — then a client compiling with
`-strict-memory-safety` sees nothing at all.** You can and should build Assay itself with
`-strict-memory-safety` on, so the `unsafe` keyword marks every risky expression in your own
sources, and then `@safe`-annotate the handful of public entry points.

---

## 8. Build and distribution cost of a C target

- **`.systemLibrary` and `.binaryTarget` are not required and should not be used.** `.systemLibrary`
  is for linking a pre-installed system `.so` (wrong: you are vendoring source). `.binaryTarget` is
  XCFramework/artifactbundle-only, Apple-platform-biased, and destroys source portability. Vendored
  C is a plain `.target` with C sources. **VERIFIED** by construction from swift-crypto/Yams/nio,
  none of which use either for their vendored C.
- **`swift build --static-swift-stdlib` is *not* blocked by a C target.** **UNVERIFIED** directly,
  but swift-crypto (which vendors an enormous C corpus) is routinely statically linked in Swift
  server container images, and `--static-swift-stdlib` concerns the Swift runtime, not your C
  objects, which are ordinary `.o` files in the same archive. The real static-linking hazards are
  glibc-specific C (`getaddrinfo`, `dlopen`, NSS) — keep the C free of libc beyond
  `<stdint.h>`/`<string.h>` and static-musl is fine.
- **Wasm:** works (swift-crypto compiles C for WASI), but every C source needs auditing for threads,
  sockets, `errno`-heavy code and inline asm. Adds real maintenance.
- **Android cross-compilation:** works through the Swift Android SDK, but the C target now depends
  on the NDK sysroot resolving correctly. This is the most common failure mode in practice
  (`bits/libc-header-start.h not found` and friends). A pure-Swift target has no such exposure.
- **Xcode previews / SwiftUI previews:** a C target does not break previews per se, but it
  lengthens clean-build times and any module-map error surfaces as an opaque preview failure.
  **UNVERIFIED.**
- **Debug-build performance:** a C target is a genuine *advantage* here — C is compiled `-O0` in
  debug too, but the C compiler's baseline codegen for a SIMD loop is far better than Swift's `-Onone`
  output, where `SIMD` types are not inlined and generics are unspecialised. If Assay's users care
  about debug-configuration decode speed (a common complaint with Swift JSON libraries), that is a
  real point for C. Mitigate in pure Swift with `@_transparent` / `@inline(__always)` and
  `.unsafeFlags(["-Onone", "-Xllvm", ...])`-free approaches such as building the core module with
  `.swiftSettings([.unsafeFlags(["-O"])])`... which is again `.unsafeFlags`. **Unresolved tension;
  measure it.**

---

## 9. Recommended architecture

```
Assay/
  Sources/
    AssaySIMD/           # pure Swift, .enableExperimentalFeature("BuiltinModule")
      Vector.swift       #   protocol AssayVector { shuffle, movemask, eq, and, or }
      Scalar.swift       #   #if !SIMD  — the correctness oracle, always built, always tested
      NEON.swift         #   #if arch(arm64)
      SSE2.swift         #   #if arch(x86_64)   — Builtin.int_x86_sse2_pmovmskb_128 etc.
      Wasm.swift         #   #if arch(wasm32)
    AssayCore/           # pure Swift, safe-ish, uses AssaySIMD; -strict-memory-safety on
    Assay/               # public API: RawSpan / Span<UInt8> / UTF8Span in, values out; @safe
  # LATER, only if x86 AVX2 measurably matters:
  #  Sources/CAssayAVX2/ # __attribute__((target("avx2"))) + cpuid, ~200 lines
  #  and a runtime-resolved `let impl: any AssayVectorImpl` in AssaySIMD
```

Key invariants:

1. **One dispatch seam, chosen once.** A `static let` global holding the selected implementation
   (Swift's lazy globals are `swift_once`-protected and free after the first call). Whether the
   implementation is Swift or C is invisible above the seam. This is what makes adding C later
   additive rather than a rewrite.
2. **The bit-per-lane ratio is implementation-defined.** x86 gives 1 bit/byte; arm64's cheap path
   gives 4 bits/byte. Do not let this leak into the parser loop.
3. **The scalar path is not optional.** It is the fallback for armv7/i686/unknown, and it is the
   differential-testing oracle. Fuzz scalar-vs-SIMD on every commit.
4. **Public API takes `RawSpan`, not pointers.** With `@safe` on the entry points and
   `-strict-memory-safety` on internally.
5. **Pin and test Swift versions.** `Builtin` is unstable. `#if compiler(>=6.2)` around the vector
   core with a scalar fallback for older/newer-broken compilers.

## 10. The first five experiments to run with a real toolchain

In priority order — each is a few minutes and each could change the plan:

1. Does `Builtin.int_x86_ssse3_pshufb_128` resolve, and with what argument-type suffix? Same for
   `Builtin.int_aarch64_neon_tbl1` and `Builtin.int_wasm_swizzle`. `swiftc -emit-assembly`, read
   for `pshufb` / `tbl` / `i8x16.swizzle`.
2. Does `Builtin.bitcast_Vec32xInt1_Int32` exist, and what does the arm64 backend emit for
   `bitcast_Vec16xInt1_Int16`? (Compare against simdjson's hand-written `vshrn` sequence.)
3. Does `.enableExperimentalFeature("BuiltinModule")` work in a release toolchain from SwiftPM, and
   does the resulting package resolve as a *versioned* dependency from a second package?
4. Does `-Xllvm -mattr=+avx2` actually change Swift codegen, or is it overridden by
   `IRGen.cpp:1208`'s TargetMachine construction? (Decides whether §2.7 option 1 exists at all.)
5. Does the Swift SDK for WebAssembly enable `simd128` by default? (`grep simd128` in the SDK's
   `swift-sdk.json`.) And do the `llvm.wasm.*` builtins select without it?

---

## Claims summary

**VERIFIED:** no stdlib byte shuffle (`SIMDVector.swift:267-365`); no stdlib movemask
(`:1563`,`:1570`); only compares and `&+`/`&-`/`&*` lower to vector ops
(`SIMDIntegerConcreteOperations.swift.gyb:82-159`); mask `.&`/`.^`/`.|` do lower
(`SIMDMaskConcreteOperations.swift.gyb:72-151`); `SIMD._value` is a public `Builtin.Vec*`
(`SIMDVectorTypes.swift.gyb:248`); `Builtin.int_*` reaches arbitrary LLVM intrinsics
(`Builtins.cpp:2565-2582`); stdlib's own movemask (`StringCreate.swift:27-31`) and intrinsic use
(`UTF16.swift:460-489`); `Builtin.shufflevector` is constant-mask-only and crashes otherwise
(`GenBuiltin.cpp:889-896`); `import Builtin` needs `Feature::BuiltinModule`, not `-parse-stdlib`
(`ImportResolution.cpp:451-463`, `Features.def:436`); Swift has **no** per-function target attribute
(`DeclAttr.def` no match; `lib/IRGen/*.cpp` no `target-features`; `IRGen.cpp:1153-1164,1208`);
C vector types import as `SIMDn` (`ImportType.cpp:719-749`); `_Builtin_intrinsics` module map exists
(clang `module.modulemap:10-80`); `.unsafeFlags` no longer blocks version-pinned deps at
tools-version ≥ 6.2 (`PackageBuilder.swift:1024-1025,1071-1072,1938-1942`) and the
`BuildSettings.swift:186-192` doc comment is stale; swift-crypto/Yams/nio vendor C with
`.define`/`.headerSearchPath` only; Windows dllimport fix goes on both targets
(`Yams/Package.swift:11-22`); `__attribute__((target("avx2")))` needs no `-mavx2` (local clang-18);
simdjson's region pragma (`portability.h:148-166`, `haswell/begin.h:10`) and raw-cpuid detection
(`isadetection.h:53-170`); ARM movemask replacements (`arm64/simd.h:137-142`, `:463-481`); NEON is
mandatory on AArch64 incl. Android arm64-v8a; `Span`/`RawSpan` are `~Escapable`
(SE-0447); `@_lifetime` + `_overrideLifetime` is the shipping pattern
(`RigidArray.swift:176-198`, `ByteBuffer-core.swift:814-844`, `LifetimeManager.swift:300-360`);
`RawSpan.withUnsafeBytes` scopes the pointer (`RawSpan.swift:600-604`); SE-0458 unsafety does not
leak to non-opted-in clients (`0458:147`), diagnostics are warnings, `@safe` exists (`0458:328-420`),
pointer-free C is safe (`0458:236-330`); `String.utf8.span` is unavailable on 32-bit watchOS
(`StringUTF8View.swift:387-395`).

**UNVERIFIED:** exact `Builtin.int_*` argument-suffix mangling for each target intrinsic;
`Builtin.bitcast_Vec32xInt1_Int32` / `Vec64xInt1_Int64` existence; quality of arm64 lowering for
`bitcast <16 x i1> to i16`; whether `-Xllvm -mattr=` affects Swift codegen at all; whether the Wasm
SDK enables `simd128` by default; whether `llvm.wasm.*` builtins select without `+simd128`;
`_Builtin_intrinsics.arm.neon` importability in practice and the constant-argument failure mode;
x86 `_Builtin_intrinsics.intel` ABI safety across the AVX boundary (assume unsafe); whether
`BuiltinModule` is enabled in the *current* tags of swift-collections/foundation/atomics;
`--static-swift-stdlib` compatibility with a C target; Xcode preview impact; which OS versions
`SwiftCompatibilitySpan 5.0` resolves to; whether `Foundation.Data` exposes a `span`/`bytes`
property; Swift Build (6.4 default) header-search-path behaviour changes; whether `.pointwiseMin`
vectorises across module boundaries; the absence of any 2026 SE proposal adding SIMD shuffle or
movemask.

Do not assert these
