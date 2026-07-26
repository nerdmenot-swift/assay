# Assay — Swift Performance Mechanics for a Byte-Level Parser Hot Loop

Research date: 2026-07-25. Primary sources: `swiftlang/swift` @ `37150b47d397fa2b06b32a2d726e27c8eb51c0ab` (2026-07-25), cloned to `/home/claude/research/swift`; `swiftlang/swift-evolution` @ `/home/claude/research/swift-evolution`; `swift-foundation`, `swift-collections`, `swift-nio` checkouts under `/home/claude/research/`.

**No Swift toolchain was available.** Nothing here was compiled, disassembled or benchmarked. Every claim is labelled:
- **VERIFIED** — read in primary source (compiler/stdlib source, evolution proposal, official doc) and cited with file:line or URL.
- **UNVERIFIED** — inferred, secondhand, or folklore that could not be confirmed.

Raw per-topic notes: `/home/claude/research/notes/{arc,specialization,span,bounds_switch,scanner,existentials_concurrency}.md`.

---

## 0. Executive summary — ranked by impact on Assay's design

| # | Finding | Status |
|---|---|---|
| 1 | `switch` over `String` (and over integer literals) is a **linear chain of comparisons** at all optimization levels. SILGen treats them as wildcard `ExprPattern`s. Only `switch` over an **enum** produces a real jump table. | VERIFIED |
| 2 | Library evolution (resilience) is **off by default** and Assay **cannot** enable it from `Package.swift` anyway. The resilience-kills-perf worry is real but not Assay's problem. | VERIFIED |
| 3 | Specialization and inlining across a module boundary require the callee body in the client's SILModule. For a SwiftPM source package that means **`@inlinable` + `@usableFromInline` on every hot primitive**, or it does not happen. | VERIFIED |
| 4 | `Span`/`RawSpan` checked subscript uses `_precondition`, which **survives `-O`**. Removal requires a linear induction variable iterating 0..<count. A data-dependent JSON cursor does **not** qualify. `subscript(unchecked:)` is public and free. | VERIFIED |
| 5 | `UnsafeBufferPointer`'s **element** subscript is `_debugPrecondition` → free at `-O`. Its **slice** subscript is `_precondition` → not free. `Array`'s subscript is not free. | VERIFIED |
| 6 | Short keys (≤15 UTF-8 bytes on 64-bit) already produce an **immortal, non-allocating, non-refcounted** `String`. The "avoid String allocation for keys" hypothesis is **partially falsified**; the real cost is Foundation's eager Dictionary stringify + SipHash. | VERIFIED |
| 7 | "Structs + generics + non-escaping closures = ARC-free at -O" is **folklore**. Only *transitively trivial* structs are ARC-free. A struct containing a `String`, `Array`, closure or class is not. | VERIFIED |
| 8 | `Sendable` is a marker protocol: **exactly zero** runtime cost, no witness table, no calling-convention change. Sync calls within an isolation domain cost zero instructions. Making the parse API `async` costs real money. | VERIFIED |
| 9 | `any P` costs a 40-byte container, possible `swift_allocBox`, `swift_makeBoxUnique` on mutation, and is never devirtualizable. Foundation's `Codable` pays exactly this. | VERIFIED |
| 10 | No credible published measurement exists for bounds-check cost, exclusivity cost, ARC-as-%-of-runtime, or existential dispatch in ns/op. **Do not put numbers in Assay's docs.** | VERIFIED (as a negative) |

---

## 1. ARC on the hot path

### 1.1 The pass pipeline

**VERIFIED.** Pass registry: `include/swift/SILOptimizer/PassManager/Passes.def` (206 passes). Relevant entries: `ARCSequenceOpts` :314, `ARCLoopOpts` :316, `MandatoryARCOpts` :327, `SemanticARCOpts` :437, `CopyPropagation` :257, `RetainSinking` :389, `ReleaseHoisting` :391, `AllocBoxToStack` :62, `ClosureSpecialization` :160.

Pipeline: `lib/SILOptimizer/PassManager/PassPipeline.cpp:972-1062`. `addFunctionPasses` (`:455-636`) runs **three times** (HighLevel / MidLevel / LowLevel). ARC work inside it at `:535`, `:541-546`, `:561-565`, `:594`, `:608-610` (EarlyCodeMotion → ReleaseHoisting → ARCSequenceOpts), `:620-627` (RetainSinking ×2 → ReleaseHoisting → ARCSequenceOpts), `:630-635`. Net ≈9 runs of ARCSequenceOpts and ≈15 of SemanticARCOpts per compile.

OSSA is lowered at `PassPipeline.cpp:1039` (`OwnershipModelEliminator`) — High/Mid pipelines are OSSA, Low/LateLoop/LastChance are not.

**VERIFIED.** `-Onone` (`PassPipeline.cpp:1069-1147`) runs only `MandatoryARCOpts` (`:1081`). No ARCSequenceOpts, no SemanticARCOpts, no RetainSinking, no CopyPropagation. **Never benchmark or reason about Assay at `-Onone`** — it is a different language performance-wise.

The compiler documents its own gaps: `PassPipeline.cpp:621-624` — *"Retain sinking does not sink all retains in one round. Let it run one more time..."* (FIXME); `:812-815` — *"In OSSA we cannot do all kind of redundant load elimination, yet."*

### 1.2 What the ARC optimizer can and cannot prove

**VERIFIED — the default is pessimistic.** `lib/SILOptimizer/Analysis/ARCAnalysis.cpp:86-88`:
> *"We cannot conservatively prove that this instruction cannot decrement the ref count of Ptr. So assume that it does. return true;"*

**VERIFIED — escape analysis has a shrinking complexity budget, and a macro-generated mega-decoder is its worst case.** `SwiftCompilerSources/Sources/Optimizer/Analysis/AliasAnalysis.swift:498-503`:
```
getComplexityBudget = 1_000_000 / estimatedFunctionSize
```
and at `:137` that budget is divided by a further **10** for the ARC path, with the comment *"Workaround for quadratic complexity in ARCSequenceOpts"*. Budget exhaustion returns `.abortWalk` (`Utilities/EscapeUtils.swift:974-980`), and `.abortWalk` **is** the "it escapes" answer (`:983`: `private var isEscaping: WalkResult { .abortWalk }`).

Consequence: a 10,000-instruction function gets 100 walk steps; the ARC query gets 10. **Running out of budget is indistinguishable from "it escapes", so the retains stay.** This is a direct architectural instruction for Assay: prefer many medium-sized functions over one giant fully-inlined decode function. A macro that emits one enormous flat body is actively fighting the optimizer.

**VERIFIED — COW uniqueness checks are hard ARC barriers.** `is_unique`, `begin_cow_mutation` and `destroy_not_escaped_closure` are unconditionally `mayReleaseOrReadRefCount == true` (`lib/SIL/IR/SILInstruction.cpp:1307-1316`). `ARCAnalysis.cpp:73` notes *"Reading the RC is as 'bad' as releasing."* Every `Array`/`String`/`Dictionary` mutation in the hot loop emits one of these and acts as a barrier to retain/release motion across it.

**VERIFIED (negative result) — existentials get no special handling.** Grepping `ARCAnalysis.cpp` for `Existential` / `ObjC` / `Weak` / `Unowned` returns **zero hits**. They fall through to the `return true` default, plus an opaque witness `apply` the analysis cannot see through. **Zero existentials in Assay's hot loop.**

**VERIFIED — `inout` is worse for the analysis than `borrowing`.** Only `@in_guaranteed` is recognised as an immutable address by alias analysis (`AliasAnalysis.swift:880-888`); `@inout` is not, and additionally introduces `begin_access` scopes.

### 1.3 Calling conventions

**VERIFIED.** SE-0377 `:41-47`:
> *"initializers and property setters ... **consume** ... **Other functions default to borrowing**."*

Confirmed in lowering: `Direct_Guaranteed` is pervasive in `lib/SIL/IR/SILFunctionType.cpp` (:1518, :1527, :2531, :2552, :2648, :3379). SIL docs: `docs/SIL/SIL.md:450-493`, `:308-309`.

So: **a normal function call does NOT retain its arguments** — that piece of folklore is false. Parameters and `self` arrive `@guaranteed` (+0).

**But returns are `@owned` (+1).** A hot-loop accessor that *returns* a non-trivial value creates a retain/release pair the optimizer then has to clean up. `_read`/`_modify` coroutine accessors (being standardised as `yielding get/set`, SE-0474) avoid this by yielding a borrow instead of returning an owned value. SE-0390 `:1283` discusses this.

### 1.4 SE-0377 `borrowing`/`consuming` and SE-0390 `~Copyable` — what they actually buy

**VERIFIED, and blunter than the marketing.** The payoff is overwhelmingly **(b) predictability**, occasionally **(c) real codegen at boundaries the optimizer structurally cannot cross**, and almost never **(a) removing retains `-O` would have removed anyway**.

SE-0377's own motivation, `:51-57`:
> *"the circumstances in which we can automate this are limited. The ownership convention becomes part of the ABI for public API ... The optimizer also does not try to optimize polymorphic interfaces, such as non-final class methods or protocol requirements."*

And `:486`, on `consume`:
> *"...without depending on optimization and **vague ARC optimizer rules**"*

That is Gottesman and Groff's own characterisation of the status quo. Even `copy x` is not a guarantee (`:255-258`). SE-0390 `:1400-1403` explicitly expects ARC to remain sufficient for most code.

`~Copyable`'s real value for Assay is **static enforcement**: a compile error instead of a silent copy. That is genuinely worth having on the cursor/reader type, because it converts "we believe this is ARC-free" into an invariant the compiler checks. But do not expect same-module `@inlinable` code to get faster merely from adding the annotations.

### 1.5 The central question: is a struct/generic/non-escaping-closure parser ARC-free at -O?

**Answer: only if it is transitively trivial. Otherwise it is folklore. VERIFIED.**

`docs/SIL/SIL.md:492`: *"Trivial values (like `Int`) values of address types don't have an ownership kind associated."* A struct is trivial iff all of its stored properties are trivial.

- `Int`, `UInt8`, `UnsafeRawPointer`, `UnsafeRawBufferPointer`, `Span`, `RawSpan` → genuinely ARC-free.
- `String`, `Array`, `Data`, any closure, any class reference, any existential → **not** trivial, ARC applies, and elimination is best-effort.

**The best dump-backed evidence available:** https://forums.swift.org/t/why-retain-release-pair-is-not-removed-in-this-particular-case/77206 — contains Godbolt x86-64 assembly at `-O` *and* SIL showing `strong_retain`/`strong_release`. Two reproducers: (a) an array of existentials, retains not removed; (b) **a `struct Wrap` containing a class instance** — merely wrapping the class in a struct defeated elimination *"despite the value being guaranteed to outlive the function call."* Karl Wagner's diagnosis in-thread: *"`for` loops use consuming iteration, which needs to copy the array."* Suggested workarounds: index-based loops rather than `for-in`, and `Unmanaged._withUnsafeGuaranteedRef`.

**UNVERIFIED:** no forum thread with SIL dumps specifically about a byte-level JSON parser was found. Thread 77206 is the closest and strongest evidence.

### 1.6 Non-escaping closures

**VERIFIED.** `docs/SIL/Types.md:164-183`: `@noescape` lowers to `@convention(thin)` or `@callee_guaranteed`, and *"If the function type is also `@noescape`, then the context value is **unowned**"*; `@callee_owned` is mutually exclusive with `@noescape`. **A non-escaping closure argument is never retained by the callee.**

`docs/SIL/Instructions.md:2812-2819`: `partial_apply [on_stack]` allocates its context **on the stack** and *"The closed-over values are **not retained**"*. Contrast `:2820-2828` (escaping) — *"heap allocated with a retain count of 1"*, captures consumed. `:2829-2832`: capturing an `inout` non-escapingly uses `@inout_aliasable` and does not own the value — free.

`AllocBoxToStack.swift` (:15, :90, :143, :190) promotes non-escaping boxes to the stack. A mutated captured `var` gets an `alloc_box` which stays heap-allocated **iff it escapes**. `ClosureLifetimeFixup.cpp:653` creates `OnStackKind::OnStack` in the mandatory pipeline.

**UNVERIFIED:** the exhaustive list of conditions that block on-stack promotion, and `ClosureSpecializer`'s exact firing conditions. Structure was read; not every bail-out path.

