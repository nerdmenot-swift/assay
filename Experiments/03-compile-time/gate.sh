#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# CI gate: fail if per-type @Schema expansion cost regresses past the budget.
#
# Modelled on swift-nio's approach to the allocation gate — an ABSOLUTE threshold with an
# exact expected value, re-baselined only in a reviewed commit, rather than a percentage
# drift against a noisy stored baseline.
#
# Wall clock is normally the wrong thing to gate on, and docs/PERFORMANCE.md §12.4 says so
# for the *runtime* benchmarks. Compile time is the exception: the quantity users care
# about IS wall clock, there is no allocation-count proxy for it, and the signal here is
# large (a regression that matters is tens of percent, not single digits).
#
# EVERY NUMBER BELOW IS A MINIMUM OF `REPEATS` BUILDS (default 3), not a single one. It was
# a single one until 2026-08-30, and the gate flaked accordingly: two false failures in one
# afternoon, 177.8 ms and 147.0 ms against a 145 ms budget, on a tree that measures 120-129
# when the machine is quiet. Build time is a floor plus contention, so noise only ever
# ADDS and the minimum is the least-contaminated sample -- the same reason the runtime
# benchmarks have always reported minimum-of-5. Measured spread on the arm that flaked went
# from ~36% to ~8%; the ratio below is now stable to under 1%.
#
# The budgets did NOT move as a result. Sampling properly lowered the central values by
# ~10 ms and they were already inside their budgets, so the change buys sensitivity and
# calm rather than headroom. What changed is that each budget's stated basis is now the
# measurement it is actually compared against.
set -euo pipefail
cd "$(dirname "$0")"

# Per type at 10 fields. See docs/COMPILE-TIME.md §2.
#
# Held at 100 ms. The multi-format decode body briefly pushed this to 118 ms and the
# budget was raised to 140; making formats OPT-IN (@Schema(formats:), default .json)
# brought the default back to ~82 ms, so the original budget stands.
#
# Min-of-3 measures 80.0 / 83.6 / 85.0 over three consecutive runs, so 100 carries ~18%
# headroom over the worst of them. This arm was never the one that flaked.
#
# This gate deliberately measures the DEFAULT configuration, because that is what a JSON
# user pays. A type opting into `.all` costs ~118 ms, which is a cost that type asked for.
BUDGET_MS=${BUDGET_MS:-100}
TYPES=${TYPES:-50}
FIELDS=${FIELDS:-10}

# A SECOND budget, for a type that carries rules on nearly every field.
#
# `_assayCheck` (docs/VALIDATE.md) is emitted only for a type that declares a @Validate or
# a @Check, so the arm above — a rule-free type — is unaffected by it and stays the number
# a plain JSON user pays. This one is what a heavily-validated type costs, measured
# best-of-three at 100 types: 87 ms/type rule-free, 90 ms with rules and no validator body,
# 114 ms with it. The 24 ms difference is the per-field cost paid once more over the same
# fields, which is exactly what the 7.3 ms/field model in docs/COMPILE-TIME.md §2 predicts;
# there is no fat in it to remove, so it is gated rather than optimised away.
#
# Held at 145. This is the arm that flaked, and the reason it did was the measurement, not
# the budget: a single build landed anywhere from 131 to 178 ms depending on what else the
# machine was doing. Min-of-3 measures 119.8 / 124.6 / 129.4 over three consecutive runs,
# so 145 carries ~12% headroom over the worst of them — the same margin the primary budget
# above now carries, arrived at honestly instead of by padding for noise.
#
# Not tightened to ~135 even though the numbers would allow it. This gate exists to catch a
# regression of tens of percent — a per-field line that should have been an @inlinable
# runtime call — and a budget sitting 5% above the measurement buys no extra detection of
# that while making a slower machine or a new toolchain look like a code regression.
VALIDATED_BUDGET_MS=${VALIDATED_BUDGET_MS:-145}

