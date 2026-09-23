#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# The mechanical checks: licence headers, tabs, trailing whitespace, final newlines.
#
# WHY THIS EXISTS AND `swift-format` DOES NOT. Apple's packages ship a `.swift-format` and
# lint against it, and that is the convention this repository deliberately does not follow.
# Measured before deciding: `swift-format lint` reports **3,081 warnings** on this tree, and
# 2,648 of them are one disagreement repeated — the formatter wants every wrapped argument
# list one-per-line, and this codebase wraps them compactly:
#
#     public init(maxIssues: Int = 100, maxDepth: Int = 64, maxBytes: Int = 64 << 20,
#                 maxUnionAttempts: Int = 10_000, verboseUnions: Bool = false) {
#
# Adopting the formatter therefore means reformatting essentially every file. That is a real
# option and it would make contributors' format-on-save do the right thing — but this
# codebase's density is deliberate in two places where a reflow makes it worse: the macro
# emitters, whose string templates are laid out to mirror the code they generate line for
# line, and the comment blocks, which are load-bearing prose rather than decoration.
#
# So: no formatter, and this script instead. It checks the things that actually rot when
# several people edit a repository, and it takes about a second. swift-nio's
# `scripts/soundness.sh` is the same idea and the same reasoning.
#
# If you ever DO want to adopt swift-format, the honest path is one commit that reformats
# everything, `.git-blame-ignore-revs` so `git blame` survives it, and this script deleted.
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
