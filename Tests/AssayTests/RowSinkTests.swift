// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

// The write side of the row path: one call per field, in manifest order, no tree.

/// A sink that records what it was handed, as text — what a CSV writer's would be.
struct RecordingSink: RowSink {
    var cells: [(field: Int, text: String)] = []
    mutating func write(int64 v: Int64, _ field: Int) { cells.append((field, "i:\(v)")) }
    mutating func write(double v: Double, _ field: Int) { cells.append((field, "d:\(v)")) }
    mutating func write(bool v: Bool, _ field: Int) { cells.append((field, "b:\(v)")) }
    mutating func write(string v: String, _ field: Int) { cells.append((field, "s:\(v)")) }
    mutating func write(bytes v: UnsafeRawBufferPointer, _ field: Int) { cells.append((field, "x:\(Array(v))")) }
    mutating func writeNull(_ field: Int) { cells.append((field, "null")) }
}

struct Micros: ColumnDecodable, ColumnEncodable, Equatable {
    var value: Int64
    init(_ v: Int64) { value = v }
    init?(assayColumn c: borrowing ColumnBuffer<Int64>, row: Int, metadata: ColumnMetadata) { value = c[row] }
    func assayWrite<S: RowSink & ~Copyable>(into sink: inout S, field: Int) { sink.write(int64: value, field) }
}

@Schema(keys: .snakeCase, formats: [], encodes: true, sources: true)
struct Outbound: Equatable {
    var id: Int64
    var name: String
    var ratio: Float
    var active: Bool
    var small: UInt8
    var blob: [UInt8]
    var nickname: String?
    var at: Micros
    @DateFormat(.unixSeconds) var stamp: Date
    var when: Date
    @Transform({ (s: String) in s.count }) @Inverse({ (n: Int) in String(repeating: "x", count: n) }) var width: Int
}

@Suite("RowSink — the write side")
struct RowSinkTests {

    static let value = Outbound(id: 7, name: "seven", ratio: 0.5, active: true, small: 200, blob: [1, 2],
                                nickname: nil, at: Micros(99), stamp: Date(timeIntervalSince1970: 1_700_000_000),
                                when: Date(timeIntervalSince1970: 1_789_041_600), width: 3)

    @Test("every kind, in manifest order, one call each; nil is writeNull")
    func everyKind() {
        var sink = RecordingSink()
        Self.value.encodeRow(into: &sink)
        #expect(sink.cells.map(\.field) == Array(0..<11))
        #expect(sink.cells.map(\.text) == [
            "i:7", "s:seven", "d:0.5", "b:true", "i:200", "x:[1, 2]", "null", "i:99",
            "d:1700000000.0", "s:2026-09-10T12:00:00Z", "s:xxx",
        ])
        #expect(Outbound._assayManifest.keys == ["id", "name", "ratio", "active", "small", "blob", "nickname", "at", "stamp", "when", "width"])
    }

    @Test("what encodeRow writes, batch(from:) reads back — through a RowBatch as the sink")
    func roundTrip() {
        let plan = BoundPlan(slots: Array(0..<Outbound._assayManifest.fields.count))
        var batch = RowBatch(manifest: Outbound._assayManifest, plan: plan)
        batch.setMetadata(ColumnMetadata(unit: 0), column: 7)
        var second = Self.value
        second.nickname = "n"; second.id = 8
        for v in [Self.value, second] {
            batch.beginRow()
            v.encodeRow(into: &batch)
        }
        batch.finishRow()
        let d = Outbound.batch(from: batch)
        #expect(d.isValid, "\(d.issues)")
        #expect(d.values == [Self.value, second])
    }
}
