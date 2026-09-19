#!/usr/bin/env python3
# Assay — a decoder for Swift that tells you what went wrong.
# Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
# See LICENSE and NOTICE at the repository root for terms.
"""EXACT COUNTS, NOT TIMES — the profiling matrix under Valgrind.

    count.py run     --binary AssayMatrix [--out counts.json] [--cells base/struct,...] [--jobs N]
    count.py compare --baseline counts-baseline.<arch>.json --current counts.json [--strict]
    count.py explain --binary AssayMatrix --cell base/struct [--fn swift_release] [--top 15]
    count.py scale   --binary AssayMatrix [--axes elements,depth] [--out scale.json]

WHY THIS EXISTS. CLAUDE.md forbids gating CI on wall clock and says package-benchmark's
instruction counter silently reports zero on hosted runners (no PMU). Both are right, and
together they meant no performance gate could run anywhere but a quiet Mac. Valgrind needs no
PMU: Callgrind counts executed instructions and calls in software, so the same numbers come
out on a laptop, in a container and on a GitHub runner. Measured 2026-09-19 on aarch64 Linux,
Swift 6.3.3: runtime call counts IDENTICAL across three runs, instruction counts within ~50 of
4.9 million (0.001%) — not bit-exact, which is why Ir gets a tolerance and calls do not.

It also answers two questions this repository had no instrument for: how much ARC traffic a
decode does (`swift_retain`/`swift_release` calls), and total allocation traffic on Linux
(DHAT), which `Benchmarks/Sources/AssayBench/TotalAllocations.swift` can only do on Darwin.

METHOD. Every cell runs twice, at K=1 and K=3 calls of the verb, and the difference is
divided by two. Start-up, fixture loading, `make`'s setup and every one-time static appear in
both runs and cancel exactly, so what remains is the steady-state cost of one call.

Linux only: Valgrind has no macOS port for current releases. `Benchmarks/count.sh` runs this
in a container on a Mac.
"""
import argparse, collections, json, os, platform, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

K_LO, K_HI = 1, 3

# Runtime entry points worth counting. Each is a CALL count per verb invocation.
WATCH = {
    "retain": ["swift_retain", "swift_retain_n", "swift_nonatomic_retain"],
    "release": ["swift_release", "swift_release_n", "swift_nonatomic_release"],
    "bridge_retain": ["swift_bridgeObjectRetain", "swift_bridgeObjectRetain_n"],
    "bridge_release": ["swift_bridgeObjectRelease", "swift_bridgeObjectRelease_n"],
    "alloc_object": ["swift_allocObject"],
    "slow_alloc": ["swift_slowAlloc"],
    "malloc": ["malloc", "calloc", "realloc", "posix_memalign", "aligned_alloc"],
    "unique_check": ["swift_isUniquelyReferenced_nonNull_native",
                     "swift_isUniquelyReferenced_native"],
    "begin_access": ["swift_beginAccess"],
    "dynamic_cast": ["swift_dynamicCast", "swift_conformsToProtocol",
                     "swift_conformsToProtocol2"],
}
NAME_TO_KEY = {n: k for k, ns in WATCH.items() for n in ns}

# Counters that RATCHET: any increase fails the gate. Instructions get a tolerance instead,
# because they are not bit-exact across runs; heap bytes get one because a String growth
# policy change in the toolchain moves them without meaning anything.
RATCHET = ["retain", "release", "bridge_retain", "bridge_release", "alloc_object",
           "slow_alloc", "malloc", "unique_check", "begin_access", "dynamic_cast",
           "heap_blocks"]
TOLERANT = {"ir": 0.02, "heap_bytes": 0.01}
IMPROVED_IR = 0.01   # an Ir DROP past this asks for a re-baseline under --strict


def base_name(fn):
    return fn.split("'")[0].strip()


def is_runtime(fn):
    """A call made BY the Swift runtime is part of the call that entered it: the
    `swift_release` inside every `swift_bridgeObjectRelease`, the `malloc` inside every
    `swift_slowAlloc`. Counting those as well double-counted every String release on the
    first run, which read as four releases per field when there were two."""
    return fn.startswith(("swift_", "_swift_", "swift::")) or "swift::" in fn


