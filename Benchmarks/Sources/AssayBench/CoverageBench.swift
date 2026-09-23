// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// THE SURFACES THAT SHIPPED WITH NO BENCHMARK ARM.
//
// The audit on 2026-09-12 listed them: plists, the XML→RawValue projection, unions,
// `@Inline`, `@Wraps`. Every one is a feature someone can put on a hot path, and none of
// them had a number that would move if it regressed.
//
// The XML projection is the one that proves the point. It had no arm, and on 2026-09-13 a
// profile found it building the whole member list for a LEAF element and then discarding
// it — the projection was costing more than the parse that produced it, 0.0123 s against
// 0.0030 s over 100,000 leaves, a 4× regression that had shipped and could have stayed.
//
// EVERY NUMBER HERE HAS AN OWNER IN THE SAME RUN, which is the rule the rest of this
// harness follows. Where a competitor exists it is the competitor (Foundation's
// `PropertyListDecoder`); where none does, the owner is the alternative a developer would
// otherwise write — a union against decoding its variant directly, `@Inline` against the
// nested `@Schema` it replaces, `@Wraps` against the plain field plus rule it is sugar for.
// A bare ns/op with nothing beside it is a number nobody can read.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore
import AssayXML
import AssayPlist

// MARK: - Shapes

@Schema(formats: .all) struct CovRows: Equatable { var rows: [CovRow] }
struct CodableCovRows: Codable, Equatable { var rows: [CodableCovRow] }

@Schema(formats: .all) struct CovRow: Equatable {
    var id: Int64
    var name: String
    var score: Double
    var active: Bool
}

struct CodableCovRow: Codable, Equatable {
    var id: Int64
    var name: String
    var score: Double
    var active: Bool
}

// The union, and the variant decoded directly — the same bytes, so the delta is the
// discriminator scan and the rewind, and nothing else.
@Schema struct ClickEvent: Equatable { var x: Int64; var y: Int64; var target: String }
@Schema struct ViewEvent: Equatable { var path: String; var referrer: String }

@Schema(discriminator: "type")
enum CovEvent: Equatable {
    case click(ClickEvent)
    case view(ViewEvent)
}

// `@Inline` against the nesting it replaces. Same wire bytes on the inline side as the
// flattened document; the nested side reads the same fields one level down.
// `@Inline` requires the type to be NESTED — that is what makes key-collision detection
// total at expansion, since a macro cannot see another type's members in any module.
@Schema struct CovInlined: Equatable {
    @Schema struct Page: Equatable { var page: Int64; var perPage: Int64; var total: Int64 }
    var items: [String]
    @Inline var meta: Page
}
@Schema struct CovNested: Equatable {
    @Schema struct Page: Equatable { var page: Int64; var perPage: Int64; var total: Int64 }
    var items: [String]
    var meta: Page
}

// `@Wraps` against the plain field plus the rule it is sugar for. EXPERIENCE.md §8 states
// that these two produce IDENTICAL issues; this is the other half of that claim — that the
// equivalence is not paid for.
@Schema struct CovWrapped: Equatable {
    var email: Email
    var note: String
}
// `@Wraps` is an attribute on a TYPE, not a property: it generates the storage, the
// conformance and the rest.
@Wraps(String.self, .email)
struct Email {}

@Schema struct CovPlain: Equatable {
    @Validate(.email) var email: String
    var note: String
}

// MARK: - The arm

