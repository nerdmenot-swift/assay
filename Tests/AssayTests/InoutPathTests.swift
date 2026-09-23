// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayYAML

//===----------------------------------------------------------------------===//
// The diagnostic path is `inout` since 2026-09-19: nested decodes push a component, call,
// and pop, on one buffer for the whole decode, instead of allocating `path + [...]` per
// nesting level per element. The new way to be wrong is a LEAK — a push not undone, so every
// LATER issue reports under the wrong prefix. Each test here puts an error AFTER a failure
// inside a nested scope and checks the later path exactly.
//===----------------------------------------------------------------------===//

@Schema(formats: .all) struct IPInner: Equatable { var x: Int }
@Schema(formats: .all) struct IPOuter: Equatable { var a: IPInner; var b: Int }
@Schema(formats: .all) struct IPList: Equatable { var items: [IPInner]; var tail: Int }
@Schema(formats: .all) struct IPMap: Equatable { var m: [String: IPInner]; var after: Int }
@Schema struct IPGroup: Equatable {
    @Key(path: "p.list") var list: [Int]
    @Key(path: "p.inner") var inner: IPInner
    var z: Int
}
@Schema struct IPFlat: Equatable { var list: [Int]; var z: Int }
enum IPColor: String, Equatable, Assay.JSONAssayable { case red, green }
@Schema enum IPOpen: Equatable { case red, green; @Unknown case other(String) }
@Schema struct IPEnumHolder: Equatable { var c: IPColor; var o: IPOpen; var z: Int }
@Schema struct IPGroups: Equatable { var rows: [IPGroup]; var last: Int }

@Suite("The inout diagnostic path does not leak")
struct InoutPathTests {

    static func paths<T: JSONAssayable>(_ t: T.Type, _ json: String) -> [String] {
        T.diagnose(json: json).issues.map(\.path.pathDescription)
    }

    @Test("an issue after a failed nested field")
    func nestedField() {
        #expect(Self.paths(IPOuter.self, #"{"a":{"x":"bad"},"b":"bad"}"#) == ["a.x", "b"])
    }

    @Test("an issue after a failed array element, and in a later element")
    func arrayElement() {
        #expect(
            Self.paths(
                IPList.self,
                #"{"items":[{"x":"bad"},{"x":1},{"x":"bad"}],"tail":"bad"}"#)
                == ["items[0].x", "items[2].x", "tail"])
    }

    @Test("an issue after a failed dictionary value")
    func dictionaryValue() {
        #expect(
            Self.paths(IPMap.self, #"{"m":{"k":{"x":"bad"}},"after":"bad"}"#)
                == ["m.k.x", "after"])
    }

    @Test("an issue after failures inside a @Key(path:) group")
    func pathGroup() {
        #expect(
            Self.paths(
                IPGroup.self,
                #"{"p":{"list":"notarray","inner":{"x":"bad"}},"z":"bad"}"#)
                == ["p.list", "p.inner.x", "z"])
    }

    @Test("groups inside array elements, then a sibling of the array")
    func groupsInArray() {
        #expect(
            Self.paths(
                IPGroups.self,
                """
                {"rows":[{"p":{"list":[1],"inner":{"x":"bad"}},"z":1},
                         {"p":{"list":"no","inner":{"x":2}},"z":"bad"}],
                 "last":"bad"}
                """) == ["rows[0].p.inner.x", "rows[1].p.list", "rows[1].z", "last"])
    }

    /// A container given the wrong type must be CONSUMED after it is reported. Until
    /// 2026-09-19 none of these were: the leftover value was read where ',' or '}' was
    /// expected, and one false `malformed_document` replaced every later issue, which is the
    /// opposite of what `diagnose` promises.
    @Test(
        "a wrong-typed container is consumed, so later issues still appear",
        arguments: [
            #"{"list":"notarray","z":"bad"}"#, #"{"list":{"o":1},"z":"bad"}"#,
            #"{"list":7,"z":"bad"}"#
        ])
    func arrayMismatchResyncs(_ json: String) {
        #expect(Self.paths(IPFlat.self, json) == ["list", "z"])
        #expect(
            !IPFlat.diagnose(json: json).issues.contains {
                $0.code.codeString == "malformed_document"
            })
    }

    @Test("nested object, dictionary and enum mismatches resync too")
    func otherMismatchesResync() {
        #expect(Self.paths(IPOuter.self, #"{"a":"notobject","b":"bad"}"#) == ["a", "b"])
        #expect(Self.paths(IPOuter.self, #"{"a":[1,2],"b":"bad"}"#) == ["a", "b"])
        #expect(Self.paths(IPMap.self, #"{"m":"notobject","after":"bad"}"#) == ["m", "after"])
        #expect(
            Self.paths(IPList.self, #"{"items":[7,{"x":1}],"tail":"bad"}"#) == ["items[0]", "tail"])
        // A closed enum (Enums.swift) and an open one (EnumGen), each given a non-string.
        #expect(Self.paths(IPEnumHolder.self, #"{"c":42,"o":"red","z":"bad"}"#) == ["c", "z"])
        #expect(Self.paths(IPEnumHolder.self, #"{"c":"red","o":["x"],"z":"bad"}"#) == ["o", "z"])
    }

    /// The RawValue path (YAML, TOML, XML) takes the path `inout` too, since 2026-09-19:
    /// push and pop around a nested field, `_assayPushed` inside an element expression.
    @Test("the RawValue path does not leak either (via YAML)")
    func rawPath() {
        func paths<T: RawDecodable>(_ t: T.Type, _ yaml: String) -> [String] {
            T.diagnose(yaml: yaml).issues.map(\.path.pathDescription)
        }
        #expect(paths(IPOuter.self, "a:\n  x: bad\nb: bad\n") == ["a.x", "b"])
        // Elements carry their index and dictionary entries their key, as on the JSON
        // path. These read `items.x` and `m.x` until the element-path fix the same day.
        #expect(
            paths(IPList.self, "items:\n- x: bad\n- x: 1\ntail: bad\n") == ["items[0].x", "tail"])
        #expect(paths(IPMap.self, "m:\n  k:\n    x: bad\nafter: bad\n") == ["m.k.x", "after"])
    }

    @Test("a clean decode through every nesting shape")
    func clean() throws {
        let g = try IPGroups.parse(
            json: """
                {"rows":[{"p":{"list":[1,2],"inner":{"x":3}},"z":4}],"last":5}
                """)
        #expect(g.rows.first?.list == [1, 2] && g.last == 5)
    }
}
