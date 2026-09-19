#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# Exact counts on a Mac: run `count.py` in a Linux container, because Valgrind has no port
# for current macOS. See count.py's header for what is counted and why.
#
#   Benchmarks/count.sh                          # count every cell, compare to the baseline
#   Benchmarks/count.sh --save                   # ...and overwrite the baseline
#   Benchmarks/count.sh explain --cell base/struct --fn bridge_release
#   Benchmarks/count.sh scale [--axes elements,depth]   # the linearity gate
#
# The container is aarch64 under Colima/Docker Desktop, so this produces the AARCH64
# baseline. x86-64 comes from CI (.github/workflows/efficiency.yml), which uploads its
# counts as an artifact; there is no x86-64 hardware here and emulation would count the
# emulator's instructions, not Assay's.
#
# The build output lives in a named volume, so the second run does not rebuild the world.
# `-j 1` because the default parallelism OOMs a 4 GiB VM optimising AssayCore (see
# linux-bench.sh), and SwiftPM reports that as `signal 9` with no mention of memory.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
IMAGE=assay-valgrind:6.3.3
docker build -q -t "$IMAGE" -f Benchmarks/valgrind.Dockerfile Benchmarks >/dev/null

MODE=compare
case "${1:-}" in
  --save) MODE=save; shift ;;
  explain) MODE=explain; shift ;;
  scale) MODE=scale; shift ;;
esac

SUBSET=""
case " $* " in *" --cells "*) SUBSET=--subset ;; esac

# The mount point is /assay because the directory name IS the package name.
docker run --rm -v "$ROOT:/assay" -v assay-count-build:/build -w /assay/Benchmarks "$IMAGE" \
  bash -lc "
set -euo pipefail
# ALWAYS re-expand the macros. An incremental SwiftPM build does not reliably re-run macro
# expansion in a dependent module when the macro IMPLEMENTATION changes, so after an edit to
# AssayMacros this measured the old generated code: found 2026-09-19, when a CodeGen change
# counted identically to the version before it. Rebuilding AssayMatrix alone is cheap.
rm -rf /build/release/AssayMatrix.build /build/release/AssayMatrix
# A failed build must stop here: filtering its output through grep once hid one.
swift build -c release --product AssayMatrix -j \${JOBS:-1} --scratch-path /build > /tmp/build.log 2>&1 \
  || { grep -E 'error' /tmp/build.log | head -20; exit 1; }
B=/build/release/AssayMatrix
ARCH=\$(uname -m)
case $MODE in
  explain) python3 count.py explain --binary \$B $* ;;
  scale)   python3 count.py scale --binary \$B --jobs 2 $* ;;
  save)    python3 count.py run --binary \$B --out counts-baseline.\$ARCH.json --jobs 2 $* ;;
  compare) python3 count.py run --binary \$B --out /tmp/counts.json --jobs 2 $*
           python3 count.py compare --baseline counts-baseline.\$ARCH.json --current /tmp/counts.json $SUBSET ;;
esac
"
