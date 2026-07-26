//===----------------------------------------------------------------------===//
// Corpus generator driver. Definitions live in Shapes.swift and JSON.swift.
//
// They are in separate files deliberately: Swift initialises globals in a `main.swift`
// in source order and infers their types together, which produced a spurious
// "circular reference" error when the shape table lived alongside the driver.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Driver

var outDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // CorpusGen
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // Benchmarks
    .appendingPathComponent("Corpus/files")

var args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    outDir = URL(fileURLWithPath: args[i + 1])
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var manifestEntries: [String] = []
var lengths: [Int] = []
var positives = 0

for shape in SHAPES {
    for size in SIZES {
        var r = SplitMix64(seed: SEED)
        let doc = shape.build(&r, size)
        let blob = doc.encoded
        let name = "\(shape.name)-\(SIZE_NAMES[size]!).json"
        try Data(blob).write(to: outDir.appendingPathComponent(name))
        doc.collectStringLengths(into: &lengths)
        positives += 1
        manifestEntries.append("""
            {
              "file": "\(name)",
              "shape": "\(shape.name)",
              "target_bytes": \(size),
              "actual_bytes": \(blob.count),
              "kind": "positive",
              "doc": "\(shape.doc)"
            }
        """)
    }
}

for neg in NEGATIVES {
    var r = SplitMix64(seed: SEED)
    let blob = neg.build(&r)
    let name = "neg-\(neg.name).json"
    try Data(blob).write(to: outDir.appendingPathComponent(name))
    manifestEntries.append("""
        {
          "file": "\(name)",
          "shape": "\(neg.name)",
          "target_bytes": 8192,
          "actual_bytes": \(blob.count),
          "kind": "negative",
          "doc": "\(neg.doc)"
        }
    """)
}

// SSO capacity is 15 on 64-bit, 14 on Android arm64, 8 on wasm32 and all 32-bit. Anything
// in the 9-15 band is free on a Mac and a heap allocation on Wasm. No SSO-dependent claim
// ships without this table.
var buckets = ["<=8": 0, "9-14": 0, "15": 0, "16-35": 0, "36+": 0]
for n in lengths {
    switch n {
    case ...8:   buckets["<=8"]! += 1
    case 9...14: buckets["9-14"]! += 1
    case 15:     buckets["15"]! += 1
    case 16...35: buckets["16-35"]! += 1
    default:     buckets["36+"]! += 1
    }
}

let manifest = """
{
  "seed": \(SEED),
  "generator": "Benchmarks/Sources/CorpusGen",
  "note": "Regenerating must be byte-identical; the allocation-count CI gate depends on \
it. Fixed seed, SplitMix64 rather than the stdlib generator, ordered JSON objects, \
hand-formatted doubles. No clock reads.",
  "string_length_histogram": {
    "total_strings": \(lengths.count),
    "buckets": {
      "<=8": \(buckets["<=8"]!),
      "9-14": \(buckets["9-14"]!),
      "15": \(buckets["15"]!),
      "16-35": \(buckets["16-35"]!),
      "36+": \(buckets["36+"]!)
    },
    "why": "SSO capacity is 15 on 64-bit, 14 on Android arm64, 8 on wasm32 and all \
32-bit. No SSO-dependent claim ships without this table."
  },
  "files": [
\(manifestEntries.joined(separator: ",\n"))
  ]
}
"""

try Data(manifest.utf8).write(
    to: outDir.deletingLastPathComponent().appendingPathComponent("manifest.json"))

print("wrote \(positives) positive + \(NEGATIVES.count) negative files to \(outDir.path)")
let band = buckets["9-14"]! + buckets["15"]!
print("string lengths over \(lengths.count) strings: \(buckets)")
print("  9-15 byte band: \(band) (\(band * 100 / max(1, lengths.count))%) "
      + "— free on 64-bit, heap-allocated on wasm32")
