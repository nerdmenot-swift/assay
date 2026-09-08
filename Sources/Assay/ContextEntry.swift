// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Schema(context:)` — the entry points. EXPERIENCE.md §10, ROADMAP.md §8.
//
// ```swift
// @Schema(context: AppContext.self)
// struct Invitation {
//     var email: String
//     var role: String
//
//     @Check
//     static func roleIsAllowed(_ i: Invitation, _ ctx: AppContext,
//                               _ issues: inout Issues<Invitation>) {
//         if !ctx.availableRoles.contains(i.role) { issues.add("is not available", at: \.role) }
//     }
// }
//
// let invite = try Invitation.parse(json: data, context: appContext)
// ```
//
// WHY A SEPARATE PROTOCOL RATHER THAN A DEFAULTED PARAMETER, which is the whole design.
// `EXPERIENCE.md` §10's claim is "declaring a context makes `parse(json:context:)` the ONLY
// signature — you cannot forget to pass it." A defaulted `context: C? = nil` on the existing
// entry point makes that claim false: `parse(json:)` still compiles and the checks get a nil
// they have to unwrap, which is the `userInfo` dictionary again with better syntax.
//
// A contextual type conforms to `ContextualJSONAssayable` and NOT to `JSONAssayable`, so the
// context-free `parse(json:)` — constrained on `JSONAssayable` — is not merely discouraged,
// it does not exist for that type. The compiler enforces the sentence.
//
// WHAT THIS IS NOT. `EXPERIENCE.md` §10 also describes a type-ERASED runtime context for
// `Assayer<T>`, for schemas built dynamically. That is not built and is not on the way: it
// would be designing for an imaginary user twice over, once for the API and once for the
// erasure. The macro knows the context type at compile time and uses it.
//
// THE ONE ASYMMETRY, stated because it is a real edge the macro cannot detect. A contextual
// type may CONTAIN a context-free one — the generated call is absorbed by a defaulted
// generic overload in `Assay.swift`. The converse — a plain `@Schema` type with a contextual
// field — cannot work, because there is no context to pass. A macro reads a token: it sees
// `var m: Membership` and cannot know whether `Membership` declared a context, in this module
// or any other. Same class of limitation as `@Check` in an extension.
//
// It is caught, and the message says what to do. See the unavailable overloads below: what
// the macro cannot detect, overload resolution can, because it happens after type checking
// knows what `Membership` is.
//===----------------------------------------------------------------------===//

import AssayCore

// THE REVERSE-NESTING DIAGNOSTIC.
//
// A plain `@Schema` type with a contextual field emits `Inner._assay(from:into:at:)` — no
// context, because the macro read the token `Inner` and cannot know what it declared, in
// this module or any other. Without these, the error is "no exact matches in call to static
// method '_assay'", pointing into an expansion the author did not write.
//
// An `unavailable` overload is what turns that into a sentence. It is an exact match, so
// resolution selects it, and unavailability then reports the message below instead. It can
// only ever be selected by code that has already gone wrong: valid code calls the
// four-argument form.
extension ContextualJSONAssayable {
    @available(*, unavailable, message: "this type declared @Schema(context:), so it can only be decoded with a context — but it is nested inside a type that declared none. Add the same `context:` to the outer @Schema, or drop it from this one. (A macro reads a type's NAME, so it cannot detect this at expansion.)")
    public nonisolated static func _assay(
        from reader: inout AssayReader, into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self? { nil }
}

extension ContextualRawDecodable {
    @available(*, unavailable, message: "this type declared @Schema(context:), so it can only be decoded with a context — but it is nested inside a type that declared none. Add the same `context:` to the outer @Schema, or drop it from this one. (A macro reads a type's NAME, so it cannot detect this at expansion.)")
    public nonisolated static func _assay(
        from raw: RawValue, into sink: inout IssueSink, at path: [PathComponent]
    ) -> Self? { nil }
}

extension ContextualJSONAssayable {

    /// The shared decode core, `Entry.swift`'s with a context threaded through. Kept
    /// verbatim rather than factored: the only difference is one argument to `_assay`, and
    /// a shared generic core would need a closure over an `inout` reader — `PERFORMANCE.md`
    /// §7's rule 9, no closures capturing the hot path.
    public static func _decode(
        base: UnsafePointer<UInt8>,
        count: Int,
        into sink: inout IssueSink,
        limits: Limits,
        context: AssayContext
    ) -> Self? {
        if let bad = unsafe UTF8Validation.firstInvalid(base, count) {
            sink.add(Issue(
                code: .invalidUTF8,
                params: ["offset": .int(bad)],
                location: SourceSpan(lo: bad, len: 1)))
            return nil
        }

        var reader = unsafe AssayReader(base: base, count: count, limits: limits)
        let v = Self._assay(from: &reader, into: &sink, at: [], context: context)

        reader.skipWhitespace()
        if !reader.atEnd {
            sink.add(Issue(code: .trailingContent,
                           location: SourceSpan(lo: reader.byteOffset, len: 1)))
            return nil
        }
        return v
    }

