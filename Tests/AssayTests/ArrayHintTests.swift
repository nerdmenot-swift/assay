// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay

//===----------------------------------------------------------------------===//
// Shape hints in GENERATED code (docs/EFFICIENCY.md row 2). Every array and dictionary a
// `@Schema` body decodes reserves what the last container at the same site held, remembered
// on the `IssueSink` for the length of one parse.
//
// This file replaces `ArrayPrecountTests`, which pinned the structural pre-count that used
// to size arrays of scalars exactly. That pre-count was reverted on 2026-09-20 — it is a
// second pass over the array's bytes, and it cost up to +39.5% on the corpus's long arrays
// while the matrix, whose arrays are ten elements long, reported −18% instructions.
//
// A hint can only be WRONG ABOUT CAPACITY, never about a value, and the documents below make
// it wrong in every direction a document can: shrinking, growing, empty after full, full
// after empty, several sites in one type, nested arrays whose sites differ only by depth, and
// a second parse reusing a sink that a previous parse taught. Every case asserts the decoded
// value, because "capacity only" is the claim being tested.
//===----------------------------------------------------------------------===//

@Schema struct HintRecord: Equatable {
    var tags: [String]
    var sizes: [Int]
}

@Schema struct HintDoc: Equatable {
    var items: [HintRecord]
}

@Schema struct HintNested: Equatable {
    var grid: [[Int]]
    var tally: [String: Int]
}

@Suite("Generated shape hints never change a value")
struct ArrayHintTests {

    /// `n` records whose arrays hold exactly the lengths given, in order.
    ///
    /// Written as statements rather than one `+` chain on purpose: the chain version made
    /// Swift 6.4's type checker give up ("unable to type-check this expression in reasonable
    /// time") while 6.3.3 compiled it, which CI found and this machine could not.
    static func doc(_ lengths: [(Int, Int)]) -> [UInt8] {
        var records: [String] = []
        for (t, s) in lengths {
            let tags: String = (0..<t).map { "\"t\($0)\"" }.joined(separator: ",")
            let sizes: String = (0..<s).map { String($0) }.joined(separator: ",")
            var record: String = "{\"tags\":["
            record += tags
            record += "],\"sizes\":["
            record += sizes
            record += "]}"
            records.append(record)
        }
        var json: String = "{\"items\":["
        json += records.joined(separator: ",")
        json += "]}"
        return Array(json.utf8)
    }

    @Test(
        "arrays that shrink, grow and empty out all decode exactly",
        arguments: [
            [(10, 10), (1, 1), (0, 0), (3, 7)],  // large, small, empty, mixed
            [(0, 0), (0, 0), (25, 4)],  // empty teaches nothing, then a big one
            [(1, 40), (40, 1), (1, 40)],  // the two sites disagree, every record
            [(64, 0), (0, 64)],  // one site full while the other is empty
            [(2, 2)]  // a single record: the hint is unused
        ])
    func lengths(_ shape: [(Int, Int)]) throws {
        let decoded = try HintDoc.parse(json: Self.doc(shape))
        #expect(decoded.items.count == shape.count)
        for (record, expected) in zip(decoded.items, shape) {
            #expect(record.tags == (0..<expected.0).map { "t\($0)" })
            #expect(record.sizes == Array(0..<expected.1))
        }
    }

    @Test("a nested array's site is its depth, so inner and outer never share a hint")
    func nested() throws {
        let json = """
            {"grid":[[1,2,3,4,5],[],[9],[7,7]],"tally":{"a":1,"b":2,"c":3}}
            """
        let v = try HintNested.parse(json: Array(json.utf8))
        #expect(v.grid == [[1, 2, 3, 4, 5], [], [9], [7, 7]])
        #expect(v.tally == ["a": 1, "b": 2, "c": 3])
    }

    @Test("a dictionary's hint is per site too, and a shrinking one keeps its own keys")
    func dictionaries() throws {
        let wide = #"{"grid":[],"tally":{"a":1,"b":2,"c":3,"d":4,"e":5}}"#
        let narrow = #"{"grid":[],"tally":{"z":9}}"#
        #expect(try HintNested.parse(json: Array(wide.utf8)).tally.count == 5)
        #expect(try HintNested.parse(json: Array(narrow.utf8)).tally == ["z": 9])
    }

    @Test("a second parse is unaffected by what the first one held")
    func acrossParses() throws {
        let big = try HintDoc.parse(json: Self.doc([(100, 100)]))
        #expect(big.items[0].tags.count == 100)
        let small = try HintDoc.parse(json: Self.doc([(1, 1), (2, 2)]))
        #expect(small.items.map(\.tags.count) == [1, 2])
        #expect(small.items.map(\.sizes.count) == [1, 2])
    }

    /// A hint reserves capacity for an array whose elements may then fail to arrive, so the
    /// case worth pinning is that the reservation changes nothing about the report: the
    /// document is refused, and with the same issues a document with no hint would produce
    /// (three, for a truncation: the string, the array it was in, and the object).
    @Test("a truncated array after a well-sized one is refused, and reports the same way")
    func malformedAfterHint() {
        let hinted = #"{"items":[{"tags":["a","b","c"],"sizes":[1,2,3]},{"tags":["a","#
        let unhinted = #"{"items":[{"tags":["a","#
        let a = HintDoc.diagnose(json: Array(hinted.utf8))
        let b = HintDoc.diagnose(json: Array(unhinted.utf8))
        #expect(a.value == nil)
        #expect(a.issues.map(\.code) == b.issues.map(\.code))
    }
}
