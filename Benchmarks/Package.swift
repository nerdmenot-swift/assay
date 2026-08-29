// swift-tools-version: 6.2
// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//
// A separate package, following swift-nio's layout: benchmark tooling and its Foundation
// dependency stay out of the library's own manifest, so `AssayCore` can keep the
// "no Foundation" property that CI enforces.

import PackageDescription

let package = Package(
    name: "AssayBenchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: ".."),
        // Yams wraps libyaml — the C implementation nearly every YAML tool is built on.
        // It is an ORACLE, not a component: it exists so Assay's hand-written parser can
        // be checked against an independent one, and it is confined to this package so
        // the shipping library's dependency graph stays untouched.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // The corpus generator. No dependency on Assay — it must be runnable before the
        // library builds, and it is a published artifact in its own right
        // (docs/PERFORMANCE.md §12.2: "publish the generator, not just the files").
        .executableTarget(
            name: "CorpusGen",
            path: "Sources/CorpusGen",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // yyjson (MIT, ibireme/yyjson) — vendored into the BENCHMARK package only, never
        // the library. It is the fastest general-purpose C DOM parser and one of the two
        // baselines docs/PERFORMANCE.md names as owed. -O3 and the assertion/UTF-8
        // switches match how yyjson's own benchmarks build it, so the comparison is
        // against its intended configuration rather than a hobbled one.
        .target(
            name: "CYYJSON",
            path: "Sources/CYYJSON",
            cSettings: [
                .unsafeFlags(["-O3"]),
                .define("YYJSON_DISABLE_NON_STANDARD", to: "1"),
            ]
        ),
        // A one-function C shim so a struct-returning libc call stays on the C side of the
        // ABI boundary. See CHeapBytes.h — this is a crash fix, not a convenience.
        .target(name: "CHeapBytes", path: "Sources/CHeapBytes"),
        // A KeyedSource in ANOTHER MODULE, to settle whether the generic entry point
        // specialises across a module boundary — which is where every real driver lives.
        .target(
            name: "ForeignSource",
            dependencies: [.product(name: "Assay", package: "assay")],
            path: "Sources/ForeignSource",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The YAML/XML renderers over the JSON corpus, shared by DiffFuzz and AssayBench
        // so the documents the oracles verify and the documents the benchmarks time are
        // the same bytes.
        .target(
            name: "CorpusRender",
            dependencies: [.product(name: "Assay", package: "assay")],
            path: "Sources/CorpusRender",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Differential (vs JSONSerialization) + deterministic fuzz. Lives here rather
        // than in the test target: importing Foundation there would pull swift-testing's
        // _Testing_Foundation overlay, whose macOS 13 floor would raise the LIBRARY's
        // deployment floor for the sake of a test.
        .executableTarget(
            name: "DiffFuzz",
            dependencies: [
                .product(name: "Assay", package: "assay"),
                .product(name: "AssayYAML", package: "assay"),
                .product(name: "AssayXML", package: "assay"),
                // For the Date/UUID column conformances, which cannot be tested in the
                // library's own test target: importing Foundation there pulls
                // swift-testing's _Testing_Foundation overlay and its macOS 13 floor.
                .product(name: "AssayFoundation", package: "assay"),
                .product(name: "Yams", package: "Yams"),
                "CorpusRender",
            ],
            path: "Sources/DiffFuzz",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AssayBench",
            dependencies: [
                .product(name: "Assay", package: "assay"),
                .product(name: "AssayYAML", package: "assay"),
                .product(name: "AssayXML", package: "assay"),
                // The BASELINE for the YAML rows, exactly as it is the oracle for the
                // differential: Yams is what a Swift project would otherwise use.
                .product(name: "Yams", package: "Yams"),
                "CorpusRender",
                "CYYJSON",
                "CHeapBytes",
                "ForeignSource",
            ],
            path: "Sources/AssayBench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
