// swift-tools-version: 6.2
// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//
// Deliberate choices, each with a reason in docs/:
//   * No `platforms:` clause — see docs/research/cross-platform-audit.md.
//   * No `.unsafeFlags` anywhere, ever — see CLAUDE.md → hard constraints #10.
//   * No `-enable-library-evolution`.
//   * AssaySIMD is a separate target so the BuiltinModule feature is contained to it.
//   * Format support is separate products so the core has no Foundation dependency.
//
// swift-syntax is pinned to the 603 line, which is the release line matching Swift 6.3.
// This matters beyond ordinary version hygiene: the prebuilt swift-syntax that Swift 6.2+
// ships — the one mitigation for macro build cost in docs/EXPERIENCE.md §13 — only applies
// when the resolved swift-syntax matches the toolchain's. A stale pin silently forfeits it
// and every developer pays a from-source swift-syntax build.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Assay",
    // `platforms:` CONSTRAINS APPLE PLATFORMS ONLY. It sets no floor and imposes no
    // requirement on Linux, Windows, Android or WebAssembly — those are governed entirely
    // by what the toolchain supports. This line is not a statement that Assay is
    // Apple-only; it is the Apple deployment floor and nothing else.
    // (docs/research/cross-platform-audit.md §9.)
    //
    // Two things force the value:
    //   * swift-syntax's SwiftSyntaxMacros/SwiftCompilerPlugin require macOS 10.15, and
    //     `platforms:` is package-wide, so there is no way to scope a floor to the macro
    //     target alone.
    //   * `String(unsafeUninitializedCapacity:)` (SE-0263) requires macOS 11, and it is
    //     the one-copy string construction path in AssayCore/Strings.swift.
    // macOS 11 shipped November 2020, so the practical exclusion is negligible.
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "Assay",     targets: ["Assay"]),
        // Separate products so a JSON-only user never links YAML or XML. Each currently
        // vends its value model; the parsers land later.
        .library(name: "AssayYAML", targets: ["AssayYAML"]),
        .library(name: "AssayXML",  targets: ["AssayXML"]),
        // Data/URL/FileManager conveniences, and parse(mmapped:) for files larger than
        // memory. Foundation-dependent by definition, so it stays out of the core.
        .library(name: "AssayFoundation", targets: ["AssayFoundation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        // The scanner and the reader. No Foundation.
        .target(
            name: "AssayCore",
            swiftSettings: [.strictMemorySafety()]
        ),

        // The macro implementation. Runs at compile time; the hot-path performance rules
        // do not apply to it — but the *compile-time* budget in docs/COMPILE-TIME.md does.
        .macro(
            name: "AssayMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        // The public surface: @Schema, Assayable, parse/diagnose.
        .target(
            name: "Assay",
            dependencies: ["AssayCore", "AssayMacros"]
        ),

        // Foundation-dependent conveniences: mmap-backed parsing for large files.
        .target(
            name: "AssayFoundation",
            dependencies: ["Assay", "AssayCore"],
            swiftSettings: [.strictMemorySafety()]
        ),

        // YAML.Node, the parser, and parse(yaml:) on a @Schema type.
        .target(
            name: "AssayYAML",
            dependencies: ["Assay", "AssayCore"],
            swiftSettings: [.strictMemorySafety()]
        ),

        // XML.Node, the parser, and parse(xml:) on a @Schema type.
        .target(
            name: "AssayXML",
            dependencies: ["Assay", "AssayCore"],
            swiftSettings: [.strictMemorySafety()]
        ),

        .testTarget(
            name: "AssayTests",
            dependencies: [
                "Assay",
                "AssayCore",
                "AssayYAML",
                "AssayXML",
                "AssayFoundation",
                // The macro implementation itself, so its diagnostics and expansions are
                // unit-testable directly — no XCTest-based test-support module needed.
                "AssayMacros",
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                // Deliberately NOT SwiftSyntaxMacrosTestSupport: it is XCTest-based and
                // therefore needs a full Xcode, not just Command Line Tools. The
                // swift-testing equivalent is SwiftSyntaxMacrosGenericTestSupport; add it
                // when expansion-assertion tests are written.
            ]
        ),
    ]
)

// AssaySIMD is deliberately absent until phase 4. Experiments/02-builtin/RESULTS.md
// confirms the BuiltinModule route works and survives versioned dependency resolution,
// so adding it later is additive. Experiments also showed `-Xllvm -mattr=+avx2` does
// nothing, so x86-64 AVX2 will require a C target or nothing at all.
