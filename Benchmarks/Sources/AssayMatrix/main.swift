// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A PROFILING MATRIX: one property per fixture, one verb per task.
//
// `AssayBench`'s arms grew one at a time, each against one corpus shape, so a number told
// you how fast that shape was and nothing about why. Two of this week's findings were found
// by accident rather than by method — the XML→RawValue projection had regressed 4× and
// nothing timed it, and `@Wraps` costs 2× the thing it is sugar for, which surfaced only
// when an arm was finally written for it. This makes the method the method.
//
//     swift run -c release AssayMatrix run [--reps N] [--baseline f.json] [--save f.json]
//     swift run -c release AssayMatrix run --only struct,diagnose --shapes base,fields-20
//
// Each cell runs in ITS OWN PROCESS. That is not ceremony: it keeps allocator state, page
// cache and any lazily-built statics from leaking between measurements, and it is the only
// way to attribute peak memory to a verb. Time takes the best of the reps and memory the
// worst — the floor is the right estimate of how fast something can go, and the ceiling is
// the right estimate of how much memory it can need.
//===----------------------------------------------------------------------===//

import Foundation

// Unbuffered, because a slow matrix and a hung one look identical otherwise. haul's first
// run of the same design spent twenty-one minutes with nothing on stdout.
//
// A write to the file handle rather than `print` + `fflush(stdout)`: Glibc declares `stdout`
// as a mutable global, which Swift 6 language mode rejects, so this target did not compile on
// Linux at all from the day it was written until 2026-09-19 — nothing had built it there.
func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func lpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}
func fixed(_ d: Double, _ places: Int) -> String { String(format: "%.\(places)f", d) }

struct Cell: Codable {
    var ns: Double          // per element
    var elements: Int
    var bytes: Int
    /// Peak resident bytes, as the child reported them. Optional so a baseline saved before
    /// memory was recorded still decodes.
    var rss: Int?
}

func peakResidentBytes() -> Int {
    var usage = rusage()
    #if canImport(Darwin)
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    #else
    // Glibc imports RUSAGE_SELF as an enum case, not the `Int32` getrusage takes.
    guard getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage) == 0 else { return 0 }
    #endif
    // Darwin reports bytes, Linux kilobytes.
    #if canImport(Darwin)
    return Int(usage.ru_maxrss)
    #else
    return Int(usage.ru_maxrss) * 1024
    #endif
}

// MARK: - Child mode

/// `AssayMatrix task <shape> <task> <path>` — runs one verb once, prints one line.
///
/// The child does its own warm-up and repetition and reports ns per element, because the
/// process spawn is milliseconds and would swamp a single decode.
func runChild(shape: String, taskName: String, path: String) -> Never {
    guard let data = FileManager.default.contents(atPath: path) else {
        say("ERR no fixture at \(path)"); exit(2)
    }
    let bytes = [UInt8](data)
    guard let task = allTasks().first(where: { $0.name == taskName }) else {
        say("ERR no task \(taskName)"); exit(2)
    }
    // `make` does the setup — decoding, for a verb that operates on a value — OUTSIDE the
    // timed region, and hands back the closure to time.
    guard let verb = task.make(shape, bytes), let n = verb(), n > 0 else {
        say("DECLINED"); exit(0)
    }

    // Warm: the first call per type does one-time work (cold start is its own arm).
    for _ in 0..<3 { _ = verb() }

    // NINE REPS OF 100 ms, KEEPING THE FLOOR. The window and the rep count were chosen from
    // measured noise rather than picked: at five reps of 50 ms, two runs of the unchanged
    // matrix disagreed by a median of 1.5% but a p90 of 5.2% and a worst case of 11.6%,
    // which makes a 5% regression threshold fire on about a tenth of the table for nothing.
    // A detector that cries wolf is one nobody reads, and the fix is a quieter measurement
    // rather than a looser threshold — a looser threshold hides real regressions too.
    var best = Double.infinity
    let reps = 9
    for _ in 0..<reps {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var iterations = 0
        repeat {
            _ = verb()
            iterations += 1
        } while DispatchTime.now().uptimeNanoseconds - t0 < 100_000_000
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0)
        best = min(best, elapsed / Double(iterations) / Double(n))
    }
    say("OK ns=\(best) elements=\(n) bytes=\(bytes.count) rss=\(peakResidentBytes())")
    exit(0)
}

