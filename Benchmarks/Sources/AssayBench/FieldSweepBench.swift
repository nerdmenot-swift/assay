// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// FIELD-COUNT SWEEP — experiment #1's threshold, tested at RUN TIME for the first time.
//
// `Experiments/01-jump-table` read the assembly and found that a switch over a `UInt8`
// candidate index becomes a real arm64 jump table at N >= 10, and a balanced binary search
// tree below it. That is a fact about lowering. Nothing ever checked what it COSTS, because
// every benchmark and every corpus shape in this repository has fewer than ten fields.
//
// Everything is held constant except the field count:
//
//   * key width — always three bytes (`k00`…`k63`), so the 2-vs-3 byte step between `f9`
//     and `f10` that confounded the profiling matrix is gone;
//   * value width — always one byte, so the per-field cost is dominated by FINDING the
//     field rather than reading it, which is what makes this a dispatch measurement;
//   * everything else — flat, minified, no nulls, all present, all `String`.
//
// The counts cluster around the threshold (8, 9, 10, 11, 12) because a discontinuity there
// is the prediction, and spread out afterwards for the trend. They stop at 64 because that
// is `@Schema`'s documented ceiling — which is how the profiling matrix's `fields-100` row
// was caught decoding through a 20-field type and structurally skipping the other 80.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore

@Schema struct F2: Equatable {
    var k00: String
    var k01: String
}
@Schema struct DF2: Equatable { var items: [F2] }

@Schema struct F4: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
}
@Schema struct DF4: Equatable { var items: [F4] }

@Schema struct F6: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
}
@Schema struct DF6: Equatable { var items: [F6] }

@Schema struct F8: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
}
@Schema struct DF8: Equatable { var items: [F8] }

@Schema struct F9: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
}
@Schema struct DF9: Equatable { var items: [F9] }

@Schema struct F10: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
}
@Schema struct DF10: Equatable { var items: [F10] }

@Schema struct F11: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
}
@Schema struct DF11: Equatable { var items: [F11] }

@Schema struct F12: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
    var k11: String
}
@Schema struct DF12: Equatable { var items: [F12] }

@Schema struct F14: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
    var k11: String
    var k12: String
    var k13: String
}
@Schema struct DF14: Equatable { var items: [F14] }

@Schema struct F16: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
    var k11: String
    var k12: String
    var k13: String
    var k14: String
    var k15: String
}
@Schema struct DF16: Equatable { var items: [F16] }

@Schema struct F20: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
    var k11: String
    var k12: String
    var k13: String
    var k14: String
    var k15: String
    var k16: String
    var k17: String
    var k18: String
    var k19: String
}
@Schema struct DF20: Equatable { var items: [F20] }

@Schema struct F24: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
    var k11: String
    var k12: String
    var k13: String
    var k14: String
    var k15: String
    var k16: String
    var k17: String
    var k18: String
    var k19: String
    var k20: String
    var k21: String
    var k22: String
    var k23: String
}
@Schema struct DF24: Equatable { var items: [F24] }

@Schema struct F32: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
    var k11: String
    var k12: String
    var k13: String
    var k14: String
    var k15: String
    var k16: String
    var k17: String
    var k18: String
    var k19: String
    var k20: String
    var k21: String
    var k22: String
    var k23: String
    var k24: String
    var k25: String
    var k26: String
    var k27: String
    var k28: String
    var k29: String
    var k30: String
    var k31: String
}
@Schema struct DF32: Equatable { var items: [F32] }

@Schema struct F48: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
    var k11: String
    var k12: String
    var k13: String
    var k14: String
    var k15: String
    var k16: String
    var k17: String
    var k18: String
    var k19: String
    var k20: String
    var k21: String
    var k22: String
    var k23: String
    var k24: String
    var k25: String
    var k26: String
    var k27: String
    var k28: String
    var k29: String
    var k30: String
    var k31: String
    var k32: String
    var k33: String
    var k34: String
    var k35: String
    var k36: String
    var k37: String
    var k38: String
    var k39: String
    var k40: String
    var k41: String
    var k42: String
    var k43: String
    var k44: String
    var k45: String
    var k46: String
    var k47: String
}
@Schema struct DF48: Equatable { var items: [F48] }

