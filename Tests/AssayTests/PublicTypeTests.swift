// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay

// Regression test for a bug the compile-time harness caught and the rest of the suite
// could not: the generated `_assay` was marked `@inlinable`, and SE-0193 restricts an
// @inlinable body to referencing ABI-public declarations. A *public* struct's memberwise
// initializer is internal, so every public @Schema type failed with:
//
//   error: initializer 'init(id:name:)' is internal and cannot be referenced from an
//          '@inlinable' function
//
// Every other test type in this suite is internal, so none of them exercised it. This
// file exists so that access-level combination is always compiled.
//
// If this file stops compiling, the macro has started emitting something that a public
// type cannot satisfy.

@Schema
public struct PublicArticle {
    public var title: String
    public var readingMinutes: Int
    public var tags: [String] = []
}

@Schema(keys: .snakeCase)
public struct PublicProfile {
    public var userID: String
    public var displayName: String
    public var isActive: Bool
    public var nickname: String?
}

@Schema
public struct PublicOuter {
    public var name: String
    public var inner: PublicArticle
}

@Suite("Public types")
struct PublicTypeTests {

    @Test("a public @Schema type compiles and decodes")
    func publicDecodes() throws {
        let a = try PublicArticle.parse(json: #"{"title":"t","readingMinutes":3,"tags":["x"]}"#)
        #expect(a.title == "t")
        #expect(a.readingMinutes == 3)
        #expect(a.tags == ["x"])
    }

    @Test("public + snake_case + optional")
    func publicSnake() throws {
        let p = try PublicProfile.parse(
            json: #"{"user_id":"u","display_name":"D","is_active":true}"#)
        #expect(p.userID == "u")
        #expect(p.displayName == "D")
        #expect(p.isActive)
        #expect(p.nickname == nil)
    }

    @Test("public type nested in a public type")
    func publicNested() throws {
        let o = try PublicOuter.parse(
            json: #"{"name":"n","inner":{"title":"t","readingMinutes":1,"tags":[]}}"#)
        #expect(o.inner.title == "t")
    }

    @Test("explicit null is distinct from absence")
    func explicitNull() throws {
        // Optional field, explicit null: fine, and nil.
        let p = try PublicProfile.parse(
            json: #"{"user_id":"u","display_name":"D","is_active":true,"nickname":null}"#)
        #expect(p.nickname == nil)

        // Required field, explicit null: an error, not a silent default.
        let d = PublicProfile.diagnose(
            json: #"{"user_id":null,"display_name":"D","is_active":true}"#)
        #expect(d.isValid == false)
    }
}
