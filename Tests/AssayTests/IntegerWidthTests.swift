// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The narrow fixed-width integers, added 2026-08-31. docs/COMPILE-TIME.md is not the
// point here; correctness at the edges is.
//
// Before this, `Int`, `Int32`, `Int64` and `UInt` were the entire set, so `var b: UInt8`
// did not compile in any `@Schema` type — and with it `[UInt8]`, which is the obvious way
// to carry a blob and the field type the columnar bytes column existed for.
//
// What these tests are actually for is the EDGES. A width is only worth having if it
// rejects what does not fit, on every path, and the interesting values are all ±1 away
// from a boundary that a 64-bit scanner has no opinion about.
//===----------------------------------------------------------------------===//

import Testing
import Assay

@Schema(formats: .all, encodes: true)
struct Widths: Equatable {
    var i8: Int8
    var i16: Int16
    var u8: UInt8
    var u16: UInt16
    var u32: UInt32
    var u64: UInt64
}

@Schema
struct Blob: Equatable {
    var payload: [UInt8]
    var label: String
}

@Suite("Narrow integer widths")
struct IntegerWidthTests {

    static let atLimits = #"""
    {"i8": -128, "i16": -32768, "u8": 255, "u16": 65535,
     "u32": 4294967295, "u64": 9007199254740993}
    """#

    @Test("each width decodes its own extremes")
    func extremes() throws {
        let v = try Widths.parse(json: Array(Self.atLimits.utf8))
        #expect(v.i8 == Int8.min)
        #expect(v.i16 == Int16.min)
        #expect(v.u8 == UInt8.max)
        #expect(v.u16 == UInt16.max)
        #expect(v.u32 == UInt32.max)
        // 2^53 + 1, which is the first integer a Double cannot represent. If any width
        // routed through the floating-point scanner this would come back as 2^53.
        #expect(v.u64 == 9_007_199_254_740_993)
    }

    /// One past each boundary, one field at a time, so a width that silently truncated
    /// would show up as a missing issue rather than as a wrong value somewhere else.
    @Test("one past the boundary is refused, per width")
    func overflowRejected() {
        let cases = [
            ("i8", "128"), ("i8", "-129"),
            ("i16", "32768"), ("i16", "-32769"),
            ("u8", "256"), ("u8", "-1"),
            ("u16", "65536"), ("u16", "-1"),
            ("u32", "4294967296"), ("u32", "-1"),
            ("u64", "-1"),
        ]
        for (field, bad) in cases {
            var fields = ["i8": "0", "i16": "0", "u8": "0",
                          "u16": "0", "u32": "0", "u64": "0"]
            fields[field] = bad
            let body = fields.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
            let d = Widths.diagnose(json: Array("{\(body)}".utf8))
            #expect(!d.isValid, "\(field) = \(bad) should not decode")
            #expect(d.issues.contains { $0.path == [.key(field)] },
                    "the issue should name \(field), got \(d.issues.map(\.path))")
        }
    }

    /// `UInt64` cannot reach its own maximum, and that is inherited rather than new:
    /// `scanInt64` returns `Int64`, so anything above `Int64.max` fails to scan. `UInt` has
    /// had exactly this ceiling since it was added. Pinned so that whoever writes
    /// `scanUInt64` finds a test that goes green rather than one that has to be discovered.
    @Test("UInt64 above Int64.max is refused — the documented ceiling")
    func uint64Ceiling() {
        let d = Widths.diagnose(json: Array(#"""
        {"i8":0,"i16":0,"u8":0,"u16":0,"u32":0,"u64":18446744073709551615}
        """#.utf8))
        #expect(!d.isValid)
        #expect(d.issues.first?.path == [.key("u64")])
    }

    @Test("round-trip through JSON is exact at the extremes")
    func roundTrip() throws {
        let v = try Widths.parse(json: Array(Self.atLimits.utf8))
        let again = try Widths.parse(json: try v.encodedJSON())
        #expect(again == v)
    }

    /// The bug this fix uncovered: `write(_ v: UInt)` reinterpreted the bit pattern
    /// (`Int64(bitPattern:)`) instead of converting, so every unsigned value above
    /// `Int64.max` encoded as a NEGATIVE number — `UInt.max` came out as `-1`. Well-formed
    /// JSON carrying a different value, which is the worst shape an encoder bug can take.
    /// Not reachable by decoding, because the scanner caps input at `Int64.max`; reachable
    /// by any program that builds the value itself and encodes it.
    @Test("an unsigned value above Int64.max encodes as itself, not as a negative")
    func unsignedEncodingIsNotReinterpreted() throws {
        let v = Widths(i8: 0, i16: 0, u8: 0, u16: 0, u32: 0, u64: UInt64.max)
        let text = String(decoding: try v.encodedJSON(), as: UTF8.self)
        #expect(text.contains("18446744073709551615"))
        #expect(!text.contains("-1"))
    }

    @Test("the widths work on the RawValue path too")
    func rawPath() throws {
        let raw = RawValue.mapping([
            .init(key: "i8", value: .int(-128)), .init(key: "i16", value: .int(-32768)),
            .init(key: "u8", value: .int(255)), .init(key: "u16", value: .int(65535)),
            .init(key: "u32", value: .int(4294967295)), .init(key: "u64", value: .int(42)),
        ])
        var sink = IssueSink(limits: .default)
        let v = try #require(Widths._assay(from: raw, into: &sink, at: []))
        #expect(sink.issues.isEmpty)
        #expect(v.u32 == UInt32.max)
        #expect(v.i8 == Int8.min)
    }

    @Test("the RawValue path refuses an out-of-range value rather than truncating")
    func rawOverflow() {
        let raw = RawValue.mapping([
            .init(key: "i8", value: .int(0)), .init(key: "i16", value: .int(0)),
            .init(key: "u8", value: .int(256)), .init(key: "u16", value: .int(0)),
            .init(key: "u32", value: .int(0)), .init(key: "u64", value: .int(0)),
        ])
        var sink = IssueSink(limits: .default)
        #expect(Widths._assay(from: raw, into: &sink, at: []) == nil)
        #expect(sink.issues.first?.path == [.key("u8")])
    }
}

@Suite("[UInt8] as a field type")
struct BlobFieldTests {

    @Test("a byte array decodes from JSON")
    func fromJSON() throws {
        let v = try Blob.parse(json: Array(#"{"payload": [0, 1, 255], "label": "x"}"#.utf8))
        #expect(v.payload == [0, 1, 255])
    }

    /// The element is refused; the path names the FIELD but not the index.
    ///
    /// That is pre-existing and general rather than anything about bytes — `[Int32]` with an
    /// out-of-range element reports `[.key("xs")]` in exactly the same way, and has since
    /// arrays were added. Asserted as it actually behaves rather than as it ought to, so
    /// this test does not quietly start failing when somebody fixes it; the fix belongs with
    /// array codegen, where it would land for every element type at once.
    @Test("an element that does not fit a byte is refused")
    func elementOverflow() {
        let d = Blob.diagnose(json: Array(#"{"payload": [0, 256], "label": "x"}"#.utf8))
        #expect(!d.isValid)
        #expect(d.issues.first?.path == [.key("payload")], "got \(d.issues.map(\.path))")
    }

    @Test("an empty blob is a blob")
    func empty() throws {
        let v = try Blob.parse(json: Array(#"{"payload": [], "label": "x"}"#.utf8))
        #expect(v.payload.isEmpty)
    }
}

@Suite("Validation carets on wide integers")
struct IntegerSpanTests {

    @Schema
    struct Spanned {
        @Validate(.range(0...10)) var wide: Int64
        @Validate(.range(0...10)) var narrow: Int
    }

    /// `decodeInt64` and `decodeInt32` did not call `beginValue()`, so `lastValueSpan` —
    /// which is what the generated code captures for a rule failure — was left pointing at
    /// wherever the previous value ended. For `{"wide": 999, "narrow": 999}` the caret for
    /// `wide` came out as (lo: 0, len: 9): the start of the document, spanning nine bytes
    /// of unrelated text. `Int` was correct all along, which is why it went unnoticed.
    ///
    /// Found 2026-08-31 while adding the narrow widths, because the question "does a new
    /// primitive need beginValue()?" has to be answered before writing eighteen of them.
    @Test("the caret points at the offending value, not at the start of the document")
    func caretsAreCorrect() {
        let json = #"{"wide": 999, "narrow": 999}"#
        let d = Spanned.diagnose(json: Array(json.utf8))
        #expect(d.issues.count == 2)
        for issue in d.issues {
            let span = try? #require(issue.location)
            guard let span else { continue }
            let bytes = Array(json.utf8)
            let text = String(decoding: bytes[Int(span.lo) ..< Int(span.lo) + Int(span.len)],
                              as: UTF8.self)
            #expect(text == "999", "\(issue.path) pointed at \"\(text)\"")
        }
    }
}