### 1.7 `@_effects` — the most under-used lever

**VERIFIED.** `docs/ReferenceGuides/UnderscoredAttributes.md:150-380` plus `docs/SIL/FunctionAttributes.md:188-191`.

Purpose (`:152-156`): *"information to the optimizer that it can't already infer from static analysis"* — precisely the manual escape hatch for the opaque-call and budget-exhaustion problems above. **Violations are undefined behaviour** (`:158-159`).

- `readnone`: must not release any parameter or anything reachable from one; **cannot be used with non-trivial owned arguments** (`:209-211`).
- **The ARC-convention trap (`:249-278`):** these attributes are *"sensitive to the ARC calling convention"*. For initializers and setters (which *consume*), `readonly` is likely invalid, and you must additionally write `releasenone` explicitly to signal intent.
- `releasenone` non-obvious violations the doc calls out (`:287-303`): owned params, **assignments (they release the old value)**, **COW types e.g. Strings**, class references nested deep inside value types.
- `readwrite` is *"not used by the compiler"* (`:305-307`) — don't bother.
- **`@_effects(notEscaping s.**)` and `@_effects(escaping x => y)` (`:309-380`)** let you *state* the escape answer rather than hoping the walker finds it inside its budget. Given §1.2, this is the single most valuable underscored attribute for Assay's reader type.

`ComputeSideEffects` / `ComputeEscapeEffects` infer these bottom-up and run ~7× (`PassPipeline.cpp:663, 712, 731, 775, 798, 836, 869`).

### 1.8 Verifying ARC traffic without guessing

**VERIFIED.** Exact flags:

- `-Rpass-missed=sil-assembly-vision-remark-gen` — retains/releases are emitted as **`RemarkMissed`**: `lib/SILOptimizer/Transforms/AssemblyVisionRemarkGenerator.cpp:735-755` (retain), `:801-820` (release), `:822+` (alloc stack-vs-heap), `:687-733` (exclusivity). Takes a **regex** (`include/swift/Option/Options.td:1106`; `lib/Frontend/CompilerInvocation.cpp:505-515`). It infers source-level names (`:125-126`, e.g. *"'myPair.lhs' is being retained"*).
- `@_assemblyVision` on a function or type (`UnderscoredAttributes.md:34-40`) — per-declaration, no global flag needed.
- **It runs last in the pipeline** (`PassPipeline.cpp:911`, `addLastChanceOptPassPipeline`) so remarks reflect *final* ARC traffic, not intermediate.
- `-Xllvm -sil-print-function=<name>` (`PassManager.cpp:136`), `-sil-print-functions=` (:140), `-sil-print-before/after/around=<pass>` (:145/:150/:155), `-sil-print-pass-name` (:58), `-sil-print-pass-time` (:62).
- Dedicated dumpers: `-sil-epilogue-arc-dumper`, `-sil-epilogue-retain-release-dumper` (`Passes.def:265-268`).

**Recommendation:** wire `-Rpass-missed=sil-assembly-vision-remark-gen` into Assay's CI on a canonical benchmark target and diff the remark set. It is the only ARC regression detector available that does not require reading disassembly.

---

## 2. Generic specialization, inlining attributes, and the resilience question

### 2.1 The one mechanical fact everything reduces to

**VERIFIED. Specialization and inlining both require the callee's SIL body to be present in the client's SILModule.** Three independent gates:

- `lib/SILOptimizer/Transforms/GenericSpecializer.cpp:118-126` — `if (!Callee->isDefinition() && !Callee->hasPrespecialization())` → emits the optimization remark *"Unable to specialize generic function ... since definition is not visible"*.
- `lib/SILOptimizer/Utils/Generics.cpp:3386` — `if (!prespecializedF.hasFunction() && !RefF->isDefinition()) return;`
- `lib/SILOptimizer/Utils/PerformanceInlinerUtils.cpp:802-804` — *"We can't inline external declarations."*

A body reaches the client by exactly four routes:
1. Same module (WMO).
2. `@inlinable` / `@_alwaysEmitIntoClient` / `@_transparent` serialization.
3. Cross-module optimization (CMO) serialization.
4. A `@_specialize(exported:)` prespecialization — a concrete body matched by exact substitution.

**For Assay this is the whole ballgame.** The macro emits into the user's module; every call it makes into Assay crosses the boundary. If Assay's primitives are not `@inlinable`, route 1 is unavailable, route 3 is unreliable (§2.3), route 4 is impossible (user types are unknown at Assay build time), and the client gets unspecialized generic code.

### 2.2 The decisive question: does library evolution destroy Assay?

**VERIFIED: No — because it is off by default and Assay cannot turn it on even if it wanted to.**

https://www.swift.org/blog/library-evolution/ : *"Library evolution support is turned **off** by default"*; *"Enabling library evolution support **changes your framework's performance characteristics**."*

The paragraph to quote in Assay's design doc, `docs/LibraryEvolution.rst:102-109`:
> *"This model is largely not of interest to libraries that are bundled with their clients (distribution via source, static library, or embedded/sandboxed dynamic library, as used by the Swift Package Manager) ... **anyone writing a bundled library should (ideally) not be required to use any of the annotations described below in order to achieve full performance.**"*

**VERIFIED:** SwiftPM has no `SwiftSetting` for library evolution, and `.unsafeFlags` is **rejected for version-pinned dependencies** — Ankit Aggarwal, https://forums.swift.org/t/confused-by-unsafe-flags-being-disallowed-in-dependencies/27359 ; Cory Benfield, https://forums.swift.org/t/using-library-evolution-in-a-versioned-package/63486 (*"Unsafe flags are not supported in stable library dependencies"*). So Assay can ship **neither** `-enable-library-evolution` **nor** `-cross-module-optimization` from its own manifest. Both are decisions its consumers make.

**What resilience costs when it *is* on** (relevant only if a consumer wraps Assay inside a resilient framework):
- `lib/IRGen/GenStruct.cpp:1787-1842` lowers every resilient struct to `IGM.OpaqueTy` (*"resilient structs are opaque"*, `:1703`).
- `lib/IRGen/ResilientTypeInfo.h:55-158` routes **every** copy / take / destroy / enum-tag operation through a value-witness call.
- Each such call is: metadata → VWT load **at index −1** (`lib/IRGen/GenMeta.cpp:5902-5925`) + pointer-auth → witness-slot load + pointer-auth (`lib/IRGen/GenOpaque.cpp:440-475`) → indirect call, with all operands address-only.
- `docs/LibraryEvolution.rst:920-945` on general optimizer pessimism, including *"inlinable code must be treated as if it is outside the current module."*

Mitigation set, if ever needed: `@frozen` + `@inlinable` / `@_alwaysEmitIntoClient` + `@usableFromInline`. Under a normal SwiftPM build `@frozen` is a **no-op** — SE-0497 L171: *"there does not exist a notion of non-`@frozen` types outside of Library Evolution."*

**Design conclusion: stop worrying about resilience. Worry about `@inlinable` coverage instead.** The mitigation for resilience and the mitigation for plain cross-module opacity are the same annotations, so applying them is a free hedge.

### 2.3 Cross-module optimization: real, but not something to depend on

**VERIFIED.** Frontend default is **Off** (`include/swift/AST/SILOptions.h:130`); nothing in the compiler auto-enables the aggressive form. SE-0497 resolves the apparent contradiction with forum reports: *"The 'conservative' form of CMO, **which has been enabled by the Swift Package Manager since Swift 5.8**, does this primarily for `public` functions."*

`lib/SILOptimizer/IPO/CrossModuleOptimization.cpp:1149-1194` — the pass **returns immediately if the module is resilient** (unless Package CMO) and requires `M.isWholeModule()`.

Two traps in `canSerializeFunction` (`:503-620`):
- **`if (!function->getSpecializeAttrs().empty()) return false;`** — with the comment that it is *"probably the developer's intention that the function is not serialized"*. **Adding `@_specialize` opts a function OUT of CMO.** This is a genuine footgun.
- Conservative size limit: `20*20 = 400` for polymorphic functions, `20` otherwise.

Published evidence:
- https://developer.apple.com/forums/thread/750712 — CMO flag, Xcode setting and `Package.swift` `swiftSettings` all produced no win; adding `@inlinable` gave **92µs → 3µs (~30×)** and 445µs → 12µs.
- https://forums.swift.org/t/what-are-the-tradeoffs-of-cross-module-optimization/45585 — records a **4× regression** in one case.
- https://forums.swift.org/t/66869 — 0.59s → 0.17s (CMO) → 0.04s (manual specialization + CMO).

**Conclusion: annotate, don't flag.** `@inlinable` beat CMO decisively in the one case with numbers, and CMO can regress.

### 2.4 Specialization preconditions and the unspecialized fallback

**VERIFIED.** Partial specialization is **off by default** — `lib/SILOptimizer/Utils/Generics.cpp:48-51`, `EnablePartialSpecialization(..., init(false))`. A call whose substitutions are still generic gets nothing.

Complexity bailouts, `Generics.cpp:82-85`: depth 50 / width 2000 / **associated-type chain length 10**. Generous — not Assay's problem. The real bailout list is `ReabstractionInfo::prepareAndCheck`, `Generics.cpp:559-692` (archetypes present, dynamic `Self`, too complex, all-generic substitutions, infinite specialization loop). Callee opt-outs at `Generics.cpp:437-460`.

**Unspecialized convention** (`lib/IRGen/GenProto.cpp:4209-4249`, `PolymorphicConvention` at `:103`): one type-metadata pointer per generic parameter plus one witness-table pointer per conformance, appended to the argument list. Address-only (`@in`/`@out`) passing for anything whose layout isn't known.

**Inliner cost model** (`lib/SILOptimizer/Transforms/PerformanceInliner.cpp:83-178`): **`GenericSpecializationBenefit = 320`**, equal to `DevirtualizedCallBenefit`; `TrivialFunctionThreshold = 18`; `OverallCallerBlockLimit = 400`. Note the shape of this: the inliner will inline a wrapper *specifically in order to expose a specialization opportunity*. Thin `@inlinable` forwarding shims are therefore cheap and useful.

### 2.5 Attribute semantics — what each one actually commits you to

**VERIFIED**, from `docs/ReferenceGuides/UnderscoredAttributes.md`, `docs/LibraryEvolution.rst`, `docs/TransparentAttr.md`, `docs/archive/Generics.rst` and the proposals.

| Attribute | Emits | ABI commitment | Crosses module? |
|---|---|---|---|
| `@inlinable` | body + symbol | **Yes** — body becomes ABI | Yes |
| `@usableFromInline` | symbol for internal decl | Yes (symbol) | Yes (as a reference target) |
| `@_alwaysEmitIntoClient` | body only, **no** symbol | **No** — not part of ABI | Yes |
| `@_transparent` | body, inlined pre-diagnostics | Yes | Yes |
| `@inline(__always)` | nothing extra | No | **No** |
| `@_specialize` | prespecialized clone | `exported:` → yes | Only via exact substitution |
| `@frozen` | layout | Yes | No-op outside library evolution |
| `@_optimize(none)` | — | — | **Blocks** specialization + inlining |

Details worth internalising:
- `@inlinable` — SE-0193 L80-88: *"**Inlinable declarations cannot define local types**"*; *"can only reference ABI-public declarations."* This constrains how Assay's `@inlinable` primitives can be written.
- `@_alwaysEmitIntoClient` — `LibraryEvolution.rst:270-286`: like `@inlinable` *"except the declaration is **not part of the module's ABI**."* Formalised as `@export(implementation)` in SE-0497 (Implemented, Swift 6.3). **This is the better default for Assay** — same optimization visibility, no ABI lock-in.
- `@_transparent` — inlined **before dataflow diagnostics, even at `-Onone`**; implicitly inlinable; does *not* imply `@usableFromInline`. The doc's own advice: *"Is it okay if the function is not inlined? ... Then you should use `@inlinable`."* Reserve for tiny leaf accessors.
- `@inline(__always)` — `UnderscoredAttributes.md:640-646`: *"**no effect in debug builds**"*, and it exports nothing. Useless on its own across a module boundary; must be paired with `@inlinable`.
- `@_specialize` — `docs/archive/Generics.rst:700-770`: *"acts as a **hint** ... The performance impact is not guaranteed."* `EagerSpecializer.cpp` clones the body and dispatches via a **runtime type check inserted at the top of the generic function**; `exported: true` sets `SILLinkage::Public` (`:820-824`); the client side is an exact-substitution *lookup* (`Generics.cpp:3150-3265`) gated on `availability:`. Combined with the CMO opt-out above, **`@_specialize` is a poor fit for Assay** — the user types are unknown.

