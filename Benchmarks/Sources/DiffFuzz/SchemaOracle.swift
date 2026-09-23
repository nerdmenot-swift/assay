// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// FUZZING THE GENERATED CODE, which nothing did until 2026-09-13.
//
// Every oracle in this tool mutates bytes into a VALUE MODEL — `JSON.Value.decode`,
// `YAML.decodeAll`, `XML.decode`, `TOML.decode`. Those are hand-written parsers and they
// are the right things to fuzz. But they are not where most of Assay's code comes from:
// the `@Schema` expansion is, and a mutated document reaching a generated decode body
// exercises the window dispatch table, the coercion arms, the narrowing integer paths, the
// `@Key(path:)` chain, the unknown-key handling and the rule engine — none of which the
// value models touch.
//
// The finding that motivates this: the audit on 2026-09-12 recorded "the `@Schema` decode
// path is never fuzzed", and it was right. The parsers had found two real bugs by fuzzing
// and the emitter had found none, because nobody had pointed the same gun at it.
//
// THREE LAWS ARE ASSERTED, not just "it did not crash":
//
//   1. `parse` throws if and only if `diagnose` is not valid. Two doors onto the same
//      decision; a document where they disagree is a bug in one of them.
//   2. **`T.validate(try T.parse(json: d))` never reports an issue** — the law
//      `docs/VALIDATE.md` states in so many words. A decoded value that its own schema
//      then rejects means decode-time and validate-time rules have drifted, which is
//      exactly the failure `T.validate(_:)` exists to make impossible.
//   3. A valid diagnosis carries a value and an invalid one carries at least one issue.
//      The empty-issues-but-invalid case is how a truncated issue buffer used to lie.
//
// The type below is deliberately wide rather than realistic. Every field is a different
// arm of the emitter, so a mutation that reaches any of them is a mutation that tests
// generated code nothing else tests.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore
import AssayYAML
import AssayXML
import AssayTOML

/// A nested schema — the `Base._assay(...)` arm, and the one that carries an array of
/// its own so that element paths are exercised at depth.
@Schema(keys: .snakeCase, formats: .all)
struct FuzzInner: Equatable {
    var label: String
    @Validate(.min(1)) var weights: [Double] = []
    var enabled: Bool?
}

/// Every emitter arm that can be reached from one type, on one document.
///
/// Narrow integer widths, a dictionary, an optional, a default, a `@Fallback`, a
/// `@Key(or:)` alias, a `@Key(path:)` chain, an `@Extras` bag under `.collect`, a nested
/// schema, an array of nested schemas, a coerced scalar and a validated string.
@Schema(keys: .snakeCase, unknownKeys: .collect, coerceScalars: true, formats: .all)
struct FuzzWide: Equatable {
    @Validate(.min(1), .max(64)) var name: String
    @Key("id", or: "identifier") var id: Int64
    var small: Int16 = 0
    var unsignedSmall: UInt8 = 0
    var ratio: Double = 0
    @Key(path: "meta.revision") var revision: Int?
    @Fallback(0) var attempts: Int
    var flags: [String] = []
    var lookup: [String: Int] = [:]
    var inner: FuzzInner?
    var children: [FuzzInner] = []
    @Extras var extras: [String: RawValue] = [:]
}

