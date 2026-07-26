# Experiments #2–#5 — Builtin intrinsics, packaging, ISA targeting, Wasm

- Toolchain: Apple Swift 6.3.3 (swift-6.3.3-RELEASE), `arm64-apple-macosx26.0`, macOS 26.5.2
- Date: 2026-07-26

None of these gate phase 1. They gate phases 4–5 (SIMD and C). Recorded now because they
were cheap and two of them change the plan.

---

## #2 — Do the `Builtin.int_*` intrinsics resolve? **YES**

`swiftc -O -S -enable-experimental-feature BuiltinModule` compiles all three of:

- `Builtin.bitcast_Vec16xInt1_Int16` ∘ `Builtin.cmp_slt_Vec16xInt8`  (the stdlib's `_pmovmskb`)
- `Builtin.bitcast_Vec32xInt1_Int32` ∘ `Builtin.cmp_slt_Vec32xInt8`  — **exists**, previously UNVERIFIED
- `Builtin.cmp_eq_Vec16xInt8`

and they emit real NEON:

```asm
; eqMask16
dup.16b  v1, w0
cmeq.16b v0, v0, v1
and.16b  v0, v0, v1
ext.16b  v1, v0, v0, #8
zip1.16b v0, v0, v1
addv.8h  h0, v0
fmov     w0, s0
```

**Answers a question `perf-simd-and-c.md` §5.1 left open: the quality of arm64 lowering for
`bitcast <16 x i1> to i16`.** It is ~6 instructions (`and`/`ext`/`zip1`/`addv`/`fmov`)
against simdjson's hand-written `vshrn_n_u16` shift-narrow at 2. So the portable route
works but is ~3× the instruction count of the hand-written one on arm64. If a movemask ever
lands on the hot path, the shift-narrow is worth reaching for — **but note §5.1's caveat
that `vshrn_n_u16` needs a compile-time constant, which the `_Builtin_intrinsics.arm.neon`
route cannot supply.** Unresolved; irrelevant until phase 4.

## #3 — Does `BuiltinModule` survive as a *versioned* dependency? **YES**

Built a `VecLib` package with `.enableExperimentalFeature("BuiltinModule")`, `git tag 1.0.0`,
and consumed it from a second package via `.package(url:, from: "1.0.0")`. SwiftPM resolved
at 1.0.0 and the build succeeded, **including an `@inlinable` function whose body references
`Builtin` being inlined into a client module that has not enabled the feature**. That was the
real risk and it is not a problem.

Confirms it is not `.unsafeFlags`-like: `.enableExperimentalFeature` carries no dependency
restriction. `Package.swift`'s existing `AssaySIMD` setting is safe.

## #4 — Does `-Xllvm -mattr=+avx2` change Swift codegen? **NO** ⚠️

```
swiftc -O -S -module-name M -target x86_64-apple-macosx26.0 [-Xllvm -mattr=+avx2] avx.swift
```

Byte-identical output. Zero `ymm` registers in either. `SIMD32<UInt8>` addition is emitted as
two `xmm` operations regardless.

**This is a negative result that closes off an option.** `perf-simd-and-c.md` §2.7 listed two
routes to runtime-dispatched AVX2 and called option 1 "a trap dressed as a shortcut" while
flagging it UNVERIFIED. It is now verified as *non-existent*: IRGen's module-wide
TargetMachine construction overrides the LLVM flag entirely.

**Consequence: if x86-64 AVX2 ever measurably matters, a C target is the only route.** There
is no pure-Swift or per-module-flag alternative. Phase 5's cost is therefore the real cost,
and phase 4's x86-64 numbers have to justify it on their own.

*Caveat: tested by cross-compiling to `x86_64-apple-macosx26.0` from an arm64 host. Not run
on a native x86-64 toolchain.*

## #5 — Does the Wasm SDK enable `simd128` by default? **NOT RUN**

`swift sdk list` → "No Swift SDKs are currently installed." Answering this needs a ~1 GB SDK
install that gates nothing before phase 4. Deferred, deliberately, rather than guessed.

`wasmkit` *is* present in the toolchain (`~/.swiftly/bin/wasmkit`), so when the SDK is
installed the `swift test --swift-sdk` path from `cross-platform-audit.md` §6 should work.
Remember the 16 MB stack-size toolset from swift-syntax — a recursive-descent parser will
blow the default Wasm stack.

---

## Reproduce

```sh
swiftc -O -S -enable-experimental-feature BuiltinModule intrin.swift -o intrin.s   # 2
# 3: see the Lib/App pair described above; note SwiftPM derives package identity
#    from the *directory* name, not Package(name:)
swiftc -O -S -module-name M -target x86_64-apple-macosx26.0 avx.swift -o b.s       # 4
swiftc -O -S -module-name M -target x86_64-apple-macosx26.0 -Xllvm -mattr=+avx2 avx.swift -o m.s
diff b.s m.s
```

**Methodology note:** the first #4 run compared `avx_base.s` against `avx_mattr.s` and
reported a difference. That difference was entirely the mangled module name, which swiftc
derives from the output filename. Always pass `-module-name` when diffing assembly.
