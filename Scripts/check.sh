#!/usr/bin/env bash
# The one command to run before you push.
#
# CONTRIBUTING.md listed eight commands across three sections and no single entry point,
# so "did you run everything" was answered from memory. This runs the gates that are fast
# and deterministic — build, warnings, tests, documented examples, differentials — and
# tells you the two it deliberately does NOT run, because they are slow and because
# running them concurrently with each other measures contention rather than code:
#
#     cd Benchmarks && swift run -c release AssayBench      # ~8 minutes
#     bash Experiments/03-compile-time/gate.sh              # never at the same time
#
# Every step is reported, and the exit code is the count of failures, so a partial pass is
# visible rather than being whatever the last command happened to return.
set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=()
step() {
    local name="$1"; shift
    printf '\n\033[1m── %s\033[0m\n' "$name"
    if "$@"; then
        printf '\033[32m   ok\033[0m  %s\n' "$name"
    else
        printf '\033[31m   FAILED\033[0m  %s\n' "$name"
        FAILED+=("$name")
    fi
}

# Warnings are errors here in spirit: the library builds clean, and a warning in generated
# code is the user's warning, not ours. `touch` forces a real recompile — an incremental
# build reports nothing for files it did not rebuild, so a warnings check that skips this
# is a check that cannot fail.
warnings() {
    find Sources -name '*.swift' -exec touch {} +
    local log
    # On failure print the WHOLE log: the reason is in there, and a caller grepping the
    # script's output for "ok/FAILED" will otherwise see a failure with no cause.
    log=$(swift build --build-tests 2>&1) || { printf '%s\n' "$log"; return 1; }
    # `ld: warning:` is the linker complaining about deployment targets in the toolchain's
    # own dylibs. It is environmental, says nothing about this package, and is not something
    # a contributor can act on — so it must not fail the check that exists for SOURCE
    # warnings. A bare grep for "warning:" catches it.
    local w
    w=$(grep "warning:" <<<"$log" | grep -v "^ld: warning:") || true
    if [ -n "$w" ]; then printf '%s\n' "$w"; return 1; fi
}

step "soundness"                      bash Scripts/soundness.sh
step "format"                         bash -c 'xcrun swift-format lint --strict --recursive --configuration .swift-format Sources Tests Benchmarks/Sources Scripts Package.swift'
step "build (warning-free, forced)"   warnings
step "tests"                          swift test
step "documented examples"            swift Scripts/check-doc-examples.swift
step "benchmarks build"               swift build --package-path Benchmarks
step "differentials + fuzz"           bash -c 'cd Benchmarks && swift run -c release DiffFuzz'

printf '\n'
if [ ${#FAILED[@]} -eq 0 ]; then
    printf '\033[32mall checks passed\033[0m\n'
    printf 'not run here, on purpose — slow, and never concurrently with each other:\n'
    printf '  cd Benchmarks && swift run -c release AssayBench\n'
    printf '  bash Experiments/03-compile-time/gate.sh\n'
    exit 0
fi
printf '\033[31m%d failed:\033[0m %s\n' "${#FAILED[@]}" "${FAILED[*]}"
exit "${#FAILED[@]}"
