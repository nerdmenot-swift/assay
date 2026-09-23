// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Building a JSON.Value from bytes, on the existing scanner.
//
// This is the *document* path, and it is deliberately not the primary one.
// PERFORMANCE.md §1.3 measures a map/tree DOM at 2-7x against direct-to-struct, and
// sonic-rs's own README shows 6.8x on its DOM path against 2.8x on its struct path from
// the same library. Nothing here is on the `@Schema` hot path — a schema decodes straight
// into your fields and never builds one of these.
//
// It exists so that `@Extras`, `unknownKeys: .collect`, and the honest "I don't know this
// shape" case have somewhere to land.
//
// Recursion is bounded by `Limits.maxDepth` on the way in, which matters more here than on
// the schema path: a schema's nesting is bounded by its own declaration, but a document
// value's nesting is bounded only by the attacker.
//===----------------------------------------------------------------------===//

extension AssayReader {

    /// Parse one JSON value at the cursor. Returns nil and reports an issue on malformed
    /// input; the caller decides whether that is fatal.
    ///
    /// Part of the hand-written-decoder surface, so this signature is fixed. Internally
    /// the path is threaded `inout` — see `_scanJSONValue`.
    public mutating func scanJSONValue(
        _ sink: inout IssueSink,
        _ path: [PathStep] = []
    ) -> JSON.Value? {
        var p = path
        var hints = _ShapeHints()
        return _scanJSONValue(&sink, &p, &hints)
    }

    @usableFromInline
    mutating func _scanJSONValue(
        _ sink: inout IssueSink,
        _ path: inout [PathStep],
        _ hints: inout _ShapeHints
    ) -> JSON.Value? {
        skipWhitespace()
        guard !atEnd else {
            reportMalformed(&sink, path, expected: "a value")
            return nil
        }

        switch current {
        case 0x6E:                                   // n(ull)
            guard scanNull() else { reportMalformed(&sink, path, expected: "null"); return nil }
            return .null

        case 0x74, 0x66:                             // t(rue) / f(alse)
            guard let b = scanBool() else {
                reportMalformed(&sink, path, expected: "true or false"); return nil }
            return .bool(b)

        case 0x22:                                   // "
            guard let s = scanString() else {
                reportMalformed(&sink, path, expected: "a string"); return nil }
            return .string(s)

        case 0x5B:                                   // [
            return scanJSONArray(&sink, &path, &hints)

        case 0x7B:                                   // {
            return scanJSONObject(&sink, &path, &hints)

        default:
            return scanJSONNumber(&sink, &path)
        }
    }

    /// Integers and doubles are distinguished here rather than deferred, because the
    /// scanner already knows which it saw. `scanInt64` deliberately refuses a value with a
    /// fraction or exponent and rewinds, so falling through to `scanDouble` is exact
    /// rather than a re-parse of something already consumed.
    @usableFromInline
    mutating func scanJSONNumber(
        _ sink: inout IssueSink,
        _ path: inout [PathStep]
    ) -> JSON.Value? {
        if let i = scanInt64() { return .int(i) }
        if let d = scanDouble() { return .double(d) }
        // The value model gets the same verdict as the struct path: a literal that is a
        // number and cannot be represented is an error, not `inf` and not `malformed`.
        if numberRangeErrorAt >= 0 {
            sink.add(Issue(code: .numberOverflow, path: path,
                           location: SourceSpan(lo: numberRangeErrorAt,
                                                len: numberRangeErrorLength)))
            numberRangeErrorAt = -1
            return nil
        }
        reportMalformed(&sink, path, expected: "a value")
        return nil
    }

