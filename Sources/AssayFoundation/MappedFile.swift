// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A memory-mapped file.
//
// docs/STREAMING.md §3.5. The reason this is worth having, precisely:
//
// PERFORMANCE.md §5.4 requires "a single contiguous buffer that does not change underneath
// the parse". An mmap'd file satisfies that *literally* — the virtual address range is
// contiguous, while physical residency is not, because the kernel demand-loads pages and
// evicts them under pressure.
//
// So a document far larger than RAM parses with no incremental parser, no resumable state
// machine, and no change to the decoder at all:
//   * zero-copy string slices still point into valid mapped memory;
//   * byte-offset source spans still resolve — rendering a caret faults the page back in;
//   * whole-buffer UTF-8 validation is still one sequential pass, and every page it
//     touches is immediately evictable;
//   * mapped pages are CLEAN and file-backed, so they reclaim for free, where an
//     [UInt8] is dirty anonymous memory that must swap before it can be reclaimed.
//
// MEASURED (387 MB document, extracting one top-level field, Apple silicon, -O):
//
//     read into [UInt8]     0.76 s   412 MB RSS   407 MB peak footprint
//     parse(mmapped:)       0.21 s   412 MB RSS  1.88 MB peak footprint
//
// Note max RSS is IDENTICAL. mmap does not reduce how many pages are touched — the
// whole-buffer UTF-8 pass touches all of them. It changes them from irreclaimable to
// free-to-reclaim, which is what memory limits and the OOM killer actually act on, and it
// removes the copy. Corroborated by a 1.5 GB document under a 64 MB limit being
// OOM-killed when read and completing in 3.35 s when mapped
// (https://tinselcity.github.io/Large-Json-Stream/).
//
// AND THE BOUNDARY: decoding ALL 8,000,000 records of that file costs 1.067 GB footprint
// read vs 661 MB mapped — still exactly the file size apart. mmap saves the input, always;
// it does nothing about the output, which is dirty anonymous memory however it arrived.
// So mmap bounds the INPUT, not the total: it does not let you decode a 10 GB file into a
// 10 GB value on a 4 GB machine.
//
// THE HONEST CAVEATS, since they are easy to discover the hard way:
//   1. Files only. A socket cannot be mapped, so this does nothing for network input.
//   2. Whole-buffer UTF-8 validation touches every page, so a 10 GB file is *read* in
//      full even if you decode one field. Resident memory stays bounded; I/O does not.
//   3. Output values still cost RAM proportional to what you retain. Decoding a 10 GB
//      document into a struct that keeps all of it still fails.
//   4. `Limits.maxDepth` becomes the binding constraint rather than input size — hence
//      `Limits.mapped` below.
//===----------------------------------------------------------------------===//

public import AssayCore
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Android)
@preconcurrency import Android
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif os(Windows)
import ucrt
import WinSDK
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#else
#error("AssayFoundation was unable to identify your C library.")
#endif

/// A read-only memory mapping of a file, valid for the lifetime of this object.
///
/// A `final class` deliberately: `deinit` is what releases the mapping, and
/// `SourceBytes.borrowed` retains one of these to keep a `Diagnosis`'s carets renderable
/// without copying the file.
@safe
public final class MappedFile: @unchecked Sendable {

    /// Base address of the mapping. Valid while this object is alive.
    public let base: UnsafeRawPointer
    /// Length in bytes.
    public let count: Int

    private let release: @Sendable (UnsafeRawPointer, Int) -> Void

    private init(
        base: UnsafeRawPointer,
        count: Int,
        release: @escaping @Sendable (UnsafeRawPointer, Int) -> Void
    ) {
        self.base = base
        self.count = count
        self.release = release
    }

    deinit {
        release(base, count)
    }

    /// Map `url` read-only.
    ///
    /// An empty file is mapped as a zero-length region rather than failing: `mmap` rejects
    /// a length of 0, and an empty document is a legitimate (if invalid-JSON) input that
    /// should produce a parse error, not an I/O error.
    public static func open(_ url: URL) throws -> MappedFile {
        guard url.isFileURL else {
            throw MappedFileError.notAFileURL(url)
        }
        return try open(path: url.withUnsafeFileSystemRepresentation { String(cString: $0!) })
    }

