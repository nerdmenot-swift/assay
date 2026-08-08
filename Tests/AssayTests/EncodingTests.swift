// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Encoding, and the round-trip law. docs/ENCODING.md.
//
// The law, from question 5, is the reason this file exists rather than a handful of
// spot checks:
//
//   For any `v` produced by `parse`, `parse(encode(v))` produces a value equal to `v`,
//   EXCEPT where a @Fallback fired, an @Unknown case was captured without opting in, or
//   unknown keys were dropped by a policy other than .collect.
//
// A law with a closed exception list is testable; "round-trip mostly works" is not. Each
// exception below has its own named case, so the list cannot quietly grow.
//===----------------------------------------------------------------------===//

import Testing
import Assay

@Schema(keys: .snakeCase, encodes: true)
struct EncPayload: Equatable {
    var requestId: String
    var page: Int
    var ratio: Double
    var active: Bool
    var note: String?
    var tags: [String] = []
    var counts: [String: Int] = [:]
    var retries: Int = 3
    var nested: EncItem
    var items: [EncItem] = []
}

@Schema(keys: .snakeCase, encodes: true)
struct EncItem: Equatable {
    var id: String
    var amount: Double
}

@Schema(encodes: true)
struct EncTransformed: Equatable {
    @Transform({ (a: [String]) in Set(a) })
    @Inverse({ (s: Set<String>) in s.sorted() })
    var tags: Set<String>
}

@Schema(unknownKeys: .collect, encodes: true)
struct EncOpen: Equatable {
    var id: String
    @Extras var rest: [String: RawValue]
}

@Schema(encodes: true)
struct EncFallback: Equatable {
    @Fallback(0) var score: Int
}

@Schema(encodes: true)
struct EncFloat: Equatable {
    var value: Double
}

@Suite("Encoding")
struct EncodingTests {

    // MARK: The law

    @Test("round-trip: parse -> encode -> parse is identity")
    func roundTrip() throws {
        let json = """
        {"request_id":"r-1","page":2,"ratio":0.25,"active":true,"note":"hi",
         "tags":["a","b"],"counts":{"x":1,"y":2},"retries":7,
         "nested":{"id":"n","amount":1.5},
         "items":[{"id":"i1","amount":2.5},{"id":"i2","amount":-3}]}
        """
        let original = try EncPayload.parse(json: Array(json.utf8))
        let encoded = try original.encode()
        let again = try EncPayload.parse(json: encoded)
        #expect(again == original, "round-trip must be identity")
    }

    @Test("round-trip is stable — encoding twice produces identical bytes")
    func stable() throws {
        let json = #"{"request_id":"r","page":1,"ratio":1.5,"active":false,"note":null,"tags":["z","a"],"counts":{"b":2,"a":1},"nested":{"id":"n","amount":0}}"#
        let v = try EncPayload.parse(json: Array(json.utf8))
        // Dictionaries have no order, so the encoder sorts keys. Without that the law
        // above would be untestable and diffs would be noise.
        #expect(try v.encode() == v.encode())
        let text = try v.encodedString()
        #expect(text.contains(#""counts":{"a":1,"b":2}"#), "dictionary keys must be sorted")
    }

    @Test("the encoder targets .input — output is what parse accepts")
    func targetsInput() throws {
        // The transformed field decodes from [String] and holds a Set; the encoder must
        // write the ARRAY back, or the output would not re-decode.
        let v = try EncTransformed.parse(json: Array(#"{"tags":["b","a"]}"#.utf8))
        let text = try v.encodedString()
        #expect(text == #"{"tags":["a","b"]}"#, "got \(text)")
        #expect(try EncTransformed.parse(json: v.encode()) == v)
    }

    // MARK: Q6 — defaults and @Extras

    @Test("defaults are always emitted, present or absent in the input")
    func defaultsEmitted() throws {
        let json = #"{"request_id":"r","page":1,"ratio":0,"active":true,"nested":{"id":"n","amount":0}}"#
        let v = try EncPayload.parse(json: Array(json.utf8))
        let text = try v.encodedString()
        // `retries` was absent and defaulted to 3; it is written, so a consumer with a
        // different default reads the same value.
        #expect(text.contains(#""retries":3"#))
        #expect(text.contains(#""tags":[]"#))
        #expect(text.contains(#""counts":{}"#))
        #expect(try EncPayload.parse(json: v.encode()) == v)
    }

    @Test("@Extras are written back, so a decode-edit-encode proxy loses nothing")
    func extrasRoundTrip() throws {
        let json = #"{"id":"x","extra_a":1,"extra_b":{"k":"v"},"extra_c":[1,2]}"#
        let v = try EncOpen.parse(json: Array(json.utf8))
        #expect(v.rest.count == 3)
        let again = try EncOpen.parse(json: v.encode())
        #expect(again == v, "collected keys must survive the round trip")
    }

    @Test("an @Extras key colliding with a declared key is an error, not a duplicate")
    func extrasCollision() {
        let v = EncOpen(id: "x", rest: ["id": .string("shadow")])
        let d = v.diagnoseEncode()
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .extrasKeyCollision })
        #expect(d.issues.first?.message.contains("collides") == true)
    }

    // MARK: Q1 — @Fallback

