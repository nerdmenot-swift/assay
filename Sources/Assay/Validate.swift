// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Validating a value you already have. docs/VALIDATE.md.
//
// WHY THIS EXISTS. Assay fuses validation into decoding, which is the right default and is
// most of what makes it fast: the rules run against the wire value, in the same pass, with
// the byte offsets still in hand, so a violation gets a caret. But it left a real hole. If
// something ELSE produced your value — a fast columnar reader, a database driver, a hand
// written initialiser, a UI form, a value you mutated after decoding — there was no way to
// ask the schema whether it is still legal. The rules were declared on the type and only
// reachable through a decode.
//
// That hole is what closes here, and it is the correct seam between Assay and a
// specialised reader. A Parquet or CSV library decodes far faster than any generic path
// can, because it knows its own layout; what it does NOT have is a rule engine, an issue
// vocabulary, or a renderer. So:
//
//     let trips = try Table("trips.parquet").rows(of: Trip.self)   // their decode
//     try Trip.validate(trips)                                     // our rules
//
// Neither side pays for the other. This is deliberately NOT a decode path — an earlier
// attempt to make one general enough to serve such readers was built, measured, and
// removed; Sources/AssayCore/ColumnarSource.swift's header records why.
//
// WHAT RUNS, AND WHAT CANNOT. The governing law is
//
//     T.validate(try T.parse(json: d))   never reports an issue
//
// for any `d` that parses cleanly — a value the decoder accepted must not be rejected by
// the validator. `Tests/AssayTests/ValidateValueTests.swift` checks it over the corpus. Holding
// that law is what decides the three exclusions:
//
//   * @Preprocess does not run. It normalises WIRE text before decoding — `.trim` on a
//     string that arrived with spaces. The value in hand is already decoded, and `validate`
//     reports rather than mutates, so there is nothing for it to do.
//   * A @Fallback field's rules do not run. At decode time a violation there is SWALLOWED:
//     the field takes its fallback and records a warning. Re-reporting it against the
//     constructed value would break the law directly.
//   * A @Transform field's rules do not run. Rules are checked against the WIRE type and
//     the transform runs after them, so the property holds a different type than the rules
//     were type-checked against. The macro names such fields, and says why, in the doc
//     comment it generates on `_assayCheck` — so the exclusion shows up in quick-help
//     rather than being discovered by a check that quietly never ran.
//
// NO CARETS. Issues carry a path and no location, because there is no source document to
// point at. The renderer has always handled that — a missing-field issue has never had a
// span either.
//===----------------------------------------------------------------------===//

public import AssayCore

/// A type whose `@Schema` rules can be run against an already-constructed value.
///
/// Conformance is generated whenever a schema declares any `@Validate` or `@Check`. It is
/// not opt-in like `encodes:` or `sources:`, because a type that declares no rules gets an
/// empty body and pays nothing — the generated code is proportional to the rules that are
/// already there.
public protocol Validatable: Sendable {
    /// Run every rule and cross-field check against `value`. Generated.
    nonisolated static func _assayCheck(
        _ value: Self, into sink: inout IssueSink, at path: [PathComponent])
}

/// Everything a validation pass found.
///
/// Deliberately not `Diagnosis`: there is no `value` (you already have it) and no source
/// bytes (there is no document), and a result type that carried two empty fields would be
/// claiming a caret it cannot render.
public struct Validation: Sendable {
    public var issues: [Issue]
    public var warnings: [Warning]
    /// True when `Limits.maxIssues` was hit — a hundred-of-a-hundred reads differently
    /// from a hundred-of-ten-thousand, and over a batch that distinction is the usual one.
    public var truncatedIssues: Bool

    public init(issues: [Issue], warnings: [Warning], truncatedIssues: Bool) {
        self.issues = issues
        self.warnings = warnings
        self.truncatedIssues = truncatedIssues
    }

    public var isValid: Bool { issues.isEmpty }

    /// Throw if anything failed, with every issue — the same error type every other path
    /// throws, so one `catch let e as AssayError` covers decoding and validation alike.
    public func check() throws(AssayError) {
        guard issues.isEmpty else {
            throw AssayError(issues: issues, source: SourceBytes([]), sourceName: "<value>")
        }
    }

    /// Paths and messages, in the same styles the decode paths render. No carets: see this
    /// file's header.
    public func render(_ style: RenderStyle) -> String {
        Renderer.render(issues: issues, warnings: warnings,
                        source: SourceBytes([]), sourceName: "<value>", style: style)
    }
}

extension Validatable {

    // `@inlinable` on all four, and it is load-bearing rather than decorative. These are
    // generic over `Self` and over the sequence, they live in a source package, and the call
    // site is in the user's module — which is hard constraint 5's exact case: without it,
    // cross-module specialization does not happen and the per-element iteration runs through
    // witness tables. The batch measured 176 ns/row against 79 ns for the identical check on
    // a single value; adding these four attributes took it to 87, which is 79 plus the array
    // element copy. The gap was the unspecialized loop, not the rules.
    //
    // SE-0193's restriction does not bite here: these bodies reference only public API. It
    // is `@Schema`'s GENERATED bodies that cannot be @inlinable, because a public type's
    // memberwise init is internal.

