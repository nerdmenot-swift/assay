#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# Generate N equivalent types in one of four modes, for compile-time comparison.
#
# The arms must be *semantically equivalent* or the comparison is meaningless: same field
# names, same field types, same count. Only the conformance mechanism varies.
#
#   gen_types.sh <count> <fields> <plain|codable|schema|validated>
#
# `validated` puts a @Validate on EVERY field, which is the worst case for the generated
# `_assayCheck` body and not a realistic schema. It exists so the cost of validation is
# measured rather than inferred from the rule-free arm — the default `schema` arm is what
# the gate holds, because a type with no rules gets no validator body at all.
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
  schema|validated)  echo "import Assay" ;;
  *)       echo "import Foundation" ;;
esac
echo

for ((k = 0; k < N; k++)); do
  case "$MODE" in
    schema|validated)
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
