// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore
import AssayTOML

// The TOML 1.0.0 parser against the specification's own examples, then the schema door.
// `DiffFuzz toml` runs the official toml-test suite and TOMLKit as oracles; these are
// the cases a reader of the spec would check by hand.

@Suite("TOML: values")
struct TOMLValueTests {

    func node(_ s: String) throws -> TOML.Node { try TOML.parse(s) }

    @Test("the specification's front-page example")
    func frontPage() throws {
        let doc = try node(
            """
            # This is a TOML document

            title = "TOML Example"

            [owner]
            name = "Tom Preston-Werner"
            dob = 1979-05-27T07:32:00-08:00

            [database]
            enabled = true
            ports = [ 8000, 8001, 8002 ]
            data = [ ["delta", "phi"], [3.14] ]
            temp_targets = { cpu = 79.5, case = 72.0 }

            [servers]

            [servers.alpha]
            ip = "10.0.0.1"
            role = "frontend"

            [servers.beta]
            ip = "10.0.0.2"
            role = "backend"
            """)
        #expect(doc["title"]?.string == "TOML Example")
        #expect(doc["owner"]?["name"]?.string == "Tom Preston-Werner")
        #expect(doc["owner"]?["dob"]?.dateTime == .offsetDateTime("1979-05-27T07:32:00-08:00"))
        #expect(doc["database"]?["enabled"]?.bool == true)
        #expect(doc["database"]?["ports"]?.array?.compactMap(\.int) == [8000, 8001, 8002])
        #expect(doc["database"]?["data"]?[1]?[0]?.double == 3.14)
        #expect(doc["database"]?["temp_targets"]?["cpu"]?.double == 79.5)
        #expect(doc["servers"]?["alpha"]?["ip"]?.string == "10.0.0.1")
        #expect(doc["servers"]?["beta"]?["role"]?.string == "backend")
        #expect(doc.table?.map(\.key) == ["title", "owner", "database", "servers"])
    }

