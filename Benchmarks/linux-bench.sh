#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# Run the benchmark suite on Linux, in a container, with the same toolchain as the host.
#
# WHY THIS EXISTS. Every published ratio was one arm64 Mac for the whole life of the project,
# and the caveat was written on each of them — but a caveat is not a measurement. Running the
# suite on a second platform is what turned "we do not know" into a result, and one of the
# ratios INVERTED: XML goes from 1.30x over Foundation on Darwin to 0.54x on Linux, because
# `FoundationXML` is libxml2 there and the Darwin implementation is not. See RESULTS.md.
#
# WHAT THIS DOES NOT DO: x86-64. There is no x86-64 hardware here, and emulation would time
# the emulator. `Experiments/01-jump-table` is still arm64-only and says so.
#
# The container is aarch64 under Apple's Virtualization.framework, so ABSOLUTE timings from
# it are meaningless — 2 vCPU on a virtualised box is not a deployment target. The ratios are
# what transfer: the baseline runs on the same machine under the same conditions, so a slow
# host slows both sides equally.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

IMAGE="${SWIFT_IMAGE:-swift:6.3-noble}"
# `-j 1` is not caution. The default parallelism OOMs a 4 GiB VM while optimising AssayCore,
# and SwiftPM reports that as `signal 9` with no mention of memory.
JOBS="${JOBS:-1}"

echo "image:  $IMAGE"
echo "mount:  $ROOT -> /assay   (the directory name IS the package name; mounting it"
echo "        anywhere else renames the package and every dependency fails to resolve)"
echo ""

docker run --rm -v "$ROOT:/assay" -w /assay/Benchmarks "$IMAGE" bash -lc "
set -e
echo '--- toolchain ---'
swift --version
uname -m
echo ''
# The scratch path is inside the container so the host's .build (Mach-O) is untouched.
swift build -c release --product AssayBench -j $JOBS --scratch-path /tmp/lbuild 2>&1 \
  | grep -E 'error|Build of product' || true
/tmp/lbuild/release/AssayBench
"