@Schema struct F64: Equatable {
    var k00: String
    var k01: String
    var k02: String
    var k03: String
    var k04: String
    var k05: String
    var k06: String
    var k07: String
    var k08: String
    var k09: String
    var k10: String
    var k11: String
    var k12: String
    var k13: String
    var k14: String
    var k15: String
    var k16: String
    var k17: String
    var k18: String
    var k19: String
    var k20: String
    var k21: String
    var k22: String
    var k23: String
    var k24: String
    var k25: String
    var k26: String
    var k27: String
    var k28: String
    var k29: String
    var k30: String
    var k31: String
    var k32: String
    var k33: String
    var k34: String
    var k35: String
    var k36: String
    var k37: String
    var k38: String
    var k39: String
    var k40: String
    var k41: String
    var k42: String
    var k43: String
    var k44: String
    var k45: String
    var k46: String
    var k47: String
    var k48: String
    var k49: String
    var k50: String
    var k51: String
    var k52: String
    var k53: String
    var k54: String
    var k55: String
    var k56: String
    var k57: String
    var k58: String
    var k59: String
    var k60: String
    var k61: String
    var k62: String
    var k63: String
}
@Schema struct DF64: Equatable { var items: [F64] }

/// (field count, decode) — one row per shape. A function rather than a global so the
/// closures need not be `Sendable`.
func fieldSweepTable() -> [(count: Int, decode: ([UInt8]) -> Int?)] {
    [
        (2, { b in (try? DF2.parse(json: b)).map { $0.items.count } }),
        (4, { b in (try? DF4.parse(json: b)).map { $0.items.count } }),
        (6, { b in (try? DF6.parse(json: b)).map { $0.items.count } }),
        (8, { b in (try? DF8.parse(json: b)).map { $0.items.count } }),
        (9, { b in (try? DF9.parse(json: b)).map { $0.items.count } }),
        (10, { b in (try? DF10.parse(json: b)).map { $0.items.count } }),
        (11, { b in (try? DF11.parse(json: b)).map { $0.items.count } }),
        (12, { b in (try? DF12.parse(json: b)).map { $0.items.count } }),
        (14, { b in (try? DF14.parse(json: b)).map { $0.items.count } }),
        (16, { b in (try? DF16.parse(json: b)).map { $0.items.count } }),
        (20, { b in (try? DF20.parse(json: b)).map { $0.items.count } }),
        (24, { b in (try? DF24.parse(json: b)).map { $0.items.count } }),
        (32, { b in (try? DF32.parse(json: b)).map { $0.items.count } }),
        (48, { b in (try? DF48.parse(json: b)).map { $0.items.count } }),
        (64, { b in (try? DF64.parse(json: b)).map { $0.items.count } }),
    ]
}

/// `{"items":[{"k00":"v",...}, ...]}` with `count` fields per element.
func fieldSweepDocument(_ count: Int, elements: Int) -> [UInt8] {
    var keys: [String] = []
    for i in 0..<count { keys.append("\"k" + (i < 10 ? "0" : "") + String(i) + "\":\"v\"") }
    let element = "{" + keys.joined(separator: ",") + "}"
    return Array(("{\"items\":[" + Array(repeating: element, count: elements)
        .joined(separator: ",") + "]}").utf8)
}

func runFieldSweepBenchmarks() -> Bool {
    let elements = 2_000
    print("")
    print("Field-count sweep - the jump-table threshold, measured rather than read")
    print("Key width (3 bytes) and value width (1 byte) are held constant, so ns/field is")
    print("the cost of FINDING a field. Experiment #1 predicts a balanced search tree below")
    print("10 fields and a real arm64 jump table at 10 and above.")
    print(pad("fields", 8, right: true) + pad("bytes", 9) + pad("ns/elem", 11)
          + pad("ns/field", 11) + pad("MB/s", 9) + "   lowering")
    print(String(repeating: "-", count: 62))

    var ok = true
    var perField: [(Int, Double)] = []
    for (count, decode) in fieldSweepTable() {
        let bytes = fieldSweepDocument(count, elements: elements)
        guard let n = decode(bytes), n == elements else {
            print(pad(String(count), 8, right: true) + "   did not decode"); ok = false; continue
        }
        let iters = max(50, 4_000_000 / bytes.count)
        let ns = measure(iterations: iters) { _ = decode(bytes) }
        let perElement = ns / Double(elements)
        perField.append((count, perElement / Double(count)))
        print(pad(String(count), 8, right: true)
              + pad(String(bytes.count), 9)
              + pad(fmt(perElement, 1), 11)
              + pad(fmt(perElement / Double(count), 2), 11)
              + pad(fmt((Double(bytes.count) / 1e6) / (ns / 1e9), 0), 9)
              + "   " + (count >= 10 ? "jump table" : "search tree"))
    }

    // The prediction under test, stated as a comparison rather than left to the reader.
    if let below = perField.first(where: { $0.0 == 9 })?.1,
       let above = perField.first(where: { $0.0 == 10 })?.1 {
        print("")
        print("9 fields " + fmt(below, 2) + " ns/field -> 10 fields " + fmt(above, 2)
              + " ns/field: " + fmt((above - below) / below * 100, 0) + "%")
        print("Experiment #1's threshold lies between those two rows.")
    }
    return ok
}

private func fmt(_ d: Double, _ places: Int) -> String { String(format: "%.\(places)f", d) }