    @Test("@Fallback writes its value — a documented exception to the law")
    func fallbackWritesValue() throws {
        // Invalid input salvaged to 0. The encoder writes 0, because provenance is a
        // property of the decode and not of the value. The law's exception list names
        // this case explicitly.
        let d = EncFallback.diagnose(json: Array(#"{"score":"nope"}"#.utf8))
        let v = try d.get()
        #expect(v.score == 0)
        #expect(d.warnings.contains { $0.code == .fallbackApplied })
        #expect(try v.encodedString() == #"{"score":0}"#)
        // And the re-parse is clean: the salvage is not repeated, which is exactly why
        // this is an exception rather than a violation.
        let again = EncFallback.diagnose(json: try v.encode())
        #expect(again.warnings.isEmpty)
        #expect(again.value == v)
    }

    // MARK: Q4 — the error channel

    @Test("NaN and infinity are reported with a path, not silently written")
    func unrepresentable() {
        for bad in [Double.nan, .infinity, -.infinity] {
            let d = EncFloat(value: bad).diagnoseEncode()
            #expect(!d.isValid, "\(bad) must be reported")
            let issue = d.issues.first
            #expect(issue?.code == .unrepresentableValue)
            #expect(issue?.path.pathDescription == "value")
            #expect(issue?.message.contains("cannot be represented in JSON") == true)
            // Partial output is still handed back — the point of diagnoseEncode.
            #expect(!d.bytes.isEmpty)
        }
    }

    @Test("encode throws with every issue, and renders through the same renderers")
    func encodeThrows() {
        let v = EncFloat(value: .nan)
        #expect(throws: AssayError.self) { try v.encode() }
        let d = v.diagnoseEncode()
        // The whole point of reusing Issue: the machine renderers work unchanged.
        #expect(d.render(.json).contains("unrepresentable_value"))
        #expect(d.render(.problemDetails).contains("\"status\":422"))
        #expect(d.render(.plain).contains("value cannot be represented"))
    }

    // MARK: Escaping and shape

    @Test("strings are escaped exactly, and survive a round trip")
    func escaping() throws {
        let nasty = "quote\" backslash\\ newline\n tab\t control\u{01} unicode café 😀"
        let v = EncItem(id: nasty, amount: 0)
        let again = try EncItem.parse(json: v.encode())
        #expect(again.id == nasty)
        let text = try v.encodedString()
        #expect(text.contains("\\\""), "quote must be escaped")
        #expect(text.contains("\\n"), "newline must be escaped")
        #expect(text.contains("\\u0001"), "control bytes escape as \\u00XX")
    }

    @Test("optionals write null, and null round-trips to nil")
    func optionals() throws {
        let json = #"{"request_id":"r","page":1,"ratio":0,"active":true,"note":null,"nested":{"id":"n","amount":0}}"#
        let v = try EncPayload.parse(json: Array(json.utf8))
        #expect(v.note == nil)
        #expect(try v.encodedString().contains(#""note":null"#))
        #expect(try EncPayload.parse(json: v.encode()) == v)
    }

    @Test("integers write exactly, including the extremes")
    func integers() throws {
        for n in [0, 1, -1, Int.max, Int.min, 42, -999_999] {
            let v = EncPayload(requestId: "r", page: n, ratio: 0, active: true, note: nil,
                               tags: [], counts: [:], retries: 0,
                               nested: EncItem(id: "n", amount: 0), items: [])
            let again = try EncPayload.parse(json: v.encode())
            #expect(again.page == n, "\(n) did not round-trip")
        }
    }

    @Test("doubles round-trip bit-exactly")
    func doubles() throws {
        for d in [0.0, 1.0, -1.5, 0.1, 1e300, 1e-300, .greatestFiniteMagnitude,
                  .leastNormalMagnitude, 3.141592653589793] {
            let v = EncItem(id: "x", amount: d)
            let again = try EncItem.parse(json: v.encode())
            #expect(again.amount.bitPattern == d.bitPattern,
                    "\(d) round-tripped to \(again.amount)")
        }
    }

    @Test("pretty printing is valid JSON that parses back identically")
    func pretty() throws {
        let json = #"{"request_id":"r","page":1,"ratio":2.5,"active":true,"tags":["a"],"nested":{"id":"n","amount":1}}"#
        let v = try EncPayload.parse(json: Array(json.utf8))
        let text = try v.encodedString(pretty: true)
        #expect(text.contains("\n"))
        #expect(try EncPayload.parse(json: Array(text.utf8)) == v)
    }
}

@Suite("Encoding macro diagnostics")
struct EncodingMacroTests {

    @Test("a @Transform without an @Inverse cannot be encoded, and says so")
    func transformWithoutInverse() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(encodes: true) struct S {
            @Transform({ (a: [String]) in Set(a) }) var tags: Set<String>
        }
        """)
        #expect(diags.contains { $0.contains("@Inverse") && $0.contains("'tags'") })
    }

    @Test("an @Inverse without a @Transform is refused too")
    func inverseWithoutTransform() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(encodes: true) struct S {
            @Inverse({ (s: Set<String>) in Array(s) }) var tags: Set<String>
        }
        """)
        #expect(diags.contains { $0.contains("would never run") })
    }

    @Test("a transform without an inverse is fine when the type does not encode")
    func transformFineWithoutEncoding() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S {
            @Transform({ (a: [String]) in Set(a) }) var tags: Set<String>
        }
        """)
        #expect(diags.isEmpty, "decode-only types must not pay for encode rules")
    }

    @Test("encodes: false emits no encoder — the compile-time budget is why it is opt-in")
    func optInIsReal() {
        let (withOut, _) = expandSchemaForTesting("@Schema struct S { var a: Int }")
        let (withIn, _) = expandSchemaForTesting("@Schema(encodes: true) struct S { var a: Int }")
        #expect(!withOut.contains("_assayEncode"))
        #expect(withIn.contains("_assayEncode"))
        #expect(withIn.contains("JSONEncodableSchema"))
    }
}
