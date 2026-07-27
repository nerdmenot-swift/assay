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

    public init(maxIssues: Int = 100, maxDepth: Int = 64, maxBytes: Int = 64 << 20) {
        self.maxIssues = maxIssues
        self.maxDepth = maxDepth
        self.maxBytes = maxBytes
    }

    public static let `default` = Limits()
}
