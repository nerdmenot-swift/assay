import Testing
import Assay
import AssayCore

// The macro builds runtime method names as STRINGS — there is no compile-time link
// between codegen and the runtime API. Renaming `decodeInt32OrNull` would break nothing
// in this package until a *user* compiled a schema that happens to hit that variant.
//
// This file is the countermeasure: one schema per axis, covering every scalar type ×
// optionality × coercion × format path the generators can emit. If codegen and runtime
// drift, this file stops compiling — here, not in a bug report.

// Every scalar, required: decodeString/Int/Int64/Int32/UInt/Double/Float/Bool.
@Schema(formats: .all)
struct SinkRequired {
    var s: String
    var i: Int
    var i64: Int64
    var i32: Int32
    var u: UInt
    var d: Double
    var f: Float
    var b: Bool
}

// Every scalar, optional: the ...OrNull family, and the RawValue optional path.
@Schema(formats: .all)
struct SinkOptional {
    var s: String?
    var i: Int?
    var i64: Int64?
    var i32: Int32?
    var u: UInt?
    var d: Double?
    var f: Float?
    var b: Bool?
}

// Every scalar, coerced: the ...Coercing family, and assayX(coerce: true).
@Schema(formats: .all)
struct SinkCoerced {
    @Coerce var s: String
    @Coerce var i: Int
    @Coerce var i64: Int64
    @Coerce var i32: Int32
    @Coerce var u: UInt
    @Coerce var d: Double
    @Coerce var f: Float
    @Coerce var b: Bool
}

// Optional AND coerced — the null-check-wrapping-coercing-call shape.
@Schema(formats: .all)
struct SinkOptionalCoerced {
    @Coerce var i: Int?
    @Coerce var s: String?
    @Coerce var b: Bool?
    @Coerce var d: Double?
}

// Arrays of every scalar, plus nested arrays.
@Schema(formats: .all)
struct SinkArrays {
    var ss: [String]
    var ii: [Int]
    var dd: [Double]
    var bb: [Bool]
    var nested: [[Int]]
}

// Nested schemas: required, optional, array-of.
@Schema(formats: .all)
struct SinkChild {
    var name: String
}

@Schema(formats: .all)
struct SinkNested {
    var child: SinkChild
    var maybe: SinkChild?
    var many: [SinkChild]
}

// Defaults on every axis.
@Schema(formats: .all)
struct SinkDefaults {
    var s: String = "x"
    var i: Int = 7
    var d: Double = 1.5
    var b: Bool = true
    var arr: [Int] = [1, 2]
}

@Suite("Kitchen sink — every codegen variant decodes")
struct KitchenSinkTests {

    @Test("required scalars, JSON and YAML")
    func required() throws {
        let json = #"{"s":"x","i":-3,"i64":9007199254740993,"i32":-70000,"u":42,"d":2.5,"f":1.25,"b":true}"#
        let v = try SinkRequired.parse(json: json)
        #expect(v.s == "x" && v.i == -3 && v.i64 == 9_007_199_254_740_993)
        #expect(v.i32 == -70000 && v.u == 42 && v.d == 2.5 && v.f == 1.25 && v.b)

        let y = try SinkRequired.parse(yaml: """
        s: x
        i: -3
        i64: 9007199254740993
        i32: -70000
        u: 42
        d: 2.5
        f: 1.25
        b: true
        """)
        #expect(y.i64 == v.i64 && y.f == v.f && y.u == v.u)
    }

    @Test("out-of-range narrows are errors, not truncations")
    func narrowing() {
        // Int32 overflow, UInt negative — every narrowing variant must refuse.
        #expect(SinkRequired.diagnose(
            json: #"{"s":"x","i":1,"i64":1,"i32":3000000000,"u":1,"d":1,"f":1,"b":true}"#
        ).isValid == false)
        #expect(SinkRequired.diagnose(
            json: #"{"s":"x","i":1,"i64":1,"i32":1,"u":-5,"d":1,"f":1,"b":true}"#
        ).isValid == false)
    }

    @Test("optional scalars: absent, present, and explicit null")
    func optionals() throws {
        let absent = try SinkOptional.parse(json: "{}")
        #expect(absent.s == nil && absent.i == nil && absent.f == nil)

        let present = try SinkOptional.parse(
            json: #"{"s":"x","i":1,"i64":2,"i32":3,"u":4,"d":5.5,"f":6.5,"b":false}"#)
        #expect(present.i == 1 && present.b == false)

        let nulls = try SinkOptional.parse(
            json: #"{"s":null,"i":null,"i64":null,"i32":null,"u":null,"d":null,"f":null,"b":null}"#)
        #expect(nulls.s == nil && nulls.u == nil && nulls.b == nil)

        // Present-but-wrong is still an error for an optional. EXPERIENCE §6.
        #expect(SinkOptional.diagnose(json: #"{"i":"nope"}"#).isValid == false)
    }

    @Test("coerced scalars accept strings, JSON and (typeless) XML")
    func coerced() throws {
        let v = try SinkCoerced.parse(
            json: #"{"s":9,"i":"7","i64":"8","i32":"9","u":"10","d":"2.5","f":"1.5","b":"yes"}"#)
        #expect(v.s == "9" && v.i == 7 && v.i64 == 8 && v.i32 == 9)
        #expect(v.u == 10 && v.d == 2.5 && v.f == 1.5 && v.b == true)

        let x = try SinkCoerced.parse(xml: """
        <r><s>text</s><i>7</i><i64>8</i64><i32>9</i32><u>10</u><d>2.5</d><f>1.5</f><b>true</b></r>
        """)
        #expect(x.i == 7 && x.d == 2.5 && x.b == true)
    }

    @Test("optional + coerced compose")
    func optionalCoerced() throws {
        let v = try SinkOptionalCoerced.parse(json: #"{"i":"42","b":"on"}"#)
        #expect(v.i == 42 && v.b == true && v.s == nil && v.d == nil)

        let nulls = try SinkOptionalCoerced.parse(json: #"{"i":null,"s":null}"#)
        #expect(nulls.i == nil && nulls.s == nil)
    }

    @Test("arrays of every scalar, nested arrays, both paths")
    func arrays() throws {
        let json = #"{"ss":["a"],"ii":[1,2],"dd":[1.5],"bb":[true,false],"nested":[[1],[2,3]]}"#
        let v = try SinkArrays.parse(json: json)
        #expect(v.nested == [[1], [2, 3]])

        let y = try SinkArrays.parse(yaml: """
        ss: [a]
        ii: [1, 2]
        dd: [1.5]
        bb: [true, false]
        nested: [[1], [2, 3]]
        """)
        #expect(y.nested == v.nested && y.bb == v.bb)
    }

    @Test("nested schemas: required, optional, array-of, both paths")
    func nested() throws {
        let json = #"{"child":{"name":"a"},"many":[{"name":"b"},{"name":"c"}]}"#
        let v = try SinkNested.parse(json: json)
        #expect(v.child.name == "a" && v.maybe == nil && v.many.count == 2)

        let y = try SinkNested.parse(yaml: """
        child:
          name: a
        maybe:
          name: m
        many:
          - name: b
        """)
        #expect(y.maybe?.name == "m" && y.many[0].name == "b")
    }

    @Test("defaults fire on absence, on both paths")
    func defaults() throws {
        let v = try SinkDefaults.parse(json: "{}")
        #expect(v.s == "x" && v.i == 7 && v.d == 1.5 && v.b == true && v.arr == [1, 2])
        let y = try SinkDefaults.parse(yaml: "i: 9\n")
        #expect(y.i == 9 && y.s == "x" && y.arr == [1, 2])
    }
}
