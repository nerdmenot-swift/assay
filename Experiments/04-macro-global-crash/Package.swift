// swift-tools-version: 6.2
import PackageDescription
import CompilerPluginSupport
let package = Package(
    name: "CrashRepro", platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", from: "601.0.0")],
    targets: [
        .macro(name: "Impl", dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax")]),
        .target(name: "Lib", dependencies: ["Impl"]),
        .executableTarget(name: "Run", dependencies: ["Lib"]),
    ])
