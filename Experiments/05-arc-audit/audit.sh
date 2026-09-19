#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# Static ARC audit. Builds the profiling matrix in release with the optimiser's
# assembly-vision remarks recorded, summarises the retain/release/allocation SITES left in
# every function of AssayCore, Assay and AssayMatrix (whose generated `_assay` bodies are
# the code that matters), and compares them against the golden. See arcsum.py.
#
#   audit.sh                 # compare against golden-<os>/
#   audit.sh --update        # rewrite golden-<os>/
#   OUT=dir audit.sh --summarise-only
#
# The golden is per OS and per pinned toolchain, not per architecture: the remark pass is
# SIL-level and runs before LLVM, so two 64-bit targets built by one compiler should agree.
# The Linux golden is the gate (CI runs it in the swift:6.3.3 container); on a Mac, run it
# through Benchmarks/count.sh's container rather than trusting whatever Xcode is installed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
case "$(uname -s)" in Linux) OSNAME=linux ;; Darwin) OSNAME=darwin ;; *) OSNAME=other ;; esac
GOLDEN="$HERE/golden-$OSNAME"
WORK="${WORK:-${TMPDIR:-/tmp}/assay-arc-audit}"
OUT="${OUT:-$WORK/summary}"
# Created before the build writes its log into it: CI's first run failed here, because every
# local run had pointed WORK at a directory that already existed.
mkdir -p "$WORK"
# Always re-expand the macros: an incremental build can keep AssayMatrix's generated code
# from before an AssayMacros change (see Benchmarks/count.sh). Touch, never delete: deleting
# the module's build directory broke SwiftPM's cached build plan.
touch "$ROOT"/Benchmarks/Sources/AssayMatrix/*.swift

( cd "$ROOT/Benchmarks" && swift build -c release --product AssayMatrix \
    -j "${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}" --scratch-path "$WORK/build" \
    -Xswiftc -save-optimization-record=yaml \
    -Xswiftc -save-optimization-record-passes -Xswiftc sil-assembly-vision-remark-gen \
    > "$WORK/build.log" 2>&1 ) || { grep -E 'error' "$WORK/build.log" | head -20; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
for module in AssayCore Assay AssayMatrix; do
  rec=$(find "$WORK/build" -path "*/release/$module.build/$module.opt.yaml" | head -1)
  [ -n "$rec" ] || { echo "no optimisation record for $module"; exit 1; }
  python3 "$HERE/arcsum.py" summarise "$rec" > "$OUT/$module.tsv"
done

case "${1:-}" in
  --update) rm -rf "$GOLDEN"; cp -R "$OUT" "$GOLDEN"; echo "golden-$OSNAME updated" ;;
  --summarise-only) echo "summary in $OUT" ;;
  *) python3 "$HERE/arcsum.py" compare "$GOLDEN" "$OUT" ${STRICT:+--strict} ;;
esac