# THE RATIO, which is what CI can actually check.
#
# Everything above is absolute wall clock, and that is right for a developer: the quantity
# they care about is how long their build takes on their machine. It is wrong for CI. A
# shared hosted runner measured 179 ms/type against the 87 ms this budget was calibrated
# against — the same code, twice the number, because the hardware is half the speed. Gating
# on it there fails on GitHub's fleet rather than on this repository's code.
#
# `schema / codable` is the portable form of the same question: how much more does @Schema
# cost than the thing it replaces? It still varies with hardware — the plugin round trip and
# the type checker scale differently — but it varies far less, and a regression that matters
# moves it a lot.
#
# The observed values MOVED UP when sampling changed, and that is expected rather than a
# regression: `codable` has more warm-up slack than `schema`, so taking minimums speeds the
# denominator proportionally more. Single-shot read 3.3x locally and 2.3x on a hosted
# runner; min-of-3 reads 4.12 / 4.13 / 4.14 locally — stable to under 1%, where it used to
# be the noisiest thing here. A hosted runner reads 3.20x under the same sampling (measured
# 2026-08-31, ubuntu-latest / swift:6.3.3), against 148.4 ms and 251.0 ms absolute — which
# is the whole reason those two are not gated here.
#
# Held at 6.0, which is ~45% above the worst local reading. Deliberately loose: this is a
# blowup detector, not a performance gate, and the absolute budgets above are the tight
# ones. It is also the ONLY check CI enforces, so it must not fail on hardware.
RATIO_BUDGET=${RATIO_BUDGET:-6.0}

# Set CI=1 (GitHub sets it) to check the ratio only.
CI="${CI:-}"

out=$(FIELDS="$FIELDS" ./measure.sh)
echo "$out"

schema=$(echo "$out" | awk -v t="$TYPES" '$1==t{print $4}')
validated=$(echo "$out" | awk -v t="$TYPES" '$1==t{print $5}')
if [ -z "$schema" ]; then
  echo "GATE ERROR: could not read the schema timing for $TYPES types" >&2
  exit 2
fi

per_type_ms=$(awk -v s="$schema" -v t="$TYPES" 'BEGIN{ printf "%.1f", s/t*1000 }')

validated_ms=$(awk -v s="$validated" -v t="$TYPES" 'BEGIN{ printf "%.1f", s/t*1000 }')
codable=$(echo "$out" | awk -v t="$TYPES" '$1==t{print $3}')
ratio=$(awk -v s="$schema" -v c="$codable" 'BEGIN{ printf "%.2f", (c > 0) ? s/c : 0 }')

echo ""
echo "per-type cost: ${per_type_ms} ms   budget: ${BUDGET_MS} ms"
echo "  with rules:  ${validated_ms} ms   budget: ${VALIDATED_BUDGET_MS} ms"
echo "vs Codable:    ${ratio}x          budget: ${RATIO_BUDGET}x"

if awk -v r="$ratio" -v b="$RATIO_BUDGET" 'BEGIN{ exit !(r > b) }'; then
  cat >&2 <<EOF

GATE FAILED — @Schema cost this much more than Codable:

  measured: ${ratio}x
  budget:   ${RATIO_BUDGET}x

This is the hardware-independent check, so a slow runner is not the explanation. See
docs/COMPILE-TIME.md §3.
EOF
  exit 1
fi

if [ -n "$CI" ]; then
  echo ""
  echo "CI: the ratio is gated, the absolute milliseconds are not. They were calibrated on"
  echo "a developer machine and a hosted runner is roughly half its speed, so an absolute"
  echo "budget here would fail on GitHub's fleet rather than on this code."
  echo "GATE PASSED"
  exit 0
fi

if awk -v m="$validated_ms" -v b="$VALIDATED_BUDGET_MS" 'BEGIN{ exit !(m > b) }'; then
  cat >&2 <<EOF

GATE FAILED — the cost of a rule-carrying type regressed.

  measured: ${validated_ms} ms per type (${FIELDS} fields, a @Validate on nearly every one)
  budget:   ${VALIDATED_BUDGET_MS} ms

The rule-free arm is fine, so this is the '_assayCheck' body (docs/VALIDATE.md) or the
rule arrays, not the decode body. The discipline is one line of generated code per rule
attribute, with everything conditional in an @inlinable runtime function.
EOF
  exit 1
fi

if awk -v m="$per_type_ms" -v b="$BUDGET_MS" 'BEGIN{ exit !(m > b) }'; then
  cat >&2 <<EOF

GATE FAILED — @Schema expansion cost regressed.

  measured: ${per_type_ms} ms per type (${FIELDS} fields)
  budget:   ${BUDGET_MS} ms

Compile time is an adoption gate, not a footnote: a developer replaces ': Codable' with
'@Schema' across their model layer in one commit and then waits for a build. See
docs/COMPILE-TIME.md §3 for the codegen rules this most likely violated — the usual cause
is newly-emitted per-field code that belongs in an @inlinable runtime function instead.

If the regression is intentional, re-baseline BUDGET_MS in a reviewed commit.
EOF
  exit 1
fi

echo "GATE PASSED"
