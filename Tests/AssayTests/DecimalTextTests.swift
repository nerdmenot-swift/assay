// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayPlist
import AssayYAML

//===----------------------------------------------------------------------===//
// Text that might be a number, and `Double(String)` never being asked first.
//
// The table of refused inputs is the regression test. Every string in it is one that
// `Double(String)` either accepts and no document format means (`0x1p3`, `infinity`), or
// must merely survive: `12e3-4` and its relatives trap inside the standard library on the
// nightly-main toolchain of 2026-10-04. On that toolchain these tests pass only because
// the strings never reach it.
//===----------------------------------------------------------------------===//

@Schema(formats: [.json, .yaml])
struct LooseText: Equatable {
    var id: String
    @Coerce var ratio: Double
}

@Suite("Decimal text: the grammar is checked before the converter is called")
struct DecimalTextTests {

    @Test(
        "decimal floats are accepted",
        arguments: [
            "0", "1", "-1", "+1", "1.5", "1.", ".5", "-.5", "+.5e2", "1e5", "1E5", "1e+5",
            "1e-5", "00012", "0.000", "123e4567", "1e999"
        ])
    func accepted(_ text: String) {
        #expect(_assayIsDecimalFloat(text.utf8), "\(text)")
        #expect(_assayDecimalDouble(text) == Double(text), "\(text)")
    }

    @Test(
        "everything else is refused without being converted",
        arguments: [
            "", "+", "-", ".", "e5", "1e", "1e+", "1.5.2", " 1", "1 ", "1_000",
            // Accepted by `Double(String)`, meant by no document format.
            "0x1p3", "0x10", "inf", "infinity", "nan", "-inf",
            // Exponent digits followed by `-`: the inputs that trap on nightly-main.
            "12e3-4", "5e4567-", "123e4567-e89b", "123e4567-e89b-12d3-a456-426614174000",
            "1e5x", "1-2"
        ])
    func refused(_ text: String) {
        #expect(!_assayIsDecimalFloat(text.utf8), "\(text)")
        #expect(_assayDecimalDouble(text) == nil, "\(text)")
    }

    @Test("the non-finite words are read only when asked for, in any case, signed or not")
    func nonFinite() {
        #expect(_assayDecimalDouble("inf", allowingNonFinite: true) == .infinity)
        #expect(_assayDecimalDouble("+Infinity", allowingNonFinite: true) == .infinity)
        #expect(_assayDecimalDouble("-INF", allowingNonFinite: true) == -.infinity)
        #expect(_assayDecimalDouble("NaN", allowingNonFinite: true)?.isNaN == true)
        #expect(_assayDecimalDouble("0x1p3", allowingNonFinite: true) == nil)
        #expect(_assayDecimalDouble("infinite", allowingNonFinite: true) == nil)
        #expect(_assayDecimalDouble("12e3-4", allowingNonFinite: true) == nil)
    }
}

@Suite("Decimal text: the six doors that used to ask Double(String) first")
struct DecimalTextDoorTests {

    static let uuid = "123e4567-e89b-12d3-a456-426614174000"

    @Test("YAML: a UUID that opens like a float is a string, and a hex float is not a number")
    func yamlResolution() throws {
        let v = try LooseText.parse(yaml: "id: \(Self.uuid)\nratio: 1.5\n")
        #expect(v == LooseText(id: Self.uuid, ratio: 1.5))

        let node = try YAML.parse(Array("a: 12e3-4\nb: 0x1p3\nc: 1e3\nd: 5e4567-\n".utf8))
        #expect(RawValue(node)?["a"] == .string("12e3-4"))
        #expect(RawValue(node)?["b"] == .string("0x1p3"))
        #expect(RawValue(node)?["c"] == .double(1000))
        #expect(RawValue(node)?["d"] == .string("5e4567-"))
        // The node accessor asks the same question and gets the same answer.
        #expect(node["a"]?.resolvedDouble == nil)
        #expect(node["b"]?.resolvedDouble == nil)
        #expect(node["c"]?.resolvedDouble == 1000)
    }

    @Test("YAML encoding: a string that reads as a float is quoted; one that does not is plain")
    func yamlWriter() throws {
        for text in ["1e3", "12e3-4", Self.uuid, "0x1p3", "infinity"] {
            let v = LooseText(id: text, ratio: 0.5)
            let yaml = try encodeYAML(v)
            #expect(try LooseText.parse(yaml: yaml) == v, "\(text): \(yaml)")
        }
    }

    private func encodeYAML(_ v: LooseText) throws -> String {
        // No `encodes:` on the fixture: render the same mapping the encoder would.
        let raw = RawValue.mapping([
            .init(key: "id", value: .string(v.id)), .init(key: "ratio", value: .double(v.ratio))
        ])
        return YAML.encode(raw).text()
    }

    @Test("@Coerce: a string becomes a Double by the same grammar, on both decode paths")
    func coercion() throws {
        #expect(try LooseText.parse(json: #"{"id":"x","ratio":"1e3"}"#).ratio == 1000)
        #expect(try LooseText.parse(json: #"{"id":"x","ratio":"-inf"}"#).ratio == -.infinity)
        #expect(try LooseText.parse(yaml: "id: x\nratio: \"2.5\"\n").ratio == 2.5)
        for bad in ["12e3-4", "0x1p3", "1_000", Self.uuid] {
            let j = LooseText.diagnose(json: "{\"id\":\"x\",\"ratio\":\"\(bad)\"}")
            #expect(j.issues.map(\.code) == [.typeMismatch], "\(bad)")
            let y = LooseText.diagnose(yaml: "id: x\nratio: \"\(bad)\"\n")
            #expect(y.issues.map(\.code) == [.typeMismatch], "\(bad)")
        }
    }

    @Test("a plist <real> is a decimal or a non-finite word, and nothing else")
    func plistReal() {
        func real(_ text: String) -> (RawValue?, [IssueCode]) {
            var sink = IssueSink(limits: .default)
            let doc = "<plist><dict><key>r</key><real>\(text)</real></dict></plist>"
            let v = Plist.decode(Array(doc.utf8), into: &sink, limits: .default)
            return (v?["r"], sink.issues.map(\.code))
        }
        #expect(real("1.5").0 == .double(1.5))
        #expect(real("+infinity").0 == .double(.infinity))
        #expect(real(" 2.5 ").0 == .double(2.5))
        #expect(real("nan").0?.double?.isNaN == true)
        for bad in ["12e3-4", "0x1p3", "abc"] {
            let (v, codes) = real(bad)
            #expect(v == nil && codes.count == 1, "\(bad): \(codes)")
        }
    }
}