    @Test("strings: the four forms and every escape")
    func strings() throws {
        let doc = try node(
            #"""
            basic = "I'm a string. \"You can quote me\". Name\tJos\u00E9\nLocation\tSF."
            lit = 'C:\Users\nodejs\templates'
            winpath = '\\ServerX\admin$\system32\'
            ml = """
            Roses are red
            Violets are blue"""
            trimmed = """
            The quick brown \

              fox jumps over \
                the lazy dog."""
            quotes = """Here are fifteen quotation marks: ""\"""\"""\"""\"""\"."""
            adjacent = """"This," she said, "is just a pointless statement.""""
            mllit = '''
            The first newline is
            trimmed in raw strings.
               All other whitespace
               is preserved.
            '''
            apos = ''''That,' she said, 'is still pointless.''''
            emoji = "\U0001F600"
            """#)
        #expect(
            doc["basic"]?.string == "I'm a string. \"You can quote me\". Name\tJosé\nLocation\tSF.")
        #expect(doc["lit"]?.string == #"C:\Users\nodejs\templates"#)
        #expect(doc["winpath"]?.string == #"\\ServerX\admin$\system32\"#)
        #expect(doc["ml"]?.string == "Roses are red\nViolets are blue")
        #expect(doc["trimmed"]?.string == "The quick brown fox jumps over the lazy dog.")
        #expect(
            doc["quotes"]?.string
                == "Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\".")
        #expect(doc["adjacent"]?.string == "\"This,\" she said, \"is just a pointless statement.\"")
        #expect(
            doc["mllit"]?.string
                == "The first newline is\ntrimmed in raw strings.\n   All other whitespace\n   is preserved.\n"
        )
        #expect(doc["apos"]?.string == "'That,' she said, 'is still pointless.'")
        #expect(doc["emoji"]?.string == "😀")
    }

    @Test("integers: signs, underscores, bases, the Int64 range")
    func integers() throws {
        let doc = try node(
            """
            a = +99
            b = 42
            c = 0
            d = -17
            e = 1_000
            f = 5_349_221
            g = 53_49_221
            h = 1_2_3_4_5
            hex1 = 0xDEADBEEF
            hex2 = 0xdeadbeef
            hex3 = 0xdead_beef
            oct1 = 0o01234567
            oct2 = 0o755
            bin1 = 0b11010110
            max = 9223372036854775807
            min = -9223372036854775808
            """)
        #expect(doc["a"]?.int == 99)
        #expect(doc["b"]?.int == 42)
        #expect(doc["c"]?.int == 0)
        #expect(doc["d"]?.int == -17)
        #expect(doc["e"]?.int == 1000)
        #expect(doc["f"]?.int == 5_349_221)
        #expect(doc["g"]?.int == 5_349_221)
        #expect(doc["h"]?.int == 12345)
        #expect(doc["hex1"]?.int == 0xDEADBEEF)
        #expect(doc["hex2"]?.int == 0xDEADBEEF)
        #expect(doc["hex3"]?.int == 0xDEADBEEF)
        #expect(doc["oct1"]?.int == 0o01234567)
        #expect(doc["oct2"]?.int == 0o755)
        #expect(doc["bin1"]?.int == 0b11010110)
        #expect(doc["max"]?.int == Int64.max)
        #expect(doc["min"]?.int == Int64.min)
    }

    @Test("floats: fractions, exponents, both, underscores, inf and nan")
    func floats() throws {
        let doc = try node(
            """
            flt1 = +1.0
            flt2 = 3.1415
            flt3 = -0.01
            flt4 = 5e+22
            flt5 = 1e06
            flt6 = -2E-2
            flt7 = 6.626e-34
            flt8 = 224_617.445_991_228
            sf1 = inf
            sf2 = +inf
            sf3 = -inf
            sf4 = nan
            sf5 = +nan
            sf6 = -nan
            z = 0.0
            nz = -0.0
            """)
        #expect(doc["flt1"]?.double == 1.0)
        #expect(doc["flt2"]?.double == 3.1415)
        #expect(doc["flt3"]?.double == -0.01)
        #expect(doc["flt4"]?.double == 5e22)
        #expect(doc["flt5"]?.double == 1e6)
        #expect(doc["flt6"]?.double == -2e-2)
        #expect(doc["flt7"]?.double == 6.626e-34)
        #expect(doc["flt8"]?.double == 224617.445991228)
        #expect(doc["sf1"]?.double == .infinity)
        #expect(doc["sf2"]?.double == .infinity)
        #expect(doc["sf3"]?.double == -.infinity)
        #expect(doc["sf4"]?.double?.isNaN == true)
        #expect(doc["sf5"]?.double?.isNaN == true)
        #expect(doc["sf6"]?.double?.isNaN == true)
        #expect(doc["z"]?.double == 0)
        #expect(doc["nz"]?.double?.sign == .minus)
        // A float is a float, an integer an integer: the wire is typed.
        if case .double = doc["flt1"]! {} else { Issue.record("1.0 must parse as a double") }
    }

    @Test("date-times: the four kinds, the space separator, fractions, case")
    func dateTimes() throws {
        let doc = try node(
            """
            odt1 = 1979-05-27T07:32:00Z
            odt2 = 1979-05-27T00:32:00-07:00
            odt3 = 1979-05-27T00:32:00.999999-07:00
            odt4 = 1979-05-27 07:32:00Z
            odt5 = 1979-05-27t07:32:00z
            ldt1 = 1979-05-27T07:32:00
            ldt2 = 1979-05-27T00:32:00.999999
            ld1 = 1979-05-27
            lt1 = 07:32:00
            lt2 = 00:32:00.999999
            leap = 2016-12-31T23:59:60Z  # time-second is 00-60 in the ABNF; toml++ disagrees
            feb29 = 2024-02-29
            """)
        #expect(doc["odt1"]?.dateTime == .offsetDateTime("1979-05-27T07:32:00Z"))
        #expect(doc["odt2"]?.dateTime == .offsetDateTime("1979-05-27T00:32:00-07:00"))
        #expect(doc["odt3"]?.dateTime == .offsetDateTime("1979-05-27T00:32:00.999999-07:00"))
        #expect(doc["odt4"]?.dateTime == .offsetDateTime("1979-05-27T07:32:00Z"))
        #expect(doc["odt5"]?.dateTime == .offsetDateTime("1979-05-27T07:32:00Z"))
        #expect(doc["ldt1"]?.dateTime == .localDateTime("1979-05-27T07:32:00"))
        #expect(doc["ldt2"]?.dateTime == .localDateTime("1979-05-27T00:32:00.999999"))
        #expect(doc["ld1"]?.dateTime == .localDate("1979-05-27"))
        #expect(doc["lt1"]?.dateTime == .localTime("07:32:00"))
        #expect(doc["lt2"]?.dateTime == .localTime("00:32:00.999999"))
        #expect(doc["leap"]?.dateTime == .offsetDateTime("2016-12-31T23:59:60Z"))
        #expect(doc["feb29"]?.dateTime == .localDate("2024-02-29"))
    }

    @Test("arrays: mixed, nested, multi-line with comments and a trailing comma")
    func arrays() throws {
        let doc = try node(
            """
            integers = [ 1, 2, 3 ]
            colors = [ "red", "yellow", "green" ]
            nested_mixed = [ [ 1, 2 ], ["a", "b", "c"] ]
            numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
            contributors = [
              "Foo Bar <foo@example.com>",
              { name = "Baz Qux", email = "bazqux@example.com", url = "https://example.com/bazqux" }
            ]
            integers2 = [
              1, 2, 3
            ]
            integers3 = [
              1,
              2, # this is ok
            ]
            empty = []
            """)
        #expect(doc["integers"]?.array?.count == 3)
        #expect(doc["nested_mixed"]?[1]?[2]?.string == "c")
        #expect(doc["numbers"]?[3]?.int == 1)
        #expect(doc["contributors"]?[1]?["name"]?.string == "Baz Qux")
        #expect(doc["integers2"]?.array?.count == 3)
        #expect(doc["integers3"]?.array?.count == 2)
        #expect(doc["empty"]?.array?.isEmpty == true)
    }

    @Test("keys: bare, quoted, empty, dotted with whitespace, numeric-looking")
    func keys() throws {
        let doc = try node(
            """
            key = "key"
            bare_key = "bare_key"
            bare-key = "bare-key"
            1234 = "1234"
            "127.0.0.1" = "value"
            "character encoding" = "value"
            "ʎǝʞ" = "value"
            'key2' = "value"
            'quoted "value"' = "value"
            "" = "blank"
            name = "Orange"
            physical.color = "orange"
            physical.shape = "round"
            site."google.com" = true
            fruit . flavor = "banana"
            3.14159 = "pi"
            """)
        #expect(doc["1234"]?.string == "1234")
        #expect(doc["127.0.0.1"]?.string == "value")
        #expect(doc["ʎǝʞ"]?.string == "value")
        #expect(doc["quoted \"value\""]?.string == "value")
        #expect(doc[""]?.string == "blank")
        #expect(doc["physical"]?["color"]?.string == "orange")
        #expect(doc["physical"]?["shape"]?.string == "round")
        #expect(doc["site"]?["google.com"]?.bool == true)
        #expect(doc["fruit"]?["flavor"]?.string == "banana")
        #expect(doc["3"]?["14159"]?.string == "pi")
    }

    @Test("tables and arrays of tables, with the specification's fruit example")
    func tables() throws {
        let doc = try node(
            """
            [[fruits]]
            name = "apple"

            [fruits.physical]  # subtable
            color = "red"
            shape = "round"

            [[fruits.varieties]]  # nested array of tables
            name = "red delicious"

            [[fruits.varieties]]
            name = "granny smith"


            [[fruits]]
            name = "banana"

            [[fruits.varieties]]
            name = "plantain"
            """)
        let fruits = try #require(doc["fruits"]?.array)
        #expect(fruits.count == 2)
        #expect(fruits[0]["name"]?.string == "apple")
        #expect(fruits[0]["physical"]?["color"]?.string == "red")
        #expect(
            fruits[0]["varieties"]?.array?.compactMap { $0["name"]?.string } == [
                "red delicious", "granny smith"
            ])
        #expect(fruits[1]["name"]?.string == "banana")
        #expect(fruits[1]["varieties"]?.array?.count == 1)
    }

    @Test("implicit tables are defined by a later header, in first-appearance order")
    func implicitThenExplicit() throws {
        let doc = try node(
            """
            [x.y.z.w]
            [x]
            a = 1
            [a.b]
            c = 1
            [a]
            d = 2
            """)
        #expect(doc.table?.map(\.key) == ["x", "a"])
        #expect(doc["x"]?["a"]?.int == 1)
        #expect(doc["x"]?["y"]?["z"]?["w"]?.table?.isEmpty == true)
        #expect(doc["a"]?.table?.map(\.key) == ["b", "d"])
    }

    @Test("dotted keys define tables that headers may nest under but not redefine")
    func dottedTables() throws {
        let doc = try node(
            """
            [fruit]
            apple.color = "red"
            apple.taste.sweet = true

            [fruit.apple.texture]  # you can add sub-tables
            smooth = true
            """)
        #expect(doc["fruit"]?["apple"]?["taste"]?["sweet"]?.bool == true)
        #expect(doc["fruit"]?["apple"]?["texture"]?["smooth"]?.bool == true)
    }

    @Test("an empty document, a comment-only document, CRLF, and a BOM")
    func edges() throws {
        #expect(try node("").table?.isEmpty == true)
        #expect(try node("# nothing\n\n   \n").table?.isEmpty == true)
        #expect(try node("a = 1\r\nb = 2\r\n")["b"]?.int == 2)
        // CRLF inside a multi-line string is normalised to LF, in both forms.
        #expect(
            try node("a = \"\"\"\r\nx\r\ny\"\"\"\r\nb = '''\r\nx\r\ny'''\r\n")["a"]?.string
                == "x\ny")
        #expect(
            try node("a = \"\"\"\r\nx\r\ny\"\"\"\r\nb = '''\r\nx\r\ny'''\r\n")["b"]?.string
                == "x\ny")
        #expect(try TOML.parse([0xEF, 0xBB, 0xBF] + Array("a = 1".utf8))["a"]?.int == 1)
        #expect(try node("a = 1 # trailing")["a"]?.int == 1)
    }

    @Test("member spans point at the value")
    func spans() throws {
        let text = "title = \"x\"\n[t]\nn = 42\n"
        let doc = try node(text)
        let title = try #require(doc.table?.first)
        #expect(title.span?.lo == 8)
        #expect(title.span?.len == 3)
        let n = try #require(doc["t"]?.table?.first)
        #expect(n.span?.lo == UInt32(text.utf8.count - 3))
        #expect(n.span?.len == 2)
    }
}

@Suite("TOML: refusals")
struct TOMLRefusalTests {

    func code(_ s: String) -> String? {
        var sink = IssueSink()
        _ = TOML.decode(Array(s.utf8), into: &sink)
        return sink.issues.first?.code.codeString
    }

    @Test(
        "every specification-stated invalid document is refused, with its own code",
        arguments: [
            // keys
            ("= \"no key name\"", "toml_expected_key"),
            ("key = \"a\" key2 = \"b\"", "toml_expected_newline"),
            ("key = # no value", "toml_expected_value"),
            ("key", "toml_expected_equals"),
            ("\"\"\"k\"\"\" = 1", "toml_expected_key"),
            ("a.b = 1\na.b = 2", "duplicate_key"),
            ("name = \"Tom\"\nname = \"Pradyun\"", "duplicate_key"),
            ("spelling = \"favorite\"\n\"spelling\" = \"favourite\"", "duplicate_key"),
            ("fruit.apple = 1\nfruit.apple.smooth = true", "toml_not_a_table"),
            // tables
            ("[fruit]\napple = \"red\"\n\n[fruit]\norange = \"orange\"", "toml_redefined_table"),
            ("[fruit]\napple = \"red\"\n\n[fruit.apple]\ntexture = \"smooth\"", "toml_not_a_table"),
            ("[fruit]\napple.color = \"red\"\n[fruit.apple]", "toml_redefined_table"),
            ("[fruit]\napple.taste.sweet = true\n[fruit.apple.taste]", "toml_redefined_table"),
            ("[a.b.c]\nz = 9\n[a]\nb.c.t = 1", "toml_redefined_table"),
            ("[a]\n[a.b]\n[a]", "toml_redefined_table"),
            ("[[a]]\n[a]", "toml_redefined_table"),
            ("fruits = []\n[[fruits]]", "toml_not_a_table"),
            (
                "[[fruits]]\nname = \"apple\"\n[[fruits.varieties]]\nname = \"x\"\n[fruits.varieties]",
                "toml_redefined_table"
            ),
            (
                "[[fruits]]\nname = \"apple\"\n[fruits.physical]\ncolor = \"red\"\n[[fruits.physical]]",
                "toml_redefined_table"
            ),
            ("[fruit.physical]\ncolor = \"red\"\n[[fruit]]", "toml_redefined_table"),
            ("[a", "toml_unterminated_table_header"),
            ("[[a]", "toml_unterminated_table_header"),
            ("[]", "toml_expected_key"),
            // inline tables
            ("t = { a = 1 }\nt.b = 2", "toml_inline_table_closed"),
            ("t = { a = 1 }\n[t.c]", "toml_inline_table_closed"),
            ("t = { a = 1, a = 2 }", "duplicate_key"),
            ("t = { a = 1, }", "toml_expected_key"),
            ("t = { a = 1\n}", "toml_unterminated_inline_table"),
            ("t = { a = 1", "toml_unterminated_inline_table"),
            // strings
            ("s = \"unterminated", "toml_unterminated_string"),
            ("s = \"a\nb\"", "toml_unterminated_string"),
            ("s = 'a\nb'", "toml_unterminated_string"),
            ("s = \"\\q\"", "toml_bad_escape"),
            ("s = \"\\uD800\"", "toml_bad_escape"),
            ("s = \"\\U00110000\"", "toml_bad_escape"),
            ("s = \"\\u12\"", "toml_bad_escape"),
            ("s = \"a \\ b\"", "toml_bad_escape"),
            ("s = \"\u{01}\"", "toml_control_character"),
            ("s = '\u{7F}'", "toml_control_character"),
            ("s = \"\"\"\u{01}\"\"\"", "toml_control_character"),
            ("s = \"\"\"a\"\"\"\"\"\"", "toml_expected_newline"),
            ("s = \"\"\"a\rb\"\"\"", "toml_control_character"),
            ("# comment \u{01}", "toml_control_character"),
            ("a = 1\r", "toml_expected_newline"),
            // numbers
            ("n = 01", "toml_bad_number"),
            ("n = 1_", "toml_bad_number"),
            ("n = _1", "toml_expected_value"),
            ("n = 1__2", "toml_bad_number"),
            ("n = 0x", "toml_bad_number"),
            ("n = +0x1", "toml_bad_number"),
            ("n = 0xG", "toml_bad_number"),
            ("n = 9223372036854775808", "number_overflow"),
            ("n = -9223372036854775809", "number_overflow"),
            ("n = 0xFFFFFFFFFFFFFFFF", "number_overflow"),
            ("f = .5", "toml_expected_value"),
            ("f = 5.", "toml_bad_number"),
            ("f = 1.e5", "toml_bad_number"),
            ("f = 1e", "toml_bad_number"),
            ("f = 03.14", "toml_bad_number"),
            ("f = 1.2.3", "toml_expected_newline"),
            ("f = infinity", "toml_bad_number"),
            ("b = True", "toml_expected_value"),
            // date-times
            ("d = 1979-13-27", "toml_bad_date_time"),
            ("d = 1979-02-30", "toml_bad_date_time"),
            ("d = 1979-05-27T25:00:00", "toml_bad_date_time"),
            ("d = 1979-05-27T07:60:00", "toml_bad_date_time"),
            ("d = 1979-05-27T07:32", "toml_bad_date_time"),
            ("d = 1979-05-27T07:32:00+24:00", "toml_bad_date_time"),
            ("d = 1979-05-27T07:32:00.", "toml_bad_date_time"),
            ("d = 07:32", "toml_bad_date_time"),
            ("d = 1979-05-27 T07:32:00", "toml_expected_newline"),
            ("d = 2023-02-29", "toml_bad_date_time"),
            // arrays
            ("a = [1, 2", "toml_unterminated_array"),
            ("a = [1 2]", "toml_unterminated_array"),
            ("a = [,]", "toml_expected_value"),
            ("a = [1,,2]", "toml_expected_value")
        ])
    func refused(_ doc: String, _ expected: String) {
        #expect(code(doc) == expected, "for \(doc.debugDescription)")
    }

    @Test("a parse error throws an AssayError that renders with a caret")
    func caret() {
        do {
            _ = try TOML.parse("a = 1\nb = 01\n")
            Issue.record("expected a throw")
        } catch {
            let text = error.render(.plain)
            #expect(text.contains("invalid number literal"))
            #expect(text.contains("2:5"))
        }
    }

    @Test("limits: depth on arrays, inline tables and headers; bytes")
    func limits() {
        let limits = Limits(maxDepth: 4)
        var sink = IssueSink(limits: limits)
        _ = TOML.decode(Array("a = [[[[[1]]]]]".utf8), into: &sink, limits: limits)
        #expect(sink.issues.first?.code == .depthExceeded)
        sink = IssueSink(limits: limits)
        _ = TOML.decode(Array("[a.b.c.d.e]".utf8), into: &sink, limits: limits)
        #expect(sink.issues.first?.code == .depthExceeded)
        sink = IssueSink(limits: limits)
        _ = TOML.decode(
            Array("a = {b = {c = {d = {e = {f = 1}}}}}".utf8), into: &sink, limits: limits)
        #expect(sink.issues.first?.code == .depthExceeded)
        let tiny = Limits(maxBytes: 4)
        sink = IssueSink(limits: tiny)
        _ = TOML.decode(Array("a = 12345".utf8), into: &sink, limits: tiny)
        #expect(sink.issues.first?.code == .tooManyBytes)
    }
}

// MARK: - The schema door

@Schema(keys: .snakeCase, formats: [.json, .toml], encodes: true)
struct TOMLServer: Equatable {
    var ip: String
    var role: String
    var weight: Int = 1
}

@Schema(keys: .snakeCase, formats: [.json, .toml], encodes: true)
struct TOMLConfig: Equatable {
    var title: String
    @Validate(.min(1), .max(65535)) var port: Int
    var ratio: Double
    var enabled: Bool
    var tags: [String] = []
    var servers: [TOMLServer] = []
    var primary: TOMLServer
    var note: String?
    var limits: [String: Int] = [:]
}

@Schema(formats: [.toml])
struct TOMLDated {
    var when: Date
    @DateFormat(.pattern("yyyy-MM-dd")) var day: Date
}

@Schema(formats: [.toml])
struct TOMLWide {
    var u8: UInt8
    var i16: Int16
    var u64: UInt64
    var f: Double
}

@Suite("TOML: the schema door")
struct TOMLSchemaTests {

    static let document = document()

    static func document(port: String = "8080", ratio: String = "0.75") -> String {
        """
        title = "svc"
        port = \(port)
        ratio = \(ratio)
        enabled = true
        tags = ["a", "b"]

        [primary]
        ip = "10.0.0.1"
        role = "frontend"

        [[servers]]
        ip = "10.0.0.2"
        role = "backend"
        weight = 3

        [[servers]]
        ip = "10.0.0.3"
        role = "backend"

        [limits]
        cpu = 4
        mem = 8
        """
    }

    @Test("one struct decodes from TOML and JSON to the same value")
    func decodes() throws {
        let t = try TOMLConfig.parse(toml: Self.document)
        let j = try TOMLConfig.parse(
            json: #"""
                {"title":"svc","port":8080,"ratio":0.75,"enabled":true,"tags":["a","b"],
                 "primary":{"ip":"10.0.0.1","role":"frontend"},
                 "servers":[{"ip":"10.0.0.2","role":"backend","weight":3},{"ip":"10.0.0.3","role":"backend"}],
                 "limits":{"cpu":4,"mem":8}}
                """#)
        #expect(t == j)
        #expect(t.servers[0].weight == 3)
        #expect(t.servers[1].weight == 1)
        #expect(t.note == nil)
        #expect(t.limits == ["cpu": 4, "mem": 8])
    }

    @Test("same rules, same errors, with carets into the TOML source")
    func sameErrors() {
        let d = TOMLConfig.diagnose(
            toml: """
                title = "svc"
                port = 70000
                ratio = "high"
                enabled = true
                [primary]
                ip = "10.0.0.1"
                """)
        #expect(!d.isValid)
        let codes = d.issues.map { ($0.path.pathDescription, $0.code.codeString) }
        #expect(codes.contains { $0 == ("port", "too_large") })
        #expect(codes.contains { $0 == ("ratio", "type_mismatch") })
        #expect(codes.contains { $0 == ("primary.role", "missing") })
        let rendered = d.render(.plain)
        #expect(rendered.contains("2:8"), "the caret points at 70000: \(rendered)")
    }

    @Test("a TOML integer decodes into a Double field; a float does not decode into Int")
    func numericWire() throws {
        let ok = try TOMLConfig.parse(toml: Self.document(ratio: "1"))
        #expect(ok.ratio == 1)
        let bad = TOMLConfig.diagnose(toml: Self.document(port: "80.5"))
        #expect(bad.issues.first?.code == .typeMismatch)
    }

    @Test("TOML date-times decode into Date fields through the RFC 3339 projection")
    func dates() throws {
        let d = try TOMLDated.parse(
            toml: """
                when = 1979-05-27 07:32:00Z
                day = 1979-05-27
                """)
        #expect(d.when.timeIntervalSince1970 == 296_638_320)
        #expect(d.day.timeIntervalSince1970 == 296_611_200)
    }

    @Test("narrow widths range-check on the TOML path")
    func widths() throws {
        let ok = try TOMLWide.parse(
            toml: "u8 = 255\ni16 = -32768\nu64 = 9223372036854775807\nf = 1e3")
        #expect(ok.u8 == 255 && ok.i16 == -32768 && ok.f == 1000)
        let bad = TOMLWide.diagnose(toml: "u8 = 256\ni16 = 1\nu64 = 1\nf = 1.0")
        #expect(bad.issues.first?.path.pathDescription == "u8")
    }

    @Test("parse errors surface through the schema door with the TOML code")
    func parseError() {
        let d = TOMLConfig.diagnose(toml: "title = \"x\"\nport = 01")
        #expect(d.issues.first?.code.codeString == "toml_bad_number")
        #expect(d.value == nil)
    }

    @Test("encode: the layout, and the round trip")
    func encode() throws {
        let value = try TOMLConfig.parse(toml: Self.document)
        let text = try value.tomlText()
        #expect(
            text == """
                title = "svc"
                port = 8080
                ratio = 0.75
                enabled = true
                tags = ["a", "b"]

                [primary]
                ip = "10.0.0.1"
                role = "frontend"
                weight = 1

                [limits]
                cpu = 4
                mem = 8

                [[servers]]
                ip = "10.0.0.2"
                role = "backend"
                weight = 3

                [[servers]]
                ip = "10.0.0.3"
                role = "backend"
                weight = 1

                """)
        #expect(try TOMLConfig.parse(toml: text) == value)
    }

    @Test("encode: nil members are omitted; strings and keys are quoted as needed")
    func encodeQuoting() throws {
        var v = try TOMLConfig.parse(toml: Self.document)
        v.note = nil
        v.title = "tab\there \"quoted\" \\ back\nline \u{01}"
        v.tags = ["a b", "", "ünï"]
        v.limits = ["a b": 1, "": 2, "ok-key": 3]
        v.servers = []
        let text = try v.tomlText()
        #expect(!text.contains("note"))
        #expect(text.contains(#"title = "tab\there \"quoted\" \\ back\nline \u0001""#))
        #expect(text.contains(#""a b" = 1"#))
        #expect(text.contains(#""" = 2"#))
        #expect(text.contains("ok-key = 3"))
        #expect(try TOMLConfig.parse(toml: text) == v)
    }

    @Test("encode: inf, nan, whole doubles stay doubles, and a nested empty table")
    func encodeNumbers() throws {
        var v = try TOMLConfig.parse(toml: Self.document)
        v.ratio = .infinity
        v.limits = [:]
        v.servers = []
        #expect(try v.tomlText().contains("ratio = inf"))
        v.ratio = 2
        let text = try v.tomlText()
        #expect(text.contains("ratio = 2.0"))
        #expect(text.contains("[limits]\n"))
        #expect(try TOMLConfig.parse(toml: text) == v)
    }

    @Test("encode: a null where TOML has no spelling is an issue, not a substitution")
    func encodeNull() {
        var sink = IssueSink()
        _ = TOML.encode(
            .mapping([.init(key: "a", value: .sequence([.int(1), .null]))]), into: &sink)
        #expect(sink.issues.first?.code == .tomlNoNull)
        #expect(sink.issues.first?.path.pathDescription == "a[1]")
        sink = IssueSink()
        _ = TOML.encode(.sequence([]), into: &sink)
        #expect(sink.issues.first?.code == .tomlRootNotATable)
    }

    @Test("content negotiation reaches the TOML parser")
    func negotiation() throws {
        let body = Array("ip = \"1\"\nrole = \"r\"\n".utf8)
        let s = try TOMLServer.parse(
            body: body, contentType: "application/toml", accepting: [.toml])
        #expect(s.ip == "1")
        let t = try TOMLServer.parse(
            body: body, contentType: "application/vnd.x+toml; charset=utf-8", accepting: [.toml])
        #expect(t.role == "r")
        let refused = TOMLServer.diagnose(
            body: body, contentType: "application/toml", accepting: [.json])
        #expect(refused.issues.first?.code.codeString == "unsupported_media_type")
    }
}
