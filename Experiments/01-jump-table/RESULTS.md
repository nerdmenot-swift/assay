# Experiment #1 — does field dispatch lower to a jump table?

**Status: ANSWERED — YES. The design assumption in `PERFORMANCE.md` §4 holds.**

- Toolchain: Apple Swift 6.3.3 (swift-6.3.3-RELEASE), target `arm64-apple-macosx26.0`
- Host: macOS 26.5.2, Apple silicon (18 logical cores)
- Flags: `swiftc -O -emit-ir` / `swiftc -O -S`. No `-Ounchecked`, no `.unsafeFlags`.
- Date: 2026-07-26

## The question

`PERFORMANCE.md` §15.1 called this "the highest-stakes assumption in the document":

> Write a 50-arm switch over a `UInt8` candidate index, dump IR, and look for a genuine
> `llvm::SwitchInst` rather than a comparison chain. §4 assumes a table; §8's finding that
> Swift lowers integer-literal patterns to comparison chains says it may not.

## Answer

**LLVM reforms SILGen's output into a jump table (N ≥ 10) or a balanced binary search
tree (N < 10). It is never a linear scan.** The §8 finding is true *at SILGen* and
immaterial *after LLVM*.

### N = 50, divergent code per arm — a real arm64 jump table

```asm
and  w8, w0, #0xff
cmp  w8, #49
b.hi LBB60_52              ; range check -> default
adrp x9, LJTI60_0@PAGE     ; LJTI = LLVM Jump Table Index
add  x9, x9, LJTI60_0@PAGEOFF
adr  x10, LBB60_2
ldrb w11, [x9, x8]         ; one byte-load from the table
add  x10, x10, x11, lsl #2
br   x10                   ; indirect branch
```

The enum variant emits the identical sequence **minus the `cmp`/`b.hi`**, because an
exhaustive enum switch needs no range check.

### The threshold sweep

`br x` = jump table formed; `cmp` = comparisons on the dispatch path.

| N | u8 jmptbl | u8 cmps | enum jmptbl | enum cmps |
|---|---|---|---|---|
| 2 | 0 | 1 | 0 | 1 |
| 3 | 0 | 2 | 0 | 2 |
| 4 | 0 | 4 | 0 | 3 |
| 5 | 0 | 5 | 0 | 4 |
| 6 | 0 | 6 | 0 | 5 |
| 8 | 0 | 10 | 0 | 7 |
| **10** | **1** | **1** | **1** | **0** |
| 12–50 | 1 | 1 | 1 | 0 |

**Threshold: N ≥ 10 → jump table.** Below it, LLVM emits a *balanced binary search
tree*, verified at N=6:

```asm
cmp w8, #2 ; b.le  ->  cmp w8, #4 ; b.gt  ->  cmp w8, #3 ; b.ne
```

~⌈log₂N⌉ well-predicted compares, not O(N). Both regimes are appropriate at their size;
LLVM's heuristic is making the right call, not failing.

## Consequences for the macro

1. **The window-dispatch design in §4.2 is sound.** A `UInt8` candidate index from a
   256-entry window table, switched on, reaches a jump table for types with ≥10 fields.
2. **Map the candidate index to a dense enum anyway.** It is a real but *small* win, and
   not the one §6.4 of `perf-swift-codegen.md` predicted. It does not change linear→table;
   it removes the range check (N≥10) or one comparison level (N<10). Free, so take it.
3. **Do not special-case small structs.** A 4-field struct getting 3 predicted compares is
   fine and probably beats an indirect branch.
4. **§4.1's warning still stands for `String`.** Nothing here tests string switching;
   `_findStringSwitchCase` remains a linear scan and the macro must never emit one.

## Caveat

Verified on arm64 only. x86-64 SimplifyCFG uses the same `SwitchToLookupTable` /
jump-table machinery and the threshold is target-independent in LLVM's source, but the
sweep has not been re-run there. Re-run `sweep.sh` on x86-64 before claiming it.

## Reproduce

```sh
./gen.sh const && swiftc -O -emit-ir switches.swift      -o switches.ll   # 1a: constant arms
./gen.sh code   && swiftc -O -S      switches_code.swift  -o switches_code.s # 1b: divergent code
./sweep.sh                                                                     # 1c: threshold
```

**Note on 1a:** the first attempt used `acc += 1000 + i` case bodies. Those are affine in
the index, so SimplifyCFG folded the entire switch into arithmetic (`switch.offset`) and
erased the dispatch. Case bodies must be non-affine for this experiment to mean anything —
worth knowing before anyone re-runs it.
