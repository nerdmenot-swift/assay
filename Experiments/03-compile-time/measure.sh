#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# Compile-time cost of @Schema, measured rather than assumed.
#
# Why this is a gate and not a footnote: docs/EXPERIENCE.md §13 already names the risk —
# published field reports of a 30-second build going to 5 minutes, a 44-second build
# going to 338 seconds, and one report of a macro that did nothing at all doubling release
# build times. Every expansion is a round trip to a separate plugin process.
#
# For Assay the exposure is structural, because the macro IS the product: a user adopting
# Assay replaces `: Codable` with `@Schema` across their whole model layer in one commit,
# so whatever the per-expansion cost is, they pay all of it at once.
#
# Three arms, semantically equivalent, N types each:
#   plain    — struct, no conformance   (the floor: pure type-checking + codegen)
#   codable  — struct + Codable         (what they are replacing)
#   schema   — struct + @Schema         (what Assay costs)
#
# METHOD NOTE. The dependency graph (swift-syntax, Assay) is built ONCE up front and
# reused. An earlier version of this script rm -rf'd the whole work package per data
# point, which rebuilt swift-syntax fifteen times and measured almost nothing else.
# Only the module under test is recompiled per measurement.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
WORK="${TMPDIR:-/tmp}/assay-ct"
FIELDS=${FIELDS:-10}
CONFIG=${CONFIG:-debug}
REPEATS=${REPEATS:-3}

rm -rf "$WORK"
mkdir -p "$WORK/Sources/M"
cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "M",
  platforms: [.macOS(.v11)],
  dependencies: [.package(path: "$ROOT")],
  targets: [.target(name: "M", dependencies: [.product(name: "Assay", package: "assay")])]
)
EOF

# Build the dependency graph once. Everything after this times only module M.
./gen_types.sh 1 "$FIELDS" schema > "$WORK/Sources/M/Types.swift"
( cd "$WORK" && swift build -c "$CONFIG" >/dev/null 2>&1 )

# TWO STATISTICS, and picking the wrong one for the wrong job failed the gate in CI.
#
# The MINIMUM is right for an absolute cost: build time is a floor plus contention, noise
# only ever adds, so the minimum is the least-contaminated estimate of what the work costs.
# That is what the per-type budgets are compared against.
#
# The minimum is WRONG for a RATIO. `schema / codable` divides two independently-noisy
# minima, and taking the minimum of the DENOMINATOR maximises the quotient -- so a single
# spuriously-fast `codable` sample inflates the ratio in one direction only. On a hosted
# runner that produced codable timings that were non-monotonic in the number of types
# (1.05 s at 25, 0.93 s at 50 -- fifty cannot compile faster than twenty-five) and pushed
# the gated ratio to 6.11x against a 6.0 budget, on code that measures 3.36x locally.
#
# So the ratio uses the MEDIAN of both arms, which has no such bias, and the absolute
# budgets keep the minimum. Both are emitted; `gate.sh` picks.
#
# MINIMUM of REPEATS builds, not a single one.
#
# The minimum is the right statistic and not merely a nicer one: build time is a floor plus
# contention, so noise only ever ADDS. A single sample is that floor plus whatever else the
# machine happened to be doing, which is why this gate produced two false failures in one
# afternoon -- 177.8 ms and 147.0 ms against a 145 ms budget, on a tree that measures
# 130-137 ms when the machine is quiet. A gate that cries wolf is one people learn to click
# past, and this one guards the number docs/COMPILE-TIME.md says the adoption decision
# turns on. The runtime benchmarks already report minimum-of-5; this was the odd one out.
#
# It also buys ACCURACY, not just calm. The previous budgets were widened to cover
# single-shot spread -- the comment in gate.sh said so outright -- which made the gate both
# flaky and less sensitive. Sampling properly lets them come back down.
#
# THE TRAP, which is why the loop is not just `for i; do time swift build; done`: SwiftPM is
# incremental. Repeats over byte-identical sources are no-ops of ~0.1 s, and a minimum over
# those would report a build time near zero and pass every budget forever -- silent, and in
# the direction that hides regressions. The marker comment makes each repeat's source
# genuinely different, so every one is a real compile of module M. Run with SHOW_SAMPLES=1
# to see the individual timings and confirm that is still true.
time_build() {
  local mode="$1" n="$2" i t samples=""
  # bash's `time` with TIMEFORMAT gives real seconds to 3dp with no external tooling.
  local TIMEFORMAT='%R'
  for i in $(seq 1 "$REPEATS"); do
    ./gen_types.sh "$n" "$FIELDS" "$mode" > "$WORK/Sources/M/Types.swift"
    echo "// repeat $i" >> "$WORK/Sources/M/Types.swift"
    # THE SECOND TRAP, and it fired in CI before it was caught here. `swift build` was run
    # with its output discarded AND its exit status ignored, so a build that FAILED measured
    # as very fast and was reported as a timing. On a hosted runner the codable arm at 50
    # types came out at 0.52 s -- less than 50 empty structs -- which pushed the gated
    # schema/codable ratio to 9.44x and failed the only check CI enforces. A harness that
    # reports a failure as a good number is worse than one that reports nothing.
    t=$( { time ( cd "$WORK" && swift build -c "$CONFIG" > "$WORK/build.log" 2>&1 ) ; } 2>&1 )
    if [ $? -ne 0 ]; then
      echo "measure.sh: BUILD FAILED — mode=$mode types=$n repeat=$i" >&2
      echo "--- last 20 lines of $WORK/build.log ---" >&2
      tail -20 "$WORK/build.log" >&2
      exit 2
    fi
    samples="$samples $t"
    [ -n "${SHOW_SAMPLES:-}" ] && echo "    $mode n=$n repeat $i: $t" >&2
  done
  # Emits "min median". Callers pick, and which one they pick matters -- see below.
  echo "$samples" | tr ' ' '\n' | grep -v '^$' | sort -n | awk '{ v[NR]=$1 }
    END { printf "%.2f %.2f", v[1], v[int((NR+1)/2)] }'
}