    @usableFromInline
    mutating func scanJSONArray(
        _ sink: inout IssueSink,
        _ path: inout [PathStep],
        _ hints: inout _ShapeHints
    ) -> JSON.Value? {
        guard tryConsume(0x5B) else { reportMalformed(&sink, path, expected: "'['"); return nil }
        guard enterContainer(&sink) else { return nil }
        defer { leaveContainer() }

        var items: [JSON.Value] = []
        if tryConsume(0x5D) { return .array(items) }
        let level = path.count
        items.reserveCapacity(hints.items(at: level))

        while true {
            // Push, descend, pop — rather than `path + [.index(…)]`, which allocated an
            // array per VALUE in the document and copied the parent into it, for a path
            // nothing reads unless the document is malformed. Same bug as the (removed) columnar
            // row path (2026-09-10) and haul's report before it; this is the third place
            // it was written, and the last one still standing.
            path.append(.index(items.count))
            guard let v = _scanJSONValue(&sink, &path, &hints) else { return nil }
            path.removeLast()
            items.append(v)
            if tryConsume(0x2C) { continue }
            break
        }
        guard tryConsume(0x5D) else {
            reportMalformed(&sink, path, expected: "',' or ']'"); return nil }
        hints.setItems(items.count, at: level)
        return .array(items)
    }

    @usableFromInline
    mutating func scanJSONObject(
        _ sink: inout IssueSink,
        _ path: inout [PathStep],
        _ hints: inout _ShapeHints
    ) -> JSON.Value? {
        guard tryConsume(0x7B) else { reportMalformed(&sink, path, expected: "'{'"); return nil }
        guard enterContainer(&sink) else { return nil }
        defer { leaveContainer() }

        var members: [JSON.Value.Member] = []
        if tryConsume(0x7D) { return .object(members) }
        let level = path.count
        members.reserveCapacity(hints.members(at: level))

        while true {
            // The key has to become a String here — unlike the schema path, where the
            // window dispatcher compares bytes against compile-time literals and never
            // materialises one. That difference is most of why the document path is
            // slower, and it is unavoidable when the key set is unknown.
            guard let key = scanString() else {
                reportMalformed(&sink, path, expected: "a key in double quotes"); return nil }
            guard expect(0x3A) else {
                reportMalformed(&sink, path, expected: "':' after the key"); return nil }
            path.append(.key(key))
            guard let v = _scanJSONValue(&sink, &path, &hints) else { return nil }
            path.removeLast()

            // Duplicates are kept, not overwritten. RFC 8259 leaves the behaviour
            // undefined and dropping one silently is the worst available answer.
            members.append(.init(key: key, value: v))

            if tryConsume(0x2C) { continue }
            break
        }
        guard tryConsume(0x7D) else {
            reportMalformed(&sink, path, expected: "',' or '}'"); return nil }
        hints.setMembers(members.count, at: level)
        return .object(members)
    }
}

/// SHAPE MEMORY for the tree builder: how many members (or items) the last container at each
/// depth held, so the next one there reserves that much up front.
///
/// Documents are mostly arrays of same-shaped records, and a container growing by doubling
/// paid 0 → 1 → 2 → 4 → 8: four allocations for a five-member object where one would do
/// (`count.py explain` on `base/value`: 8,001 of its 8,016 blocks, 2026-09-19). With the hint,
/// a homogeneous document allocates each container once, at its exact size.
///
/// It cannot amplify. A container over-reserves only after a LARGER sibling at the same depth,
/// by at most that sibling's size, which was itself in the input, and the hint then updates.
/// So the extra capacity is bounded by the document.
///
/// Shared by every tree builder: JSON.Value here, and the YAML and TOML parsers.
@_documentation(visibility: internal)
public struct _ShapeHints {
    /// Item and member counts INTERLEAVED per depth (`2 * level` and `2 * level + 1`), in
    /// one array reserved once: two arrays growing by doubling cost a document of empty
    /// objects 3 blocks per call for hints it never used (count.py, `optional-absent/value`).
    @usableFromInline var counts: [Int] = []

    @inlinable public init() {}

    @inlinable public func items(at level: Int) -> Int {
        2 &* level < counts.count ? counts[2 &* level] : 0
    }
    @inlinable public func members(at level: Int) -> Int {
        2 &* level &+ 1 < counts.count ? counts[2 &* level &+ 1] : 0
    }
    @inlinable public mutating func setItems(_ n: Int, at level: Int) { set(n, 2 &* level) }
    @inlinable public mutating func setMembers(_ n: Int, at level: Int) { set(n, 2 &* level &+ 1) }

