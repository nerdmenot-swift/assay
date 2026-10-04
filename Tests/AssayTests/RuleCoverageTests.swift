// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

//===----------------------------------------------------------------------===//
// Rule overloads nobody had called.
//
// `Rule` has two spellings of most constructors — the bare `static let` and an `or:` form
// that carries a message — and a `Double` twin of each numeric one. `ValidateTests` uses
// the bare forms and `.min(3, or:)`; the rest of the `or:` column and every `Double`
// overload had no caller in the suite. They are one line each, which is the argument for
// a table rather than against testing them: the mistake a one-liner makes is passing the
// wrong `Kind`, and only a failing value with the right code shows that.
//
// The same goes for the array overloads. `.each` over `[Int]` and `[Double]` were rewritten
// on 2026-09-20 to build one path per field instead of one per element; `.min`/`.max` as an
// ELEMENT COUNT has its own arm. Neither had run under test.
//===----------------------------------------------------------------------===//

@Schema
struct RuleMessages {
    @Validate(.min(1.5, or: "min-d")) var a: Double
    @Validate(.max(2.5, or: "max-d")) var b: Double
    @Validate(.range(0.0...1.0, or: "range-d")) var c: Double
    @Validate(.notEmpty(or: "not-empty")) var d: String
    @Validate(.email(or: "email")) var e: String
    @Validate(.url(or: "url")) var f: String
    @Validate(.uuid(or: "uuid")) var g: String
    @Validate(.hostname(or: "hostname")) var h: String
    @Validate(.ascii(or: "ascii")) var i: String
    @Validate(.multipleOf(0.25, or: "multiple-d")) var j: Double
    @Validate(.isTrimmed(or: "trimmed")) var k: String
    @Validate(.isLowercase(or: "lowercase")) var l: String
    @Validate(.positive(or: "positive")) var m: Int
    @Validate(.negative(or: "negative")) var n: Int
    @Validate(.nonNegative(or: "non-negative")) var o: Int
    @Validate(.length(3, or: "length")) var p: String
    @Validate(.oneOf(["x", "y"], or: "one-of")) var q: String
    @Validate(
        .prefix("a", or: "prefix"), .suffix("z", or: "suffix"),
        .contains("m", or: "contains"))
    var r: String
    @Validate(.range(1...5, or: "range-i")) var s: UInt64
}

@Schema
struct RuleCollections {
    @Validate(.min(2), .max(3)) var names: [String]
    @Validate(.each(.range(1...9)), .unique(or: "dupes")) var ints: [Int]
    @Validate(.each(.max(1.0), or: "ratio too big"), .count(2, or: "two")) var ratios: [Double]
    @Validate(.notEmpty, .max(2)) var flags: [Bool]
}

@Suite("Rules: every or: overload, every element type")
struct RuleCoverageTests {

