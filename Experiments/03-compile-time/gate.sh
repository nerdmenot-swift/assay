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
# large (a regression that matters is tens of percent, not single digits). The threshold
# is set well above measurement noise to compensate.
set -euo pipefail
cd "$(dirname "$0")"

# Per type at 10 fields. See docs/COMPILE-TIME.md §2.
#
# Held at 100 ms. The multi-format decode body briefly pushed this to 118 ms and the
# budget was raised to 140; making formats OPT-IN (@Schema(formats:), default .json)
# brought the default back to ~82 ms, so the original budget stands.
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
# Held at 145, which is the same ~13% headroom the primary budget above carries (88 of
# 100). Best-of-three at 100 types measures 114 ms; a single build — which is all a gate
# run does — lands around 128. A gate that flakes gets disabled, so the margin covers the
# single-shot spread rather than the best case.
VALIDATED_BUDGET_MS=${VALIDATED_BUDGET_MS:-145}

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

echo ""
echo "per-type cost: ${per_type_ms} ms   budget: ${BUDGET_MS} ms"
echo "  with rules:  ${validated_ms} ms   budget: ${VALIDATED_BUDGET_MS} ms"

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