    /// Map a filesystem path read-only.
    ///
    /// The path-based spelling is the primitive and the `URL` one wraps it, not the other
    /// way round: `URL` carries availability quirks of its own (see
    /// cross-platform-audit.md §0 on `URL(string:)`), and a caller who already has a path
    /// should not have to round-trip through one.
    public static func open(path: String) throws -> MappedFile {

        #if os(Windows) || os(WASI)
        // No POSIX mmap here. Windows would need CreateFileMapping/MapViewOfFile and WASI
        // has no mapping at all, so both fall back to reading the file. Correct, and
        // without the memory benefit — stated rather than silently pretended.
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MappedFileError.cannotOpen(path, 2 /* ENOENT */)
        }
        let n = data.count
        let buf = UnsafeMutableRawPointer.allocate(
            byteCount: max(n, 1), alignment: MemoryLayout<UInt64>.alignment)
        data.withUnsafeBytes { src in
            if let s = src.baseAddress, n > 0 { buf.copyMemory(from: s, byteCount: n) }
        }
        return MappedFile(base: UnsafeRawPointer(buf), count: n) { p, _ in
            UnsafeMutableRawPointer(mutating: p).deallocate()
        }
        #else
        let fd = path.withCString { unsafe Foundation.open($0, O_RDONLY) }
        guard fd >= 0 else { throw MappedFileError.cannotOpen(path, errno) }
        defer { _ = unsafe close(fd) }

        var st = stat()
        guard unsafe fstat(fd, &st) == 0 else {
            throw MappedFileError.cannotStat(path, errno)
        }
        let size = Int(st.st_size)

        guard size > 0 else {
            // Zero-length mapping is not permitted; hand back a valid empty region.
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
            return MappedFile(base: UnsafeRawPointer(buf), count: 0) { p, _ in
                UnsafeMutableRawPointer(mutating: p).deallocate()
            }
        }

        guard let raw = unsafe mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              raw != MAP_FAILED else {
            throw MappedFileError.cannotMap(path, errno)
        }

        // The parse is one forward pass — UTF-8 validation, then the scanner — so tell the
        // kernel to read ahead aggressively and to drop pages behind us. This is the whole
        // reason the mmap path is not just "slower malloc".
        unsafe madvise(raw, size, MADV_SEQUENTIAL)

        return MappedFile(base: UnsafeRawPointer(raw), count: size) { p, n in
            unsafe munmap(UnsafeMutableRawPointer(mutating: p), n)
        }
        #endif
    }

    /// Scoped access to the mapped bytes.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let buffer = unsafe UnsafeRawBufferPointer(start: base, count: count)
        defer { withExtendedLifetime(self) {} }
        return try unsafe body(buffer)
    }

    /// A `SourceBytes` that borrows this mapping and keeps it alive, so a `Diagnosis` can
    /// render carets without copying the file.
    public var sourceBytes: SourceBytes {
        unsafe SourceBytes(unsafeBorrowed: base, count: count, owner: self)
    }
}

public enum MappedFileError: Error, CustomStringConvertible {
    case notAFileURL(URL)
    case cannotOpen(String, Int32)
    case cannotStat(String, Int32)
    case cannotMap(String, Int32)

    public var description: String {
        switch self {
        case .notAFileURL(let u):
            return "mmap requires a file URL, got \(u)"
        case .cannotOpen(let p, let e):
            return "could not open \(p): \(String(cString: strerror(e)))"
        case .cannotStat(let p, let e):
            return "could not stat \(p): \(String(cString: strerror(e)))"
        case .cannotMap(let p, let e):
            return "could not map \(p): \(String(cString: strerror(e)))"
        }
    }
}

extension Limits {
    /// Limits appropriate for a mapped file.
    ///
    /// `maxBytes` defaults to 64 MB, which would reject the very files this path exists to
    /// serve — a 10 GB document would fail before a byte was read. Here it is unbounded,
    /// because the input is not resident and bounding it makes no memory guarantee.
    ///
    /// `maxDepth` stays at 64 and matters *more*: with input size no longer the binding
    /// constraint, recursion depth is what stands between a hostile document and the stack.
    public static let mapped = Limits(maxIssues: 100, maxDepth: 64, maxBytes: .max)
}
