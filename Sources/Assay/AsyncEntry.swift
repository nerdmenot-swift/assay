// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The async `parse`/`diagnose` pair, for a type that declares an `@AsyncCheck`. The sync
// pass runs first and collects everything; async checks run only on a clean sync pass,
// and then concurrently. `docs/EXPERIENCE.md` §11.
//
// Split out of Assay.swift on 2026-09-10.
//===----------------------------------------------------------------------===//

public import AssayCore


extension JSONAssayable where Self: AsyncCheckAssayable {

    /// The async verb pair. Sync first, collecting everything; async checks only on a
    /// clean sync pass, concurrently.
    public static func parse(
        json bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async throws -> Self {
        try await diagnose(json: bytes, limits: limits, sourceName: sourceName).get()
    }

    public static func parse(
        json text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async throws -> Self {
        try await parse(json: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    public static func diagnose(
        json bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async -> Diagnosis<Self> {
        // The synchronous pass — the decode itself stays synchronous, in the swifterror
        // register, exactly as PERFORMANCE.md §3.2 requires. Only the checks await.
        // The non-async function type pins overload resolution to the sync diagnose;
        // without it, an async context prefers this very function and recurses.
        let syncDiagnose: ([UInt8], Limits, String) -> Diagnosis<Self> =
            Self.diagnose(json:limits:sourceName:)
        let d = syncDiagnose(bytes, limits, sourceName)
        guard let value = d.value, d.isValid else { return d }

        let asyncIssues = await Self._assayAsyncChecks(value, at: [])
        guard !asyncIssues.isEmpty else { return d }
        return Diagnosis(value: nil,
                         issues: d.issues + asyncIssues,
                         warnings: d.warnings,
                         truncatedIssues: d.truncatedIssues,
                         source: d.source, sourceName: d.sourceName)
    }

    public static func diagnose(
        json text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async -> Diagnosis<Self> {
        await diagnose(json: Array(text.utf8), limits: limits, sourceName: sourceName)
    }
}