/// One document against one schema, through one door. Returns the number of checks made
/// so the arm can report work rather than just silence.
///
/// A THROW IS NOT A FAILURE HERE. Almost every mutated document is invalid, and being
/// told so precisely is the product. What is a failure is the two doors disagreeing, a
/// decoded value its own schema rejects, or a diagnosis that is neither valid nor
/// carrying an issue.
/// Documents that DO decode, so that law 2 has something to check.
///
/// Without these the arm is decorative: a mutation of an arbitrary corpus file will not
/// produce a document with `name` and `id` in it, so `parse` always throws, so "the value
/// the schema produced is one the schema accepts" is never actually asked. These seeds are
/// valid `FuzzWide` documents in each format; mutating THEM lands on both sides of the
/// verdict, and `schemaAccepted` counts how often the successful side came up.
let schemaSeeds: [(format: String, bytes: [UInt8])] = [
    (
        "json",
        Array(
            """
            {"name":"a","id":7,"small":3,"unsigned_small":9,"ratio":0.5,\
            "meta":{"revision":2},"attempts":1,"flags":["x","y"],"lookup":{"k":1},\
            "inner":{"label":"i","weights":[1.5],"enabled":true},\
            "children":[{"label":"c","weights":[2.5]}],"spare":"extra"}
            """.replacingOccurrences(of: "\\\n", with: "")
                .replacingOccurrences(of: " ", with: "").utf8)
    ),
    (
        "yaml",
        Array(
            """
            name: a
            id: 7
            small: 3
            unsigned_small: 9
            ratio: 0.5
            meta:
              revision: 2
            attempts: 1
            flags: [x, y]
            lookup: {k: 1}
            inner:
              label: i
              weights: [1.5]
              enabled: true
            children:
              - label: c
                weights: [2.5]
            """.utf8)
    ),
    (
        "toml",
        Array(
            """
            name = "a"
            id = 7
            small = 3
            unsigned_small = 9
            ratio = 0.5
            attempts = 1
            flags = ["x", "y"]
            [meta]
            revision = 2
            [lookup]
            k = 1
            [inner]
            label = "i"
            weights = [1.5]
            enabled = true
            """.utf8)
    ),
    (
        "xml",
        Array(
            """
            <root><name>a</name><id>7</id><small>3</small><unsigned_small>9</unsigned_small>\
            <ratio>0.5</ratio><meta><revision>2</revision></meta><attempts>1</attempts>\
            <flags>x</flags><flags>y</flags><inner><label>i</label><weights>1.5</weights>\
            <enabled>true</enabled></inner></root>
            """.replacingOccurrences(of: "\\\n", with: "").utf8)
    )
]

/// How many mutated documents actually decoded. Printed by the arm, because a law that
/// only ever sees failures is a law nothing checks.
nonisolated(unsafe) var schemaAccepted = 0
nonisolated(unsafe) var schemaChecks = 0

@discardableResult
func fuzzSchema(_ bytes: [UInt8], _ format: String) -> Int {
    let limits = Limits(maxIssues: 20, maxDepth: 64, maxBytes: 1 << 20)

    func check<T: Equatable>(
        _ what: String,
        diagnosed: Diagnosis<T>,
        parsed: () throws -> T,
        revalidate: (T) -> Validation
    ) -> Int {
        var threw = false
        var value: T? = nil
        do { value = try parsed() } catch { threw = true }

        // Law 1 — the two doors decide the same thing.
        if threw != !diagnosed.isValid {
            fail(
                "schema fuzz (\(what)): parse \(threw ? "threw" : "returned") but "
                    + "diagnose said \(diagnosed.isValid ? "valid" : "invalid")")
        }
        // Law 3 — a verdict is never empty in either direction.
        if diagnosed.isValid, diagnosed.value == nil {
            fail("schema fuzz (\(what)): valid diagnosis with no value")
        }
        if !diagnosed.isValid, diagnosed.issues.isEmpty {
            fail("schema fuzz (\(what)): invalid diagnosis with no issue")
        }
        schemaChecks += 1
        // Law 2 — the law docs/VALIDATE.md states.
        if let v = value {
            schemaAccepted += 1
            let again = revalidate(v)
            if !again.isValid {
                fail(
                    "schema fuzz (\(what)): parse succeeded, then the same schema "
                        + "rejected its own output: \(again.issues.map(\.code))")
            }
        }
        return 1
    }

    switch format {
    case "json":
        return check(
            "json/wide",
            diagnosed: FuzzWide.diagnose(json: bytes, limits: limits),
            parsed: { try FuzzWide.parse(json: bytes, limits: limits) },
            revalidate: { FuzzWide.diagnose($0, limits: limits) })
            + check(
                "json/inner",
                diagnosed: FuzzInner.diagnose(json: bytes, limits: limits),
                parsed: { try FuzzInner.parse(json: bytes, limits: limits) },
                revalidate: { FuzzInner.diagnose($0, limits: limits) })
    case "yaml":
        return check(
            "yaml/wide",
            diagnosed: FuzzWide.diagnose(yaml: bytes, limits: limits),
            parsed: { try FuzzWide.parse(yaml: bytes, limits: limits) },
            revalidate: { FuzzWide.diagnose($0, limits: limits) })
    case "xml":
        return check(
            "xml/wide",
            diagnosed: FuzzWide.diagnose(xml: bytes, limits: limits),
            parsed: { try FuzzWide.parse(xml: bytes, limits: limits) },
            revalidate: { FuzzWide.diagnose($0, limits: limits) })
    case "toml":
        return check(
            "toml/wide",
            diagnosed: FuzzWide.diagnose(toml: bytes, limits: limits),
            parsed: { try FuzzWide.parse(toml: bytes, limits: limits) },
            revalidate: { FuzzWide.diagnose($0, limits: limits) })
    default:
        return 0
    }
}
