// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayYAML
import AssayTOML
import AssayXML

//===----------------------------------------------------------------------===//
// An issue inside an array or dictionary names the element, from every format.
//
// On the RawValue path (YAML, TOML, XML) an element's issue path had NO index until
// 2026-09-19: a bad `x` in the second item read `items.x` where JSON says `items[1].x`,
// and a scalar element `tags.tags` — the field key appended twice. A user with a
// thousand-element list was told the field, not the element. The generated body now
// pushes `.index(i)` per element and the dictionary key per entry, and the scalar
// helpers take an empty key to mean "the path already names this value".
//===----------------------------------------------------------------------===//

@Schema(formats: .all) struct REPInner: Equatable { var x: Int }
@Schema(formats: .all) struct REPDoc: Equatable {
    var items: [REPInner]
    var tags: [Int]
    var grid: [[Int]]
    var byName: [String: Int]
    var lists: [String: [Int]]
    var when: [Date]
    var maps: [[String: Int]] = []
}
@Schema(coerceScalars: true, formats: .all) struct REPTags: Equatable { var tag: [Int] }
@Schema(coerceScalars: true, formats: .all) struct REPWrapped: Equatable { @XML(.wrapped) var tags: [Int] }

@Suite struct RawElementPathTests {

    static func paths<T: RawDecodable>(_ d: Diagnosis<T>) -> [String] {
        d.issues.map(\.path.pathDescription)
    }

    @Test func yamlElementsCarryTheirIndexAndKey() {
        let yaml = """
        items:
        - x: 1
        - x: bad
        tags: [1, two, 3]
        grid: [[1], [2, nope]]
        byName: {a: 1, b: bad}
        lists: {k: [1, 2, bad]}
        when: [2026-01-01T00:00:00Z, notadate]
        maps: [{a: 1}, {b: 2, c: bad}]
        """
        #expect(Self.paths(REPDoc.diagnose(yaml: yaml)) == [
            "items[1].x", "tags[1]", "grid[1][1]", "byName.b", "lists.k[2]", "when[1]",
            "maps[1].c",
        ])
    }

    /// JSON had two of the same gaps, found by writing this test: `grid[1][1]` read
    /// `grid[1]` (the INNER index alone) and a date element named no element.
    @Test func jsonSaysTheSame() {
        let json = #"""
        {"items":[{"x":1},{"x":"bad"}],"tags":[1,"two",3],"grid":[[1],[2,"nope"]],
         "byName":{"a":1,"b":"bad"},"lists":{"k":[1,2,"bad"]},
         "when":["2026-01-01T00:00:00Z","notadate"],"maps":[{"a":1},{"b":2,"c":"bad"}]}
        """#
        let fromJSON = REPDoc.diagnose(json: Array(json.utf8)).issues.map(\.path.pathDescription)
        #expect(fromJSON == [
            "items[1].x", "tags[1]", "grid[1][1]", "byName.b", "lists.k[2]", "when[1]",
            "maps[1].c",
        ])
    }

    @Test func tomlElementsCarryTheirIndex() {
        let toml = """
        tags = [1, "two", 3]
        grid = [[1], [2, "nope"]]
        when = ["2026-01-01T00:00:00Z", "notadate"]
        [byName]
        a = 1
        b = "bad"
        [lists]
        k = [1, 2, "bad"]
        [[items]]
        x = 1
        [[items]]
        x = "bad"
        """
        #expect(Set(Self.paths(REPDoc.diagnose(toml: toml))) == [
            "items[1].x", "tags[1]", "grid[1][1]", "byName.b", "lists.k[2]", "when[1]",
        ])
    }

    /// XML spells a sequence as repeated siblings, each arriving as its own call: the
    /// index is how many came before it.
    @Test func xmlRepeatedSiblingsCountTheirPosition() {
        let xml = "<r><tag>1</tag><tag>bad</tag><tag>3</tag><tag>worse</tag></r>"
        #expect(Self.paths(REPTags.diagnose(xml: Array(xml.utf8))) == ["tag[1]", "tag[3]"])
    }

    @Test func xmlWrappedElementsCarryTheirPosition() {
        let xml = "<r><tags><t>1</t><t>bad</t></tags></r>"
        #expect(Self.paths(REPWrapped.diagnose(xml: Array(xml.utf8))) == ["tags[1]"])
    }

    @Test func aCleanDecodeIsUnchanged() throws {
        let yaml = """
        items:
        - x: 1
        tags: [1]
        grid: [[1, 2], []]
        byName: {a: 1}
        lists: {k: [3]}
        when: [2026-01-01T00:00:00Z]
        """
        let d = try REPDoc.parse(yaml: yaml)
        #expect(d.items == [REPInner(x: 1)] && d.tags == [1] && d.grid == [[1, 2], []])
        #expect(d.byName == ["a": 1] && d.lists == ["k": [3]] && d.when.count == 1)
    }
}
