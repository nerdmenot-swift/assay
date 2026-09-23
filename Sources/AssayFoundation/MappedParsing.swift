// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// parse(mmapped:) — the large-file entry points.
//
// These live in AssayFoundation rather than the core for the reason EXPERIENCE.md §12
// already gives: file I/O, URL handling and extension sniffing are all Foundation, and
// the core stays usable where they do not exist. The core keeps taking bytes.
//
// Nothing about the decoder changes. That is the entire point of the mmap finding — the
// contiguous-buffer invariant is satisfied by a mapping, so the same synchronous,
// recursive-descent, zero-copy scanner reads a 10 GB file as it reads a 10 kB one.
//===----------------------------------------------------------------------===//

public import Assay
public import AssayCore
// NOT re-exported, and that is a decision rather than an oversight. `public import` does
// not re-export symbols (that is `@_exported`, which is underscored), and a library that
// pulls Foundation into every file importing it is doing something its name does not
// entitle it to. A `Date` FIELD therefore needs `import Foundation` in the file that
// declares it — which every document showing one now says, and none did until 2026-09-12,
// when the flagship example was compiled verbatim for the first time and did not build.
import Foundation

extension JSONAssayable {

    /// Decode from a memory-mapped file.
    ///
    /// Resident memory is bounded by what the kernel keeps mapped, not by file size — so
    /// this handles documents larger than RAM. Three caveats worth knowing before reaching
    /// for it (see `MappedFile`): whole-buffer UTF-8 validation reads every page, so the
    /// I/O is not avoided even if you decode one field; the decoded value still costs
    /// memory proportional to what it retains; and `Limits.maxDepth` becomes the binding
    /// safety constraint.
    public static func parse(
        mmapped url: URL,
        limits: Limits = .mapped
    ) throws -> Self {
        let d = diagnose(mmapped: url, limits: limits)
        return try d.get()
    }

    /// Diagnose from a memory-mapped file.
    ///
    /// The returned `Diagnosis` **retains the mapping**, not a copy of the bytes, so
    /// rendering a caret faults the relevant page back in rather than requiring the file
    /// to have been read into an array. That is what `SourceBytes.borrowed` exists for.
    ///
    /// ## Calling this from an async function: wrap it
    ///
    /// This is synchronous and it page-faults on first touch of every page, so it performs
    /// the file's entire I/O on the calling thread. In an `async` function that thread is a
    /// cooperative-pool thread, and blocking it is measurable at 8 MB and a liveness problem
    /// on a multi-gigabyte mapping — the pool is sized to the core count and has no spare
    /// threads to donate.
    ///
    /// Swift has no blocking-I/O executor to hand this to, so the answer is a detached task
    /// rather than an API:
    ///
    /// ```swift
    /// let diagnosis = await Task.detached { Ledger.diagnose(mmapped: url) }.value
    /// ```
    ///
    /// `Task.detached`, not `Task { }`: a child task inherits the current executor and
    /// would block the same pool. Nothing here needs the caller's actor.
    public static func diagnose(
        mmapped url: URL,
        limits: Limits = .mapped
    ) -> Diagnosis<Self> {
        let file: MappedFile
        do {
            file = try MappedFile.open(url)
        } catch {
            var sink = IssueSink(limits: limits)
            sink.add(
                Issue(
                    code: .cannotMapFile,
                    params: [
                        "path": .string(url.path),
                        "reason": .string(String(describing: error))
                    ]))
            return Diagnosis(
                value: nil, issues: sink.issues, warnings: sink.warnings,
                issuesWereTruncated: false,
                source: .empty,
                sourceName: url.lastPathComponent)
        }

        var sink = IssueSink(limits: limits)
        let value = unsafe Self._decode(
            base: file.base.assumingMemoryBound(to: UInt8.self),
            count: file.count,
            into: &sink,
            limits: limits)

        return Diagnosis(
            sink: sink, value: value, source: file.sourceBytes, sourceName: url.lastPathComponent)
    }
}

extension JSONAssayable {

    /// Decode from a memory-mapped file at `path`. See `parse(mmapped:)`.
    public static func parse(
        mmappedPath path: String,
        limits: Limits = .mapped
    ) throws -> Self {
        try diagnose(mmappedPath: path, limits: limits).get()
    }

