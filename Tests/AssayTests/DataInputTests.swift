// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayFoundation

//===----------------------------------------------------------------------===//
// `Data` input (`AssayFoundation/DataParsing.swift`). The overloads decode inside
// `withUnsafeBytes`, so nothing is copied — and the thing to test about a door that skips a
// copy is that it is otherwise INDISTINGUISHABLE from the door that makes one.
//
// So almost every test here is an equality against `parse(json: Array(data))`: same value,
// same issue codes, same params, and — the one that would actually catch a broken
// implementation — the same RENDERED output, because carets need the bytes that this door
// deliberately does not keep unless there is something to render.
//
// The documented asymmetry is tested too, rather than left as prose: on a clean decode
// `Diagnosis.source` is empty, because the caller passed the `Data` in and still holds it.
//===----------------------------------------------------------------------===//

@Schema(unknownKeys: .warn)
struct DataDoor: Equatable {
    var title: String
    var count: Int
}

/// `parse(body:)` needs the `RawValue` projection whatever `accepting:` holds — negotiation
/// picks a parser at run time, which `CapabilityRefusals.swift` explains at length — so the
/// body tests use a type that has it.
@Schema(unknownKeys: .warn, formats: .all)
struct DataBody: Equatable {
    var title: String
    var count: Int
}

@Suite("Data input matches the array door")
struct DataInputTests {

    static let good = #"{"title":"x","count":7}"#
    static let badType = #"{"title":"x","count":"seven"}"#
    static let truncated = #"{"title":"x","count":"#
    static let unknown = #"{"title":"x","count":7,"extra":1}"#

    static func data(_ s: String) -> Data { Data(s.utf8) }
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test("a clean decode produces the same value")
    func cleanValue() throws {
        let fromData = try DataDoor.parse(json: Self.data(Self.good))
        let fromArray = try DataDoor.parse(json: Self.bytes(Self.good))
        #expect(fromData == fromArray)
        #expect(fromData == DataDoor(title: "x", count: 7))
    }

    @Test("issues, params and rendered output are identical", arguments: [
        DataInputTests.badType, DataInputTests.truncated, "", "not json at all", "{",
        #"{"title":"x"}"#,                       // a missing required field
        #"{"title":"x","count":7}extra"#,        // trailing content
    ])
    func failuresMatch(_ document: String) {
        let d = DataDoor.diagnose(json: Self.data(document))
        let a = DataDoor.diagnose(json: Self.bytes(document))
        #expect(d.issues.map(\.code) == a.issues.map(\.code), "codes for \(document)")
        #expect(d.issues.map(\.params) == a.issues.map(\.params), "params for \(document)")
        #expect(d.value == a.value)
        // The one that matters: a caret needs the source bytes, which this door keeps only
        // because the decode was not clean.
        #expect(d.render(.terminal) == a.render(.terminal), "terminal render for \(document)")
        #expect(d.render(.json) == a.render(.json), "json render for \(document)")
        #expect(d.render(.problemDetails) == a.render(.problemDetails))
    }

    @Test("a warning also keeps the bytes, so its render matches too")
    func warningsMatch() {
        let d = DataDoor.diagnose(json: Self.data(Self.unknown))
        let a = DataDoor.diagnose(json: Self.bytes(Self.unknown))
        #expect(!d.warnings.isEmpty)
        #expect(d.warnings.map(\.code) == a.warnings.map(\.code))
        #expect(d.value == a.value)
        #expect(d.render(.terminal) == a.render(.terminal))
        #expect(d.source.count == a.source.count)
    }

    @Test("on a clean decode the source is empty, which is the documented difference")
    func cleanSourceIsEmpty() {
        let d = DataDoor.diagnose(json: Self.data(Self.good))
        #expect(d.isValid)
        #expect(d.warnings.isEmpty)
        #expect(d.source.count == 0)
        // The array door keeps them, and that difference is the whole reason this one is
        // free: `Data`'s bytes are valid only inside `withUnsafeBytes`.
        #expect(DataDoor.diagnose(json: Self.bytes(Self.good)).source.count == Self.good.utf8.count)
    }

    @Test("empty Data reports exactly what an empty array reports")
    func emptyData() {
        let d = DataDoor.diagnose(json: Data())
        let a = DataDoor.diagnose(json: [] as [UInt8])
        #expect(d.issues.map(\.code) == a.issues.map(\.code))
        #expect(d.value == nil)
        #expect(!d.issues.isEmpty, "an empty document is not a silent nil")
    }