/// `AssayMatrix count <shape> <task> <path> <K>` — runs one verb EXACTLY `k` times, with no
/// timing, no warm-up and no repetition loop, for an instruction-counting tool to observe.
///
/// This is the child `Benchmarks/count.py` drives under Valgrind. It runs every cell twice,
/// at two values of `k`, and subtracts: process start-up, fixture loading, `make`'s setup and
/// every one-time static cancel exactly, and what is left is the steady-state cost of the
/// verb itself. That is why there is no warm-up here — a warm-up would be counted in both
/// runs and cancel anyway, so it would only cost Valgrind time.
func runCount(shape: String, taskName: String, path: String, k: Int) -> Never {
    guard let data = FileManager.default.contents(atPath: path) else {
        say("ERR no fixture at \(path)"); exit(2)
    }
    let bytes = [UInt8](data)
    guard let task = allTasks().first(where: { $0.name == taskName }) else {
        say("ERR no task \(taskName)"); exit(2)
    }
    guard let verb = task.make(shape, bytes) else { say("DECLINED"); exit(0) }
    var n = 0
    for _ in 0..<k { n = verb() ?? 0 }
    guard n > 0 else { say("DECLINED"); exit(0) }
    say("OK elements=\(n) bytes=\(bytes.count)")
    exit(0)
}

// MARK: - Parent

func flag(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

/// Spawns the child and parses its one line. A child that does not finish in `timeout`
/// seconds is killed and reported: a hung benchmark is a benchmark bug, and it must not
/// stall the run.
func measure(binary: String, shape: String, task: String, path: String,
             timeout: Double = 120) -> Cell? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = ["task", shape, task, path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }

    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning {
        p.terminate()
        say("      \(shape)/\(task): KILLED after \(Int(timeout))s — a hung benchmark is a bug")
        return nil
    }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard out.hasPrefix("OK ") else { return nil }
    func field(_ k: String) -> Double {
        guard let r = out.range(of: "\(k)=") else { return 0 }
        let rest = out[r.upperBound...].prefix { !$0.isWhitespace }
        return Double(rest) ?? 0
    }
    return Cell(ns: field("ns"), elements: Int(field("elements")),
                bytes: Int(field("bytes")), rss: Int(field("rss")))
}

let args = CommandLine.arguments

if args.count >= 5, args[1] == "task" {
    runChild(shape: args[2], taskName: args[3], path: args[4])
}
if args.count >= 6, args[1] == "count" {
    runCount(shape: args[2], taskName: args[3], path: args[4], k: Int(args[5]) ?? 1)
}
// `AssayMatrix axes <dir>` — writes every scaling-axis fixture and prints one line per point,
// `axis shape task size path`, for `count.py scale`.
if args.count >= 3, args[1] == "axes" {
    let out = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for axis in allAxes() {
        for size in axis.sizes {
            let path = out.appendingPathComponent("\(axis.name)-\(size).json")
            try? Data(axis.build(size)).write(to: path)
            for task in axis.tasks { say("\(axis.name) \(axis.shape) \(task) \(size) \(path.path)") }
        }
    }
    exit(0)
}
// `AssayMatrix cells <dir>` — writes every fixture into `dir` and prints the applicable
// cells, one `shape task` per line. The counting driver needs the grid without the timing
// parent, and taking it from here keeps one definition of which cells exist.
if args.count >= 3, args[1] == "cells" {
    let out = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for s in allShapes() {
        try? Data(s.json).write(to: out.appendingPathComponent("\(s.name).json"))
        for t in allTasks() where t.applies(s.name) { say("\(s.name) \(t.name)") }
    }
    exit(0)
}

guard args.count >= 2, args[1] == "run" else {
    say("""
        usage: AssayMatrix run [--reps N] [--baseline f.json] [--save f.json]
                               [--only task,task] [--shapes shape,shape]

        One property per fixture, one verb per task. Every cell runs in its own process;
        time is the best of the reps and memory the worst. A cell that moves more than 5%
        in time or 10% in memory against a saved baseline is flagged.
        """)
    exit(args.count >= 2 ? 2 : 0)
}

let shapes = allShapes()
let tasks = allTasks()
let onlyTasks = flag("--only").map { Set($0.split(separator: ",").map(String.init)) }
let onlyShapes = flag("--shapes").map { Set($0.split(separator: ",").map(String.init)) }

// Fixtures are written to a scratch directory and regenerated every run: they are
// deterministic, they cost milliseconds, and a stale fixture is a way to measure the wrong
// thing for a week.
let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("assay-matrix")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for s in shapes {
    try? Data(s.json).write(to: dir.appendingPathComponent("\(s.name).json"))
}

var baseline: [String: Cell] = [:]
if let bp = flag("--baseline"), let data = FileManager.default.contents(atPath: bp) {
    baseline = (try? JSONDecoder().decode([String: Cell].self, from: data)) ?? [:]
    say("baseline: \(baseline.count) cells from \(bp)")
}

say("")
say("Assay profiling matrix — one property per fixture, one verb per task")
say("ns is PER ELEMENT (\(elementCount) per document), so shapes are comparable.")
say("")
say(pad("shape", 17) + pad("moves", 34) + pad("task", 10)
    + lpad("ns/elem", 10) + lpad("MB/s", 8) + lpad("peak MB", 9) + "  notes")