### 2.6 `@_semantics` is a closed list — Assay cannot use it

**VERIFIED.** `include/swift/AST/SemanticAttrs.def` (173 lines) is a closed, name-matched list; arbitrary strings do nothing. `docs/HighLevelSILOptimizations.rst:56`: *"We use the `@_semantics` attribute to annotate code **in the standard library**."* Applying `array.*` / `string.*` to a third-party type is UB (`UnderscoredAttributes.md:1146-1155`). `@_semantics` can also *block* inlining (`PerformanceInlinerUtils.cpp:775-800`, and see §4.3). swift-collections uses it zero times.

The only third-party-safe members are the `optimize.sil.*` opt-out knobs.

### 2.7 What real libraries do

**VERIFIED** — counts over the on-disk checkouts:

| repo | `@inlinable` | `@usableFromInline` | `@_specialize` | `@_alwaysEmitIntoClient` | `@inline(__always)` | `@frozen` |
|---|---|---|---|---|---|---|
| swift-collections | 2486 | 570 | **0** | 908 | 1217 | 115 |
| swift-nio | 1329 | 552 | **1** | 75 | 27 | 0 |
| swift-foundation | 143 | 187 | 14 | 609 | 384 | 58 |
| swift-algorithms | 457 | 172 | **0** | 0 | 0 | 0 |

**None of them pass optimization flags in `Package.swift`.** Canonical pattern: `/home/claude/research/swift-collections/Sources/OrderedCollections/OrderedSet/OrderedSet.swift:279` — `@frozen public struct OrderedSet<Element>` with `@usableFromInline internal var __storage` and `@inlinable internal init`. swift-nio's single `@_specialize` (`Sources/NIOCore/ByteBuffer-core.swift:585-589`) is `@inline(never) @inlinable @_specialize(where Bytes == CircularBuffer<UInt8>)` on a deliberately-outlined *slow* path.

**Two findings that directly justify Assay's macro architecture:**

1. **VERIFIED.** `/home/claude/research/swift-foundation/Sources/FoundationEssentials/PropertyList/BPlistEncodingFormat.swift:13-14` — *"This code is duplicate for performance reasons, as use of **`@_specialize` has not been able to completely replicate the benefits of manual duplication**."* Apple's own team hand-monomorphized because `@_specialize` was not good enough. **A macro is that technique, automated.** This is the strongest available third-party endorsement of Assay's premise.

2. **VERIFIED.** Foundation's JSON decoder is **not `@inlinable` anywhere** — everything under `Sources/FoundationEssentials/JSON/` is internal and module-local, relying on WMO plus `@inline(__always)` (JSONEncoder 31 uses, JSONDecoder 20, JSONScanner 16). It buys speed by keeping everything in one module. **Assay structurally cannot do that**, because the macro emits into the user's module. Assay must therefore buy the same effect with `@inlinable` / `@export(implementation)` on its leaf primitives. This is not optional polish; it is the mechanism by which Assay matches Foundation's baseline before it starts beating it.

### 2.8 Recipe for Assay

1. Every reader primitive, every byte-level accessor, every generic entry point: **`@inlinable`** (or `@_alwaysEmitIntoClient` / `@export(implementation)` to avoid ABI lock-in) plus `@usableFromInline` on the internal storage they touch.
2. Do **not** use `@_specialize` — it opts the function out of CMO and cannot name user types anyway.
3. Do **not** ship `-enable-library-evolution`; do not attempt `.unsafeFlags` (it breaks versioned dependency resolution).
4. Keep `@inlinable` bodies free of local types and non-ABI-public references (SE-0193 constraint).
5. Emit macro bodies that are **concrete and monomorphic** so that no cross-module specialization is needed for per-field work at all (§7.4).
6. Keep generated function bodies medium-sized, not enormous — see the escape-analysis budget in §1.2.

---

## 3. Bounds and exclusivity checking

### 3.1 The assert family — which survives what

**VERIFIED**, `stdlib/public/core/Assert.swift`:

| function | `-Onone` | `-O` | `-Ounchecked` | line |
|---|---|---|---|---|
| `assert` | traps | **gone** | gone | :40 |
| `precondition` / `_precondition` | traps | `cond_fail` | **gone** | :102 / :317 |
| `_debugPrecondition` | traps | **gone** | gone | :372 |
| `_internalInvariant` | only with `INTERNAL_CHECKS_ENABLED` | gone | gone | :411 |
| `fatalError` | traps | traps | **traps** | :271 |

This three-way distinction is the single most useful thing to internalise about stdlib performance. When reading any stdlib source, the *name* of the assert tells you exactly what it costs at `-O`.

Under `-Ounchecked` both branches of `_precondition` fold to false, and the docs state the optimizer *"may assume that it always evaluates to `true`"* — i.e. it is **UB, not merely unchecked**. Configuration enum: `include/swift/AST/SILOptions.h:209-221`.

### 3.2 `-Ounchecked` trace

**VERIFIED**, `lib/Frontend/CompilerInvocation.cpp`:
- `:3117-3122` — `-Ounchecked` → `RemoveRuntimeAsserts = true`, `AssertConfig = Unchecked`.
- `:3019-3044` — exclusivity parsing.
- **`:3465-3466`** — `if (RemoveRuntimeAsserts) EnforceExclusivityDynamic = false;` — this runs *before* `:3467-3468`, so **`-Ounchecked -enforce-exclusivity=checked` re-enables dynamic exclusivity checks.** A usable middle ground for someone who wants unchecked arithmetic/bounds but keeps exclusivity.
- **`:4512-4518`** — SE-0458 strict memory safety combined with `-Ounchecked` is a **hard error**. If Assay's users adopt `-strict-memory-safety` (increasingly likely in 2026), they cannot also use `-Ounchecked`. **Assay must never require `-Ounchecked`.**

Integer overflow trapping is removed by `-Ounchecked` as well (same `cond_fail` mechanism). `Array` bounds checking is removed. All of it is client-side and whole-module.

### 3.3 Exclusivity

**VERIFIED.** Marker emission: `lib/SILGen/SILGenLValue.cpp:3783-3796` — `let` → no marker; global / static / class `var` → `[dynamic]`.

Resolution: `lib/SILOptimizer/Mandatory/AccessEnforcementSelection.cpp:701-767` — **`@inout` → STATIC always** (`:729-733`); `alloc_stack` → STATIC (`:759-766`); `project_box` of a non-`alloc_box` → DYNAMIC (`:694-696`). Elimination: `AccessMarkerElimination.cpp:72-89`. `[no_nested_conflict]` (`AccessEnforcementOpts.cpp:863-881`) → `lib/IRGen/IRGenSIL.cpp:7289-7290` skips `swift_endAccess` entirely.

**`AccessEnforcementWMO.cpp:263`: `if (key.isNull() || isVisibleExternally(key, &module)) return;` — the pass never optimizes `public` / `open` / `package` storage.** Direct design instruction: **avoid `public var` stored properties on hot types.**

**Notable 2026 change, VERIFIED.** `swift_beginAccess` / `swift_endAccess` are now implemented in Swift — `stdlib/public/core/Exclusivity.swift` (654 lines), `:172-208` / `:210-223`. It is a thread-local singly-linked list of 3-word `struct Access` (`:25-165`) held in a caller-stack `ValueBuffer` (`IRGenSIL.cpp:7135-7139`, "access-scratch"); `Access.search:69-114` is a **linear scan**. No lock, no allocation, no hash table. Darwin arm64 TLS access is `mrs %x0, TPIDRRO_EL0` slot 107 (`include/swift/Threading/ThreadLocalStorage.h:38-63`). There is **no `SWIFT_EXCLUSIVITY` environment variable** (absent from `EnvironmentVariables.def`).

**Consequence:** every pre-2026 published number for exclusivity-check cost is stale. Do not cite any of them.

**Practical guidance:** struct-local `inout` is statically enforced and therefore free. `let` bindings emit no marker at all. Class stored properties and globals are the dynamic cases. Assay's reader should be a `struct` passed `inout`, or better, a `~Copyable` struct — both land in the static-enforcement bucket.

### 3.4 Flags: the curated list

**VERIFIED — `-disable-safety-checks` DOES NOT EXIST.** Grepping `include/swift/Option/Options.td` matches the string only inside HelpText at `:1230` / `:1270`. Do not reference it.

Dead knobs (do not use, do not document):
- `-experimental-performance-annotations` — *"Deprecated, has no effect"* (`Options.td:1264-1266`).
- `-enable-ossa-modules` — *"Obsolete. This option is ignored"* (`FrontendOptions.td:1462`). **Note: this contradicts advice given in forum thread 77206 (§1.5); that workaround is stale.**

Corrections to commonly-repeated claims:
- `-sil-inline-caller-benefit-reduction-factor` is a **frontend option** (`FrontendOptions.td:1122-1126`), not an `-Xllvm` option.
- `-stack-promotion-limit` (default 1024) governs `alloc_ref [stack]`, **not** `Builtin.stackAlloc`. Two unrelated 1024s; do not conflate with `withUnsafeTemporaryAllocation`'s threshold (§5.5).
- `select_value` / `SelectValueInst` **no longer exists** in SIL.

Live and useful: `-Rpass-missed=sil-assembly-vision-remark-gen` (§1.8), `-enforce-exclusivity=unchecked`, `-cross-module-optimization`, `-unavailable-decl-optimization`.

### 3.5 The practical question: unchecked indexing for clients on default flags

**Answer: yes, via `UnsafeBufferPointer`'s element subscript or `Span.subscript(unchecked:)`. `-Ounchecked` is not available to a library — it is a client-side whole-module flag, and `_precondition` is `@_transparent`, folded per-client via `ConstantFolding.cpp`.**

**Ranked list of byte-access primitives at plain `-O` (VERIFIED):**

1. **`UnsafeBufferPointer` / `UnsafeMutableBufferPointer` *element* subscript — already free.** `stdlib/public/core/UnsafeBufferPointer.swift.gyb:428-439` uses `_debugPrecondition(i >= 0)` and `_debugPrecondition(i < endIndex)`. Doc: *"Bounds checks for `i` are performed only in debug mode."* Comment at `:48-50` explicitly says *"This works around `_debugPrecondition()` impacting the performance of optimized code. (rdar://72246338)"*.
2. **`Span` / `RawSpan` `subscript(unchecked:)`** — public `@unsafe` escape hatch, no check emitted (`stdlib/public/core/Span/Span.swift:500-506`, `RawSpan.swift:422-425`). **Keeps lifetime safety while dropping the bounds check** — this is the best of both worlds and the single most important API in this section.
3. **`RawSpan.unsafeLoad(fromUncheckedByteOffset:as:)`** (`RawSpan.swift:694-698`) vs the checked `:663-671`.
4. **`Array.withUnsafeBufferPointer` then index the UBP** — collapses to #1.
5. **Bounds-check elimination** (`BoundsCheckOpts.cpp`) — real, but see §4.4; unreliable for data-dependent decoder indexing.
6. **NOT free: `Span` / `RawSpan` *checked* subscript** — `_checkIndex` → `_precondition` (`Span.swift:469-473`, `RawSpan.swift:397-400`).
7. **NOT free: plain `Array` subscript** — `ContiguousArrayBuffer.swift:695-696`, `:708-709`.
8. **NOT free: `UnsafeBufferPointer` *slice* subscript** — `UnsafeBufferPointer.swift.gyb:521`, `_precondition(_checkBounds(bounds), "Index out of range")`.

**Trap for the unwary, worth a comment in Assay's source: for `UnsafeBufferPointer`, the element subscript is free but the slice subscript is not.** Same type, same syntax family, 2× different cost. Assay should never take a slice of a UBP in the hot loop; it should carry `(base, offset, count)` itself.

### 3.6 Measured cost of bounds checking

**VERIFIED as a negative: no credible published measurement was found** for bounds-check cost, exclusivity-check cost, or `-Ounchecked` speedup on decoder-like workloads. The 2026 Swift rewrite of `swift_beginAccess` (§3.3) invalidates every pre-existing exclusivity number anyway.

**Do not put a figure in Assay's documentation or README.** If a number is needed, Assay must measure it itself once a toolchain is available.

