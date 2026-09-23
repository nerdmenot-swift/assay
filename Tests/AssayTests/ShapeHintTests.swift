// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay

//===----------------------------------------------------------------------===//
// Shape memory in the JSON.Value builder (JSONShapeHints, 2026-09-19): each container
// reserves what the previous container at its depth held. It is only a capacity hint, so it
// must never change a VALUE. These documents are chosen to make the hint wrong in every
// direction: large then small, small then large, mixed kinds at one depth, deep and shallow.
//===----------------------------------------------------------------------===//

@Suite("JSON.Value shape memory never changes a value")
struct ShapeHintTests {

    static func roundTrip(_ json: String) throws -> JSON.Value {
        try JSON.Value.parse(Array(json.utf8))
    }

    /// The tree's container structure as text: `[..]` for an array, `{n}` for an object with
    /// n members followed by its values' signatures, `.` for a scalar.
    static func signature(_ v: JSON.Value) -> String {
        switch v {
        case .array(let xs): return "[" + xs.map(signature).joined(separator: ",") + "]"
        case .object(let ms):
            return "{\(ms.count):" + ms.map { signature($0.value) }.joined(separator: ",") + "}"
        default: return "."
        }
    }

    @Test(
        "heterogeneous siblings decode exactly",
        arguments: [
            (
                #"[{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6},{"a":1},{},{"x":1,"y":2}]"#,
                "[{6:.,.,.,.,.,.},{1:.},{0:},{2:.,.}]"
            ),
            (
                #"[[],[1],[1,2,3,4,5,6,7,8,9,10],[1,2],[]]"#,
                "[[],[.],[.,.,.,.,.,.,.,.,.,.],[.,.],[]]"
            ),
            (
                #"[{"a":[1,2,3]},[{"b":1},{"c":2,"d":3}],{"e":{"f":{"g":[[],[1]]}}}]"#,
                "[{1:[.,.,.]},[{1:.},{2:.,.}],{1:{1:{1:[[],[.]]}}}]"
            ),
            (
                #"{"k":[{"a":1,"b":2},{"a":1,"b":2,"c":3}],"m":[{"z":0}]}"#,
                "{2:[{2:.,.},{3:.,.,.}],[{1:.}]}"
            )
        ])
    func heterogeneous(_ json: String, _ expected: String) throws {
        #expect(Self.signature(try Self.roundTrip(json)) == expected)
    }

    @Test("counts are exact after a larger sibling")
    func exactCounts() throws {
        let v = try Self.roundTrip(#"[{"a":1,"b":2,"c":3,"d":4},{"a":1},{"a":1,"b":2}]"#)
        guard case .array(let xs) = v else { Issue.record("not an array"); return }
        let counts = xs.map { v -> Int in
            if case .object(let m) = v { return m.count } else { return -1 }
        }
        #expect(counts == [4, 1, 2])
    }
}
