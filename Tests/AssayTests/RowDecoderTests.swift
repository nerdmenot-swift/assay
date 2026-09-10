// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

@Schema(keys: .snakeCase, formats: [], sources: true)
struct RDRow: Equatable {
    var id: Int64
    @Validate(.email) var email: String
    @Fallback(0) var score: Int
}

@Suite("RowDecoder")
struct RowDecoderTests {

    func feed(_ dec: inout RowDecoder<RDRow>, _ id: Int64, _ email: String?, _ score: Int64?) {
        dec.beginRow()
        dec.append(int64: id, column: 0)
        if let e = email { dec.append(string: e, column: 1) } else { dec.appendNull(column: 1) }
        if let s = score { dec.append(int64: s, column: 2) } else { dec.appendNull(column: 2) }
    }

    @Test("rows stream through in batches, and row indices are global")
    func batches() {
        var dec = RowDecoder<RDRow>(columns: ["id", "email", "score"], batchSize: 3)
        var out: [RDRow] = []
        var issues: [AssayCore.Issue] = []
        var warnings: [Warning] = []
        for i in 0..<8 {
            feed(&dec, Int64(i), i == 4 ? "not an email" : "u\(i)@x.io", i == 6 ? nil : Int64(i))
            let full = dec.isFull
            if full {
                let d = dec.flush()
                out += d.values; issues += d.issues; warnings += d.warnings
            }
        }
        let last = dec.finish()
        out += last.values; issues += last.issues; warnings += last.warnings
        #expect(out.map(\.id) == [0, 1, 2, 3, 5, 6, 7])
        #expect(issues.map(\.path) == [[.index(4), .key("email")]])
        #expect(issues.first?.code == .invalidEmail)
        #expect(warnings.map(\.path) == [[.index(6), .key("score")]])
        #expect(out[5].score == 0)
        let offset = dec.rowOffset
        #expect(offset == 8)
    }

    @Test("flush cadence: isFull at batchSize, and a partial batch on finish")
    func cadence() {
        var dec = RowDecoder<RDRow>(columns: ["id", "email", "score"], batchSize: 2)
        feed(&dec, 1, "a@x.io", 1)
        let afterOne = dec.isFull
        #expect(!afterOne)
        feed(&dec, 2, "b@x.io", 2)
        // The second row is still open and counts: the check comes after the row's cells.
        let afterTwo = dec.isFull
        #expect(afterTwo)
        let first = dec.flush()
        #expect(first.values.map(\.id) == [1, 2])
        feed(&dec, 3, "c@x.io", 3)
        let afterThree = dec.isFull
        #expect(!afterThree)
        let second = dec.finish()
        #expect(second.values.map(\.id) == [3])
        let third = dec.finish()
        #expect(third.values.isEmpty)
        let offset = dec.rowOffset
        #expect(offset == 3)
    }

    @Test("positional binding, and a missing required column known before the first row")
    func positionalAndMissing() {
        let ok = RowDecoder<RDRow>(plan: BoundPlan(slots: [0, 1, 2])).missingColumns
        #expect(ok.isEmpty)
        var dec = RowDecoder<RDRow>(columns: ["id", "score"])
        let missing = dec.missingColumns
        #expect(missing == ["email"])
        dec.beginRow(); dec.append(int64: 1, column: 0); dec.append(int64: 1, column: 1)
        let d = dec.finish()
        #expect(d.values.isEmpty)
        #expect(d.issues.map(\.code) == [.missingColumn])
    }

    @Test("limits apply per flush, and truncation is reported per flush")
    func limits() {
        var dec = RowDecoder<RDRow>(columns: ["id", "email", "score"], batchSize: 100,
                                    limits: Limits(maxIssues: 5))
        for i in 0..<50 { feed(&dec, Int64(i), "bad", 0) }
        let d = dec.finish()
        #expect(d.issues.count == 5)
        #expect(d.truncatedIssues)
        #expect(d.issues.last?.path.first == .index(4))
    }

    @Test("metadata survives a flush; rejected cells reset with it")
    func metadata() {
        var dec = RowDecoder<RDRow>(columns: ["id", "email", "score"], batchSize: 1)
        dec.setMetadata(ColumnMetadata(unit: -6), column: 0)
        dec.beginRow(); dec.append(string: "text into id", column: 0)
        let before = dec.rejectedCells
        #expect(before == [1, 0, 0])
        _ = dec.finish()
        let after = dec.rejectedCells
        #expect(after == [0, 0, 0])
    }
}