def parse_callgrind(path):
    """Return (total Ir, calls-into-watched counter, callers[(caller, callee)] -> calls)."""
    names, calls, callers = {}, collections.Counter(), collections.Counter()
    total, cur_fn, cur_cfn = 0, None, None
    with open(path, errors="replace") as f:
        for line in f:
            m = re.match(r"^(c?fn)=\((\d+)\)(?: (.*))?$", line.rstrip("\n"))
            if m:
                kind, i, name = m.groups()
                if name is not None:
                    names[i] = name
                if kind == "fn":
                    cur_fn = names.get(i)
                else:
                    cur_cfn = names.get(i)
                continue
            if line.startswith("calls=") and cur_cfn is not None:
                n = int(line[6:].split()[0])
                callee, caller = base_name(cur_cfn), base_name(cur_fn or "?")
                key = NAME_TO_KEY.get(callee)
                if key and not is_runtime(caller):
                    calls[key] += n
                callers[(caller, callee)] += n
                continue
            if line.startswith("summary:") or line.startswith("totals:"):
                total = int(line.split()[1])
    return total, calls, callers


def run_callgrind(binary, shape, task, path, k, out):
    r = subprocess.run(["valgrind", "--tool=callgrind", f"--callgrind-out-file={out}",
                        binary, "count", shape, task, path, str(k)],
                       capture_output=True, text=True)
    if r.returncode != 0 or "OK" not in r.stdout:
        return None, r.stdout.strip() or r.stderr[-400:]
    return parse_callgrind(out), r.stdout


def run_dhat(binary, shape, task, path, k):
    r = subprocess.run(["valgrind", "--tool=dhat", "--dhat-out-file=/dev/null",
                        binary, "count", shape, task, path, str(k)],
                       capture_output=True, text=True)
    m = re.search(r"Total:\s+([\d,]+) bytes in ([\d,]+) blocks", r.stderr)
    if not m:
        return None
    return int(m.group(1).replace(",", "")), int(m.group(2).replace(",", ""))


def count_cell(binary, fixtures, shape, task, scratch):
    path = os.path.join(fixtures, f"{shape}.json")
    lo, out_lo = run_callgrind(binary, shape, task, path, K_LO,
                               os.path.join(scratch, f"{shape}.{task}.lo"))
    if lo is None:
        return {"declined": True} if "DECLINED" in (out_lo or "") else {"error": out_lo}
    hi, out_hi = run_callgrind(binary, shape, task, path, K_HI,
                               os.path.join(scratch, f"{shape}.{task}.hi"))
    if hi is None:
        return {"error": out_hi}
    span = K_HI - K_LO
    cell = {"elements": int(re.search(r"elements=(\d+)", out_hi).group(1)),
            "ir": (hi[0] - lo[0]) / span}
    for key in WATCH:
        cell[key] = (hi[1][key] - lo[1][key]) / span
    d_lo = run_dhat(binary, shape, task, path, K_LO)
    d_hi = run_dhat(binary, shape, task, path, K_HI)
    if d_lo and d_hi:
        cell["heap_bytes"] = (d_hi[0] - d_lo[0]) / span
        cell["heap_blocks"] = (d_hi[1] - d_lo[1]) / span
    # The floor: the least heap the RESULT can occupy (Floors.swift). Computed natively, not
    # under Valgrind — it is arithmetic over a decoded value, not a measurement. Reported
    # beside the measured heap and never gated: it says how much is LEFT, not what moved.
    fl = subprocess.run([binary, "floor", shape, task, path], capture_output=True, text=True)
    m = re.search(r"FLOOR blocks=(\d+) bytes=(\d+)", fl.stdout)
    if m:
        cell["floor_blocks"], cell["floor_bytes"] = int(m.group(1)), int(m.group(2))
    return cell


def toolchain():
    try:
        return subprocess.run(["swift", "--version"], capture_output=True,
                              text=True).stdout.splitlines()[0].strip()
    except Exception:
        return "unknown"


