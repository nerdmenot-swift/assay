#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# The mechanical checks that `swift-format` does not make: licence headers, tabs, trailing
# whitespace, final newlines, and no `.unsafeFlags` in the manifest.
#
# Formatting itself is `swift-format`'s job — `.swift-format` at the repository root, lint
# gated in CI, and the whole tree was reformatted to it on 2026-09-23. This script is the
# other half, in the shape of swift-nio's `scripts/soundness.sh`: a licence header is not a
# formatting question, and neither is a tab inside a string literal.
#
# ONE FILE IS EXEMPT FROM THE FORMATTER and the reason is recorded where it applies —
# `Sources/AssayMacros/CodeGen.swift` carries `// swift-format-ignore-file` because it nests
# multi-line string literals inside interpolations of other multi-line string literals, and
# reformatting it produced 44 "insufficient indentation" compile errors. A closing delimiter
# decides what Swift strips from a literal, and in that file one line belongs to two literals
# at once. The golden expansions are what keep it honest instead.
#
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { echo "  $*"; }

# 1. Every Swift file carries the licence header. Three lines, identical everywhere, because
#    a file without one is the file someone copies into another project.
missing=$(find Sources Tests -name '*.swift' \
    -exec sh -c 'head -1 "$1" | grep -q "^// Assay — a decoder" || echo "$1"' _ {} \;)
if [ -n "$missing" ]; then
    echo "✗ Swift files without the licence header:"
    echo "$missing" | while read -r f; do note "$f"; done
    fail=$((fail + 1))
else
    echo "✓ licence header on every Swift file"
fi

# 2. Tabs. The indentation is four spaces everywhere; a tab renders differently in every
#    tool that will ever open the file.
tabs=$(grep -rlP '\t' --include='*.swift' Sources Tests 2>/dev/null || true)
if [ -n "$tabs" ]; then
    echo "✗ files containing tabs:"
    echo "$tabs" | while read -r f; do note "$f"; done
    fail=$((fail + 1))
else
    echo "✓ no tabs"
fi

# 3. Trailing whitespace. Invisible, and it makes a diff about nothing.
trailing=$(grep -rlE ' +$' --include='*.swift' Sources Tests 2>/dev/null || true)
if [ -n "$trailing" ]; then
    echo "✗ files with trailing whitespace:"
    echo "$trailing" | while read -r f; do note "$f"; done
    fail=$((fail + 1))
else
    echo "✓ no trailing whitespace"
fi

# 4. A final newline, so `cat` of two files does not glue a line together and every diff
#    ends cleanly.
nofinal=$(find Sources Tests -name '*.swift' \
    -exec sh -c '[ -n "$(tail -c1 "$1")" ] && echo "$1"' _ {} \; || true)
if [ -n "$nofinal" ]; then
    echo "✗ files without a final newline:"
    echo "$nofinal" | while read -r f; do note "$f"; done
    fail=$((fail + 1))
else
    echo "✓ every file ends with a newline"
fi

# 5. `.unsafeFlags` — CLAUDE.md hard constraint #10, and it silently makes the package
#    unusable as a versioned dependency for reasons that took a while to pin down.
# Comment lines are stripped first: the manifest's own header says "no `.unsafeFlags`
# anywhere, ever", and matching that sentence is how this check failed on its first run.
if grep -vE '^[[:space:]]*//' Package.swift | grep -q 'unsafeFlags('; then
    echo "✗ Package.swift contains .unsafeFlags (CLAUDE.md constraint 10)"
    fail=$((fail + 1))
else
    echo "✓ no .unsafeFlags in the manifest"
fi

echo
if [ "$fail" -gt 0 ]; then
    echo "$fail soundness check(s) failed"
    exit 1
fi
echo "soundness: all checks passed"
