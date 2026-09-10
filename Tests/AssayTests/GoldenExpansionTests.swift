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

    static let shapes: [(name: String, source: String)] = [
        ("plain",
         "@Schema struct S { var a: Int; var b: String?; var c: [Int] = []; var d: Nested }"),
        ("all-formats-snake",
         "@Schema(formats: .all, keys: .snakeCase) struct S { var aB: Int; var c: [String]; var m: [String: Int] }"),
        ("encodes-path-extras",
         #"@Schema(encodes: true) struct S { var a: Int; @Key(path: "p.q") var q: Int; @Key("k", or: "kk") var k: String; @Extras var rest: [String: RawValue] }"#),
        ("rules-checks-async",
         #"@Schema struct S { @Validate(.min(1), .email) var a: String; @Validate(.count(1...3)) var t: [Int]; @Preprocess(.trim) var p: String; @Fallback(0) var f: Int; @Transform({ (a: [String]) in Set(a) }) var s: Set<String>; @Check(\.a) static func f(_ a: String) -> String? { nil }; @AsyncCheck static func g(_ v: S, _ i: inout Issues<S>) async {} }"#),
        ("context",
         "@Schema(context: Ctx.self) struct S { var a: Int; var n: Nested }"),
        ("describes",
         "@Schema(describes: true, unknownKeys: .reject) struct S { @Validate(.min(1)) var a: String; var b: Int? }"),
        ("sources",
         "@Schema(sources: true) struct S { var a: Int; var b: String; var c: Double? }"),
        ("xml-encodes-root",
         #"@Schema(formats: .all, encodes: true, coerceScalars: true) @XML(root: "r") struct S { @XML(.attribute) var id: Int; @XML(.text) var body: String; @XML(.wrapped) var tags: [String] }"#),
        ("dates-inline",
         #"@Schema struct S { struct P { var x: Int; @Key("yy") var y: Int }; @Inline var p: P; var when: Date; @DateFormat(.unixSeconds, .iso8601) var ts: Date }"#),
        ("tagged-union-encodes",
         #"@Schema(keys: .snakeCase, encodes: true, discriminator: "type") enum U { case click(A); @Key("pv") case pageView(B) }"#),
        ("untagged-union",
         "@Schema(discriminator: .untagged) enum U { case text(String); case number(Double); case b(B) }"),
        ("open-enum",
         "@Schema(encodes: true) enum E { case active, suspended; @Unknown(roundTrips: true) case other(String) }"),
        ("one-or-many-narrow",
         "@Schema(formats: .all) struct S { @OneOrMany var tags: [String]; var w: UInt8; var bytes: [UInt8]; @Coerce var n: Int }"),
    ]

    static var goldensDirectory: String {
        "/" + #filePath.split(separator: "/").dropLast().joined(separator: "/") + "/Goldens"
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
