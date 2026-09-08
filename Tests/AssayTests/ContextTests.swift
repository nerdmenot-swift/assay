// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Schema(context:)`, built 2026-09-08. EXPERIENCE §10, ROADMAP §8.
//
// The load-bearing tests here are the two the design turns on:
//
//   `contextualTypeContainingAPlainOne` — the composition case. The macro is syntactic and
//   emits `Membership._assay(..., context: context)` for EVERY nested type, because it reads
//   a token and cannot know whether that type declared a context. A plain type has no such
//   member; a defaulted generic overload in `Assay.swift` absorbs the argument. If overload
//   resolution ever preferred the absorbing overload for a type that DID declare a context,
//   the context would be silently dropped and every contextual check would run against
//   nothing — which is exactly the `@XML(root:)` failure, where a shadowed no-op compiled,
//   ran, and checked nothing. `nestedContextualTypeReceivesTheContext` is the other half:
//   it proves the concrete member wins when there is one.
//
//   `validateTakesTheContextToo` — `docs/VALIDATE.md`'s law is that
//   `T.validate(try T.parse(json: d))` never reports an issue. Without a contextual
//   `validate`, that law would be unstatable for exactly the types whose checks are most
//   interesting.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore
import AssayYAML
import AssayXML

/// A context with something a check genuinely cannot get from the document.
struct TenantContext: Sendable {
    var availableRoles: Set<String>
    var maximumSeats: Int
}

@Schema(context: TenantContext.self, keys: .snakeCase, formats: .all)
struct Invitation: Equatable {
    var email: String
    var role: String

    @Check
    static func roleIsAllowed(_ i: Invitation, _ ctx: TenantContext,
                              _ issues: inout Issues<Invitation>) {
        if !ctx.availableRoles.contains(i.role) {
            issues.add("is not available on your plan", at: \.role)
        }
    }
}

/// A plain nested type inside a contextual one — the absorbing-overload case.
@Schema
struct Membership: Equatable {
    var team: String
}

@Schema(context: TenantContext.self, keys: .snakeCase)
struct Seat: Equatable {
    var owner: String
    var membership: Membership
    var seatCount: Int

    @Check
    static func withinPlan(_ s: Seat, _ ctx: TenantContext, _ issues: inout Issues<Seat>) {
        if s.seatCount > ctx.maximumSeats {
            issues.add("exceeds the \(ctx.maximumSeats) seats on your plan", at: \.seatCount)
        }
    }
}

/// A CONTEXTUAL nested type inside a contextual one — the other half of the same question.
@Schema(context: TenantContext.self, keys: .snakeCase)
struct Assignment: Equatable {
    var role: String

    @Check
    static func known(_ a: Assignment, _ ctx: TenantContext,
                      _ issues: inout Issues<Assignment>) {
        if !ctx.availableRoles.contains(a.role) { issues.add("unknown role", at: \.role) }
    }
}

@Schema(context: TenantContext.self, keys: .snakeCase)
struct Grant: Equatable {
    var user: String
    var assignment: Assignment
}

/// Arrays and the field form of `@Check`, both of which take the context too.
@Schema(context: TenantContext.self, keys: .snakeCase)
struct Roster: Equatable {
    var name: String
    var assignments: [Assignment]

    @Check(\Roster.name)
    static func nameIsNotReserved(_ n: String, _ ctx: TenantContext) -> String? {
        ctx.availableRoles.contains(n) ? "collides with a role name" : nil
    }
}

@Suite("@Schema(context:)")
struct ContextTests {

    static let ctx = TenantContext(availableRoles: ["admin", "member"], maximumSeats: 5)

    @Test("a context reaches a cross-field check")
    func reachesTheCheck() throws {
        let ok = try Invitation.parse(json: #"{"email":"a@b.com","role":"admin"}"#,
                                      context: Self.ctx)
        #expect(ok.role == "admin")

        let bad = Invitation.diagnose(json: #"{"email":"a@b.com","role":"owner"}"#,
                                      context: Self.ctx)
        #expect(!bad.isValid)
        #expect(bad.issues.first?.path.description.contains("role") == true)
        #expect(bad.issues.first?.message.contains("not available") == true)
    }

    /// The same document, two contexts, two verdicts. This is the whole feature: the
    /// answer depends on something the bytes do not contain.
    @Test("the same document decodes differently under two contexts")
    func twoContexts() {
        let json = #"{"email":"a@b.com","role":"auditor"}"#
        let narrow = TenantContext(availableRoles: ["admin"], maximumSeats: 5)
        let wide = TenantContext(availableRoles: ["admin", "auditor"], maximumSeats: 5)
        #expect(!Invitation.diagnose(json: json, context: narrow).isValid)
        #expect(Invitation.diagnose(json: json, context: wide).isValid)
    }

    /// **Load-bearing.** The absorbing overload must accept the argument the macro emits
    /// for a nested type that never declared a context.
    @Test("a contextual type may contain a plain one")
    func contextualTypeContainingAPlainOne() throws {
        let s = try Seat.parse(
            json: #"{"owner":"ada","membership":{"team":"core"},"seat_count":3}"#,
            context: Self.ctx)
        #expect(s.membership.team == "core")

        let over = Seat.diagnose(
            json: #"{"owner":"ada","membership":{"team":"core"},"seat_count":9}"#,
            context: Self.ctx)
        #expect(!over.isValid)
        #expect(over.issues.first?.message.contains("5 seats") == true)
    }