---

## 4. Span, RawSpan, UTF8Span, InlineArray, and the 2026 memory-safety story

### 4.1 Inventory and status

**VERIFIED** from on-disk proposal headers and stdlib `@available` annotations.

| Type / feature | SE | Status | Swift |
|---|---|---|---|
| `Span`, `RawSpan` | 0447 | Implemented | 6.2 |
| `MutableSpan`, `MutableRawSpan` | 0467 | Implemented | 6.2 |
| `OutputSpan`, `OutputRawSpan` | 0485 | Implemented (some stdlib extensions pending) | 6.2 |
| `Array.span`, `.mutableSpan`; `String.UTF8View.span` | 0456 | Implemented | 6.2 |
| `UTF8Span`, `String.utf8Span` | 0464 | Implemented | 6.2 |
| `InlineArray` | 0453 | Implemented | 6.2 |
| `[N of T]` sugar | 0483 | Implemented | 6.2 |
| Strict memory safety (`@safe`/`@unsafe`/`unsafe`) | 0458 | Implemented | 6.2 |
| `Iterable` (the "Container" protocol) | 0516 | on-disk header says Active review Jun 2026; **already in stdlib** | 6.4 |
| `borrow` / `mutate` accessors | 0507 | Implemented | 6.4 |
| `RawSpan.load(as:)` | 0525 | Implemented | 6.4 |
| `@export(implementation)` | 0497 | Implemented | 6.3 |

### 4.2 Availability floors — the prior claim is CONFIRMED

**VERIFIED.** Availability macro values (from `utils/availability-macros.def`):
- `SwiftCompatibilitySpan 5.0` = **macOS 10.14.4 / iOS 12.2 / watchOS 5.2 / tvOS 12.2 / visionOS 1.0**
- `SwiftStdlib 6.2` = **anyAppleOS 26.0**
- `SwiftStdlib 6.4` = **anyAppleOS 27.0**

| Thing | Annotation | file:line |
|---|---|---|
| `Span`, `RawSpan` | `@available(SwiftCompatibilitySpan 5.0, *)` + `@_originallyDefinedIn(module: "Swift;CompatibilitySpan", SwiftCompatibilitySpan 6.2)` | `Span/Span.swift:25-29`, `Span/RawSpan.swift:24-29` |
| `MutableSpan`, `MutableRawSpan` | same | `MutableSpan.swift:20-23`, `MutableRawSpan.swift:20-23` |
| `OutputSpan`, `OutputRawSpan` | same | `OutputSpan.swift:22-25`, `OutputRawSpan.swift:23-25` |
| `Array.span` | `@available(SwiftStdlib 6.2, *)` | `Array.swift:1757` |
| `Array.mutableSpan` | `@available(SwiftStdlib 6.2, *)` | `Array.swift:1883` |
| `String.UTF8View.span` | `@available(SwiftStdlib 6.2, *)` | `StringUTF8View.swift:359` |
| `UTF8Span`, `String.utf8Span` | `@available(SwiftStdlib 6.2, *)`, no back-deploy | `UTF8Span.swift:15-18`, `:266-268` |
| `InlineArray` | `@available(SwiftStdlib 6.2, *)`, no back-deploy | `InlineArray.swift:97-101` |

**The prior research is correct.** Mechanism: `stdlib/public/core/CMakeLists.txt:397-407` — *"Backward deployment of Span on Apple platforms is implemented via the libswiftCompatibilitySpan.dylib shim ... we emit the correct `$ld$previous$` symbols"*; on new OSes the dylib is a symlink to `libswiftCore.dylib` (`:499-527`).

Corroborated by Guillaume Lessard, 2025-06-17, https://forums.swift.org/t/using-span-on-pre-26-apple-os-versions/80513 : *"`Array.span`, `String.utf8.span` and `Substring.utf8.span` aren't back-deployable due to the bridging changes they depend on."*

**Design consequence for Assay.** The *types* `Span`/`RawSpan` back-deploy to macOS 10.14.4, but **every convenient way of obtaining one from a standard Swift container requires macOS 26**. So a Span-based public API is only broadly usable if Assay constructs the span itself from an unsafe pointer (`RawSpan(_unsafeBytes:)`, §4.6) — which is available at the low floor. That is viable, but it means Assay's own entry points take `[UInt8]` / `Data` / `UnsafeRawBufferPointer` and do the conversion internally, rather than asking users for a `Span`.

### 4.3 The key question: does a RawSpan parser generate the same code as an UnsafeRawBufferPointer parser?

**Answer: not by default, and the reason is bounds checks that survive `-O` unless a specific loop shape is present.**

**VERIFIED (a) — the check survives `-O`.** `RawSpan.subscript(_:)` calls `_checkIndex` (`RawSpan.swift:397-400`), which is `_precondition(byteOffsets.contains(position), "Index out of bounds")`. Per §3.1, `_precondition` lowers to `Builtin.condfail_message` at `-O` and is removed only under `-Ounchecked`. Contrast `UnsafeBufferPointer`'s element subscript, which uses `_debugPrecondition` and is free.

**VERIFIED (b) — Span carries no extra state.** `Span` / `RawSpan` are `_pointer: UnsafeRawPointer?` + `_count: Int` (`Span.swift:38,52`; `RawSpan.swift:38,52`). `UTF8Span` is pointer + `_countAndFlags: UInt64` (`UTF8Span.swift:20,35`). All `@frozen`. There is **no lifetime token at runtime** — same register footprint as `UnsafeRawBufferPointer`. Lifetime safety is entirely a compile-time construct.

**VERIFIED (c) — Span's implementation is fully visible to the client optimizer.** `Span.swift` contains **61 `@export(implementation)` and zero `@inlinable`**. Per SE-0497 `:91` (`@export(implementation)` subsumes `@_alwaysEmitIntoClient`) and `:140` (*"Always inlined everywhere; callers emit their own definitions"*), `_checkIndex` and friends are emitted into Assay's own code. So the check is *visible* — the question is only whether it can be *proved redundant*.

### 4.4 Bounds-check elimination for Span — exactly when it fires

Two subagents contradicted each other here. **Resolved by direct reading; the optimistic reading is correct — the machinery is real, not aspirational.**

**VERIFIED.** `_checkIndex` carries `@_semantics("fixed_storage.check_index")` (`Span/Span.swift:464-472`, `Span/RawSpan.swift:397-399`, `InlineArray.swift:489-492`), registered at `include/swift/AST/SemanticAttrs.def:167-168`, wrapped by `FixedStorageSemanticsCall` (`include/swift/SIL/InstWrappers.h:407-411`, `lib/SIL/Utils/InstWrappers.cpp:107-108`).

`lib/SILOptimizer/LoopTransforms/BoundsCheckOpts.cpp` consumes it in three places:
- `hoistFixedStorageBoundsChecksInBlock` (`:1269`) — block-local; **merges adjacent checks on the same self, it does not remove them** (`:1305-1330`). It sets up later CSE.
- `removeRedundantFixedStorageBoundsChecksInLoop` (`:1088`, driven from `:1598`) — dominator-based redundancy removal.
- `hoistFixedStorageBoundsChecksInLoop` (`:1727`) — the important one.

**The precise removal conditions, `BoundsCheckOpts.cpp:1727-1800`:**
- `canOptimize` (`:1252-1267`) — passes if `self` is a **value** (not an address); if it is an address, the root must be a function argument with convention **`Indirect_In_Guaranteed`**. A `Span` held in a local `let` and passed by value qualifies.
- `self` must dominate the loop preheader (`:1758-1763`).
- **If the index is loop-invariant → the check is hoisted** (`:1768-1774`).
- The index must be a **linear function of an induction variable** — `AccessFunction::getLinearFunction(indexValue, indVars, DT, preheader)`; otherwise *"not a linear function"* and the pass gives up (`:1776-1781`).
- **`if (accessFunction.isZeroToCount(selfValue))` → the check is erased entirely** (`:1783-1789`), logging *"Redundant Span/InlineArray bounds check removed"*.
- Otherwise, if the block always executes, the check is hoisted to the preheader as a lower/upper bound pair (`:1791-1800`).

**This is the finding.** `for i in span.indices { ... span[i] ... }` is exactly `isZeroToCount` and gets the check **erased**. A JSON scanner's `while cursor < end { ... cursor &+= n }`, where `n` is data-dependent (skip a string, skip whitespace, skip a number), is **not a linear function of an induction variable**, so `getLinearFunction` returns null and **every checked subscript keeps its `_precondition`**.

**UNVERIFIED (needs a toolchain to settle):** whether a simple `cursor &+= 1` byte loop is recognised as an induction variable by `InductionAnalysis`. It plausibly is; the variable-stride case certainly is not.

**VERIFIED — the stdlib deliberately preserves the markers for client code.** `lib/SILOptimizer/Transforms/PerformanceInliner.cpp:1078-1084` refuses to inline `array.*` and `fixed_storage.*` semantics functions *when compiling the stdlib itself*, *"because they need to be preserved, so that the optimizer can properly optimize a user code later."* So the markers do reach Assay.

SE-0447 `:136` concedes the residual: unchecked variants exist *"for cases where bounds-checking is proving costly, such as in tight loops."*

**Design conclusion: use `Span`/`RawSpan` for lifetime safety, but index with `subscript(unchecked:)` in the cursor loop.** That gives identical codegen to `UnsafeRawBufferPointer` (two-word value, no check) while retaining compile-time lifetime safety that raw pointers do not provide. Reserve the checked subscript for the `for i in span.indices` shapes where the compiler will erase it anyway.

### 4.5 The bigger Span risk: `mark_dependence` blocking closure specialization

**VERIFIED, and more important than bounds checks.** https://forums.swift.org/t/mutablespan-comes-with-performance-penalties-compared-to-unsafepointer-s/87385 (June 2026, Swift 6.4) — a `MutableSpan` port cost **+75%** (200ms → 350ms). Root cause was **not** bounds checks: `mark_dependence [nonescaping]` arising from `~Escapable` **blocked closure specialization**, leaving generic indirect calls. Fixed by compiler PRs #90002 / #90161.

This is the pattern to watch: `~Escapable` values introduce dependence markers that other optimizer passes are not yet uniformly taught to see through. For a macro-driven decoder that passes a reader into generated per-field closures or generic helpers, this is a realistic regression vector. **Assay should avoid closures over Span-typed values in the hot path**, preferring `inout` reader parameters.

**UNVERIFIED:** no RawSpan-vs-UnsafeRawBufferPointer *parsing* benchmark exists in public. This is the highest-value thing for Assay to measure first.

### 4.6 `~Escapable` and `@_lifetime` — ergonomics

**VERIFIED — the spelling is still underscored and gated.** `include/swift/AST/DiagnosticsSema.def:8796`: `WARNING(use_lifetime_underscored, ... "Unsupported use of @lifetime, use @_lifetime to specify lifetime dependencies")`. Feature gates: `include/swift/Basic/Features.def:577` `SUPPRESSIBLE_EXPERIMENTAL_FEATURE(Lifetimes, true)` and `:471` `EXPERIMENTAL_FEATURE(LifetimeDependence, true)` — usable in shipping toolchains but requires `-enable-experimental-feature Lifetimes`.

**There is no accepted SE proposal for the attribute.** SE-0465 `:366-368` states flatly: *"the `@_lifetime` attribute is not real; it is merely a didactic placeholder."* `dependsOn` is a dead older pitch spelling.

