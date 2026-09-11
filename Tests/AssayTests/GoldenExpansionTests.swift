// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Golden expansions: what `@Schema` EMITS, pinned byte for byte.
//
// Every other test checks what generated code DOES. None checked what it IS — which is how
// `__assayCaseNames` was emitted into every `@Unknown` enum with no reader for as long as it
// existed, how `var __extras` warned in every user's build, and how "the context-free
// expansion is byte-identical" was verified once by hand and never again. Under the
// compile-time budget, an accidental change to emitted code is the change class that
// matters most, and a diff is the only test that sees it.
//
// One golden per generator shape. On a mismatch the test prints the diff and the command
// that regenerates the file; regenerate ONLY when the change to the expansion is the change
// you meant to make, and read the diff before you do.
//
//     ASSAY_UPDATE_GOLDENS=1 swift test --filter Golden
//===----------------------------------------------------------------------===//

import Testing
import Foundation

@Suite("Golden expansions")
struct GoldenExpansionTests {

    /// The shapes, read from `GoldenFixtures.swift`: each `// GOLDEN: name` marker and the
    /// declaration that follows it, up to the next blank line. The fixtures file is compiled
    /// as part of this target, so every shape here is one the type checker accepted.
    static let shapes: [(name: String, source: String)] = {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures.swift").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        var name: String? = nil
        var body: [String] = []
        func flush() {
            if let n = name, !body.isEmpty { out.append((n, body.joined(separator: "\n"))) }
            name = nil; body = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("// GOLDEN: ") {
                flush(); name = String(line.dropFirst("// GOLDEN: ".count)); continue
            }
            if name != nil {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { body.append(String(line)) }
            }
        }
        flush()
        return out
    }()

    static var goldensDirectory: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens").path
    }

    @Test("the fixtures file was found and parsed")
    func fixturesRead() {
        #expect(GoldenExpansionTests.shapes.count == 12, "\(GoldenExpansionTests.shapes.map(\.name))")
    }

    @Test("each shape expands to its golden", arguments: GoldenExpansionTests.shapes.map(\.name))
    func golden(_ name: String) throws {
        let shape = try #require(GoldenExpansionTests.shapes.first { $0.name == name })
        let (expansion, diagnostics) = expandSchemaForTesting(shape.source)
        #expect(diagnostics.isEmpty, "the shape itself must expand cleanly: \(diagnostics)")
        let actual = expansion + "\n"
        let path = GoldenExpansionTests.goldensDirectory + "/\(name).swift.golden"

        if ProcessInfo.processInfo.environment["ASSAY_UPDATE_GOLDENS"] == "1" {
            try actual.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        guard let expected = try? String(contentsOfFile: path, encoding: .utf8) else {
            Issue.record("no golden at \(path) — run: ASSAY_UPDATE_GOLDENS=1 swift test --filter Golden")
            return
        }
        if actual != expected {
            Issue.record("""
                expansion of '\(name)' changed. If that is the change you meant to make, run
                    ASSAY_UPDATE_GOLDENS=1 swift test --filter Golden
                and read the diff before committing it.
                \(Self.diff(expected, actual))
                """)
        }
    }

    /// A minimal line diff — enough to read in a test log, no dependency.
    static func diff(_ a: String, _ b: String) -> String {
        let x = a.split(separator: "\n", omittingEmptySubsequences: false)
        let y = b.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] { i += 1; j += 1; continue }
            // Resync: find the next line of `x` that appears later in `y`, or vice versa.
            if i < x.count, let k = y[j...].firstIndex(of: x[i]), k - j <= 3 {
                for l in j..<k { out.append("+ \(y[l])") }
                j = k
            } else if j < y.count, let k = x[i...].firstIndex(of: y[j]), k - i <= 3 {
                for l in i..<k { out.append("- \(x[l])") }
                i = k
            } else {
                if i < x.count { out.append("- \(x[i])"); i += 1 }
                if j < y.count { out.append("+ \(y[j])"); j += 1 }
            }
            if out.count > 60 { out.append("… (truncated)"); break }
        }
        return out.joined(separator: "\n")
    }
}