    /// **Load-bearing, the other half.** A nested type that DID declare a context must
    /// receive it — if the absorbing overload won here, the nested check would silently
    /// never run.
    @Test("a nested contextual type receives the context")
    func nestedContextualTypeReceivesTheContext() {
        let d = Grant.diagnose(json: #"{"user":"ada","assignment":{"role":"ghost"}}"#,
                               context: Self.ctx)
        #expect(!d.isValid, "the nested check did not run — the context was dropped")
        #expect(d.issues.first?.message.contains("unknown role") == true)
        #expect(d.issues.first?.path.description.contains("assignment") == true)
    }

    @Test("array elements of a contextual type receive the context")
    func arrayElements() {
        let d = Roster.diagnose(
            json: #"{"name":"team","assignments":[{"role":"admin"},{"role":"ghost"}]}"#,
            context: Self.ctx)
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.path.description.contains("assignments") })
        #expect(d.issues.contains { $0.path.description.contains("1") },
                "the bad element is at index 1: \(d.issues.map(\.path.description))")
    }

    @Test("the field form of @Check takes the context too")
    func fieldFormCheck() {
        let d = Roster.diagnose(json: #"{"name":"admin","assignments":[]}"#,
                                context: Self.ctx)
        #expect(!d.isValid)
        #expect(d.issues.first?.message.contains("collides") == true)
    }

    /// `docs/VALIDATE.md`'s law, restated for contextual types.
    @Test("validate takes the context, and agrees with parse")
    func validateTakesTheContextToo() throws {
        let v = try Invitation.parse(json: #"{"email":"a@b.com","role":"admin"}"#,
                                     context: Self.ctx)
        #expect(throws: Never.self) { try Invitation.validate(v, context: Self.ctx) }

        // A value the context rejects — constructed directly, which is the seam
        // `T.validate(_:)` exists for.
        let narrow = TenantContext(availableRoles: [], maximumSeats: 5)
        let d = Invitation.diagnose(v, context: narrow)
        #expect(!d.isValid)
    }

    @Test("YAML and XML reach the same check")
    func otherFormats() throws {
        let y = try Invitation.parse(yaml: "email: a@b.com\nrole: admin\n", context: Self.ctx)
        #expect(y.role == "admin")
        #expect(!Invitation.diagnose(yaml: "email: a@b.com\nrole: ghost\n",
                                     context: Self.ctx).isValid)

        let x = try Invitation.parse(
            xml: "<invitation><email>a@b.com</email><role>admin</role></invitation>",
            context: Self.ctx)
        #expect(x.email == "a@b.com")
    }

    /// The claim `EXPERIENCE.md` §10 makes in one sentence — "you cannot forget to pass it"
    /// — is enforced by the type system rather than by discipline, because a contextual type
    /// conforms to `ContextualJSONAssayable` and NOT to `JSONAssayable`.
    @Test("a contextual type does not conform to the context-free protocol")
    func contextIsNotOptional() {
        #expect(!((Invitation.self as Any.Type) is any JSONAssayable.Type))
        #expect((Invitation.self as Any.Type) is any ContextualJSONAssayable.Type)
    }

    /// Rules, keys and unknown-key policy are untouched by the context — the context is an
    /// argument to the checks, not a different decoder.
    @Test("everything else about the schema still works")
    func ordinaryFeaturesSurvive() throws {
        let s = try Seat.parse(
            json: #"{"owner":"ada","membership":{"team":"core"},"seat_count":1,"extra":2}"#,
            context: Self.ctx)
        #expect(s.seatCount == 1, "snake_case key mapping still applies")

        let d = Seat.diagnose(json: #"{"owner":"ada","membership":{"team":"core"}}"#,
                              context: Self.ctx)
        #expect(!d.isValid, "a missing required field is still missing")
    }
}

// MARK: - `@AsyncCheck` with a context
//
// §10's own motivating example — `await ctx.users.exists(email:)` — which is the concrete
// reason ROADMAP §8's "no users" argument stopped holding: `@AsyncCheck` shipped without any
// way to reach the thing it was documented as reaching.

struct DirectoryContext: Sendable {
    var taken: Set<String>
}

@Schema(context: DirectoryContext.self, keys: .snakeCase)
struct Registration: Equatable {
    var email: String

    @AsyncCheck
    static func emailIsFree(_ r: Registration, _ ctx: DirectoryContext,
                            _ issues: inout Issues<Registration>) async {
        if ctx.taken.contains(r.email) { issues.add("is already registered", at: \.email) }
    }
}

@Suite("@Schema(context:) — async")
struct ContextAsyncTests {

    @Test("an async check receives the context")
    func asyncCheck() async throws {
        let free = DirectoryContext(taken: [])
        let r = try await Registration.parse(json: #"{"email":"a@b.com"}"#, context: free)
        #expect(r.email == "a@b.com")

        let taken = DirectoryContext(taken: ["a@b.com"])
        let d = await Registration.diagnose(json: #"{"email":"a@b.com"}"#, context: taken)
        #expect(!d.isValid)
        #expect(d.issues.first?.message.contains("already registered") == true)
    }

    /// The ordering `EXPERIENCE.md` §10 states: async checks run only if the sync pass was
    /// clean, so a malformed document never reaches the network.
    @Test("async checks do not run when the sync pass failed")
    func asyncSkippedOnSyncFailure() async {
        let taken = DirectoryContext(taken: ["a@b.com"])
        let d = await Registration.diagnose(json: #"{"email":42}"#, context: taken)
        #expect(!d.isValid)
        #expect(d.issues.allSatisfy { !$0.message.contains("already registered") })
    }
}