Spellings in current use: `@_lifetime(immortal)`, `@_lifetime(borrow x)`, `@_lifetime(copy self)`, `@_lifetime(&self)` (replacing SE-0467's `inout self`), `@_lifetime(dependent: borrow source)`.

**The universal escape hatch is `_overrideLifetime`** (`stdlib/public/core/LifetimeManager.swift:302-360`, four overloads, `public` but underscore-prefixed, `@unsafe @_unsafeNonescapableResult @_transparent`). Every stdlib `.span` accessor ends with `return unsafe _overrideLifetime(span, borrowing: self)`. Assay will need this too.

**What breaks:**
- Storing a `Span` in a struct forces the enclosing struct to be `~Escapable`, and `~Escapable` **cannot be added via an extension** (SE-0446 `:109-114`).
- Adding `~Escapable` to an existing type is **source- and ABI-breaking**; `Escapable` is implicit on every existing type (SE-0446 `:68`).
- Closures are worse: `ERROR(lifetime_dependence_function_type, "lifetime dependencies on function types are not supported")` (`DiagnosticsSema.def:8819`); `ClosureLifetimes` is a separate, unshipped feature (`Features.def:282`).
- Joe Groff, 2025-09-03, https://forums.swift.org/t/lifetime-dependencies-and-pointers/81943 : *"We don't yet have public API for capturing references to individual values like this"* — his workaround was `InlineArray<1,T>` + `MutableSpan`.

**Design consequence: Assay's reader type must be `~Escapable` if it holds a Span**, which means it is subject to the experimental-feature gate and cannot be stored in ordinary escapable structs by users. That is a real ergonomic tax. The alternative — hold an `UnsafeRawPointer` + count and expose a safe façade — avoids the tax at the cost of internal unsafety. **Given the author's stated tolerance for unsafe internals, the pointer-based reader with a safe public façade is the lower-risk choice today**, revisitable when `Lifetimes` ships un-gated.

### 4.7 Accessors

**VERIFIED.** `Span`'s subscript uses SE-0507's `borrow { }` accessor (`Span.swift:482-488`), with a plain `get` for `BitwiseCopyable` elements (`:533`). Span-returning properties use `borrowing get` / `mutating get` — **no copy of the container**, just a live exclusivity borrow. `_read`/`_modify` are being standardised as `yielding get/set` (SE-0474, Accepted, behind `CoroutineAccessors`). `unsafeAddress` makes a property implicitly `@unsafe` (SE-0458 `:162`).

### 4.8 Strict memory safety (SE-0458)

**VERIFIED.** All diagnostics are **warnings** in the group `StrictMemorySafety`, and are off unless the **user** passes `-strict-memory-safety`. `unsafe` **does not propagate outward** (SE-0458 `:97`).

So Assay can seal its boundary: `unsafe` expressions internally, `@safe` on entry points whose signatures contain no unsafe types. **The real risk is macro *expansions* landing unsafe code in the user's module**, where the user's `-strict-memory-safety` setting applies. Mitigation: **expand only to calls into `@safe`-marked runtime functions**; never expand raw pointer arithmetic into user code. This is a concrete constraint on macro codegen.

Recall also §3.2: `-strict-memory-safety` + `-Ounchecked` is a hard error (`CompilerInvocation.cpp:4512-4518`).

### 4.9 C interop

**VERIFIED.** `RawSpan(_unsafeStart: UnsafeRawPointer, byteCount: Int)` (`RawSpan.swift:~196-201`, with `_precondition(byteCount >= 0)`) and `RawSpan(_unsafeBytes:)` over `UnsafeRawBufferPointer`, its `Slice`, and mutable variants (`:108-171`). All are `@unsafe` + `@_lifetime(borrow buffer)` at `SwiftCompatibilitySpan 5.0` — i.e. **available at the low back-deployment floor**.

Because the annotation ties the dependency to the *pointer's* borrow scope, you must follow with `_overrideLifetime(s, borrowing: owner)` to re-anchor it to the real owner.

Annotated C headers: `__counted_by(len) ... __noescape` → `func f(_ d: Span<UInt8>)`; `__sized_by` on `void*` → `RawSpan`; `__lifetimebound` drives the annotations. See https://www.swift.org/documentation/cxx-interop/safe-interop/ .

### 4.10 InlineArray

**VERIFIED.** `@frozen public struct InlineArray<let count: Int, Element: ~Copyable>: ~Copyable` with `Builtin.FixedArray<count, Element>` storage (`InlineArray.swift:97-104`). Sugar is **`[5 of Int]`** — whitespace around `of` is mandatory; it is **not** `[N x T]`. `MemoryLayout<InlineArray<4,UInt8>>.size == 4` (SE-0453 `:139`) — genuinely inline, genuinely stack-allocated.

Same `fixed_storage.check_index` + `_precondition` bounds-checking story as `Span` (§4.4).

**macOS 26+ only.** For back-deployable fixed-size scratch, use `withUnsafeTemporaryAllocation` (§5.5) instead.

---

## 5. Mechanics of a fast scanner in Swift

### 5.1 Small strings — the hypothesis is partially falsified

**VERIFIED. For keys ≤ 15 UTF-8 bytes on 64-bit, `String` already allocates nothing.**

Capacity, `stdlib/public/core/SmallString.swift:79-94`:
```swift
#if os(watchOS) && _pointerBitWidth(_32)
    return 10
#elseif _pointerBitWidth(_32) || _pointerBitWidth(_16)
    return 8
#elseif os(Android) && arch(arm64)
    return 14
#elseif _pointerBitWidth(_64)
    return 15
```
Note `contiguousCapacity()` at `:96-103` returns `capacity - 2` on 32-bit watchOS. **Hardcoding 15 anywhere in Assay is a portability bug** — use `_SmallString.capacity`'s logic or a conservative 8.

- **ASCII is not required.** `SmallString.swift:303-315` computes `isASCII = (leading|trailing) & 0x8080_8080_8080_8080 == 0` as a *flag*, not a gate. Any UTF-8 within capacity fits.
- **Always immortal ⇒ zero retain/release, zero heap.** `StringObject.swift:45-46` (*"Small strings are just values, always immortal"*); the immortal bit is set unconditionally by `small(isASCII:)` at `StringObject.swift:402-409`. Layout diagram `:583-593`; `isSmall` `:476-482`; count nibble `:638-645`.
- **Equality is two inlined 64-bit compares.** `StringComparison.swift:17-22` — `_stringCompare` is `@inlinable @inline(__always)` and opens with `if lhs.rawBits == rhs.rawBits { return expecting == .equal }`. No call, no memcmp, no allocation.
- **Caveat, and it matters:** the *unequal* path `_stringCompareWithSmolCheck` (`StringComparison.swift:26-43`) is `@usableFromInline` but **not `@inlinable`** — it is an outlined call. A linear scan over N candidate keys therefore pays N−1 real function calls. **This is the argument for length-bucketing** even when strings are small.

**So the real per-key cost is not allocation.** It is (a) the UTF-8 validation pass in `_tryFromUTF8` (`StringCreate.swift:168-175`), (b) the byte-at-a-time `_bytesToUInt64` packing loop (`SmallString.swift:451-467` — the stdlib's own TODO at `:328` says this should be a masked vector load), and (c) **Dictionary insert + SipHash** in Foundation's design.

The original hypothesis ("avoiding String allocation entirely for short keys may be the single biggest win") holds fully only for keys **> 15 bytes** and for the **Dictionary layer**. For short keys, the win is real but smaller than assumed, and it comes from skipping validation + packing + hashing, not from skipping malloc.

### 5.2 The highest-value finding: what Foundation actually does per key

**VERIFIED.** `/home/claude/research/swift-foundation/Sources/FoundationEssentials/JSON/JSONDecoder.swift:1259-1308`, `KeyedContainer.stringify`. For **every** JSON object, eagerly in `init` (`:1305-1309`), swift-foundation:
1. allocates a `[String: JSONMap.Value]`,
2. calls `impl.unwrapString` → `String._tryFromUTF8` on **every key**, including keys the `Decodable` type never asks for,
3. SipHashes each one,
4. inserts it.

Lookup (`getValue(forKey:)` `:1521-1530`) is then just `dictionary[key.stringValue]` — plus another hash. `.convertFromSnakeCase` adds an allocation and transform per key on top.

**This is the structural thing Assay beats, and it is the clearest single argument for the whole project.** A macro knows the field set at compile time: no Dictionary, no hashing, no stringifying unrequested keys, and snake-case conversion baked in at expansion time for zero runtime cost.

**VERIFIED:** ReerJSON does not avoid it either — `ReerJSON/Sources/ReerJSON/JSONDecoderImpl.swift:962,973` does `key.stringValue.withCString { yyjson_obj_get(...) }`, plus String-keyed dictionaries at `:713,717,1086,1090,1335,1346`. **No Swift JSON decoder that was read avoids String for keys.** That is an open lane.

**The pattern to copy — VERIFIED, `JSONScanner.swift:710-726`:** `readExpectedString(_ str: StaticString, ...)` → `memcmp(ptr, str.utf8Start, str.utf8CodeUnitCount)`. Foundation already uses `StaticString` + `memcmp` for `true` / `false` / `null`. It generalises to keys perfectly and Foundation simply never did it.

**Recommended key-dispatch design for Assay's macro:**
1. Switch on key **length** (an integer switch — see §6 for the caveat, and prefer mapping to an enum).
2. Within a length bucket, do a masked `loadUnaligned(as: UInt64.self)` compared against compile-time-baked constants — one `mov` / `and` / `cmp`. Two overlapping loads cover 9–16 bytes.
3. Fall back to `memcmp` against `StaticString.utf8Start` for long keys.

**What the stdlib does NOT give you — VERIFIED:** `_stringCompareFastUTF8` and `_binaryCompare` → `_swift_stdlib_memcmp` are internal. `String.utf8.elementsEqual` and `UTF8Span.bytesEqual(to:)` (`UTF8SpanComparisons.swift:18-21`) are **generic `Sequence` iterator loops, not memcmp**. Assay must write its own comparison primitives. (Curiosity: a `static func ~=(_ lhs: StaticString, _ rhs: UTF8Span)` sits commented out at the end of `UTF8SpanComparisons.swift` — the stdlib considered exactly this and did not ship it.)

### 5.3 String construction — does `String(decoding:as:)` copy twice?

**VERIFIED: no, not on contiguous input.** `String.swift:442-488` (`@inlinable @inline(__always)`) tries `withContiguousStorageIfAvailable`, then `_HasContiguousBytes`, then a fallback. Only the fallback `_fromNonContiguousUnsafeBitcastUTF8Repairing` (`String.swift:420-431`, `@inline(never)`) does `Array(input)` first — **that is the sole double-copy path**. `[UInt8]`, `Data` and `UnsafeBufferPointer` all take the fast path: **one validation pass + one pack, zero allocation if ≤15 bytes.**

**VERIFIED — the real trap is `String(unsafeUninitializedCapacity:)`.** `String.swift:723-747` branches on `if _fastPath(capacity <= _SmallString.capacity)` — that is the **declared capacity, not the returned count**. Declaring 64 and writing 3 bytes **heap-allocates a 64-byte `__StringStorage`**. Additionally the non-ASCII small branch does an extra spill-and-repack round trip.

**Design instruction:** if Assay uses `String(unsafeUninitializedCapacity:)`, it must pass a tight upper bound, not a generous one. For short values this API is *worse* than `String(decoding:as:)`.

All byte→String paths funnel through `_uncheckedFromUTF8` (`StringCreate.swift:249-264`), which checks the small form first.

Ranking for building a String from a contiguous byte range:
1. `String(decoding: bytes, as: UTF8.self)` where `bytes` is contiguous — one validation pass, one pack, no allocation if small. **Default choice.**
2. `String(unsafeUninitializedCapacity:)` with a *tight* capacity — comparable, and lets you write transformed bytes directly.
3. `String(unsafeUninitializedCapacity:)` with a loose capacity — **allocates unconditionally**. Avoid.
4. Appending to a `var String` in a loop — repeated realloc. Foundation's `_slowpath_stringValue` (`JSONScanner.swift:912+`) does exactly this; it is beatable.

### 5.4 Unaligned loads

**VERIFIED.** `stdlib/public/core/UnsafeRawPointer.swift:490-498` — the `BitwiseCopyable`-constrained `loadUnaligned` is `@_transparent` + a bare `Builtin.loadRaw` = **one instruction**.

**The legacy unconstrained overload at `:522-541` is a real memcpy** (`_withUnprotectedUnsafeTemporaryAllocation` + `Builtin.int_memcpy_...`). **Always use a concrete type or constrain to `BitwiseCopyable`** — otherwise overload resolution can silently pick the slow one. This is a subtle, high-impact footgun for generic helper code.

`load(fromByteOffset:as:)` (`:443-464`) and `withMemoryRebound` (`:395-408`) both carry alignment `_debugPrecondition`s — semantically wrong for a scanner reading at arbitrary offsets, even though the check vanishes at `-O`.

SE-0349, Implemented in **Swift 5.7** (apple/swift#41033) — comfortably below any floor Assay cares about.

**SE-0525 check, and the naming misleads:** `RawSpan.load(fromByteOffset:as:)` at `RawSpan.swift:768` **delegates to `unsafeLoadUnaligned`** — it *is* unaligned despite the name. Unchecked variant at `:753`; byte-order overload at `:789`, `@available(SwiftStdlib 6.4)`. **Not worth gating Assay on 6.4** — `UnsafeRawPointer.loadUnaligned` has existed since 5.7 with identical codegen.

### 5.5 `withUnsafeTemporaryAllocation` (SE-0322)

**VERIFIED**, `stdlib/public/core/TemporaryAllocation.swift`:
- **Stack threshold is 1024 bytes, hardcoded** (`:84-90`).
- There is an unconditional `false` above it at `:92-95` — `swift_stdlib_isStackAllocationSafe` is **not wired up**.
- **Alignment must be ≤ 16** (`:80-82`; `RuntimeShims.h:101`); above that it heap-allocates.
- `_isStackAllocationSafe` is `@_transparent` (`:61`) so it constant-folds for literal sizes.
- **Over the threshold → silent `malloc`, no trap or diagnostic** (`:127-131` → `:173-187`). A hot-path hazard: a size that creeps past 1024 degrades silently.
- Deallocation is guaranteed on throw (`:138-141`).
- Loop-safe: entry-block hoisting (`lib/IRGen/GenDecl.cpp:6107-6121`) and `llvm.stacksave`/`llvm.stackrestore` (`lib/IRGen/GenOpaque.cpp:831-838`).
- **`-stack-alloc-limit n` from SE-0322 `:227` was NEVER IMPLEMENTED.** Do not document it.
- **The body parameter is synchronous in every overload** (`:223, :264, :306, :378, :406`; `IRGenSIL.cpp:3803-3805` `DoesNotAllowTaskAlloc`; `test/IRGen/temporary_allocation/async.swift:7-13` asserts `CHECK-NOT: swift_task_alloc`). **You cannot `await` inside.** Another reason for a sync parse API (§8.3).

SE-0322, Implemented Swift 5.6. Proposal `:213` states there is no stack guarantee by design. Corroborated by swift-foundation's own comment at `String+Bridging.swift:111`.

**Design instruction: keep every Assay scratch buffer ≤ 1024 bytes**, and assert that statically in the macro where possible.

### 5.6 Byte-range compare, SIMD, and movemask

**VERIFIED — a portable movemask is not available.** https://forums.swift.org/t/simd-move-mask-operation/39096 , Steve Canon: the stdlib does not expose it, and *"movemask isn't a thing that can be efficiently defined for all architectures (arm64 does not have an analogous instruction)."* His spelling uses `import _Builtin_intrinsics.intel` + `_mm_movemask_epi8`, x86-only.

**UNVERIFIED:** whether `_Builtin_intrinsics.intel` actually ships in a released toolchain — zero hits anywhere under `stdlib/` or `lib/`.

**VERIFIED** the stdlib has a private one at `StringCreate.swift:27-31` (`Builtin.bitcast_Vec16xInt1_Int16` ∘ `Builtin.cmp_slt_Vec16xInt8`) plus an arm64 `umaxv` path at `:34-36` — **unreachable from a package.** `SIMDMask._storage` is public (`SIMDVector.swift:706`), so a bitcast route plausibly exists, but **UNVERIFIED** whether it lowers well. Note that `SIMDMask.leadingZeroBitCount` / `.nonzeroBitCount` (`:766-780`) are **per-lane vectors, not bitmasks** — an easy misreading.

**SWAR is the portable answer, and Foundation uses it** — `JSONScanner.swift:862-877`, `noByteMatches`, is a `haszero` trick on `UInt32`. **Widen to `UInt64` as Assay's portable baseline; put SIMD behind a vendored-C shim and a build flag.** Given the author's stated tolerance for vendored C, this is where the C earns its keep — a portable pure-Swift SIMD scanner is not currently writable.

### 5.7 Iterating UTF-8 bytes

**VERIFIED**, ranked:
1. **`s.utf8.withContiguousStorageIfAvailable`** (`StringUTF8View.swift:676-684`) — `guard _guts.isFastUTF8 else { return nil }`, no copy. Must handle the `nil` case.
2. `withUTF8` (`StringProtocol.swift:226-233`) — **`mutating`**, and calls `makeContiguousUTF8()` (`:207-211`), which **heap-allocates and transcodes for a bridged NSString**. Small strings spill to the stack (doc `:218-222`).
3. `for b in string.utf8` — index arithmetic per byte.
4. `Array(string.utf8)` — always allocates.

**Best input types, VERIFIED:**
- `[UInt8]` — `Array.withContiguousStorageIfAvailable` (`Array.swift:1435-1444`) is always non-nil, O(1).
- `Data.withUnsafeBytes` (`Data.swift:526`) is **always contiguous** across all four representations (`Data+Inline.swift:158-164` spills its 14-byte inline tuple to the stack; slices go through `DataStorage.swift:180`).

**Design instruction:** Assay's public entry points should accept `[UInt8]`, `Data` and `UnsafeRawBufferPointer` and immediately obtain a contiguous base pointer. Accepting `String` should route through `utf8.withContiguousStorageIfAvailable` with an explicit slow path, never `withUTF8` (mutating + potential transcode).

### 5.8 Foundation's JSON scanner — technique inventory and what is beatable

**VERIFIED.** Two-phase tape design (`JSONScanner.swift:13-51`): a flat `[Int]` of markers/offsets with `nextSiblingOffset`; strings and numbers are deferred, not materialised during the scan. Worth stealing.

- `JSONPartialMapData.resizeIfNecessary` (`:275-340`) predicts the final tape size every 2048 entries from the consumed-byte ratio. **Genuinely clever, worth copying.**
- `DocumentReader` (`:599-860`) is nearly all `@inline(__always)`.
- Whitespace test via a `UInt64` bitmap shift-test.
- `skipUnicodeHexSequence` (`:818-829`) is the one unaligned `UInt32` load.
- Control-character test is `byte & 0xe0 != 0` (`:757-771`).

**Slow, and beatable by Assay:**
1. The eager Dictionary stringify of every key (§5.2) — the big one.
2. SipHash per key, twice (insert + lookup).
3. **No SIMD anywhere** (grep-verified).
4. **No `withUnsafeTemporaryAllocation` anywhere** in the JSON directory (grep-verified) — `_slowpath_stringValue` (`:912+`) does repeated `output += stringChunk` String appends with realloc, where a 1024-byte stack scratch buffer would win outright.
5. Snake-case conversion at runtime rather than at compile time.
6. An uncontended `Mutex` acquired per buffer access (`JSONMap:57-140`).

---

## 6. Switch / jump-table codegen

This was an open question in the author's prior notes. **It has a clear and consequential answer.**

### 6.1 String switch is O(n). Blunt.

**VERIFIED.** `switch someString { case "name": ...; case "age": ... }` with 50 cases performs **up to 50 sequential string comparisons, at every optimization level.** No hashing, no trie, no perfect hash, no length bucketing.

Mechanism: SILGen treats `case "name":` as an `ExprPattern`, and `isWildcardPattern` returns **true** for `PatternKind::Expr` — `lib/SILGen/SILGenPattern.cpp:217-226`, with the explanatory comment at `:212-216`:
> *"We also consider ExprPatterns to be wildcards; we test the match expression as a guard outside of the normal pattern clause matrix."*

Consequence chain:
- `chooseNecessaryColumn` (`:1049-1077`, Maranget's algorithm) returns `nullopt` for an all-`Expr` column.
- `emitDispatch` (`:1079-1155`) therefore takes the `if (!column)` branch at `:1106-1108` → processes **one row at a time**.
- `bindRefutablePatterns` (`:1249-1259`) → `emitGuardBranch` (`:1459-1491`): `:1480` emits the `~=` call, `:1485` emits `createCondBranch`.

That is a linear `~=` / `cond_br` chain.

**The saving grace is only the constant factor.** `stdlib/public/core/StringComparison.swift:15-22` — `_stringCompare` opens with `if lhs.rawBits == rhs.rawBits`. For keys ≤15 UTF-8 bytes that is **two 64-bit compares per case** (§5.1). Cheap, but paid n times, and the *miss* path `_stringCompareWithSmolCheck` (`:26-43`) is not `@inlinable`, so each miss is a real out-of-line call.

**`_findStringSwitchCase` is unreachable from a hand-written switch. VERIFIED.** Its sole producer is `lib/Sema/DerivedConformance/DerivedConformanceRawRepresentable.cpp:381-393`, gated on `:307 isStringEnum` — it exists only for the *synthesized* `init?(rawValue:)` of a String-raw-value enum. Even that is a linear scan (`StringSwitch.swift:19-33`) unless `ObjectOutliner.swift:513-519` (**> 16 cases**, `-O` only, `:583-585`) upgrades it to a cached `Dictionary`.

Tests confirming: `validation-test/SILOptimizer/string_switch.swift:13-16` (5 cases → linear), `:26-29` (37 cases → Dictionary cache); `test/SILGen/switch_debuginfo.swift:35-45` shows a plain string switch emitting bare `string_literal utf8` with no helper call at all.

**Design consequence — decisive for Assay's macro:** the macro must **never** generate `switch keyString { case "...": }`. It must generate length-bucketed + word-compare dispatch (§5.2), or map the key to a dense enum first.

### 6.2 Integer switch also comes out of SILGen as a comparison chain

**VERIFIED.** `switch_value` is emitted from **exactly one place in SILGen**: `SILGenPattern.cpp:2605`, inside `emitBoolDispatch` (`:2538`), over `i1`, with ≤2 cases. (The only other `createSwitchValue` in SILGen is `SILGenThunk.cpp:468`, for a builtin flag.)

Integer literal cases are `ExprPattern`s, so they take the **same linear guard chain** as strings (§6.1).

**UNVERIFIED, and this is the biggest open question in this report:** whether LLVM's SimplifyCFG reliably reforms a 50-arm `icmp eq` + branch chain into an `llvm::SwitchInst` and thence a jump table. LLVM does have this transform, so it plausibly does — but it was **not verified**, and it cannot be without `-emit-ir` on a real toolchain. **Do not assume it.**

**VERIFIED — repo-wide grep for `jump table` / `jumptable` / `JumpTable` in the Swift compiler returns zero hits.** Jump-table formation is entirely LLVM's job; Swift has no density heuristic of its own for this. The `TODO` at `include/swift/IRGen/SwitchBuilder.h:196-198` confirms this was deliberate.

### 6.3 Enum switch DOES produce a jump table

**VERIFIED.** `include/swift/IRGen/SwitchBuilder.h:168-202` computes a discriminant from `NumCases + (Default.getInt() == IsNotUnreachable)`: 1 → `Br`, 2 → `CondBr`, **≥3 → `SwitchSwitchBuilder`**, which emits `CreateSwitch` (`:157-158`). **The only threshold in IRGen is 3.**

No-payload enum tags are **dense from 0, in declaration order** (`lib/IRGen/GenEnum.cpp:1206-1209`; switch at `:994-1021`, `:1009`) — the ideal jump-table shape. `@objc` / C-compatible enums use raw values and may be sparse (`:1312`, `:1316-1332`).

The one genuine Swift-side density heuristic is `lib/IRGen/EnumPayload.cpp:288-334`: if the mask exceeds 2× the pointer bit width it emits a comparison chain (`:305-321`), otherwise `CreateSwitch` (`:328`).

### 6.4 The rule for Assay's macro

**Reduce the key to a dense, 0-based enum (or `Int`) and switch on that.** That is the only path that reaches an `llvm::SwitchInst` through a mechanism verified end-to-end.

Concretely, the generated dispatch should be:
1. Bucket by `utf8.count` — small, dense integer domain.
2. Within a bucket, compare 8-byte words against baked constants (§5.2), producing a **field index**.
3. `switch fieldIndex` where `fieldIndex` is a generated dense enum → real jump table (§6.3).
4. `memcmp` tail for keys longer than 16 bytes.

This replaces N string comparisons with ~2 integer compares and one indirect jump.

---

## 7. Existentials, protocol conformance, and `any`

### 7.1 Dispatch cost ranking

**Ordinal, mechanism-derived. VERIFIED as mechanism; UNVERIFIED as magnitude — no published Swift ns/op numbers exist (§9).**

| Rank | Form | Mechanism | Cite |
|---|---|---|---|
| 0 | concrete, inlined | direct call / nothing | — |
| 1 | `<T: P>` **specialized**; `some P` param (SE-0341, sugar for a generic param); `some P` result when substitutable | clone + `witness_method` → `function_ref`, `@out` SROA'd away | `Generics.cpp:3317-3390` |
| 2 | `final` / effectively-final class | devirtualized to a direct call | `Devirtualize.cpp:145-198` |
| 3 | class vtable | isa load → slot load → indirect call; **blocks inlining** | `Devirtualize.cpp` |
| 4 | `<T: P>` **unspecialized** | **+2 hidden pointer params** (Self metadata + witness table), `@out` sret + stack temp | `GenProto.cpp:4455-4468` |
| 5 | `any P` | #4 **plus** existential open (noinline helper, 2 loads, a branch), 40-byte container copies, `swift_allocBox` on store, **`swift_makeBoxUnique` CoW copy on mutation**; **never devirtualizable** | `GenExistential.cpp:2462-2545`; `Devirtualize.cpp:1238-1254` |
| 6 | `objc_msgSend` | selector + method-cache probe. **Measured** (Mike Ash): 4.9 ns vs 1.1 ns for a C++ virtual call (Core 2); 0.8 vs 0.3 ns (iPhone 5s) | — |

**VERIFIED and important caveat:** SE-0335 `:59` and `docs/OptimizationTips.rst` both state that the dominant cost is **lost optimization opportunity, not the indirect branch itself.** The ranking above is ordinal; the gap between rank 1 and rank 4/5 is mostly "everything downstream stops being optimizable", which is unbounded.

### 7.2 The existential box, exactly

**VERIFIED.** `docs/ABI/TypeLayout.rst:256-281`. Size formula `lib/IRGen/GenExistential.cpp:74-77` = `fixedBufferSize + 8*(numTables+1)`:
- `any P` = **40 bytes / 5 words**
- `Any` = 32 bytes
- `any P & Q` = 48 bytes
- `NumWords_ValueBuffer = 3` (`include/swift/ABI/MetadataValues.h:46`)
- **Class-constrained existentials = 2 words, never boxed** (`TypeLayout.rst:282-297`)

**The inline-vs-boxed rule is `isBitwiseTakable`, not POD.** `include/swift/ABI/ValueWitnessTable.h:153-157`: `isBitwiseTakable && size <= 24 && alignment <= 8`. So `struct { let s: String }` **stores inline** (bitwise-takable, non-POD). `weak` references, > 24 bytes, or over-aligned → **boxed**, via `swift_allocBox` (a refcounted `HeapObject`, `Metadata.cpp:6106-6115`).

IRGen has a free fast path: a fixed type with `FixedPacking::OffsetZero` → a bare bitcast, zero instructions (`GenExistential.cpp:2308-2312`).

**Opening cost:** read is a noinline helper — load metadata → load VWT flags → test the inline bit → branch (`GenExistential.cpp:2462-2515`). **Mutating open calls `emitMakeBoxUniqueCall` → `swift_makeBoxUnique` → a uniqueness check and possibly a full box allocation and copy** (`:2530-2540`). That is the sharp edge: a mutating method on an `any P` can allocate.

### 7.3 `Self` forces indirect return — the load-bearing citation

**VERIFIED.** `lib/SIL/IR/SILFunctionType.cpp:1638-1641` → `isFormallyReturnedIndirectly` (`:1681-1706`). The decisive clause tests the **requirement's** original abstraction pattern: `origType.isTypeParameter() && !isConcreteType() && !requiresClass()`.

Confirmed in `test/SILGen/witnesses.swift:11-13` (`-> @out τ_0_0`) and `:102-112`, which shows the load/apply/store shuffle **even for a trivial 2-word struct**. Class-constrained protocols escape this (`:146-153`).

**So `static func _assay(from:) -> Self` lowers, unspecialized, to `(@inout Reader, @thick Self.Type, wtable) -> @out Self`.** That is the shape Assay must ensure gets specialized away.

**Never put a closure in a protocol requirement.** Polymorphic reabstraction thunks **always heap-allocate a context** (`lib/IRGen/GenFunc.cpp:2399-2401`).

### 7.4 What the macro should generate

**Recommendation: (iv) as substrate, (i)/(ii) as façade.**

The macro emits, **into the user's module**, a concrete non-generic

```swift
nonisolated static func _assay(from: inout AssayReader) throws -> Self
```

with a fully monomorphic straight-line field decode: concrete reader calls, no protocol involved in the body. Then `extension UserType: Assayable {}` so it also satisfies the requirement.

**This sidesteps cross-module specialization entirely for per-field work** — the body is *already concrete* in the client module, so §2.1's visibility problem never arises for the bulk of the work. The protocol carries only the entry point and generic composition (`Array<T>`, `Optional<T>`, nesting), which is where specialization must still fire — hence §2.8's `@inlinable` requirement on Assay's generic entry points and reader primitives.

Verified details behind this recommendation:
- `public func decode<T: Assayable>(...)` and every reader primitive must be **`@inlinable` + `@usableFromInline`** — `trySpecializeApplyOfGeneric`'s visibility gate, `GenericSpecializer.cpp:118-127`.
- **Do not ship with `-enable-library-evolution`** — `lib/AST/TypeSubstitution.cpp:899-950`: `module->isResilient()` → `DontSubstitute` for `some P`; `@inlinable` → `AlwaysSubstitute` regardless. (Moot per §2.2, but the mechanism is worth knowing.)
- **`@_specialize(exported:)` is useless here** — user types are unknown at Assay build time (`Generics.cpp:3091-3160`). And it opts the function out of CMO (§2.3).
- **Option (iii), enum-based closed-world dispatch: reject.** It requires whole-world knowledge a macro cannot have and breaks across modules. (Closed-world enum dispatch *is* correct for the *field* dispatch within one type — §6.4 — just not for the type-level protocol.)
- **`@_transparent` on a witness-satisfying method does not help. VERIFIED.** The witness thunk is *already* `IsTransparent` (`lib/SILGen/SILGenType.cpp:894`), and transparency does not enable devirtualization — that needs a concrete `lookUpFunctionInWitnessTable`. Use `@_transparent` only on leaf reader accessors, post-devirtualization.
- **`@inlinable` on a protocol default implementation: yes, this is the correct lever. VERIFIED.** Caveat (`Devirtualize.cpp:769-772`): `@inlinable` **disables effectively-final class devirtualization** inside that function. **Keep classes out of `@inlinable` code.**
- The reader should be a **`struct` / `~Copyable` passed `inout`**, not a `final class`. `final` buys devirtualization but not ARC elimination (§1.5).

### 7.5 Metatypes and metadata

**VERIFIED.** `T.self` for a known non-generic type is **free** — `Thin` → `getEmptyTypeInfo()` (`lib/IRGen/GenType.cpp:2798-2821`; `IRGenSIL.cpp:3389-3423`). Non-generic fixed-layout metadata is a global address with no call (`lib/IRGen/MetadataRequest.cpp:958-1003`). Lazy accessors are a *naked* non-atomic load plus a null check, marked `isReadNone` for ≤3 arguments so LLVM can CSE them (`GenMeta.cpp:3125-3148`).

**But general `swift_getGenericMetadata` takes the writer lock** (`include/swift/Basic/Concurrent.h:791-795`). Only *prespecialized* metadata is a single atomic load (`Metadata.cpp:773-820`). `type(of:)` on an existential is a **runtime call** to `swift_getDynamicType` (`GenExistential.cpp:2033-2058`).

**Design instruction:** avoid `T.Type` parameters and dynamic metadata lookups on the per-field path. Prefer static generic dispatch that specializes away.

### 7.6 What Foundation's Codable pays — the concrete anti-pattern

**VERIFIED, exactly as suspected.** `stdlib/public/core/Codable.swift:1668-1683`: `KeyedDecodingContainer` is a **struct holding `_KeyedDecodingContainerBase`**, a **non-final class** (`:4460`) with ~45 `fatalError` stubs, subclassed by `_KeyedDecodingContainerBox<Concrete>` (`:4745`).

Per keyed `decode` call: struct method → **vtable call** → override that does `_internalInvariant(K.self == Key.self)` + **`unsafeBitCast(key, to: Key.self)`** (`:4785-4792`) → concrete implementation. Plus **one `swift_allocObject` per container** (`:1682`).

`UnkeyedDecodingContainer` and `SingleValueDecodingContainer` are **plain `any` existentials** (`Codable.swift:218`, `:226`), and swift-foundation's `UnkeyedContainer` (`JSONDecoder.swift:1574-1580`) is far larger than 3 words → **heap-boxed**.

Full per-key chain for `decode(String.self, forKey:)`: vtable call + `unsafeBitCast` + dictionary lookup + **`Mutex` acquire** (`JSONScanner.swift:103`) + String allocation. Per container: an **eager `stringify` of every key whether read or not** (`JSONDecoder.swift:1265-1309`).

**swift-foundation has zero `@inlinable` / `@_specialize` / `@usableFromInline` under `Sources/FoundationEssentials/JSON/`.** It relies on WMO and structurally cannot touch these five ABI-level costs, because they live in the stdlib's `Codable.swift`.

**Measured corroboration** (`/home/claude/research/bench/reerbench/Benchmark/results/`): ReerJSON is **16.8×** faster than Foundation on iOS 16, but only **1.25–2.75×** on iOS 26. The residual is scanner work; **the Codable-ABI costs are Assay's incremental opportunity**, and they are the part a faster scanner alone does not recover.

---

## 8. Threading and concurrency costs

### 8.1 `Sendable` is exactly zero runtime cost

**VERIFIED, hard.** `Sendable` is a `@_marker` protocol (`stdlib/public/core/Sendable.swift:197`).
- `lib/IRGen/GenMeta.cpp:7720-7722` — *"Marker protocols are never emitted"*.
- `lib/IRGen/SILSymbolVisitor.cpp:850` — skips both the protocol descriptor and the witness table.
- **`lib/IRGen/GenMeta.cpp:7963-7966` — *"Marker protocols do not record generic requirements at all"*** → **`<T: Sendable>` has the same calling convention as `<T>`**, with no extra witness-table parameter.

`@unchecked Sendable` is identical. `Sendable` never forces a copy, a box, or a retain.

**So `public protocol Assayable: Sendable` costs nothing at runtime** — and buys a great deal at the API level (§8.4).

### 8.2 Actor isolation

**VERIFIED — a synchronous call within the same isolation domain costs zero instructions.** `lib/SILGen/SILGenConcurrency.cpp:143-158, 265-272` — the executor check is emitted **only** under `-enable-actor-data-race-checks`. So **`@MainActor` on a type whose synchronous methods run in a loop costs nothing at runtime.**

An async hop: `swift_task_switchImpl` (`stdlib/public/Concurrency/Actor.cpp:2543`) — fast path is a TLS read + pointer compare + tail call (`:2571`); slow path is **one CAS** (`:2131-2133`); worst case is a full enqueue.

`swift_task_isCurrentExecutor` is **not** on the synchronous path but is expensive (`Actor.cpp:539-735`) — **keep `assumeIsolated` out of loops.**

### 8.3 Async costs real money — Assay's parse API should be synchronous

**VERIFIED.** Making a function `async` costs, even when it never suspends:
- A task-slab bump allocation (`stdlib/public/Concurrency/TaskAlloc.cpp:54-56`; slab size `1024 - 8 - header`, `TaskPrivate.h:951-957`), which **falls back to `malloc` when the slab is exhausted** (`StackAllocator.h:292-294`).
- Async context save/restore.
- **Dominantly: coroutine-split inlining loss** (`lib/IRGen/GenCall.cpp:5148-5187`).

Evidence: the Swift 5.7 async regression thread (a 9× regression, ~22% residual after the fix), where John McCall attributes the residual to the coroutine split *"blocking LLVM optimization."*

Additionally, `withUnsafeTemporaryAllocation`'s body **cannot be async** (§5.5), which would force Assay to give up stack scratch buffers.

**Design instruction: the parse API is synchronous. Wrap I/O in `async` at a higher layer; never make the parser itself async.**

### 8.4 Swift 6.2 default isolation — the single highest-leverage API decision

**VERIFIED.** SE-0466 `:68` and `lib/Sema/TypeCheckConcurrency.cpp:6255` — types that **directly** conform to a protocol inheriting `SendableMetatype` are **excluded from `-default-isolation MainActor` inference**. This is exactly the `CodingKey` precedent (SE-0466 `:191-206`).

**Therefore: declare `public protocol Assayable: Sendable`.** It costs zero at runtime (§8.1) and it automatically keeps conforming user types out of MainActor isolation even in modules that default to it. Without this, users building with `-default-isolation MainActor` would find their `Assayable` types inferred as `@MainActor`, and Assay's generic entry points would fail to accept them off the main actor.

Two further verified facts:
- The module default applies **only in the main module** (`TypeCheckConcurrency.cpp:5284-5292`), so Assay's own declarations are never affected by a user's setting.
- Macro-expanded extensions **inherit the type's isolation** rather than re-inferring it (`:6282-6287`).

**Belt and braces:** emit `nonisolated` on generated members, emit into an `extension`, and declare the protocol requirement `nonisolated` so that any mismatch surfaces as `note_actor_isolated_witness` (`DiagnosticsSema.def:6209-6211`) rather than a confusing downstream error.

### 8.5 Things that would force an allocation or atomic on the parse path

**VERIFIED:**
- **ARC atomics come from *being a class*, not from `Sendable`.** Use `struct` / `~Copyable` for the reader.
- `Mutex` allocates nothing (inline `_Cell`, `@_transparent` `os_unfair_lock`) — but Foundation's per-buffer-access `Mutex` (§7.6) shows that even an uncontended lock in the hot loop is worth eliminating structurally.
- **Task-local values allocate per push, and call `swift_slowAlloc` (a real `malloc`) when there is no current task** (`stdlib/public/Concurrency/TaskLocal.cpp:262-273`). **Do not use task-locals for parser configuration.**
- `withTaskCancellationHandler` costs 1 slab allocation + 2 CAS per call (`Task.cpp:1797-1806`) — hoist out of loops, never per-element.

**UNVERIFIED:** `OSAllocatedUnfairLock` internals (Darwin SDK, not in the checkout).

---

## 9. Measurement gaps — what nobody has published

This is a genuine and somewhat surprising finding: **the Swift performance literature is almost entirely qualitative.** The following have **no** credible published numbers that were locatable:

1. ARC as a percentage of runtime for any real workload. (A search surfaced an IBM paper *"Dynamic Atomicity: Optimizing Swift Memory Management"* but **the page 404'd — do not cite it.**)
2. Bounds-check cost, in cycles or percent.
3. Exclusivity-check cost. (And every pre-2026 number is invalidated anyway by the Swift rewrite of `swift_beginAccess`, §3.3.)
4. `-Ounchecked` speedup on decoder-like work.
5. Resilience / library-evolution overhead, in percent or ns.
6. One value-witness copy vs a direct copy, in cycles.
7. `any P` vs `some P` vs `<T: P>` vs vtable, in ns/op. WWDC 2016 session 416 and `docs/OptimizationTips.rst` are purely qualitative. The Swift repo commits benchmark *workloads* (`ExistentialPerformance.swift`, `ProtocolDispatch{,2}.swift`) but **no published results**.
8. Sync vs async call overhead as a ratio (only the 5.7 forum thread's before/after).
9. Witness-table indirect call vs direct call overhead.
10. Small-string vs heap-String construction cost.
11. Foundation JSONDecoder throughput vs simdjson / yyjson on comparable hardware.
12. RawSpan vs UnsafeRawBufferPointer for a parsing workload.

**Implication for Assay: it should publish these.** There is a genuine gap in the ecosystem, and a decoder library with a rigorous benchmark suite would be filling it. It also means **Assay cannot borrow anyone else's numbers** — every performance claim in its README must be its own measurement.

The two published numbers that *do* exist and are worth knowing:
- **`@inlinable` gave 92µs → 3µs (~30×)** where CMO flags gave nothing — https://developer.apple.com/forums/thread/750712 .
- **`MutableSpan` cost +75%** vs `UnsafePointer` due to `mark_dependence` blocking closure specialization, since fixed — https://forums.swift.org/t/87385 .

---

## 10. Actionable design conclusions for Assay

Ordered by expected impact.

1. **Never generate `switch` over `String`.** Generate length-bucket → 8-byte word compare → dense enum → `switch`. (§6.1, §6.4, §5.2)
2. **Annotate every hot primitive `@inlinable` (or `@export(implementation)`) + `@usableFromInline`.** This is the mechanism by which Assay recovers what Foundation gets free from WMO. Without it, cross-module calls are unspecialized. (§2.1, §2.7, §2.8)
3. **Generate concrete, monomorphic per-type decode bodies into the user's module**, with the protocol carrying only the entry point. This sidesteps cross-module specialization for the bulk of the work. (§7.4)
4. **Skip the Dictionary/stringify/SipHash layer entirely.** This is Foundation's largest structural cost and the clearest win available. (§5.2, §7.6)
5. **Index with `subscript(unchecked:)` on `Span`/`RawSpan`, or use `UnsafeBufferPointer`'s element subscript.** Checked Span subscripts survive `-O` unless the loop is `isZeroToCount`, which a JSON cursor is not. (§4.3, §4.4, §3.5)
6. **`public protocol Assayable: Sendable`** — zero runtime cost, and it exempts conforming types from `-default-isolation MainActor` inference. (§8.1, §8.4)
7. **Synchronous parse API.** (§8.3)
8. **Reader is a `~Copyable` struct passed `inout`**, never a class, never an existential. (§1.5, §7.4, §3.3)
9. **Keep generated function bodies medium-sized.** Escape analysis budget is `1_000_000 / functionSize`, further divided by 10 for ARC. One giant inlined body defeats it. (§1.2)
10. **Use `@_effects(notEscaping:)` on the reader** rather than hoping escape analysis finds the answer within budget. (§1.7)
11. **SWAR (`UInt64` haszero) as the portable fast path; SIMD behind a vendored-C shim.** A portable pure-Swift movemask does not exist. (§5.6)
12. **Scratch buffers ≤ 1024 bytes**, or `withUnsafeTemporaryAllocation` silently mallocs. (§5.5)
13. **Never require `-Ounchecked`** — it is client-side, whole-module, and a hard error with `-strict-memory-safety`. (§3.2)
14. **Macro expansions must not emit raw unsafe pointer code into user modules** — expand to calls into `@safe`-marked Assay functions, or users on `-strict-memory-safety` get warnings. (§4.8)
15. **Wire `-Rpass-missed=sil-assembly-vision-remark-gen` into CI** as the ARC/allocation regression detector. (§1.8)
16. **Avoid `public var` stored properties on hot types** — exclusivity WMO optimization skips externally-visible storage. (§3.3)
17. **Prefer `String(decoding:as:)` over `String(unsafeUninitializedCapacity:)`** unless the capacity bound is tight. (§5.3)
18. **Use concrete types with `loadUnaligned`**, never the unconstrained generic overload (it is a real memcpy). (§5.4)
19. **Assay's entry points should take `[UInt8]` / `Data` / `UnsafeRawBufferPointer`**, not `Span` — the convenient `.span` accessors need macOS 26. (§4.2)
20. **Prefer a pointer-based reader with a safe façade over a `~Escapable` Span-holding reader**, for now — `@_lifetime` is still underscored, experimental-feature-gated, and has no accepted proposal. (§4.6)

---

## 11. DO NOT ASSERT THESE

Claims that are **unverified, refuted, or stale**. None of these should appear in Assay's documentation, README, design notes, or marketing without first being measured or re-verified with a real toolchain.

**Refuted — do not repeat:**
1. ~~"A parser built on structs, generics and non-escaping closures is ARC-free at -O."~~ Only *transitively trivial* structs are. Any `String`/`Array`/closure/class/existential field breaks it. (§1.5)
2. ~~"Calls retain their arguments."~~ Parameters and `self` are `@guaranteed` (+0) by default. Only *returns* are `@owned`. (§1.3)
3. ~~"`-O` removes all redundant ARC within a module."~~ Refuted by the compiler's own FIXMEs (`PassPipeline.cpp:621-624`, `:812-815`) and the escape-analysis budget. (§1.2)
4. ~~"`switch` over a String compiles to a hash lookup or jump table."~~ It is a linear comparison chain. (§6.1)
5. ~~"`-disable-safety-checks` exists."~~ It does not. (§3.4)
6. ~~"`-stack-alloc-limit` controls `withUnsafeTemporaryAllocation`."~~ Never implemented; the 1024 threshold is hardcoded. (§5.5)
7. ~~"`-enable-ossa-modules` helps ARC."~~ Obsolete; the option is ignored (`FrontendOptions.td:1462`). The forum advice suggesting it is stale. (§3.4)
8. ~~"`-stack-promotion-limit` governs temporary allocations."~~ It governs `alloc_ref [stack]`. Unrelated 1024. (§3.4)
9. ~~"`select_value` / `SelectValueInst`."~~ No longer exists in SIL. (§3.4)
10. ~~"An existential stores inline only if the value is POD."~~ The rule is `isBitwiseTakable && size ≤ 24 && align ≤ 8`. `struct { let s: String }` stores inline. (§7.2)
11. ~~"Small string capacity is 15."~~ On 64-bit yes; 8 on 32/16-bit, 10 on 32-bit watchOS, 14 on Android arm64. (§5.1)
12. ~~"`@_transparent` on a protocol witness enables devirtualization."~~ The witness thunk is already transparent; it does not. (§7.4)
13. ~~"`@_specialize` improves cross-module performance for unknown client types."~~ It cannot name them, and it opts the function out of CMO. (§2.3, §2.5)
14. ~~"Library evolution is destroying Assay's performance."~~ It is off by default and Assay cannot enable it. (§2.2)

**Unverified — plausible but not established:**
15. **Whether LLVM reliably reforms SILGen's linear integer-comparison chain into a jump table.** The single biggest open question here. Needs `-emit-ir`. (§6.2)
16. Whether a simple `cursor &+= 1` loop is recognised as an induction variable for Span bounds-check elimination. Variable-stride cursors certainly are not. (§4.4)
17. Whether `_Builtin_intrinsics.intel` ships in released toolchains. (§5.6)
18. Whether a `SIMDMask._storage` bitcast lowers to `pmovmskb`. (§5.6)
19. Whether `SIMD.init(truncatingIfNeeded:)`'s scalar loop vectorizes. (§5.6)
20. Whether `UnsafeRawBufferPointer.elementsEqual` lowers to `memcmp`. (§5.6)
21. The exhaustive set of conditions blocking on-stack closure promotion, and `ClosureSpecializer`'s firing conditions. (§1.6)
22. Whether `String._tryFromUTF8` (SPI) is usable from a third-party package. (§5.1)
23. Whether SwiftPM/Xcode auto-embeds `libswiftCompatibilitySpan.dylib` for pre-26 deployment targets. (§4.2)
24. Whether Apple SDK frameworks and the stdlib are built with `-enable-library-evolution` (strongly implied, no primary source located). (§2.2)
25. Whether a `.swiftmodule`-only, compiler-version-locked XCFramework is supported. Only verified that `.swiftinterface` requires library evolution (https://forums.swift.org/t/swift-interface-without-library-evolution/31312). (§2.2)
26. Whether a dependency's `swiftSettings` can affect dependents (inferred: no). (§2.3)
27. Whether `@_specialize(exported: true)` works reliably for arbitrary external SwiftPM clients — **no third-party example exists in any surveyed repo.** (§2.5)
28. Whether freestanding macro expansions differ from attached-extension macros under `-default-isolation`. (§8.4)
29. The numeric value of `_swift_MinAllocationAlignment`. (§5.5)
30. `swift_stdlib_isStackAllocationSafe`'s implementation — no definition located in tree. (§5.5)
31. That swift-foundation's `UnkeyedContainer` actually incurs `swift_makeBoxUnique` CoW traffic (layout verified, traffic inferred). (§7.6)
32. Runtime cost of the Swift-rewritten `swift_beginAccess`. (§3.3)
33. `OSAllocatedUnfairLock` internals. (§8.5)

**All twelve measurement gaps in §9** — do not put a number on any of them.

**Methodology caveats:** nothing here was compiled, disassembled, or benchmarked. Line numbers are from `37150b47` (2026-07-25) and will drift. Two subagents contradicted each other on whether `fixed_storage.check_index` is consumed by `BoundsCheckOpts.cpp`; this was resolved by direct reading in favour of "yes, it is real" (§4.4) — but the *conditions* under which it fires are narrow and the practical consequence for a cursor loop remains untested.