say(String(repeating: "-", count: 96))

// TWO THRESHOLDS, BOTH TAKEN FROM MEASURED NOISE RATHER THAN CHOSEN.
//
// Five runs of the unchanged matrix, nine reps of 100 ms each keeping the floor: the spread
// of a cell across those runs has a median of 3.4%, a p90 of 8.0% and a worst case of 15%
// (`fields-100/value`, the largest document in the table at ~24 MB peak, where allocator
// variance dominates).
//
// So 5% is worth PRINTING and useless as a gate. A human reading the table can tell a real
// move from a jittery cell by looking at its neighbours and at whether the shape's other
// verbs moved too; a CI job cannot, and a gate that fires on a tenth of the table every
// run is one people learn to rerun rather than read. The gate is therefore 20% — above
// everything the noise produced — and cells past it are marked `!`.
//
// WHAT THIS MEANS THE TOOL IS FOR, stated so nobody expects otherwise: the matrix is a wide
// net for structural surprises and large moves — a 2× regression in a step nobody timed,
// which is exactly how the XML→RawValue projection got 4× slower unnoticed. It is not the
// instrument for resolving a 5% change. That is what the `AssayBench` arms are: one shape,
// one question, minimum of five, and a number with a named competitor beside it.
let reportThreshold = 5.0
let gateThreshold = 20.0
var gateBreaches = 0

var results: [String: Cell] = [:]
let binary = CommandLine.arguments[0]
var flagged = 0

for s in shapes where onlyShapes.map({ $0.contains(s.name) }) ?? true {
    var first = true
    for t in tasks where (onlyTasks.map { $0.contains(t.name) } ?? true) && t.applies(s.name) {
        let path = dir.appendingPathComponent("\(s.name).json").path
        let label = first ? pad(s.name, 17) + pad(s.moves, 34) : pad("", 51)
        guard let cell = measure(binary: binary, shape: s.name, task: t.name, path: path) else {
            say(label + pad(t.name, 10) + lpad("declined", 10)); first = false; continue
        }
        first = false
        let key = "\(s.name)/\(t.name)"
        results[key] = cell
        let totalNs = cell.ns * Double(cell.elements)
        let mbs = totalNs > 0 ? (Double(cell.bytes) / 1e6) / (totalNs / 1e9) : 0

        var notes: [String] = []
        if let was = baseline[key], was.ns > 0 {
            let delta = (cell.ns - was.ns) / was.ns * 100
            if abs(delta) >= reportThreshold {
                notes.append("\(delta > 0 ? "+" : "")\(fixed(delta, 0))% time"
                             + (abs(delta) >= gateThreshold ? " !" : ""))
                flagged += 1
                if abs(delta) >= gateThreshold { gateBreaches += 1 }
            }
        }
        if let was = baseline[key]?.rss, was > 0, let now = cell.rss, now > 0 {
            let delta = Double(now - was) / Double(was) * 100
            // Memory gets its own threshold on its own terms: the standing rule here is
            // that a large memory saving is worth a small slowdown, and a table that prints
            // only time reports the cost of that trade and hides the gain.
            // Memory gets its own threshold on its own terms: the standing rule here is
            // that a large memory saving is worth a small slowdown, and a table that prints
            // only time reports the cost of that trade and hides the gain. Peak RSS is far
            // steadier than time across runs, so 10% prints and 25% gates.
            if abs(delta) >= 10 {
                notes.append("\(delta > 0 ? "+" : "")\(fixed(delta, 0))% memory"
                             + (abs(delta) >= 25 ? " !" : ""))
                flagged += 1
                if abs(delta) >= 25 { gateBreaches += 1 }
            }
        }
        say(label + pad(t.name, 10)
            + lpad(fixed(cell.ns, 1), 10)
            + lpad(fixed(mbs, 0), 8)
            + lpad(cell.rss.map { fixed(Double($0) / 1e6, 1) } ?? "-", 9)
            + (notes.isEmpty ? "" : "  " + notes.joined(separator: ", ")))
    }
}

if let sp = flag("--save"), let data = try? JSONEncoder().encode(results) {
    try? data.write(to: URL(fileURLWithPath: sp))
    say("")
    say("saved \(results.count) cells to \(sp)")
}
say("")
say("\(results.count) cells"
    + (baseline.isEmpty ? "" :
        ", \(flagged) moved over \(Int(reportThreshold))%, \(gateBreaches) over \(Int(gateThreshold))% (marked !)"))
if CommandLine.arguments.contains("--gate"), gateBreaches > 0 {
    say("GATE FAILED: \(gateBreaches) cells moved more than the measured noise floor explains")
    exit(1)
}
exit(0)
