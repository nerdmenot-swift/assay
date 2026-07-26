#!/bin/bash
# Generate N equivalent types in one of three modes, for compile-time comparison.
#
# The arms must be *semantically equivalent* or the comparison is meaningless: same field
# names, same field types, same count. Only the conformance mechanism varies.
#
#   gen_types.sh <count> <fields> <plain|codable|schema>
set -euo pipefail

N=$1
FIELDS=$2
MODE=$3

TYPES=(String Int Double Bool String Int)
NAMES=(identifier displayName amountValue isEnabled createdAt
       retryCount ownerName sequenceNo ratioValue isArchived
       updatedAt parentName totalCount scoreValue isVisible)

emit_fields() {
  local i name
  for ((i = 0; i < FIELDS; i++)); do
    name=${NAMES[$((i % ${#NAMES[@]}))]}
    (( i >= ${#NAMES[@]} )) && name="${name}${i}"
    echo "    var ${name}: ${TYPES[$((i % ${#TYPES[@]}))]}"
  done
}

case "$MODE" in
  schema)  echo "import Assay" ;;
  *)       echo "import Foundation" ;;
esac
echo

for ((k = 0; k < N; k++)); do
  case "$MODE" in
    schema)
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
