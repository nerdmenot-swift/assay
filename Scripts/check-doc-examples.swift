#!/usr/bin/env swift
// Compile the Swift examples in the front-door documents.
//
// The website has compiled its examples since 2026-09-11 and that rule has caught five
// bugs. README.md, CLAUDE.md and docs/EXPERIENCE.md compiled nothing, and that is exactly
// where the flagship example rotted: `var published: Date` with `import Assay` alone, in
// three documents, for as long as it had a `Date` in it.
//
// Most blocks are fragments — a field list, an attribute, half a function — so a block
// opts in by being marked ```swift-check instead of ```swift. That keeps the rule honest:
// a block nobody marked is not silently passing.
//
//     swift Scripts/check-doc-examples.swift [--list]
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let documents = ["README.md", "CLAUDE.md", "docs/EXPERIENCE.md",
                 "docs/VALIDATE.md", "docs/ENCODING.md", "docs/UNIONS.md"]

struct Block { let file: String; let line: Int; let body: String; let preamble: String }

var blocks: [Block] = []
for doc in documents {
    let path = root.appendingPathComponent(doc)
    guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
    var inBlock = false
    var start = 0
    var body: [String] = []
    var preamble = ""
    for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = String(raw)
        // An HTML comment renders as nothing, so context the prose leaves implicit — the
        // `data` in `parse(json: data)` — can be supplied without putting noise in the doc.
        if line.hasPrefix("<!-- check-preamble:"), let r = line.range(of: "check-preamble:") {
            preamble = String(line[r.upperBound...])
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespaces)
            continue
        }
        if !inBlock, line.hasPrefix("```swift-check") { inBlock = true; start = i + 1; body = []; continue }
        if inBlock, line.hasPrefix("```") {
            blocks.append(Block(file: doc, line: start,
                                body: body.joined(separator: "\n"), preamble: preamble))
            inBlock = false; preamble = ""; continue
        }
        if inBlock { body.append(line) }
    }
}

if CommandLine.arguments.contains("--list") {
    for b in blocks { print("\(b.file):\(b.line)  \(b.body.split(separator: "\n").count) lines") }
    print("\(blocks.count) checked blocks")
    exit(0)
}

guard !blocks.isEmpty else {
    FileHandle.standardError.write(Data("no ```swift-check blocks found — is the marker right?\n".utf8))
    exit(1)
}

let preamble = """
import Assay
let data = Array("{}".utf8)
_ = data

"""

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("assay-doc-examples-\(getpid())")

// ONE TARGET PER BLOCK. Two documents may legitimately both declare `Article`, and a
// single module would call that a redeclaration error in the reader's face.
var targets: [String] = []
for (n, b) in blocks.enumerated() {
    let stem = b.file.replacingOccurrences(of: "/", with: "_")
                     .replacingOccurrences(of: ".md", with: "")
    let name = "Block\(n)_\(stem)_\(b.line)"
    let dir = tmp.appendingPathComponent("Sources/\(name)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // main.swift, because the flagship example ends in a top-level statement. A
    // library target rejects `let article = try Article.parse(...)` outside a function,
    // and rewriting the block to please the checker would defeat the checker.
    // THE PREAMBLE IS DELIBERATELY NARROW: `import Assay` and the `data` that the
    // flagship example parses from, and nothing else. Injecting `import Foundation`
    // would be the obvious convenience and it would delete the only bug this checker
    // was built to catch — `var published: Date` under `import Assay` alone. A block
    // that needs Foundation, YAML, XML, TOML or plist must import it where the reader
    // can see it, which is what a documented example is for.
    let source = preamble + (b.preamble.isEmpty ? "" : b.preamble + "\n") + b.body + "\n"
    try! source.write(to: dir.appendingPathComponent("main.swift"),
                      atomically: true, encoding: .utf8)
    targets.append("""
            .executableTarget(name: "\(name)", dependencies: [
                .product(name: "Assay", package: "assay"),
                .product(name: "AssayYAML", package: "assay"),
                .product(name: "AssayXML", package: "assay"),
                .product(name: "AssayTOML", package: "assay"),
                .product(name: "AssayPlist", package: "assay"),
                .product(name: "AssayFoundation", package: "assay")])
    """)
}

try! """
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "DocExamples", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "\(root.path)")],
    targets: [
\(targets.joined(separator: ",\n"))
    ])
""".write(to: tmp.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

// REUSE THE ROOT PACKAGE'S RESOLVED VERSIONS. Without this the scratch package resolves
// swift-syntax from scratch on every run, which makes a local correctness check depend on
// GitHub being reachable — it failed exactly that way on 2026-09-13, with 75-second connect
// timeouts. Copying `Package.resolved` pins the versions the repository already uses, so
// the shared cache answers and the network is not consulted.
//
// ONLY WHEN THERE IS ONE. The root `Package.resolved` is git-ignored (a library pins nothing
// for its consumers), so a fresh CI checkout has none, and demanding it made this check fail
// on every CI run from the day it was added: "a resolved file is required when automatic
// dependency resolution is disabled". Offline when a local resolution exists, a normal
// resolve when it does not — CI has the network, and a laptop has the file.
let pinned = (try? FileManager.default.copyItem(
    at: root.appendingPathComponent("Package.resolved"),
    to: tmp.appendingPathComponent("Package.resolved"))) != nil

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = ["swift", "build", "--package-path", tmp.path]
    + (pinned ? ["--only-use-versions-from-resolved-file"] : [])
let pipe = Pipe()
p.standardOutput = pipe
p.standardError = pipe
try! p.run()
let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
p.waitUntilExit()

if p.terminationStatus == 0 {
    print("\(blocks.count) documented examples compile")
    try? FileManager.default.removeItem(at: tmp)
    exit(0)
}
FileHandle.standardError.write(Data(out.utf8))
FileHandle.standardError.write(Data("""

A documented example does not compile. The block is in one of:
\(blocks.map { "  \($0.file):\($0.line)" }.joined(separator: "\n"))
Sources are left under \(tmp.path)/Sources — each directory names its document and line.

""".utf8))
exit(1)
