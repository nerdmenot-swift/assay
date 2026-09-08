#!/bin/bash
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.

# INCREMENTAL builds — docs/COMPILE-TIME.md §5 axis 1, previously unmeasured.
#
# §5 says it plainly: *"This is what developers feel all day, and it is not measured here at
# all. A one-type edit should re-expand only that type; unverified."* `measure.sh` beside this
# measures CLEAN builds, which is the adoption decision — the one commit where `: Codable`
# becomes `@Schema` across a model layer. This measures every day after that one.
#
# THE CLAIM UNDER TEST, and it is a real risk rather than a formality. A macro plugin is a
# separate process reached over a pipe. If SwiftPM or the driver invalidated every expansion in
# a module when one file in it changed, then `@Schema` would turn a one-line edit into a
# whole-module re-expansion — and a model layer is exactly where a developer makes one-line
# edits all day. That would not show up in any clean-build number.
#
# FOUR SCENARIOS, because "incremental" is four different questions:
#
#   touch-schema    edit ONE file holding one @Schema type, of N such files
#   touch-plain     edit one file holding an ordinary struct, in the same module
#   touch-consumer  edit a file that USES the types but declares none
#   no-op           rebuild with nothing changed (the floor: driver + manifest overhead)
#
# Read `touch-schema` against `touch-plain`: if they are close, a schema edit costs about what
# any edit costs and expansion is properly incremental. Read `touch-consumer` against `no-op`:
# if THAT is large, then editing a file that merely uses a schema re-expands the schema, which
# would be the expensive failure mode.
#
# Compared against `codable` throughout, because the number that matters to someone deciding is
# not "how long" but "how much longer than what I have now".
#
# METHOD. The dependency graph is built once. Each measurement touches exactly one file (with
# a comment appended, so the content genuinely changes and no content hash short-circuits it)
# and times `swift build`. Medians of N, for the reason measure.sh's header gives at length:
# a ratio of two minima is biased, because minimising the denominator maximises the quotient.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
WORK="${TMPDIR:-/tmp}/assay-ct-inc"
TYPES=${TYPES:-25}
FIELDS=${FIELDS:-10}
CONFIG=${CONFIG:-debug}
REPEATS=${REPEATS:-5}

setup() {
  local mode=$1
  rm -rf "$WORK"
  mkdir -p "$WORK/Sources/M"
  cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "M",
  platforms: [.macOS(.v11)],
  dependencies: [.package(path: "$ROOT")],
  targets: [.target(name: "M", dependencies: [.product(name: "Assay", package: "assay")])]
)
EOF

  # One type per FILE, not one file with N types. That is the whole point: a module compiled
  # as a single file has nothing to be incremental about, and it is also not how anyone writes
  # a model layer.
  local i
  for ((i = 0; i < TYPES; i++)); do
    ./gen_types.sh 1 "$FIELDS" "$mode" | sed "s/T0/T${i}/" > "$WORK/Sources/M/T${i}.swift"
  done

  # An ordinary struct in the same module, so a schema edit has something to be compared to.
  cat > "$WORK/Sources/M/Plain.swift" <<'EOF'
public struct PlainNeighbour {
    public var a: String
    public var b: Int
    public var c: Double
    public init(a: String, b: Int, c: Double) { self.a = a; self.b = b; self.c = c }
}
EOF

  # A consumer: references the generated types without declaring any.
  {
    echo "public func consume() -> Int {"
    echo "    var n = 0"
    for ((i = 0; i < TYPES; i++)); do
      echo "    n += MemoryLayout<T${i}>.size"
    done
    echo "    return n"
    echo "}"
  } > "$WORK/Sources/M/Consumer.swift"

  ( cd "$WORK" && swift build -c "$CONFIG" >/dev/null 2>&1 )
}

# Touch one file and rebuild, REPEATS times; print "min median" in seconds.
time_touch() {
  local file=$1
  local times=()
  local i start end
  for ((i = 0; i < REPEATS; i++)); do
    if [ -n "$file" ]; then
      echo "// incremental probe $i" >> "$WORK/Sources/M/$file"
    fi
    start=$(python3 -c 'import time; print(time.time())')
    ( cd "$WORK" && swift build -c "$CONFIG" >/dev/null 2>&1 ) || { echo "BUILD-FAILED"; return; }
    end=$(python3 -c 'import time; print(time.time())')
    times+=("$(awk -v a="$start" -v b="$end" 'BEGIN{ printf "%.2f", b-a }')")
  done
  printf '%s\n' "${times[@]}" | sort -n | awk '
    { v[NR] = $1 }
    END { printf "%s %s", v[1], (NR % 2 ? v[int(NR/2)+1] : (v[NR/2] + v[NR/2+1]) / 2) }'
}

echo "Incremental builds — docs/COMPILE-TIME.md §5 axis 1, first measured 2026-09-09"
swift --version 2>&1 | head -1
echo "types: $TYPES (one per FILE)   fields: $FIELDS   config: $CONFIG   median of: $REPEATS"
echo ""
echo "A clean build is the adoption decision. This is every day after it."
echo ""
printf "%-16s %12s %12s %10s\n" "scenario" "codable" "schema" "vs-codable"
printf -- '-%.0s' $(seq 1 54); echo

# macOS ships bash 3.2, which has no associative arrays. A parallel indexed list keeps this
# runnable with /bin/bash rather than requiring a Homebrew one — the same constraint every
# other script in this directory works under.
SCENARIOS=("no-op:" "touch-plain:Plain.swift" "touch-consumer:Consumer.swift" "touch-schema:T0.swift")
CODABLE=()

setup codable
for scenario in "${SCENARIOS[@]}"; do
  file=${scenario#*:}
  read -r _min med <<< "$(time_touch "$file")"
  CODABLE+=("$med")
done

setup schema
idx=0
for scenario in "${SCENARIOS[@]}"; do
  name=${scenario%%:*}
  file=${scenario#*:}
  read -r _min med <<< "$(time_touch "$file")"
  base=${CODABLE[$idx]}
  ratio=$(awk -v a="$med" -v b="$base" 'BEGIN{ printf "%.2fx", (b > 0 ? a/b : 0) }')
  printf "%-16s %12s %12s %10s\n" "$name" "$base" "$med" "$ratio"
  idx=$((idx + 1))
done

echo ""
echo "Reading it:"
echo "  touch-schema vs touch-plain  — if close, one edit re-expands one type, not the module"
echo "  touch-consumer vs no-op      — if large, USING a schema re-expands it, the bad case"
echo ""
echo "Reported, not gated. A clean-build budget is calibrated on one shape and a wall-clock"
echo "gate on a hosted runner is exactly what CLAUDE.md's honesty rules forbid; this exists so"
echo "the axis has a number instead of a 'should'."
