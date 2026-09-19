// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

//===----------------------------------------------------------------------===//
// PER-BUCKET WINDOWS — the fallback dispatch, past the global window's ceiling.
//
// The global window needs one 8-bit window distinct across every key and gives out at about
// a dozen fields. Past that the fallback buckets by length, and since 2026-09-19 a bucket
// whose linear chain would be EXPENSIVE (keys sharing long prefixes) gets its own window: what
// stays linear is a collision group, never the bucket. A cheap chain — realistic names, whose
// first bytes differ — is left alone, because the window costs compile time and buys nothing
// there.
//
// The hazard a window adds is a FALSE ACCEPT: an undeclared key of the same length whose
// window value lands on a declared key's arm. The arm's `keyMatches` is what refuses it, so
// the test below throws every one-byte mutation of every declared key at a `.reject` schema
// and requires each to be reported — whichever arm it lands on.
//===----------------------------------------------------------------------===//

@Schema(keys: .snakeCase, unknownKeys: .reject)
struct BucketWide: Equatable {
    var id: String
    @Key("name", or: "nick") var name: String
    var email: String
    var createdAt: String
    var updatedAt: String
    var status: String
    var type: String
    var description: String
    var url: String
    var avatarUrl: String
    var userId: String
    var ownerId: String
    var title: String
    var body: String
    var tags: String
    var count: String
}

/// Same length, same prefix: the shape whose chain is expensive and which therefore gets a
/// window. `item_99` is an alias in the same bucket, so aliases go through a window arm too.
@Schema(unknownKeys: .reject)
struct BucketPrefixed: Equatable {
    var item_00: String
    var item_01: String
    var item_02: String
    @Key("item_03", or: "item_99") var item_03: String
    var item_04: String
    var item_05: String
    var item_06: String
    var item_07: String
    var item_08: String
    var item_09: String
    var item_10: String
    var item_11: String
    var item_12: String
    var item_13: String
    var item_14: String
    var item_15: String
}

@Suite("Per-bucket window dispatch")
struct BucketDispatchTests {

    static let keys = ["id", "name", "email", "created_at", "updated_at", "status", "type",
                       "description", "url", "avatar_url", "user_id", "owner_id", "title",
                       "body", "tags", "count"]

    static func document(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { "\"\($0.0)\":\"\($0.1)\"" }.joined(separator: ",") + "}"
    }

    static let prefixed = (0..<16).map { "item_" + ($0 < 10 ? "0" : "") + String($0) }

    static func windows(_ keys: [String]) -> (Int, String) {
        let fields = keys.map { "var \($0): String" }.joined(separator: "\n")
        let (expansion, _) = expandSchemaForTesting("@Schema struct S {\n\(fields)\n}")
        return (expansion.components(separatedBy: "reader._keyWindow(__key").count - 1,
                expansion)
    }

    @Test("realistic names past the global ceiling keep their cheap chains")
    func realisticKeepsChains() {
        let (n, expansion) = Self.windows(Self.keys)
        // The global search fails on this set — the premise of the test.
        #expect(!expansion.contains("__assayKeyTable"))
        #expect(expansion.contains("switch __key.len"))
        #expect(n == 0, "\(expansion)")
    }

    @Test("same-prefix keys past the global ceiling get a bucket window")
    func prefixedGetsWindow() {
        let (n, expansion) = Self.windows(Self.prefixed)
        #expect(!expansion.contains("__assayKeyTable"))
        #expect(n == 1, "\(expansion)")
    }

    @Test("every declared key decodes, in any order")
    func decodesAll() throws {
        let pairs = Self.keys.map { ($0, "v-" + $0) }
        let forward = try BucketWide.parse(json: Self.document(pairs))
        let backward = try BucketWide.parse(json: Self.document(pairs.reversed()))
        #expect(forward == backward)
        #expect(forward.name == "v-name")
        #expect(forward.avatarUrl == "v-avatar_url")
        #expect(forward.count == "v-count")
    }

    @Test("an alias inside a windowed bucket selects its field and says so")
    func alias() {
        let pairs = Self.keys.map { ($0 == "name" ? "nick" : $0, "v-" + $0) }
        let d = BucketWide.diagnose(json: Self.document(pairs))
        #expect(d.isValid, "\(d.issues)")
        #expect(d.value?.name == "v-name")
        #expect(d.warnings.map(\.code.codeString) == ["alias_matched"])
    }

    /// Every one-byte mutation of every declared key, thrown at a `.reject` schema.
    static func mutants(of declared: Set<String>) -> [String] {
        var out: [String] = []
        for key in declared {
            let bytes = Array(key.utf8)
            for i in bytes.indices {
                for c in Array(UInt8(ascii: "a")...UInt8(ascii: "z"))
                    + Array(UInt8(ascii: "0")...UInt8(ascii: "9")) where c != bytes[i] {
                    var m = bytes; m[i] = c
                    let mutant = String(decoding: m, as: UTF8.self)
                    if !declared.contains(mutant) { out.append(mutant) }
                }
            }
        }
        return out
    }

    @Test("no one-byte mutation of a declared key is accepted as that key")
    func noFalseAccept() {
        let base = Self.keys.map { ($0, "v") }
        let mutants = Self.mutants(of: Set(Self.keys + ["nick"]))
        for mutant in mutants {
            let d = BucketWide.diagnose(json: Self.document(base + [(mutant, "x")]))
            #expect(d.issues.map(\.code.codeString) == ["unknown_key"], "\(mutant): \(d.issues)")
            #expect(d.issues.first?.received == mutant)
        }
        #expect(mutants.count > 2_000)
    }

    @Test("no one-byte mutation is accepted through a window arm either")
    func noFalseAcceptThroughWindow() throws {
        let base = Self.prefixed.map { ($0, "v-" + $0) }
        let v = try BucketPrefixed.parse(json: Self.document(base.reversed()))
        #expect(v.item_15 == "v-item_15" && v.item_03 == "v-item_03")
        let viaAlias = BucketPrefixed.diagnose(json: Self.document(
            base.map { ($0.0 == "item_03" ? "item_99" : $0.0, $0.1) }))
        #expect(viaAlias.value?.item_03 == "v-item_03")
        #expect(viaAlias.warnings.map(\.code.codeString) == ["alias_matched"])

        let mutants = Self.mutants(of: Set(Self.prefixed + ["item_99"]))
        for mutant in mutants {
            let d = BucketPrefixed.diagnose(json: Self.document(base + [(mutant, "x")]))
            #expect(d.issues.map(\.code.codeString) == ["unknown_key"], "\(mutant): \(d.issues)")
            #expect(d.issues.first?.received == mutant)
        }
        #expect(mutants.count > 3_000)
    }
}
