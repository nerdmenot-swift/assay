// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayFoundation
import AssayYAML

//===----------------------------------------------------------------------===//
// The runtime half: `Assayer<T>` leaves, `RawValue` as a value, scalar coercion and dates
// on the tree path.
//
// What these have in common is that the JSON byte path is tested hard and its `RawValue`
// twin was tested through whichever cases a YAML or XML fixture happened to contain. A
// coercion from `"8080"` to an `Int16` on the tree path, a date that arrives as a number
// from YAML, a `.double` assayer handed an integer: each is its own arm, and each was
// reached by nothing.
//===----------------------------------------------------------------------===//

// MARK: - Assayer<T>

@Suite("Assayer leaves and combinators")
struct AssayerLeafTests {

    @Test(".double accepts an integer, because an integer is a valid double")
    func double() throws {
        #expect(try Assayer.double.parse(json: "1.5") == 1.5)
        #expect(try Assayer.double.parse(json: "3") == 3.0)
        #expect(try Assayer.double.parse(.int(4)) == 4.0)
        let d = Assayer.double.diagnose(json: #""x""#)
        #expect(d.issues.map(\.code) == [.typeMismatch])
        #expect(d.issues.first?.params["expected"] == .string("number"))
    }

    @Test(".double carries rules")
    func doubleRules() {
        let ratio = Assayer.double.validate(.range(0.0...1.0))
        #expect(ratio.diagnose(json: "0.5").isValid)
        #expect(ratio.diagnose(json: "2").issues.map(\.code) == [.notInRange])
    }

    @Test(".bool")
    func bool() throws {
        #expect(try Assayer.bool.parse(json: "true") == true)
        #expect(try Assayer.bool.parse(.bool(false)) == false)
        let d = Assayer.bool.diagnose(json: "1")
        #expect(d.issues.map(\.code) == [.typeMismatch])
        #expect(d.issues.first?.params["expected"] == .string("boolean"))
    }

    @Test(".optional(): null is nil, a value is the value, a wrong type is still wrong")
    func optional() throws {
        let maybe = Assayer.string.validate(.min(2)).optional()
        #expect(try maybe.parse(json: "null") == .some(nil))
        #expect(try maybe.parse(json: #""ab""#) == "ab")
        #expect(maybe.diagnose(json: "3").issues.map(\.code) == [.typeMismatch])
        // The rules of the wrapped assayer still run on a present value.
        #expect(maybe.diagnose(json: #""a""#).issues.map(\.code) == [.tooSmall])
    }

    @Test("an object with more than eight fields resolves keys through its index")
    func wideObject() throws {
        // Past eight fields AND eight members the interpreter builds a key index instead
        // of scanning per field. Same answers either way; this is the only test that
        // takes the indexed route.
        let keys = (0..<12).map { "k\($0)" }
        let schema = Assayer.object(
            keys.map { .init($0, .raw) } + [.init("opt", .raw, optional: true)])
        let doc = "{" + keys.reversed().map { "\"\($0)\":\"\($0)\"" }.joined(separator: ",") + "}"
        let value = try schema.parse(json: doc)
        #expect(keys.allSatisfy { value[$0]?.string == $0 })

        let missing = schema.diagnose(json: doc.replacingOccurrences(of: #""k7":"k7","#, with: ""))
        #expect(missing.issues.map(\.code) == [.missing])
        #expect(missing.issues.first?.path.pathDescription == "k7")
    }

    /// The macro refuses `.email` on an `Int` at expansion. `Assayer` composes rules at
    /// run time and cannot: `validate` takes any `Rule`. The engine's answer is that a
    /// rule which has no meaning for the value's type checks nothing — it does not trap
    /// and does not invent an issue. Pinned, because the alternative behaviours are both
    /// worse and nothing said which one this was.
    @Test("a rule that does not apply to the leaf's type checks nothing")
    func inapplicableRule() {
        #expect(Assayer.int.validate(.email, .notEmpty).diagnose(json: "3").isValid)
        #expect(Assayer.double.validate(.email, .unique).diagnose(json: "3.5").isValid)
        #expect(Assayer.string.validate(.positive, .count(1...2)).diagnose(json: #""x""#).isValid)
        #expect(Assayer.bool.validate(.min(1)).diagnose(json: "true").isValid)
    }
}

// MARK: - RawValue as a value

@Suite("RawValue literals and accessors")
struct RawValueLiteralTests {

    @Test("literals build the case they look like")
    func literals() {
        let n: RawValue = nil
        let b: RawValue = true
        let i: RawValue = 7
        let d: RawValue = 1.5
        let s: RawValue = "x"
        let a: RawValue = [1, "two", nil, [true]]
        #expect(n == .null && n.isNull)
        #expect(b == .bool(true))
        #expect(i == .int(7))
        #expect(d == .double(1.5))
        #expect(s == .string("x"))
        #expect(a == .sequence([.int(1), .string("two"), .null, .sequence([.bool(true)])]))
    }

    @Test("accessors answer nil for the wrong case rather than converting")
    func accessors() {
        let a: RawValue = [1, 2]
        #expect(a.sequence?.count == 2)
        #expect(a[1] == .int(2))
        #expect(a[5] == nil)
        #expect(RawValue.string("x").sequence == nil)
        #expect(RawValue.int(1).string == nil)
    }
}

// MARK: - Coercion on the tree path

@Schema(coerceScalars: true, formats: [.yaml])
struct TreeCoerced: Equatable {
    var s: String
    var i: Int
    var i64: Int64
    var i32: Int32
    var u: UInt
    var i8: Int8
    var i16: Int16
    var u8: UInt8
    var u16: UInt16
    var u32: UInt32
    var u64: UInt64
    var b: Bool
}

@Schema(formats: [.yaml])
struct TreeStrict: Equatable {
    var i: Int
    var i64: Int64
    var u: UInt
}

@Schema(unknownKeys: .warn, formats: [.yaml])
struct TreeWarns: Equatable {
    var name: String
    var count: Int
}

@Suite("Scalar coercion from a tree")
struct TreeCoercionTests {

    static func doc(_ overrides: [String: String] = [:]) -> String {
        var fields: [(String, String)] = [
            ("s", "x"), ("i", "1"), ("i64", "1"), ("i32", "1"), ("u", "1"), ("i8", "1"),
            ("i16", "1"), ("u8", "1"), ("u16", "1"), ("u32", "1"), ("u64", "1"), ("b", "true")
        ]
        for n in fields.indices { if let v = overrides[fields[n].0] { fields[n].1 = v } }
        return fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n"
    }

    @Test("a quoted number becomes each integer width")
    func fromStrings() throws {
        let quoted = Dictionary(
            uniqueKeysWithValues: ["i", "i64", "i32", "u", "i8", "i16", "u8", "u16", "u32", "u64"]
                .map { ($0, #""42""#) })
        let v = try TreeCoerced.parse(yaml: Self.doc(quoted))
        #expect(v.i == 42 && v.i64 == 42 && v.i32 == 42 && v.u == 42 && v.i8 == 42)
        #expect(v.i16 == 42 && v.u8 == 42 && v.u16 == 42 && v.u32 == 42 && v.u64 == 42)
    }

    @Test("a number, a float and a boolean become a String")
    func toString() throws {
        #expect(try TreeCoerced.parse(yaml: Self.doc(["s": "12"])).s == "12")
        #expect(try TreeCoerced.parse(yaml: Self.doc(["s": "1.5"])).s == "1.5")
        #expect(try TreeCoerced.parse(yaml: Self.doc(["s": "true"])).s == "true")
    }

    @Test("an exactly integral float converts; a fractional one is a mismatch, not a truncation")
    func fromDoubles() throws {
        #expect(try TreeCoerced.parse(yaml: Self.doc(["i": "8.0"])).i == 8)
        let d = TreeCoerced.diagnose(yaml: Self.doc(["i": "8.5"]))
        #expect(d.issues.map(\.code) == [.typeMismatch])
        #expect(d.issues.first?.path.pathDescription == "i")
    }

    @Test("0 and 1 are booleans under coercion; 2 is not")
    func bools() throws {
        #expect(try TreeCoerced.parse(yaml: Self.doc(["b": "1"])).b == true)
        #expect(try TreeCoerced.parse(yaml: Self.doc(["b": "0"])).b == false)
        #expect(try TreeCoerced.parse(yaml: Self.doc(["b": #""yes""#])).b == true)
        let two = TreeCoerced.diagnose(yaml: Self.doc(["b": "2"]))
        #expect(two.issues.map(\.code) == [.typeMismatch])
    }

    @Test(
        "a coerced value that does not fit its width is refused, per width",
        arguments: [
            ("i32", "2147483648", "integer"), ("u", "-1", "unsigned integer"),
            ("i8", "128", "integer"), ("i16", "40000", "integer"),
            ("u8", "256", "unsigned integer"), ("u16", "70000", "unsigned integer"),
            ("u32", "4294967296", "unsigned integer"), ("u64", "-1", "unsigned integer")
        ])
    func outOfRange(field: String, value: String, expected: String) {
        let d = TreeCoerced.diagnose(yaml: Self.doc([field: "\"\(value)\""]))
        #expect(d.issues.map(\.code) == [.typeMismatch], "\(field)")
        #expect(d.issues.first?.path.pathDescription == field)
        #expect(d.issues.first?.params["expected"] == .string(expected))
    }

    @Test("without coercion a string is not an integer")
    func strict() {
        let d = TreeStrict.diagnose(yaml: "i: \"1\"\ni64: \"1\"\nu: \"1\"\n")
        #expect(d.issues.map(\.path.pathDescription) == ["i", "i64", "u"])
        #expect(d.issues.allSatisfy { $0.code == .typeMismatch })
    }

    @Test("a document that is not a mapping is a mismatch at the root")
    func notAMapping() {
        let d = TreeStrict.diagnose(yaml: "- 1\n- 2\n")
        #expect(d.issues.map(\.code) == [.typeMismatch])
        #expect(d.issues.first?.params["expected"] == .string("object"))
    }

    @Test("unknownKeys: .warn on the tree path warns, with a did-you-mean")
    func unknownKeyWarns() throws {
        let d = TreeWarns.diagnose(yaml: "name: n\ncount: 1\ncuont: 2\n")
        #expect(d.isValid)
        #expect(d.value == TreeWarns(name: "n", count: 1))
        #expect(d.warnings.map(\.code) == [.unknownKey])
        #expect(d.warnings.first?.params["didYouMean"] == .string("count"))
    }
}

// MARK: - Dates on both paths

@Schema(formats: [.json, .yaml])
struct TreeDates: Equatable {
    @DateFormat(.unixSeconds) var at: Date
    @DateFormat(.iso8601, .unixSeconds) var chained: Date
    var iso: Date
    var maybe: Date?
}

@Suite("Dates: numbers, candidate chains and fallbacks")
struct DateDecodePathTests {

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a number reaches .unixSeconds from YAML as from JSON")
    func numeric() throws {
        let json = #"""
            {"at":1700000000,"chained":"2023-11-14T22:13:20Z","iso":"2023-11-14T22:13:20Z"}
            """#
        let yaml = "at: 1700000000\nchained: 2023-11-14T22:13:20Z\niso: 2023-11-14T22:13:20Z\n"
        let want = TreeDates(at: Self.epoch, chained: Self.epoch, iso: Self.epoch, maybe: nil)
        #expect(try TreeDates.parse(json: json) == want)
        #expect(try TreeDates.parse(yaml: yaml) == want)
        // A fractional number of seconds, which YAML resolves to a double.
        let half = try TreeDates.parse(
            yaml: "at: 1700000000.5\nchained: 2023-11-14T22:13:20Z\niso: 2023-11-14T22:13:20Z\n")
        #expect(half.at == Date(timeIntervalSince1970: 1_700_000_000.5))
    }

    @Test("matching a later candidate warns which one matched, on both paths")
    func fallbackWarns() {
        let json = TreeDates.diagnose(
            json: #"{"at":1700000000,"chained":1700000000,"iso":"2023-11-14T22:13:20Z"}"#)
        let yaml = TreeDates.diagnose(
            yaml: "at: 1700000000\nchained: 1700000000\niso: 2023-11-14T22:13:20Z\n")
        for d in [json, yaml] {
            #expect(d.isValid)
            #expect(d.value?.chained == Self.epoch)
            #expect(d.warnings.map(\.code) == [.dateFormatFallback])
            #expect(d.warnings.first?.path.pathDescription == "chained")
            #expect(d.warnings.first?.params["matched"] != d.warnings.first?.params["primary"])
        }
        // A text candidate that is not the first one, too.
        let text = TreeDates.diagnose(
            yaml: "at: 1700000000\nchained: \"1700000000\"\niso: 2023-11-14T22:13:20Z\n")
        #expect(text.warnings.map(\.code) == [.dateFormatFallback])
    }

    @Test("a number offered to a text-only format is invalid_date, saying why")
    func numberForText() {
        let json = TreeDates.diagnose(
            json: #"{"at":1700000000,"chained":"2023-11-14T22:13:20Z","iso":1700000000}"#)
        let yaml = TreeDates.diagnose(
            yaml: "at: 1700000000\nchained: 2023-11-14T22:13:20Z\niso: 1700000000\n")
        for d in [json, yaml] {
            #expect(d.issues.map(\.code) == [.invalidDate])
            #expect(d.issues.first?.path.pathDescription == "iso")
            #expect(d.issues.first?.received == "1700000000")
        }
        #expect(json.issues.first?.message == yaml.issues.first?.message)
    }

    @Test("a value that is neither text nor a number is a mismatch")
    func wrongShape() {
        let json = TreeDates.diagnose(
            json: #"{"at":true,"chained":"2023-11-14T22:13:20Z","iso":"2023-11-14T22:13:20Z"}"#)
        #expect(json.issues.first?.path.pathDescription == "at")
        let yaml = TreeDates.diagnose(
            yaml: "at: [1]\nchained: 2023-11-14T22:13:20Z\niso: 2023-11-14T22:13:20Z\n")
        #expect(yaml.issues.map(\.code) == [.typeMismatch])
        #expect(yaml.issues.first?.params["expected"] == .string("date"))
    }

    @Test("an optional date: null, absent, present, and a truncated string")
    func optional() throws {
        let base = #""at":1700000000,"chained":"2023-11-14T22:13:20Z","iso":"2023-11-14T22:13:20Z""#
        #expect(try TreeDates.parse(json: "{\(base),\"maybe\":null}").maybe == nil)
        let present = try TreeDates.parse(json: "{\(base),\"maybe\":\"2023-11-14T22:13:20Z\"}")
        #expect(present.maybe == Self.epoch)
        let bad = TreeDates.diagnose(json: "{\(base),\"maybe\":\"2023-13-01T00:00:00Z\"}")
        #expect(bad.issues.map(\.code) == [.invalidDate])
        #expect(bad.issues.first?.path.pathDescription == "maybe")
        let cut = TreeDates.diagnose(json: "{\(base),\"maybe\":\"2023")
        #expect(!cut.isValid)
    }
}