    @Test("each or: form reports its own message, under its own code")
    func messages() {
        let doc = #"""
            {"a": 1.0, "b": 3.0, "c": 2.0, "d": "", "e": "x", "f": "x", "g": "x",
             "h": "-bad-", "i": "é", "j": 0.3, "k": " x", "l": "X", "m": 0, "n": 0, "o": -1,
             "p": "ab", "q": "z", "r": "q", "s": 9}
            """#
        let d = RuleMessages.diagnose(json: doc)
        let got = Dictionary(
            d.issues.map { ($0.path.pathDescription + ":" + $0.message, $0.code) },
            uniquingKeysWith: { a, _ in a })
        let want: [(String, IssueCode)] = [
            ("a:min-d", .tooSmall), ("b:max-d", .tooLarge), ("c:range-d", .notInRange),
            ("d:not-empty", .empty), ("e:email", .invalidEmail), ("f:url", .invalidUrl),
            ("g:uuid", .invalidUuid), ("h:hostname", .invalidHostname), ("i:ascii", .notAscii),
            ("j:multiple-d", .notMultiple), ("k:trimmed", .notTrimmed),
            ("l:lowercase", .notLowercased), ("m:positive", .notPositive),
            ("n:negative", .notNegative), ("o:non-negative", .negative),
            ("p:length", .wrongLength), ("q:one-of", .notOneOf), ("r:prefix", .missingPrefix),
            ("r:suffix", .missingSuffix), ("r:contains", .missingSubstring),
            ("s:range-i", .notInRange)
        ]
        for (key, code) in want {
            #expect(got[key] == code, "\(key): got \(String(describing: got[key]))")
        }
        let all = d.issues.map { "\($0.path.pathDescription):\($0.message)" }
        #expect(d.issues.count == want.count, "\(all)")
    }

    @Test("a value that satisfies every rule reports nothing")
    func clean() throws {
        let doc = #"""
            {"a": 1.5, "b": 2.5, "c": 0.5, "d": "x", "e": "a@b.co", "f": "https://a.co/",
             "g": "123e4567-e89b-12d3-a456-426614174000", "h": "a.co", "i": "x", "j": 0.75,
             "k": "x", "l": "x", "m": 1, "n": -1, "o": 0, "p": "abc", "q": "x", "r": "amz",
             "s": 5}
            """#
        #expect(RuleMessages.diagnose(json: doc).issues.isEmpty)
    }

    @Test(".min and .max on an array count elements, and say so")
    func countRules() {
        let few = RuleCollections.diagnose(
            json: #"{"names":["a"],"ints":[1],"ratios":[0.1,0.2],"flags":[true]}"#)
        #expect(few.issues.map(\.code) == [.tooSmall])
        #expect(few.issues.first?.params["unit"] == .string("items"))
        #expect(few.issues.first?.params["minimum"] == .int(2))
        #expect(few.issues.first?.received == "1 items")

        let many = RuleCollections.diagnose(
            json: #"{"names":["a","b","c","d"],"ints":[1],"ratios":[0.1,0.2],"flags":[true]}"#)
        #expect(many.issues.map(\.code) == [.tooLarge])
        #expect(many.issues.first?.params["maximum"] == .int(3))
    }

    @Test(".each over [Int] and [Double] names the element, with the each's message")
    func eachNumeric() {
        let d = RuleCollections.diagnose(
            json: #"{"names":["a","b"],"ints":[1,10,3,0],"ratios":[0.5,1.5],"flags":[true]}"#)
        #expect(d.issues.map(\.path.pathDescription) == ["ints[1]", "ints[3]", "ratios[1]"])
        #expect(d.issues.map(\.code) == [.notInRange, .notInRange, .tooLarge])
        #expect(d.issues.last?.message == "ratio too big")
    }

    @Test(".unique, .count and .notEmpty on numeric and generic arrays")
    func uniqueAndCount() {
        let d = RuleCollections.diagnose(
            json: #"{"names":["a","b"],"ints":[2,2],"ratios":[0.1],"flags":[]}"#)
        #expect(d.issues.map(\.code) == [.notUnique, .wrongCount, .empty])
        #expect(d.issues.map(\.message).prefix(2) == ["dupes", "two"])

        let tooMany = RuleCollections.diagnose(
            json: #"{"names":["a","b"],"ints":[1],"ratios":[0.1,0.2],"flags":[true,false,true]}"#)
        #expect(tooMany.issues.map(\.code) == [.tooLarge])
        #expect(tooMany.issues.first?.path.pathDescription == "flags")
    }

    @Test("the same rules run through T.validate, with no document")
    func throughValidate() {
        let v = RuleCollections(names: ["a"], ints: [0], ratios: [2, 2], flags: [])
        let report = RuleCollections.diagnose(v)
        #expect(
            report.issues.map(\.path.pathDescription)
                == ["names", "ints[0]", "ratios[0]", "ratios[1]", "flags"])
    }

    // MARK: Rules as values

    private func apply(_ rule: Rule, to value: String) -> [Assay.Issue] {
        var sink = IssueSink(limits: .default)
        _assayValidate(value, [rule], override: nil, field: "f", at: nil, path: [], &sink)
        return sink.issues
    }

    @Test("withMessage reaches into .all, and leaves a child's own message alone")
    func withMessage() {
        let rule = Rule.all(.min(3), .max(5, or: "own")).withMessage("outer")
        #expect(apply(rule, to: "ab").map(\.message) == ["outer"])
        #expect(apply(rule, to: "abcdef").map(\.message) == ["own"])
        #expect(apply(rule, to: "abcd").isEmpty)
        // On a leaf it sets the message; on a leaf that has one it does not replace it.
        #expect(apply(Rule.email.withMessage("m"), to: "x").map(\.message) == ["m"])
        let kept = Rule.email(or: "first").withMessage("m")
        #expect(apply(kept, to: "x").map(\.message) == ["first"])
    }

    @Test("a string literal is a rule that checks nothing")
    func literal() {
        let rule: Rule = "only a message"
        #expect(apply(rule, to: "").isEmpty)
    }
}