    /// Decode, or throw with every issue found.
    public static func parse(
        json bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(json: bytes, context: context,
                     limits: limits, sourceName: sourceName).get()
    }

    /// Decode and report everything, including the value when one was produced.
    public static func diagnose(
        json bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        var sink = IssueSink(limits: limits)

        if bytes.count > limits.maxBytes {
            sink.add(Issue(code: .tooManyBytes, params: ["maxBytes": .int(limits.maxBytes)]))
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }

        let value: Self? = bytes.withUnsafeBufferPointer { buf -> Self? in
            guard let base = buf.baseAddress else { return nil }
            return unsafe Self._decode(base: base, count: buf.count,
                                       into: &sink, limits: limits, context: context)
        }

        return Diagnosis(
            value: sink.isValid ? value : nil,
            issues: sink.issues,
            warnings: sink.warnings,
            truncatedIssues: sink.truncatedIssues,
            source: SourceBytes(bytes),
            sourceName: sourceName)
    }

    public static func parse(
        json text: String,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try parse(json: Array(text.utf8), context: context,
                  limits: limits, sourceName: sourceName)
    }

    public static func diagnose(
        json text: String,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        diagnose(json: Array(text.utf8), context: context,
                 limits: limits, sourceName: sourceName)
    }
}

// MARK: - The async pair

extension ContextualJSONAssayable where Self: ContextualAsyncCheckAssayable {

    /// Sync first, collecting everything; async checks only on a clean sync pass. The same
    /// ordering `EXPERIENCE.md` §10 states for the context-free door, and the reason
    /// `@AsyncCheck` needed this feature: `await ctx.users.exists(email:)` is §10's own
    /// example and could not be written at all before.
    public static func parse(
        json bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async throws -> Self {
        try await diagnose(json: bytes, context: context,
                           limits: limits, sourceName: sourceName).get()
    }

    public static func parse(
        json text: String,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async throws -> Self {
        try await parse(json: Array(text.utf8), context: context,
                        limits: limits, sourceName: sourceName)
    }

    public static func diagnose(
        json bytes: [UInt8],
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async -> Diagnosis<Self> {
        // The non-async function type pins overload resolution to the sync `diagnose`;
        // without it, an async context prefers THIS function and recurses. Exactly the
        // shape `Assay.swift`'s context-free async pair already uses.
        let syncDiagnose: ([UInt8], AssayContext, Limits, String) -> Diagnosis<Self> =
            Self.diagnose(json:context:limits:sourceName:)
        let d = syncDiagnose(bytes, context, limits, sourceName)
        guard d.isValid, let v = d.value else { return d }
        let extra = await Self._assayAsyncChecks(v, at: [], context: context)
        guard !extra.isEmpty else { return d }
        return Diagnosis(value: nil, issues: d.issues + extra, warnings: d.warnings,
                         truncatedIssues: d.truncatedIssues,
                         source: d.source, sourceName: d.sourceName)
    }

    /// The `String` convenience, and it is not optional sugar. Without it, a call written
    /// `await T.diagnose(json: "...", context: c)` has exactly one candidate — the SYNC
    /// `String` overload in the extension above — so it compiles, runs, and skips every
    /// async check. That is what happened, and only a test asserting a taken email was
    /// rejected noticed. An overload that is merely not selected produces no diagnostic.
    public static func diagnose(
        json text: String,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async -> Diagnosis<Self> {
        await diagnose(json: Array(text.utf8), context: context,
                       limits: limits, sourceName: sourceName)
    }
}

// MARK: - validate

extension ContextualValidatable {

    /// The schema's rules against an already-constructed value, with the context the checks
    /// need. `docs/VALIDATE.md`'s law — `T.validate(try T.parse(json: d))` never reports an
    /// issue — is only statable for a contextual type if this exists, and the types whose
    /// checks reach outside are exactly the ones where it matters most.
    public static func validate(
        _ value: Self, context: AssayContext, limits: Limits = .default
    ) throws(AssayError) {
        try diagnose(value, context: context, limits: limits).check()
    }

    public static func diagnose(
        _ value: Self,
        context: AssayContext,
        limits: Limits = .default
    ) -> Validation {
        var sink = IssueSink(limits: limits)
        Self._assayCheck(value, into: &sink, at: [], context: context)
        return Validation(issues: sink.issues, warnings: sink.warnings,
                          truncatedIssues: sink.truncatedIssues)
    }
}
