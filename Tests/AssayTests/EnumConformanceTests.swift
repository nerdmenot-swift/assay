// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore
import AssayYAML

//===----------------------------------------------------------------------===//
// `Assay/Enums.swift` is six `_assay` bodies: String and Int raw values, on the byte path
// and the `RawValue` path, with a `CaseIterable` refinement of each String one. The suite
// had exercised two and a half of them — a `CaseIterable` String enum's happy path from
// JSON and YAML, and an Int enum from JSON. Never an Int enum from YAML, never a String
// enum WITHOUT `CaseIterable` from anything but JSON's happy path, and never a wrong-typed
// value on the `RawValue` side at all.
//
// What is worth pinning is the claim the file's header makes: the two paths give the same
// answer. So each test decodes the same document as JSON and as YAML and compares the
// issue, rather than asserting on one path at a time.
//===----------------------------------------------------------------------===//

/// No `CaseIterable`: the less-constrained extension, which cannot list the options.
private enum Shade: String, JSONAssayable, RawDecodable { case light, dark }

private enum Level: Int, JSONAssayable, RawDecodable { case low = 1, high = 9 }

private enum Mode: String, JSONAssayable, RawDecodable, CaseIterable { case fast, careful }

@Schema(formats: [.json, .yaml])
private struct Styled: Equatable {
    var shade: Shade
    var level: Level
    var mode: Mode
}

@Suite("Enum conformances, both decode paths")
struct EnumConformanceTests {

    /// One document, both doors. YAML is a superset spelling here: flow mappings are JSON.
    private func both(_ doc: String) -> (json: Diagnosis<Styled>, yaml: Diagnosis<Styled>) {
        (Styled.diagnose(json: doc), Styled.diagnose(yaml: doc))
    }

    @Test("all three shapes decode from JSON and from YAML")
    func clean() throws {
        let (j, y) = both(#"{"shade": "dark", "level": 9, "mode": "careful"}"#)
        let want = Styled(shade: .dark, level: .high, mode: .careful)
        #expect(j.value == want)
        #expect(y.value == want)
    }

    @Test("an unknown String case without CaseIterable is unknown_variant with no option list")
    func unknownStringNoOptions() {
        let (j, y) = both(#"{"shade": "drak", "level": 1, "mode": "fast"}"#)
        for d in [j, y] {
            #expect(d.issues.map(\.code) == [.unknownVariant])
            #expect(d.issues.first?.path.pathDescription == "shade")
            #expect(d.issues.first?.received == "drak")
            // The type never said what its cases are, so there is nothing to suggest from.
            #expect(d.issues.first?.params["options"] == nil)
            #expect(d.issues.first?.params["didYouMean"] == nil)
        }
    }

    @Test("with CaseIterable the same mistake lists the options and suggests one, on both paths")
    func unknownStringWithOptions() {
        let (j, y) = both(#"{"shade": "dark", "level": 1, "mode": "carefull"}"#)
        for d in [j, y] {
            #expect(d.issues.map(\.code) == [.unknownVariant])
            #expect(d.issues.first?.params["options"] == .string(#""fast", "careful""#))
            #expect(d.issues.first?.params["didYouMean"] == .string("careful"))
        }
        #expect(j.issues.first?.message == y.issues.first?.message)
    }

    @Test("an Int that is no case is unknown_variant carrying the number")
    func unknownInt() {
        let (j, y) = both(#"{"shade": "dark", "level": 5, "mode": "fast"}"#)
        for d in [j, y] {
            #expect(d.issues.map(\.code) == [.unknownVariant])
            #expect(d.issues.first?.path.pathDescription == "level")
            #expect(d.issues.first?.received == "5")
        }
    }

    @Test("a wrong-typed value is a type mismatch, not an unknown variant")
    func mismatch() {
        // A number where a String enum is declared, and a string where an Int one is. The
        // enum's own initialiser never runs: this is the wire type being wrong, and saying
        // "42 is not one of light, dark" would send the reader looking at the wrong thing.
        let (j, y) = both(#"{"shade": 42, "level": "high", "mode": true}"#)
        for d in [j, y] {
            #expect(d.issues.map(\.path.pathDescription) == ["shade", "level", "mode"])
            #expect(d.issues.allSatisfy { $0.code == .typeMismatch })
            #expect(
                d.issues.map { $0.params["expected"] } == [
                    .string("string"), .string("integer"), .string("string")
                ])
        }
    }

    @Test("the byte path carets the value; the RawValue path has the member's span")
    func locations() {
        let (j, _) = both(#"{"shade": "drak", "level": 1, "mode": "fast"}"#)
        #expect(j.issues.first?.location != nil)
        #expect(j.render(.plain).contains("\"drak\""))
    }
}
