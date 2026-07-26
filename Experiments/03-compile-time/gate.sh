#!/bin/bash
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

out=$(FIELDS="$FIELDS" ./measure.sh)
echo "$out"

schema=$(echo "$out" | awk -v t="$TYPES" '$1==t{print $4}')
if [ -z "$schema" ]; then
  echo "GATE ERROR: could not read the schema timing for $TYPES types" >&2
  exit 2
fi

per_type_ms=$(awk -v s="$schema" -v t="$TYPES" 'BEGIN{ printf "%.1f", s/t*1000 }')

echo ""
echo "per-type cost: ${per_type_ms} ms   budget: ${BUDGET_MS} ms"

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
