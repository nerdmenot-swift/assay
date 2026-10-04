// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayFoundation
import AssayXML
import AssayYAML

//===----------------------------------------------------------------------===//
// The writers, where no test had been.
//
// `JSONWriter` and `XMLWriter` own their buffers since 2026-09-20: a write is a store into
// raw memory and `grow` is an allocate-copy-free. That reallocation had never run under
// `swift test` — every document the suite encoded fitted the initial capacity — so the one
// piece of unsafe code on the encode path was exercised only by the benchmarks and the
// fuzzer, neither of which is a unit test and neither of which runs on every platform.
//
// Everything here is a ROUND TRIP: encode, parse what was written, require the value back.
// A writer that mis-copied on growth would produce bytes that are usually still valid
// JSON, so "it did not crash" proves nothing and "it parses" proves little.
//===----------------------------------------------------------------------===//

@Schema(coerceScalars: true, formats: .all, encodes: true)
struct WRow: Equatable {
    @XML(.attribute) var id: Int
    var name: String
    var score: Double
}

@Schema(coerceScalars: true, formats: .all, encodes: true)
struct WBig: Equatable {
    var rows: [WRow]
    var blob: String
}

/// Every integer width as an element, and the attribute-legal ones as attributes.
@Schema(coerceScalars: true, formats: .all, encodes: true)
struct WWidths: Equatable {
    @XML(.attribute) var a: Int
    @XML(.attribute) var a64: Int64
    @XML(.attribute) var a32: Int32
    @XML(.attribute) var au: UInt
    @XML(.attribute) var flag: Bool
    var i64: Int64
    var i32: Int32
    var u: UInt
    var i8: Int8
    var i16: Int16
    var u8: UInt8
    var u16: UInt16
    var u32: UInt32
    var u64: UInt64
    var f: Float
}

@Schema(encodes: true)
struct WAny: Equatable {
    var any: JSON.Value
    @Key("quo\"te") var quoted: Int
    @Key("tab\there") var tabbed: String
}

@Schema(coerceScalars: true, formats: .all, encodes: true)
struct WRawXML: Equatable {
    var name: String
    var any: RawValue
}

@Suite("Writers: growth")
struct WriterGrowthTests {

    static let big = WBig(
        rows: (0..<3000).map { WRow(id: $0, name: "row-\($0)-\"quoted\"", score: Double($0) / 8) },
        // Far longer than twice any capacity reached so far, so the `length + n` arm of
        // `max(capacity * 2, length + n)` is the one that decides the new size.
        blob: String(repeating: "abcdefghij", count: 40_000))

    @Test("JSON: a document many times the initial capacity round-trips")
    func json() throws {
        let bytes = try Array(Self.big.encodedJSON())
        #expect(bytes.count > 400_000)
        #expect(try WBig.parse(json: bytes) == Self.big)
    }

    @Test("JSON, pretty: the same document, indented, is the same value")
    func jsonPretty() throws {
        let text = try Self.big.jsonText(pretty: true)
        #expect(text.hasPrefix("{\n  \"rows\": ["))
        #expect(try WBig.parse(json: text) == Self.big)
    }

    @Test("XML: growth, with and without indentation")
    func xml() throws {
        let plain = try Array(Self.big.encodedXML())
        #expect(plain.count > 400_000)
        #expect(try WBig.parse(xml: plain) == Self.big)

        let pretty = try Self.big.xmlText(pretty: true)
        #expect(pretty.contains("\n  <rows id=\"0\">"))
        #expect(try WBig.parse(xml: pretty) == Self.big)
    }

    @Test("a single string larger than the whole buffer")
    func oneHugeString() throws {
        let v = WBig(rows: [], blob: String(repeating: "é\"\\\n", count: 100_000))
        #expect(try WBig.parse(json: Array(v.encodedJSON())) == v)
    }
}

@Suite("Writers: every width")
struct WriterWidthTests {

    static let limits = WWidths(
        a: .min, a64: .max, a32: .min, au: UInt(Int64.max), flag: true,
        i64: .min, i32: .max, u: 0, i8: .min, i16: .min, u8: .max, u16: .max,
        u32: .max, u64: UInt64(Int64.max), f: 1.5)

    @Test("JSON round-trips each width at its limit")
    func json() throws {
        #expect(try WWidths.parse(json: Array(Self.limits.encodedJSON())) == Self.limits)
    }

    @Test("XML round-trips each width, as an element and as an attribute")
    func xml() throws {
        let text = try Self.limits.xmlText()
        #expect(text.contains(#"flag="true""#))
        #expect(text.contains("<i8>-128</i8>"))
        #expect(text.contains("<u32>4294967295</u32>"))
        #expect(try WWidths.parse(xml: text) == Self.limits)
    }

    @Test("YAML round-trips them through the RawValue seam")
    func yaml() throws {
        #expect(try WWidths.parse(yaml: try Self.limits.yamlText()) == Self.limits)
    }
}

@Suite("Writers: value models and awkward keys")
struct WriterValueTests {

    @Test("a JSON.Value field encodes every case, and keys are escaped")
    func jsonValue() throws {
        let any = try JSON.Value.parse(
            #"{"n":null,"b":true,"i":-3,"d":1.5,"s":"x\"y","a":[1,[2],{}],"o":{"k":"v"}}"#)
        let v = WAny(any: any, quoted: 1, tabbed: "t")
        let text = try v.jsonText()
        #expect(text.contains(#""quo\"te":1"#))
        #expect(text.contains(#""tab\there":"t""#))
        #expect(try WAny.parse(json: text) == v)
        // Pretty, too: a key the writer has to escape takes a different route to the colon.
        #expect(try WAny.parse(json: try v.jsonText(pretty: true)) == v)
    }

    @Test("a RawValue field encodes to XML: scalars, a mapping, repeated siblings")
    func rawXML() throws {
        let v = WRawXML(
            name: "n",
            any: .mapping([
                .init(key: "flag", value: .bool(true)),
                .init(key: "count", value: .int(3)),
                .init(key: "ratio", value: .double(0.5)),
                .init(key: "label", value: .string("a<b")),
                .init(key: "empty", value: .null),
                .init(key: "item", value: .sequence([.int(1), .int(2)])),
                .init(key: "inner", value: .mapping([.init(key: "k", value: .string("v"))]))
            ]))
        let text = try v.xmlText()
        #expect(text.contains("<flag>true</flag>"))
        #expect(text.contains("<label>a&lt;b</label>"))
        #expect(text.contains("<empty></empty>") || text.contains("<empty/>"))
        #expect(text.contains("<item>1</item><item>2</item>"))
        #expect(text.contains("<inner><k>v</k></inner>"))
        // XML carries no types, so what comes back is the same TREE with text leaves.
        let back = try WRawXML.parse(xml: text)
        #expect(back.name == "n")
        #expect(back.any["inner"]?["k"]?.string == "v")
        #expect(back.any.all("item").count == 2)
    }
}
