#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# Generate N equivalent types in one of four modes, for compile-time comparison.
#
# The arms must be *semantically equivalent* or the comparison is meaningless: same field
# names, same field types, same count. Only the conformance mechanism varies.
#
#   gen_types.sh <count> <fields> <plain|codable|schema|validated|arrays|paths|describes>
#
# `validated` puts a @Validate on EVERY field, which is the worst case for the generated
# `_assayCheck` body and not a realistic schema. It exists so the cost of validation is
# measured rather than inferred from the rule-free arm — the default `schema` arm is what
# the gate holds, because a type with no rules gets no validator body at all.
#
# `describes` adds @Schema(describes: true) to the VALIDATED arm, which is the shape that
# feature is for — a descriptor with no rules to describe is the cheap case, and measuring the
# cheap case would say nothing. ROADMAP §11 flagged this as HIGH compile-time risk before it
# was built, on the grounds that a per-field array literal is the exact shape rule 1 was
# written about; this arm is how that prediction gets checked instead of assumed.
#
# `paths` puts every field behind a @Key(path:), two per group, which is the shape the
# feature exists for. Added 2026-09-08 with @Key(path:) itself: a group emits a nested
# dispatch loop rather than one line, so it is the first construct since `arrays` whose
# per-field cost is not one line, and shipping it unmeasured against a scalar-only gate is
# exactly what the `arrays` note below warns about. Reported, not gated, for the same reason
# `arrays` is: the 100 ms budget was calibrated on a flat scalar type.
#
# `arrays` makes every field an ARRAY of the same scalar. Added 2026-09-08, and the reason
# is that it was missing: every arm above declares scalars only, so `arrayDecode` — which
# emits an inline loop per field rather than a single primitive call, and which two changes
# this week touched — had never been measured against the budget at all. An unmeasured
# generator is one nobody notices growing. Reported, not gated: an array-heavy type is not
# what the 100 ms budget was calibrated on, and gating a second shape on a number calibrated
# for the first is how a budget stops meaning anything.
set -euo pipefail

N=$1
FIELDS=$2
MODE=$3

TYPES=(String Int Double Bool String Int)
NAMES=(identifier displayName amountValue isEnabled createdAt
       retryCount ownerName sequenceNo ratioValue isArchived
       updatedAt parentName totalCount scoreValue isVisible)

# A rule that type-checks against each of the six rotating field types.
RULES=('.min(1)' '.range(0...1000)' '.range(0.0...1000.0)' '' '.max(64)' '.min(0)')

emit_fields() {
  local i name type rule
  for ((i = 0; i < FIELDS; i++)); do
    name=${NAMES[$((i % ${#NAMES[@]}))]}
    (( i >= ${#NAMES[@]} )) && name="${name}${i}"
    type=${TYPES[$((i % ${#TYPES[@]}))]}
    if [ "$MODE" = arrays ]; then
      echo "    var ${name}: [${type}]"
      continue
    fi
    if [ "$MODE" = paths ]; then
      # Two fields per group, so the "one arm per prefix, not per field" property is what
      # is being measured rather than a degenerate one-field-one-group case.
      echo "    @Key(path: \"group$((i / 2)).${name}\") var ${name}: ${type}"
      continue
    fi
    if [ "$MODE" = describes ]; then
      rule=${RULES[$((i % ${#RULES[@]}))]}
      if [ -n "$rule" ]; then
        echo "    @Validate(${rule}) var ${name}: ${type}"
        continue
      fi
    fi
    if [ "$MODE" = validated ]; then
      rule=${RULES[$((i % ${#RULES[@]}))]}
      if [ -n "$rule" ]; then
        echo "    @Validate(${rule}) var ${name}: ${type}"
        continue
      fi
    fi
    echo "    var ${name}: ${type}"
  done
}

case "$MODE" in
  schema|validated|arrays|paths|describes)  echo "import Assay" ;;
  *)       echo "import Foundation" ;;
esac
echo

for ((k = 0; k < N; k++)); do
  case "$MODE" in
    describes)
      echo "@Schema(keys: .snakeCase, describes: true)"
      echo "public struct T${k} {"
      ;;
    schema|validated|arrays|paths)
      echo "@Schema(keys: .snakeCase)"
      echo "public struct T${k} {"
      ;;
    codable)
      echo "public struct T${k}: Codable {"
      ;;
    plain)
      echo "public struct T${k} {"
      ;;
  esac
  emit_fields
  echo "}"
  echo
done