    @Test("maxBytes is refused before the buffer is touched, and names the limit")
    func tooManyBytes() {
        let limits = Limits(maxBytes: 8)
        let d = DataDoor.diagnose(json: Self.data(Self.good), limits: limits)
        let a = DataDoor.diagnose(json: Self.bytes(Self.good), limits: limits)
        #expect(d.issues.map(\.code) == [.tooManyBytes])
        #expect(d.issues.map(\.params) == a.issues.map(\.params))
    }

    @Test("invalid UTF-8 is caught at the same offset")
    func invalidUTF8() {
        var raw = Self.bytes(Self.good)
        raw[10] = 0xFF
        let d = DataDoor.diagnose(json: Data(raw))
        let a = DataDoor.diagnose(json: raw)
        #expect(d.issues.map(\.code) == [.invalidUTF8])
        #expect(d.issues.map(\.params) == a.issues.map(\.params))
    }

    @Test("a BOM is skipped, as on the array door")
    func bom() throws {
        let withBOM = [0xEF, 0xBB, 0xBF] as [UInt8] + Self.bytes(Self.good)
        #expect(try DataDoor.parse(json: Data(withBOM)) == DataDoor(title: "x", count: 7))
    }

    @Test("sourceName travels, so a render names the file")
    func sourceName() {
        let d = DataDoor.diagnose(json: Self.data(Self.badType), sourceName: "body.json")
        #expect(d.render(.terminal).contains("body.json"))
    }

    // MARK: The other doors

    @Test("JSON.Value parses from Data")
    func jsonValue() throws {
        let fromData = try JSON.Value.parse(Self.data(Self.good))
        let fromArray = try JSON.Value.parse(Self.bytes(Self.good))
        #expect(fromData == fromArray)
    }

    @Test("the contextual door takes Data too, and still runs its context check")
    func contextual() throws {
        let ctx = TenantContext(availableRoles: ["admin"], maximumSeats: 3)
        let ok = #"{"email":"a@b.com","role":"admin"}"#
        #expect(try Invitation.parse(json: Self.data(ok), context: ctx)
                == Invitation(email: "a@b.com", role: "admin"))

        let refused = #"{"email":"a@b.com","role":"owner"}"#
        let d = Invitation.diagnose(json: Self.data(refused), context: ctx)
        let a = Invitation.diagnose(json: Self.bytes(refused), context: ctx)
        #expect(d.issues.map(\.code) == a.issues.map(\.code))
        #expect(d.render(.terminal) == a.render(.terminal))
    }

    @Test("the async door takes Data, and a failing async check still renders")
    func asyncDoor() async {
        let clean = await AsyncSignup.diagnose(json: Self.data(#"{"email":"free@example.com"}"#))
        #expect(clean.isValid)

        let taken = #"{"email":"taken@example.com"}"#
        let d = await AsyncSignup.diagnose(json: Self.data(taken))
        let a = await AsyncSignup.diagnose(json: Self.bytes(taken))
        #expect(!d.isValid)
        #expect(d.issues.map(\.code) == a.issues.map(\.code))
        // The sync pass was clean, so the bytes were not kept — the async failure has to
        // put them back or this render would have no caret.
        #expect(d.render(.terminal) == a.render(.terminal))
    }

    @Test("Assayer<T> takes Data")
    func assayer() throws {
        let schema = Assayer<RawValue>.object([
            .init("title", .raw),
            .init("count", .raw),
        ])
        let v = try schema.parse(json: Self.data(Self.good))
        #expect(v == (try schema.parse(json: Self.bytes(Self.good))))
    }

    // MARK: An HTTP body

    @Test("a JSON body is negotiated and decoded from Data")
    func jsonBody() throws {
        let v = try DataBody.parse(body: Self.data(Self.good),
                                   contentType: "application/json", accepting: [.json])
        #expect(v == DataBody(title: "x", count: 7))
    }

    @Test("an unacceptable media type is refused without entering a parser")
    func refusedMediaType() {
        let d = DataBody.diagnose(body: Self.data("<a/>"),
                                  contentType: "application/xml", accepting: [.json])
        #expect(d.issues.map(\.code) == [.unsupportedMediaType])
        #expect(d.value == nil)
    }

    @Test("a body whose type mismatches reports as the array door does")
    func bodyFailureMatches() {
        let d = DataBody.diagnose(body: Self.data(Self.badType),
                                  contentType: "application/json", accepting: [.json])
        let a = DataBody.diagnose(body: Self.bytes(Self.badType),
                                  contentType: "application/json", accepting: [.json])
        #expect(d.issues.map(\.code) == a.issues.map(\.code))
        #expect(d.render(.terminal) == a.render(.terminal))
    }
}
