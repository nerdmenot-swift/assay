#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# Experiment #1c — at what field count does LLVM stop forming a jump table?
#
# 1b proved a 50-arm dense switch over UInt8 becomes a real jump table. Real structs have
# 5–30 fields. This sweeps N to find the threshold, because if the answer is "N >= 16" then
# the macro needs a different strategy for small types.
#
# PORTABLE ACROSS ARCHITECTURES, and that is the whole point of the 2026-08 revision. The
# original hard-coded arm64 mnemonics (`br x`) and Mach-O symbol names (a leading
# underscore), so it could only ever confirm the finding on the machine it was written on —
# and `CLAUDE.md` has carried "verified on arm64 only; re-run on x86-64 before claiming it
# there" ever since. A claim about *code generation* that has only been checked on one
# target is exactly the kind this repository is supposed to refuse.
#
# What differs per target, and nothing else does:
#
#   symbol prefix   Mach-O decorates with a leading `_`; ELF does not.
#   indirect branch arm64 `br x<n>`; x86-64 `jmp *%r..` (or `jmpq *`).
#   compare         arm64 `cmp` / `subs`; x86-64 `cmp` / `cmpl` / `cmpq`.
set -euo pipefail
cd "$(dirname "$0")"

# `TARGET=x86_64-apple-macosx13.0 ./sweep.sh` cross-EMITS assembly for another
# architecture. Nothing is executed, so no SDK, emulator or second machine is needed — and
# code generation is exactly the kind of question that can be answered without running
# anything. This is how the x86-64 column was first checked from an arm64 Mac, before any
# x86-64 runner existed.
TARGET="${TARGET:-}"
if [ -n "$TARGET" ]; then
  ARCH="${TARGET%%-*}"
  case "$TARGET" in
    *apple*) SYM_PREFIX="_" ;;
    *)       SYM_PREFIX=""  ;;
  esac
  echo "CROSS-EMITTING for $TARGET (assembly only; nothing is run)"
else
  ARCH="$(uname -m)"
  case "$(uname -s)" in
    Darwin) SYM_PREFIX="_" ;;
    *)      SYM_PREFIX=""  ;;
  esac
fi

case "$ARCH" in
  arm64|aarch64)
    JMP_RE='^[[:space:]]+br[[:space:]]+x'
    CMP_RE='^[[:space:]]+(cmp|subs)[[:space:]]'
    ;;
  x86_64|amd64)
    # An LLVM jump table on x86-64 is an indirect jump through a register or a
    # `.LJTI`-relative computation. `jmp *%rax`, `jmpq *%rax`, and the PIC form
    # `jmpq *(%rcx,%rax,8)` all match.
    JMP_RE='^[[:space:]]+jmpq?[[:space:]]+\*'
    CMP_RE='^[[:space:]]+cmp[a-z]?[[:space:]]'
    ;;
  *)
    echo "unknown architecture '$ARCH' — add its mnemonics before trusting this" >&2
    exit 2
    ;;
esac

echo "arch: $ARCH   os: $(uname -s)   swift: $(swiftc --version 2>&1 | head -1)"
echo ""
printf "%-5s %-10s %-10s %-12s %-10s\n" "N" "u8:jmptbl" "u8:cmps" "enum:jmptbl" "enum:cmps"
for N in 2 3 4 5 6 8 10 12 16 20 24 30 40 50; do
  # Generate N-arm dispatch, both over UInt8 and over a dense enum.
  {
    for ((i = 0; i < N; i++)); do
      k=$(awk -v i="$i" 'BEGIN{ printf "%d", (i * 2654435761) % 1000003 }')
      echo "@inline(never) func s${i}(_ a: inout Int) { a = a &* 31 &+ ${k} }"
    done
    echo "@inline(never) func sD(_ a: inout Int) { a = a &* 31 &+ 7 }"
    echo "public enum F: UInt8 {"
    for ((i = 0; i < N; i++)); do echo "  case f${i}"; done
    echo "  case unknown"
    echo "}"
    echo "@inline(never) public func du8(_ i: UInt8, _ acc: inout Int) {"
    echo "  switch i {"
    for ((i = 0; i < N; i++)); do echo "  case ${i}: s${i}(&acc)"; done
    echo "  default: sD(&acc)"
    echo "  }"
    echo "}"
    echo "@inline(never) public func den(_ f: F, _ acc: inout Int) {"
    echo "  switch f {"
    for ((i = 0; i < N; i++)); do echo "  case .f${i}: s${i}(&acc)"; done
    echo "  case .unknown: sD(&acc)"
    echo "  }"
    echo "}"
  } > /tmp/sweep_gen.swift
  # Branching beats expanding a possibly-empty array: bash 3.2, which is what macOS
  # ships, treats `"${EMPTY[@]}"` as an unbound variable under `set -u`.
  if [ -n "$TARGET" ]; then
    swiftc -O -S -target "$TARGET" /tmp/sweep_gen.swift -o /tmp/sweep_gen.s 2>/dev/null
  else
    swiftc -O -S /tmp/sweep_gen.swift -o /tmp/sweep_gen.s 2>/dev/null
  fi

  # Slice each function's asm and look for an indirect branch (jump table) vs cmp chain.
  # The mangled suffixes are stable across targets; only the leading decoration differs.
  u8=$(awk "/^${SYM_PREFIX}.*3du8yys5UInt8V_SiztF:/,/Begin function|\.cfi_endproc|\.size/" \
       /tmp/sweep_gen.s)
  en=$(awk "/^${SYM_PREFIX}.*3denyyAA1FO_SiztF:/,/Begin function|\.cfi_endproc|\.size/" \
       /tmp/sweep_gen.s)

  if [ -z "$u8" ] || [ -z "$en" ]; then
    echo "could not locate the generated symbols in the assembly — the mangling or the" >&2
    echo "section markers differ on this target, and a zero here would be a lie." >&2
    exit 3
  fi

  u8j=$(echo "$u8" | grep -cE "$JMP_RE" || true)
  u8c=$(echo "$u8" | grep -cE "$CMP_RE" || true)
  enj=$(echo "$en" | grep -cE "$JMP_RE" || true)
  enc=$(echo "$en" | grep -cE "$CMP_RE" || true)

  printf "%-5s %-10s %-10s %-12s %-10s\n" "$N" "$u8j" "$u8c" "$enj" "$enc"
done
