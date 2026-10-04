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
// Encoding a `Date`, by format — and the type that did not compile.
//
// `WDates` below is the regression test, and it is one by EXISTING: until 2026-10-04 an
// `encodes: true` type holding a `Date` with no `@DateFormat` failed to build with "type
// has no member '__assayDateFormats_2'", an error inside the expansion that names nothing
// the user wrote. The decoder shares `DateFormat.defaultFormats` for such a field and emits
// no per-field static; all three encoders referenced the per-field static regardless.
//
// It went unseen because every encoding fixture that held a date also annotated it, and the
// flagship example — a bare `var published: Date` — does not encode. `iso`, `maybe`, `many`
// and `byName` are the four unannotated shapes: plain, optional, array, dictionary.
//===----------------------------------------------------------------------===//

@Schema(formats: .all, encodes: true)
struct WDates: Equatable {
    @DateFormat(.unixSeconds) var s: Date
    @DateFormat(.unixMillis) var ms: Date
    var iso: Date
    var maybe: Date?
    var many: [Date]
    var byName: [String: Date]
}

@Suite("Encoding dates by format")
struct DateEncodingTests {

    static let v = WDates(
        s: Date(timeIntervalSince1970: 1_700_000_000),
        ms: Date(timeIntervalSince1970: 1_700_000_000.5),
        iso: Date(timeIntervalSince1970: 1_700_000_000),
        maybe: nil,
        many: [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 86_400)],
        byName: ["epoch": Date(timeIntervalSince1970: 0)])

    @Test("JSON writes each field in its own format, and reads it back")
    func json() throws {
        let text = try Self.v.jsonText()
        #expect(text.contains(#""s":1700000000"#))
        #expect(text.contains(#""ms":1700000000500"#))
        #expect(text.contains(#""iso":"2023-11-14T22:13:20Z""#))
        #expect(text.contains(#""many":["1970-01-01T00:00:00Z","1970-01-02T00:00:00Z"]"#))
        #expect(try WDates.parse(json: text) == Self.v)
    }

    @Test("YAML and XML do the same")
    func tree() throws {
        #expect(try WDates.parse(yaml: try Self.v.yamlText()) == Self.v)
        let xml = try Self.v.xmlText()
        #expect(xml.contains("<s>1700000000</s>"))
        #expect(xml.contains("<ms>1700000000500</ms>"))
        #expect(try WDates.parse(xml: xml) == Self.v)
    }

    @Test("a date with no ISO-8601 spelling is reported, not written as something else")
    func nonFinite() {
        var bad = Self.v
        bad.iso = Date(timeIntervalSince1970: .infinity)
        let d = bad.diagnoseEncodeJSON()
        #expect(d.issues.map(\.code) == [.unrepresentableValue])
        #expect(d.issues.first?.path.pathDescription == "iso")
        #expect(String(decoding: d.bytes, as: UTF8.self).contains(#""iso":null"#))
    }
}