    /// Run the schema's rules against one value and report everything.
    @inlinable
    public static func diagnose(_ value: Self, limits: Limits = .default) -> Validation {
        diagnose(value, at: [], limits: limits)
    }

    /// Run the schema's rules against one value, reporting under a path YOU supply.
    ///
    /// The batch forms below prefix `[i]` — the element's index in the sequence handed to
    /// them. For a reader that filtered, sampled, or resumed mid-file, that index is not
    /// the row number, and reporting "row 3" for line 91,824 is worse than reporting no
    /// row at all. A caller that knows the real position passes it:
    ///
    ///     for row in reader.rows(of: Trip.self) {
    ///         issues += Trip.diagnose(row.value, at: [.index(row.lineNumber)]).issues
    ///     }
    ///
    /// Any path shape works — `[.key("trips.parquet"), .index(91_824)]` names the file as
    /// well — because a `PathComponent` array is exactly what every other issue carries.
    @inlinable
    public static func diagnose(
        _ value: Self, at path: [PathComponent], limits: Limits = .default
    ) -> Validation {
        var sink = IssueSink(limits: limits)
        Self._assayCheck(value, into: &sink, at: path)
        return Validation(issues: sink.issues, warnings: sink.warnings,
                          truncatedIssues: sink.truncatedIssues)
    }

    /// Run the schema's rules against one value, throwing every issue at once.
    @inlinable
    public static func validate(_ value: Self, limits: Limits = .default) throws(AssayError) {
        try diagnose(value, at: [], limits: limits).check()
    }

    /// The throwing form of `diagnose(_:at:)`.
    @inlinable
    public static func validate(
        _ value: Self, at path: [PathComponent], limits: Limits = .default
    ) throws(AssayError) {
        try diagnose(value, at: path, limits: limits).check()
    }

    /// Run the schema's rules over a batch. Issues carry `[i]` for the element's index in
    /// `values` — which is the row number only when the caller has handed over every row in
    /// order. A reader that filtered or resumed wants `diagnose(_:at:)` per element instead.
    ///
    /// One sink for the whole batch, so `Limits.maxIssues` bounds the REPORT rather than
    /// each element — otherwise a file where every row is bad produces a million issues and
    /// the limit protects nothing.
    @inlinable
    public static func diagnose(
        _ values: some Sequence<Self>, limits: Limits = .default
    ) -> Validation {
        var sink = IssueSink(limits: limits)
        // ONE path array, rewritten in place per element. `[.index(i)]` inside the loop is
        // the obvious spelling and allocates per row; this is worth ~16 ns of the ~90 the
        // loop costs. Nothing retains the buffer — an Issue stores `path + [...]`, a fresh
        // array — so it stays uniquely referenced and the assignment is in place.
        var path: [PathComponent] = [.index(0)]
        for (i, v) in values.enumerated() {
            path[0] = .index(i)
            Self._assayCheck(v, into: &sink, at: path)
        }
        return Validation(issues: sink.issues, warnings: sink.warnings,
                          truncatedIssues: sink.truncatedIssues)
    }

    /// Run the schema's rules over a batch, throwing if any element failed.
    @inlinable
    public static func validate(
        _ values: some Sequence<Self>, limits: Limits = .default
    ) throws(AssayError) {
        try diagnose(values, limits: limits).check()
    }
}

// MARK: - Async checks
//
// The same ordering the decode paths use, for the same reason (EXPERIENCE.md §10): the
// synchronous pass collects EVERYTHING first, and async checks run only if it was clean.
// A round trip to a database to see whether a slug is taken is wasted work on a value that
// already failed `.min(1)`.

extension Validatable where Self: AsyncCheckAssayable {

    public static func diagnose(_ value: Self, limits: Limits = .default) async -> Validation {
        // The non-async function type pins overload resolution to the sync entry point;
        // without it, an async context prefers this very function and recurses.
        let syncDiagnose: (Self, Limits) -> Validation = Self.diagnose(_:limits:)
        var v = syncDiagnose(value, limits)
        guard v.isValid else { return v }
        v.issues = await Self._assayAsyncChecks(value, at: [])
        return v
    }

    public static func validate(
        _ value: Self, limits: Limits = .default
    ) async throws(AssayError) {
        try await diagnose(value, limits: limits).check()
    }

    /// A batch, with the async checks for every element run CONCURRENTLY. The elements are
    /// independent by construction — a check takes one value — so serialising them would
    /// turn N round trips into N sequential ones for no reason.
    public static func diagnose(
        _ values: some Sequence<Self>, limits: Limits = .default
    ) async -> Validation {
        let syncDiagnose: ([Self], Limits) -> Validation = Self.diagnose(_:limits:)
        let all = Array(values)
        var v = syncDiagnose(all, limits)
        guard v.isValid else { return v }

        v.issues = await withTaskGroup(of: [Issue].self) { group in
            for (i, value) in all.enumerated() {
                group.addTask { await Self._assayAsyncChecks(value, at: [.index(i)]) }
            }
            var out: [Issue] = []
            for await issues in group { out += issues }
            return out
        }
        return v
    }

    public static func validate(
        _ values: some Sequence<Self>, limits: Limits = .default
    ) async throws(AssayError) {
        try await diagnose(values, limits: limits).check()
    }
}
