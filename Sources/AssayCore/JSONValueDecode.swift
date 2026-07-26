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
    public mutating func scanJSONValue(
        _ sink: inout IssueSink,
        _ path: [PathComponent] = []
    ) -> JSON.Value? {
        skipWhitespace()
        guard !atEnd else {
            reportMalformed(&sink, path)
            return nil
        }

        switch current {
        case 0x6E:                                   // n(ull)
            guard scanNull() else { reportMalformed(&sink, path); return nil }
            return .null

        case 0x74, 0x66:                             // t(rue) / f(alse)
            guard let b = scanBool() else { reportMalformed(&sink, path); return nil }
            return .bool(b)

        case 0x22:                                   // "
            guard let s = scanString() else { reportMalformed(&sink, path); return nil }
            return .string(s)

        case 0x5B:                                   // [
            return scanJSONArray(&sink, path)

        case 0x7B:                                   // {
            return scanJSONObject(&sink, path)

        default:
            return scanJSONNumber(&sink, path)
        }
    }

    /// Integers and doubles are distinguished here rather than deferred, because the
    /// scanner already knows which it saw. `scanInt64` deliberately refuses a value with a
    /// fraction or exponent and rewinds, so falling through to `scanDouble` is exact
    /// rather than a re-parse of something already consumed.
    @usableFromInline
    mutating func scanJSONNumber(
        _ sink: inout IssueSink,
        _ path: [PathComponent]
    ) -> JSON.Value? {
        if let i = scanInt64() { return .int(i) }
        if let d = scanDouble() { return .double(d) }
        reportMalformed(&sink, path)
        return nil
    }

    @usableFromInline
    mutating func scanJSONArray(
        _ sink: inout IssueSink,
        _ path: [PathComponent]
    ) -> JSON.Value? {
        guard tryConsume(0x5B) else { reportMalformed(&sink, path); return nil }
        guard enterContainer(&sink) else { return nil }
        defer { leaveContainer() }

        var items: [JSON.Value] = []
        if tryConsume(0x5D) { return .array(items) }

        while true {
            guard let v = scanJSONValue(&sink, path + [.index(items.count)]) else {
                return nil
            }
            items.append(v)
            if tryConsume(0x2C) { continue }
            break
        }
        guard tryConsume(0x5D) else { reportMalformed(&sink, path); return nil }
        return .array(items)
    }

    @usableFromInline
    mutating func scanJSONObject(
        _ sink: inout IssueSink,
        _ path: [PathComponent]
    ) -> JSON.Value? {
        guard tryConsume(0x7B) else { reportMalformed(&sink, path); return nil }
        guard enterContainer(&sink) else { return nil }
        defer { leaveContainer() }

        var members: [JSON.Value.Member] = []
        if tryConsume(0x7D) { return .object(members) }

        while true {
            // The key has to become a String here — unlike the schema path, where the
            // window dispatcher compares bytes against compile-time literals and never
            // materialises one. That difference is most of why the document path is
            // slower, and it is unavoidable when the key set is unknown.
            guard let key = scanString() else { reportMalformed(&sink, path); return nil }
            guard expect(0x3A) else { reportMalformed(&sink, path); return nil }
            guard let v = scanJSONValue(&sink, path + [.key(key)]) else { return nil }

            // Duplicates are kept, not overwritten. RFC 8259 leaves the behaviour
            // undefined and dropping one silently is the worst available answer.
            members.append(.init(key: key, value: v))

            if tryConsume(0x2C) { continue }
            break
        }
        guard tryConsume(0x7D) else { reportMalformed(&sink, path); return nil }
        return .object(members)
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
    ) throws(JSONValueError) -> JSON.Value {
        var sink = IssueSink(limits: limits)
        let result = decode(bytes, into: &sink, limits: limits)
        guard let value = result, sink.isValid else {
            throw JSONValueError(issues: sink.issues)
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
        return bytes.withUnsafeBufferPointer { buf -> JSON.Value? in
            guard let base = buf.baseAddress else {
                sink.add(Issue(code: .malformedDocument))
                return nil
            }
            if let bad = UTF8Validation.firstInvalid(base, buf.count) {
                sink.add(Issue(code: .invalidUTF8,
                               params: ["offset": .int(bad)],
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
    }

    public static func parse(
        _ text: String,
        limits: Limits = .default
    ) throws(JSONValueError) -> JSON.Value {
        try parse(Array(text.utf8), limits: limits)
    }
}

/// Thrown by `JSON.Value.parse`. Carries every issue, not just the first.
public struct JSONValueError: Error, Sendable {
    public var issues: [Issue]
    public init(issues: [Issue]) { self.issues = issues }
}