def cmd_run(a):
    fixtures = tempfile.mkdtemp(prefix="assay-count-")
    grid = subprocess.run([a.binary, "cells", fixtures], capture_output=True,
                          text=True, check=True).stdout.split("\n")
    cells = [tuple(l.split()) for l in grid if l.strip()]
    if a.cells:
        want = set(a.cells.split(","))
        cells = [c for c in cells if f"{c[0]}/{c[1]}" in want]
    scratch = tempfile.mkdtemp(prefix="assay-cg-")
    results = {}

    def one(c):
        return f"{c[0]}/{c[1]}", count_cell(a.binary, fixtures, c[0], c[1], scratch)

    with ThreadPoolExecutor(max_workers=a.jobs) as pool:
        for i, (name, cell) in enumerate(pool.map(one, cells), 1):
            results[name] = cell
            note = ("declined" if cell.get("declined") else
                    f"ERROR {cell['error']}" if "error" in cell else
                    f"{cell['ir'] / cell['elements']:.0f} Ir/elem  "
                    f"{cell['release'] + cell['bridge_release']:.0f} releases  "
                    f"{cell.get('heap_blocks', 0):.0f} blocks"
                    + (f" (floor {cell['floor_blocks']})" if "floor_blocks" in cell else ""))
            print(f"[{i:3d}/{len(cells)}] {name:28s} {note}", flush=True)
    doc = {"meta": {"arch": platform.machine(), "toolchain": toolchain(),
                    "k": [K_LO, K_HI], "unit": "per call of the verb"},
           "cells": {k: v for k, v in sorted(results.items()) if not v.get("declined")}}
    errors = [k for k, v in results.items() if "error" in v]
    with open(a.out, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
    print(f"\nwrote {a.out}: {len(doc['cells'])} cells, {len(errors)} errors")
    return 1 if errors else 0


def per_call(binary, shape, task, path, scratch, tag):
    """Ir, heap bytes and heap blocks for ONE call, by the K_LO/K_HI difference."""
    lo, out = run_callgrind(binary, shape, task, path, K_LO, os.path.join(scratch, tag + ".lo"))
    if lo is None:
        return None, out
    hi, out = run_callgrind(binary, shape, task, path, K_HI, os.path.join(scratch, tag + ".hi"))
    if hi is None:
        return None, out
    span = K_HI - K_LO
    r = {"ir": (hi[0] - lo[0]) / span}
    d_lo = run_dhat(binary, shape, task, path, K_LO)
    d_hi = run_dhat(binary, shape, task, path, K_HI)
    if d_lo and d_hi:
        r["heap_bytes"] = (d_hi[0] - d_lo[0]) / span
    return r, None


def slope(points):
    """(least-squares log-log slope, slope between the last two points)."""
    import math
    pts = [(math.log(x), math.log(y)) for x, y in points if y > 0]
    if len(pts) < 2:
        return None, None
    mx = sum(p[0] for p in pts) / len(pts)
    my = sum(p[1] for p in pts) / len(pts)
    den = sum((p[0] - mx) ** 2 for p in pts)
    fit = sum((p[0] - mx) * (p[1] - my) for p in pts) / den if den else None
    tail = (pts[-1][1] - pts[-2][1]) / (pts[-1][0] - pts[-2][0])
    return fit, tail


# A slope, not a time: machine speed cancels, so the threshold is absolute. 1.10 admits a
# linear cost plus a shrinking constant and refuses n log n at these sizes (whose tail slope
# is ~1.14 from 1,000 to 2,000) as well as anything quadratic. Heap bytes below this many per
# call are too small for a slope to mean anything and are reported but not gated.
MAX_SLOPE = 1.10
MIN_HEAP_FOR_SLOPE = 4096


def cmd_scale(a):
    fixtures = tempfile.mkdtemp(prefix="assay-axes-")
    lines = subprocess.run([a.binary, "axes", fixtures], capture_output=True, text=True,
                           check=True).stdout.splitlines()
    points = [l.split() for l in lines if l.strip()]
    if a.axes:
        want = set(a.axes.split(","))
        points = [p for p in points if p[0] in want]
    scratch = tempfile.mkdtemp(prefix="assay-scale-")

    def one(p):
        axis, shape, task, size, path = p
        r, err = per_call(a.binary, shape, task, path, scratch, f"{axis}.{task}.{size}")
        return (axis, task, int(size)), r, err

    series = collections.defaultdict(list)
    errors = []
    with ThreadPoolExecutor(max_workers=a.jobs) as pool:
        for key, r, err in pool.map(one, points):
            if r is None:
                if "DECLINED" not in (err or ""):
                    errors.append(f"{key}: {err}")
                continue
            series[(key[0], key[1])].append((key[2], r))

    lines, fails, doc = [], [], {}
    lines.append("### Scaling — cost against size, per call\n")
    lines.append(f"Log-log slope of instructions and heap bytes over each axis. 1.0 is linear; "
                 f"the gate is the TAIL slope (last two sizes) at {MAX_SLOPE}.\n")
    lines.append("| axis | verb | sizes | Ir fit | Ir tail | heap fit | heap tail | |")
    lines.append("|---|---|---|---:|---:|---:|---:|---|")
    for (axis, task), pts in sorted(series.items()):
        pts.sort()
        ir_fit, ir_tail = slope([(x, r["ir"]) for x, r in pts])
        heap = [(x, r.get("heap_bytes", 0)) for x, r in pts]
        h_fit, h_tail = slope(heap)
        heap_gated = heap[-1][1] >= MIN_HEAP_FOR_SLOPE
        bad = (ir_tail is not None and ir_tail > MAX_SLOPE) or \
              (heap_gated and h_tail is not None and h_tail > MAX_SLOPE)
        if bad:
            fails.append(f"{axis}/{task}")
        f = lambda v: "—" if v is None else f"{v:.2f}"
        lines.append(f"| {axis} | {task} | {pts[0][0]}–{pts[-1][0]} | {f(ir_fit)} | "
                     f"{f(ir_tail)} | {f(h_fit)} | {f(h_tail) if heap_gated else '(small)'} | "
                     f"{'FAIL' if bad else ''} |")
        doc[f"{axis}/{task}"] = {"points": [{"size": x, **r} for x, r in pts],
                                 "ir_slope": ir_fit, "ir_tail": ir_tail,
                                 "heap_slope": h_fit, "heap_tail": h_tail}
    if errors:
        lines.append(f"\n**{len(errors)} point(s) failed to run:**")
        lines += [f"- {e[:200]}" for e in errors]
    if fails:
        lines.append(f"\n**{len(fails)} series super-linear:** {', '.join(fails)}")
    text = "\n".join(lines)
    print(text)
    if a.out:
        with open(a.out, "w") as fh:
            json.dump({"meta": {"arch": platform.machine(), "toolchain": toolchain()},
                       "series": doc}, fh, indent=1, sort_keys=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write(text + "\n")
    return 1 if fails or errors else 0


def fmt(v):
    return f"{v:,.0f}" if abs(v) >= 100 else f"{v:,.1f}"


def cmd_compare(a):
    base, cur = json.load(open(a.baseline)), json.load(open(a.current))
    lines, fails, wants_rebaseline = [], [], []
    if base["meta"].get("toolchain") != cur["meta"].get("toolchain"):
        lines.append(f"> **toolchain differs** — baseline `{base['meta'].get('toolchain')}`, "
                     f"current `{cur['meta'].get('toolchain')}`. Counts move with the "
                     f"compiler; re-baseline in a reviewed commit.\n")
    if base["meta"].get("arch") != cur["meta"].get("arch"):
        print(f"arch mismatch: {base['meta'].get('arch')} vs {cur['meta'].get('arch')}")
        return 2
    rows = []
    for name in sorted(set(base["cells"]) | set(cur["cells"])):
        b, c = base["cells"].get(name), cur["cells"].get(name)
        if b is None:
            rows.append((name, "new cell", "", "", "note")); continue
        if c is None:
            if not a.subset:
                rows.append((name, "cell disappeared", "", "", "FAIL")); fails.append(name)
            continue
        if "error" in c:
            rows.append((name, "error", "", c["error"][:60], "FAIL")); fails.append(name); continue
        for key in RATCHET:
            bv, cv = b.get(key, 0), c.get(key, 0)
            if cv > bv:
                rows.append((name, key, fmt(bv), fmt(cv), "FAIL")); fails.append(name)
            elif cv < bv:
                rows.append((name, key, fmt(bv), fmt(cv), "improved"))
                wants_rebaseline.append(name)
        for key, tol in TOLERANT.items():
            bv, cv = b.get(key, 0), c.get(key, 0)
            if bv == 0:
                continue
            rel = (cv - bv) / bv
            if rel > tol:
                rows.append((name, key, fmt(bv), fmt(cv), f"FAIL {rel:+.1%}")); fails.append(name)
            elif key == "ir" and rel < -IMPROVED_IR:
                rows.append((name, key, fmt(bv), fmt(cv), f"improved {rel:+.1%}"))
                wants_rebaseline.append(name)
            elif abs(rel) >= 0.005:
                rows.append((name, key, fmt(bv), fmt(cv), f"{rel:+.1%}"))
    lines.append(f"### Exact counts — {cur['meta'].get('arch')}\n")
    lines.append(f"{len(cur['cells'])} cells, per call of the verb. Calls and allocations "
                 f"ratchet (any increase fails); instructions fail past "
                 f"+{TOLERANT['ir']:.0%}, heap bytes past +{TOLERANT['heap_bytes']:.0%}.\n")
    if rows:
        lines.append("| cell | counter | baseline | current | |")
        lines.append("|---|---|---:|---:|---|")
        lines += [f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]} |" for r in rows]
    else:
        lines.append("No counter moved.")
    status = 0
    if fails:
        lines.append(f"\n**{len(set(fails))} cell(s) regressed.**")
        status = 1
    if wants_rebaseline and a.strict:
        lines.append(f"\n**{len(set(wants_rebaseline))} cell(s) improved.** The ratchet only "
                     f"holds if the baseline moves with them: re-run `count.py run` and "
                     f"commit the new baseline in this change.")
        status = status or 1
    text = "\n".join(lines)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text + "\n")
    return status