func runCoverageBenchmarks() -> Bool {
    var ok = true
    print("")
    print("Surfaces that had no arm until 2026-09-13 — plists, the XML→RawValue")
    print("projection, unions, @Inline, @Wraps. Each is measured against the thing a")
    print("developer would otherwise write, because a bare ns/op has no reader.")

    // ---- plists, against Foundation ----
    print("")
    print("Property lists — T.parse(plist:) vs Foundation PropertyListDecoder")
    print(
        pad("flavour", 12, right: true) + pad("rows", 7) + pad("bytes", 9)
            + pad("Foundation ns", 15) + pad("Assay ns", 12) + pad("ratio", 9))
    print(String(repeating: "-", count: 64))

    let rows = (0..<200).map {
        CodableCovRow(
            id: Int64($0), name: "name-\($0)", score: Double($0) * 1.5,
            active: $0 % 2 == 0)
    }
    for (flavour, format) in [
        ("binary", PropertyListSerialization.PropertyListFormat.binary),
        ("xml", .xml)
    ] {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = format
        guard let data = try? encoder.encode(CodableCovRows(rows: rows)) else {
            print("  \(flavour): could not encode the fixture"); ok = false; continue
        }
        let bytes = [UInt8](data)
        // Correctness before timing: both sides must produce the same 200 rows.
        guard let mine = try? CovRows.parse(plist: bytes),
            let theirs = try? PropertyListDecoder().decode(CodableCovRows.self, from: data),
            mine.rows.count == theirs.rows.count, mine.rows.count == rows.count,
            mine.rows[7].name == theirs.rows[7].name,
            mine.rows[7].score == theirs.rows[7].score
        else {
            print("  \(flavour): the two decoders disagree — not timed"); ok = false; continue
        }
        let iters = max(200, iterationCount(forBytes: bytes.count) / 4)
        let fNs = measure(iterations: iters) {
            _ = try? PropertyListDecoder().decode(CodableCovRows.self, from: data)
        }
        let aNs = measure(iterations: iters) { _ = try? CovRows.parse(plist: bytes) }
        print(
            pad(flavour, 12, right: true) + pad("\(rows.count)", 7)
                + pad("\(bytes.count)", 9)
                + pad(String(format: "%.0f", fNs), 15)
                + pad(String(format: "%.0f", aNs), 12)
                + pad(String(format: "%.2fx", fNs / aNs), 9))
    }

    // ---- the XML→RawValue projection ----
    //
    // Timed as parse-then-project against parse alone, so the printed number is the
    // PROJECTION and not the parse it rides on. That separation is the whole point: the
    // regression this arm exists for was invisible inside a combined figure.
    print("")
    print("XML → RawValue projection — the step with no arm, and a 4x regression in it")
    print("shipped unnoticed. Parse-and-project against parse alone; the delta is the")
    print("projection.")
    print(
        pad("shape", 14, right: true) + pad("elements", 10) + pad("parse ns", 12)
            + pad("+project ns", 13) + pad("projection", 12))
    print(String(repeating: "-", count: 61))

    for (shape, doc) in [("leaves", xmlLeaves(2_000)), ("nested", xmlNested(2_000))] {
        let bytes = Array(doc.utf8)
        var sink = IssueSink(limits: .default)
        guard let probe = XML.decode(bytes, into: &sink, limits: .default) else {
            print("  \(shape): did not parse"); ok = false; continue
        }
        _ = RawValue(probe.root)
        let iters = 200
        let parseNs = measure(iterations: iters) {
            var s = IssueSink(limits: .default)
            _ = XML.decode(bytes, into: &s, limits: .default)
        }
        let bothNs = measure(iterations: iters) {
            var s = IssueSink(limits: .default)
            guard let d = XML.decode(bytes, into: &s, limits: .default) else { return }
            _ = RawValue(d.root)
        }
        print(
            pad(shape, 14, right: true) + pad("2000", 10)
                + pad(String(format: "%.0f", parseNs), 12)
                + pad(String(format: "%.0f", bothNs), 13)
                + pad(String(format: "%.0f ns", bothNs - parseNs), 12))
    }

    // ---- unions, @Inline, @Wraps: each against its alternative ----
    print("")
    print("Features with no competitor — measured against the alternative a developer")
    print("would otherwise write. A ratio near 1.00x is the claim being made.")
    print(
        pad("feature", 20, right: true) + pad("alternative ns", 16)
            + pad("feature ns", 13) + pad("ratio", 9))
    print(String(repeating: "-", count: 58))

    func compare(
        _ label: String, iterations: Int = 20_000,
        alternative: @escaping () -> Void, feature: @escaping () -> Void
    ) {
        let base = measure(iterations: iterations, alternative)
        let mine = measure(iterations: iterations, feature)
        print(
            pad(label, 20, right: true)
                + pad(String(format: "%.1f", base), 16)
                + pad(String(format: "%.1f", mine), 13)
                + pad(String(format: "%.2fx", mine / base), 9))
    }

    let clickBytes = Array(#"{"type":"click","x":12,"y":40,"target":"buy-button"}"#.utf8)
    let variantBytes = Array(#"{"x":12,"y":40,"target":"buy-button"}"#.utf8)
    guard (try? CovEvent.parse(json: clickBytes)) != nil,
        (try? ClickEvent.parse(json: variantBytes)) != nil
    else {
        print("  union fixture did not decode"); return false
    }
    compare(
        "union vs variant",
        alternative: { _ = try? ClickEvent.parse(json: variantBytes) },
        feature: { _ = try? CovEvent.parse(json: clickBytes) })

    let flatBytes = Array(#"{"items":["a","b"],"page":1,"perPage":50,"total":900}"#.utf8)
    let nestBytes = Array(#"{"items":["a","b"],"meta":{"page":1,"perPage":50,"total":900}}"#.utf8)
    guard (try? CovInlined.parse(json: flatBytes)) != nil,
        (try? CovNested.parse(json: nestBytes)) != nil
    else {
        print("  @Inline fixture did not decode"); return false
    }
    compare(
        "@Inline vs nested",
        alternative: { _ = try? CovNested.parse(json: nestBytes) },
        feature: { _ = try? CovInlined.parse(json: flatBytes) })

    let wrapBytes = Array(#"{"email":"a@example.com","note":"hi"}"#.utf8)
    guard (try? CovWrapped.parse(json: wrapBytes)) != nil,
        (try? CovPlain.parse(json: wrapBytes)) != nil
    else {
        print("  @Wraps fixture did not decode"); return false
    }
    compare(
        "@Wraps vs @Validate",
        alternative: { _ = try? CovPlain.parse(json: wrapBytes) },
        feature: { _ = try? CovWrapped.parse(json: wrapBytes) })

    return ok
}

// MARK: - Fixtures

/// `n` leaf elements under one root — the shape the projection regression lived in.
private func xmlLeaves(_ n: Int) -> String {
    var s = "<root>"
    for i in 0..<n { s += "<item>value-\(i)</item>" }
    return s + "</root>"
}

/// The same element count, two levels deep with attributes, so the non-leaf arm of the
/// projection is exercised too.
private func xmlNested(_ n: Int) -> String {
    var s = "<root>"
    for i in 0..<(n / 2) {
        s += "<pair id=\"\(i)\"><k>key-\(i)</k><v>value-\(i)</v></pair>"
    }
    return s + "</root>"
}
