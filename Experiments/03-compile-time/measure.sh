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

time_build() {
  local mode="$1" n="$2"
  ./gen_types.sh "$n" "$FIELDS" "$mode" > "$WORK/Sources/M/Types.swift"
  # bash's `time` with TIMEFORMAT gives real seconds to 3dp with no external tooling.
  local TIMEFORMAT='%R'
  { time ( cd "$WORK" && swift build -c "$CONFIG" >/dev/null 2>&1 ) ; } 2>&1 \
    | awk '{ printf "%.2f", $1 }' 
}

echo "Compile-time cost of @Schema"
swift --version 2>&1 | head -1
echo "fields per type: $FIELDS   config: $CONFIG   deps prebuilt: yes"
echo ""
printf "%-8s %10s %10s %10s %11s %12s %12s\n" \
  "types" "plain" "codable" "schema" "validated" "vs-plain" "vs-codable"
printf -- '-%.0s' $(seq 1 80); echo

# `validated` is the same types with a @Validate on every field — the worst case for the
# generated `_assayCheck` body. It is reported beside the gated arm rather than instead of
# it: a type with no rules gets no validator at all, so `schema` is what a JSON user pays
# and `validated` is what a rule-carrying type costs on top.
for n in 1 10 25 50 100; do
  p=$(time_build plain "$n")
  c=$(time_build codable "$n")
  s=$(time_build schema "$n")
  v=$(time_build validated "$n")
  vp=$(awk -v a="$s" -v b="$p" 'BEGIN{ printf "%.2fx", a/b }')
  vc=$(awk -v a="$s" -v b="$c" 'BEGIN{ printf "%.2fx", a/b }')
  printf "%-8s %10s %10s %10s %11s %12s %12s\n" "$n" "$p" "$c" "$s" "$v" "$vp" "$vc"
done