def demangle(names):
    try:
        out = subprocess.run(["swift", "demangle", "--simplified"], input="\n".join(names),
                             capture_output=True, text=True).stdout.splitlines()
        return dict(zip(names, out)) if len(out) == len(names) else {n: n for n in names}
    except Exception:
        return {n: n for n in names}


def cmd_explain(a):
    """Which functions make the calls, per call of the verb. The question after every
    surprising count is WHERE, and the counts file already knows."""
    shape, task = a.cell.split("/")
    fixtures = tempfile.mkdtemp(prefix="assay-count-")
    subprocess.run([a.binary, "cells", fixtures], capture_output=True, check=True)
    path, scratch = os.path.join(fixtures, f"{shape}.json"), tempfile.mkdtemp()
    lo, _ = run_callgrind(a.binary, shape, task, path, K_LO, os.path.join(scratch, "lo"))
    hi, _ = run_callgrind(a.binary, shape, task, path, K_HI, os.path.join(scratch, "hi"))
    targets = set(WATCH.get(a.fn, [a.fn]))
    # `--fn` also matches a SUBSTRING of a mangled name, so a generic helper can be traced one
    # level further up: `--fn consumeAndCreateNew` names who grew which array, where
    # `--fn alloc_object` only names Array's own growth function.
    match = (lambda c: c in targets) if a.fn in WATCH else (lambda c: c in targets or a.fn in c)
    diff = collections.Counter()
    for (caller, callee), n in hi[2].items():
        if match(callee):
            diff[caller] += n
    for (caller, callee), n in lo[2].items():
        if match(callee):
            diff[caller] -= n
    span = K_HI - K_LO
    top = [(c, n / span) for c, n in diff.most_common(a.top) if n > 0]
    dem = demangle([c for c, _ in top])
    total = sum(n for n in diff.values() if n > 0) / span
    print(f"{a.cell}: {total:,.0f} calls to {a.fn} per call of the verb, by caller\n")
    for c, n in top:
        print(f"{n:12,.0f}  {dem[c]}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--binary", required=True)
    r.add_argument("--out", default="counts.json")
    r.add_argument("--cells")
    r.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    c = sub.add_parser("compare")
    c.add_argument("--baseline", required=True)
    c.add_argument("--current", required=True)
    c.add_argument("--strict", action="store_true")
    c.add_argument("--subset", action="store_true",
                   help="the current run counted only some cells (run --cells)")
    sc = sub.add_parser("scale")
    sc.add_argument("--binary", required=True)
    sc.add_argument("--axes")
    sc.add_argument("--out")
    sc.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    e = sub.add_parser("explain")
    e.add_argument("--binary", required=True)
    e.add_argument("--cell", required=True)
    e.add_argument("--fn", default="bridge_release",
                   help="a WATCH key (release, bridge_release, malloc, ...) or a symbol")
    e.add_argument("--top", type=int, default=15)
    a = p.parse_args()
    return {"run": cmd_run, "compare": cmd_compare, "explain": cmd_explain,
            "scale": cmd_scale}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
