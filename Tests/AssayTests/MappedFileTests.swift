import Testing
import Assay
import AssayCore
import AssayFoundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// NOTE: no `import Foundation` here, deliberately. swift-testing's Foundation integration
// (`_Testing_Foundation`) has a macOS 13 floor, and importing it would force the whole
// package's `platforms:` up to 13 — raising the deployment floor for every *consumer*
// because of a *test* dependency. The library itself only needs macOS 11
// (String(unsafeUninitializedCapacity:), SE-0263).
//
// So these exercise the path-based API and write files with POSIX. The URL overloads are
// one-line wrappers over the same primitives.

// docs/STREAMING.md §3.5. The claim being tested: an mmap'd file satisfies §5.4's
// "single contiguous buffer that does not change underneath the parse" literally, so a
// document larger than RAM parses with no change to the decoder at all.

@Schema(keys: .snakeCase)
struct MappedItem {
    var id: Int
    var name: String
    var active: Bool
}

@Schema(keys: .snakeCase)
struct MappedDoc {
    var version: String
    var items: [MappedItem]
}

/// Write bytes to a temp file, hand over the path, remove it afterwards. POSIX rather
/// than FileManager, for the reason in the header.
private func withTempFile(
    _ bytes: [UInt8],
    _ body: (String) throws -> Void
) throws {
    let dir = ProcessInfoShim.tempDir
    let path = "\(dir)/assay-mmap-\(UInt64.random(in: 0..<(.max))).json"

    let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
    #expect(fd >= 0, "could not create \(path)")
    if !bytes.isEmpty {
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
    }
    _ = close(fd)
    defer { _ = path.withCString { unlink($0) } }

    try body(path)
}

private enum ProcessInfoShim {
    static var tempDir: String {
        if let t = getenv("TMPDIR") { return String(cString: t) }
        return "/tmp"
    }
}

@Suite("Memory-mapped parsing")
struct MappedFileTests {

    @Test("parse(mmapped:) produces the same value as parse(json:)")
    func equivalence() throws {
        let json = #"{"version":"1","items":[{"id":1,"name":"a","active":true},"#
                 + #"{"id":2,"name":"b","active":false}]}"#
        let bytes = Array(json.utf8)
        let inMemory = try MappedDoc.parse(json: bytes)

        try withTempFile(bytes) { path in
            let mapped = try MappedDoc.parse(mmappedPath: path)
            #expect(mapped.version == inMemory.version)
            #expect(mapped.items.count == 2)
            #expect(mapped.items[0].name == "a")
            #expect(mapped.items[1].active == false)
        }
    }

    @Test("errors carry the same paths and codes through the mapped path")
    func errors() throws {
        let bad = #"{"version":"1","items":[{"id":"nope","name":"a","active":true}]}"#
        try withTempFile(Array(bad.utf8)) { path in
            let d = MappedDoc.diagnose(mmappedPath: path)
            #expect(d.isValid == false)
            #expect(d.issues.contains { $0.code == .typeMismatch })
            #expect(d.issues[0].path.pathDescription.contains("id"))
        }
    }

    @Test("the Diagnosis BORROWS the mapping rather than copying the file")
    func borrowsRatherThanCopies() throws {
        // The whole point. If `source` were `[UInt8]` this would be a full copy, and a
        // 10 GB file would become a 10 GB array purely so carets could render.
        let json = #"{"version":"1","items":[]}"#
        try withTempFile(Array(json.utf8)) { path in
            let d = MappedDoc.diagnose(mmappedPath: path)
            #expect(d.source.count == json.utf8.count)
            // And the borrowed bytes are still readable — the mapping outlives the parse
            // because the Diagnosis retains the MappedFile.
            d.source.withUnsafeBytes { buf in
                #expect(buf.count == json.utf8.count)
                #expect(buf.first == UInt8(ascii: "{"))
            }
        }
    }

    @Test("Limits.mapped does not cap bytes, because the default 64MB would reject the point")
    func mappedLimits() {
        #expect(Limits.mapped.maxBytes == Int.max)
        // maxDepth still bounds recursion — with input size no longer the binding
        // constraint, this is what stands between a hostile document and the stack.
        #expect(Limits.mapped.maxDepth == 64)
        #expect(Limits.default.maxBytes < Limits.mapped.maxBytes)
    }

    @Test("an empty file parses to a malformed-document error, not an I/O error")
    func emptyFile() throws {
        try withTempFile([]) { path in
            let d = MappedDoc.diagnose(mmappedPath: path)
            #expect(d.isValid == false)
            // mmap rejects a zero-length mapping; MappedFile handles that rather than
            // surfacing EINVAL as a file error.
            #expect(!d.issues.contains { $0.code == .custom("cannot_map_file") })
        }
    }

    @Test("a missing file reports an issue rather than trapping")
    func missingFile() {
        let d = MappedDoc.diagnose(mmappedPath: "/nonexistent/assay/nope.json")
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .custom("cannot_map_file") })
    }

    @Test("invalid UTF-8 in a mapped file is caught by the same whole-buffer pass")
    func invalidUTF8() throws {
        var bytes = Array(#"{"version":"1","items":[]}"#.utf8)
        bytes[3] = 0xFF
        try withTempFile(bytes) { path in
            let d = MappedDoc.diagnose(mmappedPath: path)
            #expect(d.isValid == false)
            #expect(d.issues.first?.code == .invalidUTF8)
        }
    }

    @Test("depth limit still applies, and is now the binding safety constraint")
    func depth() throws {
        let deep = String(repeating: #"{"items":"#, count: 200)
            + "1" + String(repeating: "}", count: 200)
        try withTempFile(Array(deep.utf8)) { path in
            let d = MappedDoc.diagnose(mmappedPath: path, limits: Limits(maxIssues: 100,
                                                                    maxDepth: 64,
                                                                    maxBytes: .max))
            #expect(d.isValid == false)
        }
    }

    @Test("JSON.Value.parse(mmapped:) works for the document path too")
    func documentPath() throws {
        let json = #"{"a":[1,2,3],"b":{"c":"d"}}"#
        try withTempFile(Array(json.utf8)) { path in
            let v = try JSON.Value.parse(mmappedPath: path)
            #expect(v["a"]?[1]?.int == 2)
            #expect(v["b"]?["c"]?.string == "d")
        }
    }

    @Test("a file larger than the default maxBytes parses, which is the whole point")
    func largerThanDefaultLimit() throws {
        // Larger than Limits.default.maxBytes (64 MB) would be slow for a unit test, so
        // this uses a smaller explicit limit to prove the *mechanism*: the in-memory path
        // rejects on maxBytes, the mapped path with Limits.mapped does not.
        var json = #"{"version":"1","items":["#
        for i in 0..<2000 {
            if i > 0 { json += "," }
            json += #"{"id":\#(i),"name":"item\#(i)","active":true}"#
        }
        json += "]}"
        let bytes = Array(json.utf8)
        #expect(bytes.count > 60_000)

        let tight = Limits(maxIssues: 100, maxDepth: 64, maxBytes: 1024)
        // In memory, with a tight cap: rejected before reading.
        let rejected = MappedDoc.diagnose(json: bytes, limits: tight)
        #expect(rejected.issues.contains { $0.code == .tooManyBytes })

        // Mapped, with Limits.mapped: parses.
        try withTempFile(bytes) { path in
            let d = MappedDoc.diagnose(mmappedPath: path)
            #expect(d.isValid)
            #expect(d.value?.items.count == 2000)
        }
    }
}
