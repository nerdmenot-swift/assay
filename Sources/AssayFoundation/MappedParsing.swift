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
    public static func diagnose(
        mmapped url: URL,
        limits: Limits = .mapped
    ) -> Diagnosis<Self> {
        let file: MappedFile
        do {
            file = try MappedFile.open(url)
        } catch {
            var sink = IssueSink(limits: limits)
            sink.add(Issue(
                code: .custom("cannot_map_file"),
                params: ["path": .string(url.path),
                         "reason": .string(String(describing: error))]))
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: false,
                             source: .empty,
                             sourceName: url.lastPathComponent)
        }

        var sink = IssueSink(limits: limits)
        let value = Self._decode(
            base: file.base.assumingMemoryBound(to: UInt8.self),
            count: file.count,
            into: &sink,
            limits: limits)

        return Diagnosis(
            value: sink.isValid ? value : nil,
            issues: sink.issues,
            warnings: sink.warnings,
            truncatedIssues: sink.truncatedIssues,
            // Borrowed, not copied. A 10 GB file must not become a 10 GB array here.
            source: file.sourceBytes,
            sourceName: url.lastPathComponent)
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
            sink.add(Issue(
                code: .custom("cannot_map_file"),
                params: ["path": .string(path),
                         "reason": .string(String(describing: error))]))
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: false, source: .empty, sourceName: path)
        }

        var sink = IssueSink(limits: limits)
        let value = Self._decode(
            base: file.base.assumingMemoryBound(to: UInt8.self),
            count: file.count, into: &sink, limits: limits)

        return Diagnosis(
            value: sink.isValid ? value : nil,
            issues: sink.issues, warnings: sink.warnings,
            truncatedIssues: sink.truncatedIssues,
            source: file.sourceBytes, sourceName: path)
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
        let v = file.withUnsafeBytes { buf -> JSON.Value? in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            if let bad = UTF8Validation.firstInvalid(base, buf.count) {
                sink.add(Issue(code: .invalidUTF8, params: ["offset": .int(bad)],
                               location: SourceSpan(lo: bad, len: 1)))
                return nil
            }
            var reader = AssayReader(base: base, count: buf.count, limits: limits)
            guard let v = reader.scanJSONValue(&sink, []) else { return nil }
            reader.skipWhitespace()
            if !reader.atEnd {
                sink.add(Issue(code: .trailingContent,
                               location: SourceSpan(lo: reader.byteOffset, len: 1)))
                return nil
            }
            return v
        }
        guard let value = v, sink.isValid else { throw JSONValueError(issues: sink.issues) }
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
