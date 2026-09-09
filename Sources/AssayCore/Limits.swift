// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Limits are part of the call, not a global.
//
// docs/EXPERIENCE.md §2: this was missing entirely from the first edition and it was a
// denial-of-service hole — a ten-megabyte array of malformed values would have produced
// a hundred thousand issues, each retaining a source span.
//===----------------------------------------------------------------------===//

public struct Limits: Sendable, Equatable {
    /// Stop collecting after this many issues. `Diagnosis.truncatedIssues` reports it.
    public var maxIssues: Int
    /// Maximum container nesting. Guards stack exhaustion — which bites first and
    /// hardest on WebAssembly, where the default stack is small enough that a
    /// recursive-descent parser traps rather than reporting an error.
    public var maxDepth: Int
    /// Refuse inputs larger than this outright.
    public var maxBytes: Int
    /// Branch attempts an **untagged** union may make across one decode. `docs/UNIONS.md` §3.
    ///
    /// Global rather than per-union, because the blow-up is not one union with many branches —
    /// it is *nested* unions. `[[U]]` where `U` has three branches costs 3 attempts per
    /// element and 3ⁿ for n levels, and `maxDepth` cannot see it: the depth is the array
    /// nesting and the expansion is in the breadth. Structurally the same attack as the
    /// plist's shared-object amplification (`docs/PLIST.md` §2.2), with the same answer.
    ///
    /// A *discriminated* union charges one attempt regardless of variant count, because it
    /// makes exactly one. Only the untagged form can multiply.
    ///
    /// The default is far above any real document — a hand-written schema nests unions two or
    /// three deep — so reaching it means an attack or a bug, and it is reported
    /// (`union_budget_exhausted`) rather than silently truncated.
    public var maxUnionAttempts: Int
    /// Report **every** failed branch of an untagged union, not just the closest one.
    ///
    /// Off by default because on by default is the wall of noise `EXPERIENCE.md` §9 says is
    /// the most-complained-about thing in every library with union types. It exists for the
    /// case untagged unions exist for: debugging a wire format you do not control, where the
    /// summary's one-branch guess is not enough.
    public var verboseUnions: Bool

    public init(maxIssues: Int = 100, maxDepth: Int = 64, maxBytes: Int = 64 << 20,
                maxUnionAttempts: Int = 10_000, verboseUnions: Bool = false) {
        self.maxIssues = maxIssues
        self.maxDepth = maxDepth
        self.maxBytes = maxBytes
        self.maxUnionAttempts = maxUnionAttempts
        self.verboseUnions = verboseUnions
    }

    public static let `default` = Limits()
}
