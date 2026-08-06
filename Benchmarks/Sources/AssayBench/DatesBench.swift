// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Date decoding — PERFORMANCE.md §13.2's unclaimed win, claimed or falsified here.
//
// The claim: a hand-written ISO-8601 parser is integer arithmetic (Hinnant's
// days-from-civil), while Foundation's `.iso8601` decoding strategy goes through
// ISO8601DateFormatter — a round trip built for generality. The corpus shape this was
// written for has been waiting since the generator was built: `uuids-and-dates`, "the
// realistic API case".
//
// The documents here are built FROM those corpus files — every date string in each
// file, gathered into one `{"dates": [...]}` array — so the byte distribution is the
// corpus's, not something friendlier. Correctness is gated before timing: every epoch
// must be BIT-IDENTICAL to Foundation's before either side is measured.
//
// This file is also the end-to-end proof against the real Foundation.Date: the unit
// tests use a stub (the test target cannot import Foundation), and this uses the
// genuine article — same generated code, real type.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

@Schema
struct DateList {
    var dates: [Date]
}

struct CodableDateList: Codable {
    var dates: [Date]
}

func runDateBenchmarks(corpusDir: URL, sizes: [String]) {
    print("")
    print("Date decode — @Schema [Date] vs Foundation JSONDecoder(.iso8601)")
    print("Dates gathered from the uuids-and-dates corpus files; epochs gated")
    print("bit-identical against Foundation before timing.")
    print(pad("size", 10, right: true) + pad("dates", 10) + pad("Foundation ns", 15)
          + pad("Assay ns", 13) + pad("ratio", 10))
    print(String(repeating: "-", count: 62))

    var ratios: [Double] = []
    for size in sizes {
        let url = corpusDir.appendingPathComponent("uuids-and-dates-\(size).json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSON.Value.parse([UInt8](data)),
              let members = value.object else { continue }

        // Every ISO-shaped string in the file, in document order.
        let dates = members.compactMap { m -> String? in
            guard let s = m.value.string, s.utf8.count == 20,
                  s.hasSuffix("Z"), s.utf8.contains(UInt8(ascii: "T")) else { return nil }
            return s
        }
        guard !dates.isEmpty else { continue }
        let doc = "{\"dates\":[" + dates.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
        let bytes = Array(doc.utf8)
        let docData = Data(bytes)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let theirs = try? decoder.decode(CodableDateList.self, from: docData),
              let mine = try? DateList.parse(json: bytes) else {
            print(pad(size, 10, right: true) + "   one side failed to decode"); continue
        }
        // Bit-identical epochs, every element. A fast wrong date is not a result.
        precondition(mine.dates.count == theirs.dates.count)
        for (a, b) in zip(mine.dates, theirs.dates) {
            precondition(a.timeIntervalSince1970.bitPattern
                         == b.timeIntervalSince1970.bitPattern,
                         "date mismatch at \(size): \(a) vs \(b)")
        }

        let iters = max(400, iterationCount(forBytes: bytes.count) / 2)
        let fNs = measure(iterations: iters) {
            _ = try? decoder.decode(CodableDateList.self, from: docData)
        }
        let aNs = measure(iterations: iters) { _ = try? DateList.parse(json: bytes) }
        let ratio = fNs / aNs
        ratios.append(ratio)
        print(pad(size, 10, right: true) + pad("\(dates.count)", 10)
              + pad(String(format: "%.0f", fNs), 15)
              + pad(String(format: "%.0f", aNs), 13)
              + pad(String(format: "%.2fx", ratio), 10))
    }
    if !ratios.isEmpty {
        print(String(format: "mean %.2fx over %d sizes",
                     ratios.reduce(0, +) / Double(ratios.count), ratios.count))
        print("Both sides parse the same JSON around the dates; the difference is the")
        print("date path itself — arithmetic vs ISO8601DateFormatter.")
    }
}