echo "Compile-time cost of @Schema"
swift --version 2>&1 | head -1
echo "fields per type: $FIELDS   config: $CONFIG   deps prebuilt: yes   min of: $REPEATS"
echo ""
printf "%-8s %10s %10s %10s %11s %10s %8s %11s %12s\n" \
  "types" "plain" "codable" "schema" "validated" "arrays" "paths" "vs-plain" "vs-codable"
printf -- '-%.0s' $(seq 1 101); echo

# `validated` is the same types with a @Validate on every field — the worst case for the
# generated `_assayCheck` body. It is reported beside the gated arm rather than instead of
# it: a type with no rules gets no validator at all, so `schema` is what a JSON user pays
# and `validated` is what a rule-carrying type costs on top.
medians=""
for n in 1 10 25 50 100; do
  read -r p_min p_med <<< "$(time_build plain "$n")"
  read -r c_min c_med <<< "$(time_build codable "$n")"
  read -r s_min s_med <<< "$(time_build schema "$n")"
  read -r v_min v_med <<< "$(time_build validated "$n")"
  read -r a_min a_med <<< "$(time_build arrays "$n")"
  read -r k_min k_med <<< "$(time_build paths "$n")"
  # The printed table is minima -- the absolute costs, which is what it has always shown.
  # The ratios beside it are MEDIANS, because a quotient of two minima is biased; see the
  # header. They will differ slightly from dividing the printed columns, and that is the
  # point rather than an inconsistency.
  vp=$(awk -v a="$s_med" -v b="$p_med" 'BEGIN{ printf "%.2fx", a/b }')
  vc=$(awk -v a="$s_med" -v b="$c_med" 'BEGIN{ printf "%.2fx", a/b }')
  printf "%-8s %10s %10s %10s %11s %10s %8s %11s %12s\n" \
    "$n" "$p_min" "$c_min" "$s_min" "$v_min" "$a_min" "$k_min" "$vp" "$vc"
  medians="$medians
MEDIANS $n $p_med $c_med $s_med $v_med $a_med $k_med"
done

# Machine-readable, for gate.sh, and after the table so it stays a table. The minima above
# are the absolute costs; these are what the ratio is computed from.
echo "$medians"
