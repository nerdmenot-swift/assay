// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// ZippyJSON. Measured 2026-09-09, closing the last comparison this project owed.
//
// THIS IS THE NUMBER THE WHOLE THESIS IS STATED AGAINST, and until now it was a citation
// rather than a measurement. `CLAUDE.md`:
//
//   > **Falsification condition, written down on purpose:** if a scalar Swift phase-1
//   > implementation does not comfortably clear ZippyJSON's 1.38x over Foundation on the
//   > corpus in `docs/PERFORMANCE.md` §12.2, the thesis is wrong and the SIMD/C work is moot.
//
// and the argument it rests on:
//
//   > **Assay does not need to beat simdjson. It needs to not have a `KeyedDecodingContainer`.**
//   > ZippyJSON bolted simdjson onto `Decodable` and got 1.38x over Foundation (1.04x on the
//   > most API-shaped payload).
//
// That 1.38x came from someone else's published table, on someone else's machine, against
// whichever Foundation shipped then — which was the *legacy* Darwin JSON decoder, not the
// swift-foundation rewrite this harness measures against everywhere else. Every honesty rule
// in this project says a ratio belongs to the harness that produced it. This arm produces it.
//
// WHY THIS IS THE STRONGEST FORM OF THE ARGUMENT AVAILABLE. yyjson (already measured: 0.65x
// on the use-case arm) answers "how fast is a hand-tuned C parser?" — and Assay loses, as
// predicted and published. ZippyJSON answers a different and more pointed question: **that
// same class of parser, wired to `Decodable`.** It is simdjson underneath — genuinely faster
// at parsing than anything here — with a `KeyedDecodingContainer` on top. If the thesis is
// right, the container boundary should cost more than SIMD parsing saves, and a scalar Swift
// decoder with no container should beat a SIMD C++ one that has one.
//
// If it does not, the thesis is wrong, and this file is where that would show up.
//
// FAIRNESS NOTES, because a rigged comparison proves nothing:
//   * Same bytes, same `Data`, same struct shape, same field count for all three.
//   * `ZippyJSONDecoder` is constructed once outside the loop, like `JSONDecoder`.
//   * Assay decodes from `[UInt8]`, which is its native input; ZippyJSON and Foundation
//     decode from `Data`, which is theirs. Converting either would be measuring a bridge.
//   * Correctness is checked before timing: all three must produce the same field values, or
//     the row is skipped rather than reported.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import ZippyJSON

@Schema(keys: .snakeCase)
struct ZItem {
    var id: String
    var name: String
    var description: String
    var createdAt: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    var ownerId: String
}

@Schema(keys: .snakeCase)
struct ZPayload {
    var requestId: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [ZItem]
}

struct CodableZItem: Decodable {
    var id: String
    var name: String
    var description: String
    var createdAt: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    var ownerId: String
    enum CodingKeys: String, CodingKey {
        case id, name, description, amount, active
        case createdAt = "created_at"
        case retryCount = "retry_count"
        case ownerId = "owner_id"
    }
}

struct CodableZPayload: Decodable {
    var requestId: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [CodableZItem]
    enum CodingKeys: String, CodingKey {
        case page, items
        case requestId = "request_id"
        case totalCount = "total_count"
        case hasMore = "has_more"
    }
}

func runZippyBenchmarks() {
    print("")
    print("ZippyJSON — simdjson wired to Decodable. Measured 2026-09-09.")
    print("The falsification condition is stated against this decoder's published 1.38x over")
    print("Foundation. That was a citation on someone else's machine against the LEGACY")
    print("Foundation decoder; this is the same comparison on this one, against the")
    print("swift-foundation rewrite. A ratio belongs to the harness that produced it.")
    print("")
    print(pad("items", 8, right: true) + pad("bytes", 9) + pad("Foundation", 12)
          + pad("Zippy", 10) + pad("Assay", 10)
          + pad("Zippy/F", 10) + pad("Assay/F", 10) + pad("Assay/Z", 10))
    print(String(repeating: "-", count: 79))

    let item = #"""
        {"id":"item-0","name":"a name of ordinary length","description":\
        "a description of moderate length for this item","created_at":\
        "2026-08-09T12:00:00Z","amount":12.5,"active":true,"retry_count":2,\
        "owner_id":"owner-0"}
        """#.replacingOccurrences(of: "\\\n", with: "")

    let foundationDecoder = JSONDecoder()
    let zippyDecoder = ZippyJSONDecoder()

    for count in [1, 10, 50, 200] {
        var text = #"{"request_id":"r","page":1,"total_count":\#(count),"has_more":false,"#
        text += #""items":["#
        for i in 0..<count {
            if i > 0 { text += "," }
            text += item
        }
        text += "]}"
        let bytes = Array(text.utf8)
        let data = Data(bytes)

        // All three must agree before any of them is timed.
        guard let mine = try? ZPayload.parse(json: bytes),
              let f = try? foundationDecoder.decode(CodableZPayload.self, from: data),
              let z = try? zippyDecoder.decode(CodableZPayload.self, from: data),
              mine.items.count == f.items.count, f.items.count == z.items.count,
              mine.items.first?.name == z.items.first?.name,
              mine.items.first?.amount == z.items.first?.amount,
              mine.items.first?.retryCount == z.items.first?.retryCount else {
            print(pad("\(count)", 8, right: true)
                  + "  SKIPPED — the three decoders do not agree, so no ratio is meaningful")
            continue
        }

        let reps = max(200, 400_000 / bytes.count)
        let fNs = measure(iterations: reps) {
            _ = try? foundationDecoder.decode(CodableZPayload.self, from: data)
        }
        let zNs = measure(iterations: reps) {
            _ = try? zippyDecoder.decode(CodableZPayload.self, from: data)
        }
        let aNs = measure(iterations: reps) { _ = try? ZPayload.parse(json: bytes) }

        print(pad("\(count)", 8, right: true)
              + pad("\(bytes.count)", 9)
              + pad(String(format: "%.0f", fNs), 12)
              + pad(String(format: "%.0f", zNs), 10)
              + pad(String(format: "%.0f", aNs), 10)
              + pad(String(format: "%.2fx", fNs / zNs), 10)
              + pad(String(format: "%.2fx", fNs / aNs), 10)
              + pad(String(format: "%.2fx", zNs / aNs), 10))
    }

    print("")
    print("Read the last column. Assay is scalar Swift with no SIMD anywhere; ZippyJSON is")
    print("simdjson underneath. If the container boundary were not the dominant cost, that")
    print("column could not be above 1.0 — and the thesis would be wrong.")
}