    /// Diagnose from a memory-mapped file at `path`. See `diagnose(mmapped:)`.
    public static func diagnose(
        mmappedPath path: String,
        limits: Limits = .mapped
    ) -> Diagnosis<Self> {
        let file: MappedFile
        do {
            file = try MappedFile.open(path: path)
        } catch {
            var sink = IssueSink(limits: limits)
            sink.add(
                Issue(
                    code: .cannotMapFile,
                    params: [
                        "path": .string(path),
                        "reason": .string(String(describing: error))
                    ]))
            return Diagnosis(
                value: nil, issues: sink.issues, warnings: sink.warnings,
                issuesWereTruncated: false, source: .empty, sourceName: path)
        }

        var sink = IssueSink(limits: limits)
        let value = unsafe Self._decode(
            base: file.base.assumingMemoryBound(to: UInt8.self),
            count: file.count, into: &sink, limits: limits)

        return Diagnosis(sink: sink, value: value, source: file.sourceBytes, sourceName: path)
    }
}

extension JSON.Value {

    /// Parse a `JSON.Value` from a memory-mapped file at `path`.
    public static func parse(
        mmappedPath path: String,
        limits: Limits = .mapped
    ) throws -> JSON.Value {
        try parse(mapped: MappedFile.open(path: path), limits: limits)
    }

    static func parse(
        mapped file: MappedFile,
        limits: Limits
    ) throws -> JSON.Value {
        var sink = IssueSink(limits: limits)
        // Through `JSON.Value._decode`, not a copy of its loop. This function HAD its own
        // copy, and it had drifted: it called `scanJSONValue` with no shape memory, so a
        // mapped document's containers grew by doubling while every other door reserved
        // what the previous container at that depth held (`docs/EFFICIENCY.md` row 2).
        let v = unsafe file.withUnsafeBytes { buf -> JSON.Value? in
            guard let base = unsafe buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return unsafe JSON.Value._decode(
                base: base, count: buf.count,
                into: &sink, limits: limits)
        }
        guard let value = v, sink.isValid else {
            throw AssayError(issues: sink.issues, source: .empty, sourceName: "<mapped>")
        }
        return value
    }
}

extension JSON.Value {

    /// Parse a whole document from a memory-mapped file into a `JSON.Value`.
    ///
    /// Note this is the one shape where mmap's memory benefit is *undone by the result*:
    /// a document value retains everything it parsed, so a 10 GB file becomes a 10 GB-ish
    /// tree. Use it for files that are large but not larger than memory; use a schema when
    /// the file is genuinely huge, because a schema keeps only the fields it declared.
    public static func parse(
        mmapped url: URL,
        limits: Limits = .mapped
    ) throws -> JSON.Value {
        try parse(mapped: MappedFile.open(url), limits: limits)
    }
}

// MARK: - Contextual types

extension ContextualJSONAssayable {

    /// `parse(mmapped:)` for a type that declares a context. Added 2026-09-10: the
    /// contextual entry points were a copy of the plain ones, and the copy stopped short
    /// of this file.
    public static func parse(
        mmapped url: URL, context: AssayContext, limits: Limits = .mapped
    ) throws -> Self {
        try diagnose(mmapped: url, context: context, limits: limits).get()
    }

    public static func diagnose(
        mmapped url: URL, context: AssayContext, limits: Limits = .mapped
    ) -> Diagnosis<Self> {
        let file: MappedFile
        do {
            file = try MappedFile.open(url)
        } catch {
            var sink = IssueSink(limits: limits)
            sink.add(
                Issue(
                    code: .cannotMapFile,
                    params: [
                        "path": .string(url.path),
                        "reason": .string(String(describing: error))
                    ]))
            return Diagnosis(
                sink: sink, value: nil, source: .empty,
                sourceName: url.lastPathComponent)
        }
        var sink = IssueSink(limits: limits)
        let value = unsafe Self._decode(
            base: file.base.assumingMemoryBound(to: UInt8.self), count: file.count,
            into: &sink, limits: limits, context: context)
        return Diagnosis(
            sink: sink, value: value, source: file.sourceBytes,
            sourceName: url.lastPathComponent)
    }
}
