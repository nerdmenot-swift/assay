// swift-tools-version: 6.2
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
        .executableTarget(
            name: "AssayBench",
            dependencies: [.product(name: "Assay", package: "assay")],
            path: "Sources/AssayBench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
