// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Multi-megabyte documents. Measured 2026-09-09, closing a stated verification gap.
//
// `ROADMAP.md`'s table says: *"Outside the target band and unmeasured. The corpus stops at
// 64 kB."* Both halves stay true after this arm — this is here to make the second one false
// without making the first one false, which is a distinction worth being explicit about.
//
// **THIS IS NOT A TARGET BAND, AND THE NUMBERS ARE NOT AN OPTIMISATION GOAL.**
// `docs/PERFORMANCE.md` §14 states plainly that Assay does not claim advantage on
// multi-megabyte documents, and that stands. The corpus is 512 B to 64 kB because that is the
// API-response shape the whole thesis is about. What was missing was not a claim, it was a
// *number*: "unmeasured" and "we do not optimise for it" are different sentences, and only one
// of them was true of both.
//
// WHAT CHANGES AT THIS SIZE, and why measuring it is worth anything at all:
//
//   * The document stops fitting in L2, then in L3. A decoder whose advantage came from
//     staying in cache would lose it here, and one whose advantage is structural would not.
//     That is the actual question this arm answers.
//   * Output allocation was expected to dominate. Ten thousand `String`s go to `malloc`
//     regardless of how they were parsed, so the reasoning was that both decoders converge on
//     the allocator and the ratio must shrink towards 1.0.
//
//     **That prediction was written into this header before the run and it was wrong**, which
//     is recorded rather than quietly edited out. The ratio goes 6.90x -> 6.63x -> 6.60x from
//     0.2 MB to 8.3 MB, and throughput is flat at ~700 MB/s across the whole range. Nothing
//     falls off a cache cliff and the advantage does not wash out.
//
//     The reading that survives: **the advantage is per-VALUE, not per-document.** Foundation's
//     cost scales with the number of decoded values exactly as Assay's does, because
//     `KeyedDecodingContainer` is entered per value — so allocating the same output on both
//     sides cancels rather than converging. That is the decode thesis restated at a size the
//     thesis was not about, and it is a stronger result than the shrinking one would have been.
//   * `Limits.maxBytes` has to be raised explicitly, which is the design working: the default
//     refuses a document this size until a caller says otherwise.
//
// The arm reports throughput in MB/s beside the ratio, because at this size "how long does one
// document take" is not the question anyone is asking.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

@Schema(keys: .snakeCase)
struct BigItem: Decodable {
    var id: String
    var name: String
    var amount: Double
    var active: Bool
    var retryCount: Int
}

@Schema(keys: .snakeCase)
struct BigPayload {
    var requestId: String
    var totalCount: Int
    var items: [BigItem]
}

struct CodableBigItem: Decodable {
    var id: String
    var name: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    enum CodingKeys: String, CodingKey {
        case id, name, amount, active
        case retryCount = "retry_count"
    }
}

struct CodableBigPayload: Decodable {
    var requestId: String
    var totalCount: Int
    var items: [CodableBigItem]
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case totalCount = "total_count"
        case items
    }
}

func runLargeDocumentBenchmarks() {
    print("")
    print("Multi-megabyte documents — measured 2026-09-09, previously an unmeasured gap")
    print("NOT a target band. docs/PERFORMANCE.md §14 says Assay claims no advantage here and")
    print("that still stands; what was missing was a number, not a claim. The prediction in")
    print("this arm's header — that the ratio would shrink towards 1.0 as allocation came to")
    print("dominate both decoders — was wrong. It is flat. See the header for what that means.")
    print("")
    print(pad("items", 10, right: true) + pad("MB", 8) + pad("Foundation", 12)
          + pad("Assay", 10) + pad("ratio", 9) + pad("Assay MB/s", 12))
    print(String(repeating: "-", count: 61))

    for count in [2_000, 20_000, 80_000] {
        var text = #"{"request_id":"req-1","total_count":\#(count),"items":["#
        for i in 0..<count {
            if i > 0 { text += "," }
            text += #"{"id":"item-\#(i)","name":"a name of ordinary length \#(i)",""#
                + #"amount":\#(Double(i) * 1.5),"active":\#(i % 2 == 0),"retry_count":\#(i % 4)}"#
        }
        text += "]}"

        let bytes = Array(text.utf8)
        let data = Data(bytes)
        let mb = Double(bytes.count) / 1_048_576

        // The default `maxBytes` refuses this, which is the design working rather than an
        // obstacle: a caller reading a document this size has said so.
        var limits = Limits.default
        limits.maxBytes = bytes.count + 1

        let decoder = JSONDecoder()
        guard let mine = try? BigPayload.parse(json: bytes, limits: limits),
              let theirs = try? decoder.decode(CodableBigPayload.self, from: data),
              mine.items.count == theirs.items.count else {
            print(pad("\(count)", 10, right: true) + "  SKIPPED — the two decoders disagree")
            continue
        }

        // Few iterations: at 80,000 items one decode is already tens of milliseconds, and the
        // point is throughput rather than a tight distribution.
        let reps = max(3, 40_000_000 / bytes.count)
        let foundation = measure(iterations: reps) {
            _ = try? decoder.decode(CodableBigPayload.self, from: data)
        }
        let assay = measure(iterations: reps) {
            _ = try? BigPayload.parse(json: bytes, limits: limits)
        }

        print(pad("\(count)", 10, right: true)
              + pad(String(format: "%.1f", mb), 8)
              + pad(String(format: "%.1f ms", foundation / 1_000_000), 12)
              + pad(String(format: "%.1f ms", assay / 1_000_000), 10)
              + pad(String(format: "%.2fx", foundation / assay), 9)
              + pad(String(format: "%.0f", mb / (assay / 1_000_000_000)), 12))
    }

    print("")
    print("The 64 kB corpus remains the band the thesis is about. This arm exists so that")
    print("\"we do not optimise for multi-megabyte documents\" is a choice on the record")
    print("rather than a gap nobody had looked into.")
}