    @inlinable mutating func set(_ n: Int, _ i: Int) {
        if i >= counts.count {
            if counts.isEmpty { counts.reserveCapacity(32) }
            while counts.count <= i { counts.append(0) }
        }
        counts[i] = n
    }
}

extension JSON.Value {

    /// Parse a whole document into a `JSON.Value`.
    ///
    /// Validates UTF-8 once over the whole buffer first, exactly as the schema path does —
    /// serde_json's per-string validation costs 1.65x and this path would otherwise be
    /// the one place that regression crept back in.
    public static func parse(
        _ bytes: [UInt8],
        limits: Limits = .default
    ) throws(AssayError) -> JSON.Value {
        var sink = IssueSink(limits: limits)
        let result = decode(bytes, into: &sink, limits: limits)
        guard let value = result, sink.isValid else {
            throw AssayError(issues: sink.issues, source: SourceBytes(bytes), sourceName: "<input>")
        }
        return value
    }

    /// Non-throwing form, for callers who want the issues rather than an error.
    public static func decode(
        _ bytes: [UInt8],
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> JSON.Value? {
        if bytes.count > limits.maxBytes {
            sink.add(Issue(code: .tooManyBytes,
                           params: ["maxBytes": .int(limits.maxBytes)]))
            return nil
        }
        return unsafe bytes.withUnsafeBufferPointer { buf -> JSON.Value? in
            guard let base = buf.baseAddress else {
                sink.add(Issue(code: .malformedDocument))
                return nil
            }
            return unsafe _decode(base: base, count: buf.count, into: &sink, limits: limits)
        }
    }

    /// The shared decode core, against a contiguous buffer.
    ///
    /// `decode(_:into:limits:)`, `parse(mmapped:)` in `AssayFoundation` and the `Data` door
    /// beside it all funnel through here, for the reason `JSONAssayable._decode` exists:
    /// **one scanner, one set of checks, no drift between the doors.** That was not
    /// hypothetical — the mapped path had its own hand-written copy of this loop, and it
    /// called the pre-2026-09-19 `scanJSONValue` with no shape memory, so a mapped
    /// `JSON.Value` allocated by doubling while every other door reserved from the previous
    /// container at its depth. Extracting the seam fixed that by deleting the duplicate.
    ///
    /// `maxBytes` is NOT checked here: a caller holding a pointer has already decided what
    /// buffer to hand over, and the two array-and-`Data` doors check it before they get
    /// here, where they can still name the limit in the issue.
    public static func _decode(
        base: UnsafePointer<UInt8>,
        count: Int,
        into sink: inout IssueSink,
        limits: Limits = .default
    ) -> JSON.Value? {
        if let bad = unsafe UTF8Validation.firstInvalid(base, count) {
            sink.add(Issue(code: .invalidUTF8,
                           params: ["offset": .int(bad)],
                           location: SourceSpan(lo: bad, len: 1)))
            return nil
        }
        var reader = unsafe AssayReader(base: base, count: count, limits: limits)
        reader.advanceBy(unsafe UTF8Validation.bomLength(base, count))
        var path: [PathStep] = []
        var hints = _ShapeHints()
        guard let v = reader._scanJSONValue(&sink, &path, &hints) else { return nil }
        reader.skipWhitespace()
        if !reader.atEnd {
            sink.add(Issue(code: .trailingContent,
                           location: SourceSpan(lo: reader.byteOffset, len: 1)))
            return nil
        }
        return v
    }

    public static func parse(
        _ text: String,
        limits: Limits = .default
    ) throws(AssayError) -> JSON.Value {
        try parse(Array(text.utf8), limits: limits)
    }
}

/// Thrown by `JSON.Value.parse`. Carries every issue, not just the first.
