#!/bin/bash
# Experiment #1c — at what field count does LLVM stop forming a jump table?
#
# 1b proved a 50-arm dense switch over UInt8 becomes a real arm64 jump table.
# Real structs have 5–30 fields. This sweeps N to find the threshold, because if
# the answer is "N >= 16" then the macro needs a different strategy for small types.
set -euo pipefail
cd "$(dirname "$0")"

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
  swiftc -O -S /tmp/sweep_gen.swift -o /tmp/sweep_gen.s 2>/dev/null

  # Slice each function's asm and look for an indirect branch (jump table) vs cmp chain.
  u8=$(awk '/^_.*3du8yys5UInt8V_SiztF:/,/Begin function|\.cfi_endproc/' /tmp/sweep_gen.s)
  en=$(awk '/^_.*3denyyAA1FO_SiztF:/,/Begin function|\.cfi_endproc/' /tmp/sweep_gen.s)

  u8j=$(echo "$u8" | grep -cE '^\s+br\s+x' || true)
  u8c=$(echo "$u8" | grep -cE '^\s+(cmp|subs)\s' || true)
  enj=$(echo "$en" | grep -cE '^\s+br\s+x' || true)
  enc=$(echo "$en" | grep -cE '^\s+(cmp|subs)\s' || true)

  printf "%-5s %-10s %-10s %-12s %-10s\n" "$N" "$u8j" "$u8c" "$enj" "$enc"
done
