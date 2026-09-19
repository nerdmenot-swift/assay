#!/usr/bin/env python3
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.
"""Static ARC audit: what the optimiser LEFT in each function.

    arcsum.py summarise <Module.opt.yaml>          > Module.tsv
    arcsum.py compare   <golden dir> <current dir> [--strict]

`summarise` reads the optimisation record `-Rpass-missed=sil-assembly-vision-remark-gen`
writes (docs/research/perf-swift-codegen.md §1.8) and prints one line per
(function, kind): how many retain / release / heap box / heap ref / runtime cast SITES the
optimiser could not remove. Keyed by demangled function name, never by line, so an edit
elsewhere in a file does not churn the golden. Verified 2026-09-19: two clean builds produce
byte-identical output.

These are SITES in code, not executions — Benchmarks/count.py counts executions. A site on an
error path costs nothing at run time, but it still costs code size, and rule 4's escape
analysis budget is a function of function size: the failure this audit exists to catch is a
function growing past that budget, keeping its retains, and saying nothing.

`compare` fails when a HOT function gains a site of any kind. Hot is a pattern, below,
matching the generated decode bodies and the reader's primitives. Everything else is
reported, not gated: cold paths (renderers, message getters) are allowed to allocate, and a
gate that fired on every edit to them would be one nobody reads.
"""
import collections, os, re, subprocess, sys

HOT = re.compile(r"(\._assay\(|\._assayBatch|\._assayDecode|AssayReader\.|\.scan|UTF8|"
                 r"keyMatches|_keyWindow|skipValue|Strings\.)")
KINDS = {"retain": "retain", "release": "release", "heap allocated box": "box",
         "heap allocated ref": "ref"}


def summarise(path):
    text = open(path, errors="replace").read()
    counts = collections.Counter()
    for rec in text.split("\n--- "):
        fm = re.search(r"^Function:\s+'([^']+)'", rec, re.M)
        sm = re.search(r"String:\s+'([a-z][a-z ]+?) of", rec)
        if fm and sm:
            counts[(fm.group(1), KINDS.get(sm.group(1), sm.group(1).replace(" ", "-")))] += 1
    mangled = sorted({f for f, _ in counts})
    # FULL demangling, parameter types included. `--simplified` drops them, so overloads
    # collapse to one key: the JSON `_assay(from:into:at:)` and the RawValue one merged, and
    # giving a fixture type `formats: .all` read as its JSON decoder "gaining" the RawValue
    # decoder's sites (2026-09-19). Merged keys would hide a real change in either overload.
    out = subprocess.run(["swift", "demangle", "--compact"], input="\n".join(mangled),
                         capture_output=True, text=True).stdout.splitlines()
    dem = dict(zip(mangled, out)) if len(out) == len(mangled) else {m: m for m in mangled}
    merged = collections.Counter()
    for (f, k), n in counts.items():
        merged[(dem[f], k)] += n
    for (f, k), n in sorted(merged.items()):
        print(f"{f}\t{k}\t{n}")


def load(path):
    rows = {}
    for line in open(path):
        f, k, n = line.rstrip("\n").split("\t")
        rows[(f, k)] = int(n)
    return rows


def compare(golden, current, strict):
    fails, notes, improved = [], [], []
    for name in sorted(os.listdir(golden)):
        if not name.endswith(".tsv"):
            continue
        cur_path = os.path.join(current, name)
        if not os.path.exists(cur_path):
            fails.append(f"{name}: module missing from this build"); continue
        g, c = load(os.path.join(golden, name)), load(cur_path)
        for key in sorted(set(g) | set(c)):
            gv, cv = g.get(key, 0), c.get(key, 0)
            if gv == cv:
                continue
            f, k = key
            line = f"{name[:-4]}  {f}  {k}: {gv} -> {cv}"
            if cv > gv and HOT.search(f):
                fails.append(line)
            elif cv < gv and HOT.search(f):
                improved.append(line)
            else:
                notes.append(line)
    for title, xs in (("HOT FUNCTIONS GAINED SITES", fails),
                      ("hot functions lost sites (update the golden)", improved),
                      ("cold functions moved (reported, not gated)", notes)):
        if xs:
            print(f"== {title}: {len(xs)}")
            for x in xs[:60]:
                print("   " + x)
            if len(xs) > 60:
                print(f"   ... and {len(xs) - 60} more")
    if not (fails or improved or notes):
        print("ARC audit: no site moved.")
    return 1 if fails or (strict and improved) else 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "summarise":
        summarise(sys.argv[2]); sys.exit(0)
    if len(sys.argv) >= 4 and sys.argv[1] == "compare":
        sys.exit(compare(sys.argv[2], sys.argv[3], "--strict" in sys.argv))
    print(__doc__); sys.exit(2)
