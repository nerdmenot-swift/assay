// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// How @Extras collects a value whose type the macro has never heard of.
//
// This is open question 2 from docs/VALUE-MODELS.md, and the constraint that shapes it:
// `XML.Node` lives in `AssayXML`, which `AssayCore` must not depend on. So the core cannot
// name the types it collects — it can only name a *capability*.
//
// The desirable property, which this achieves: declaring
//
//     @Extras var rest: [String: XML.Node]
//
// and then calling `parse(json:)` is a **compile** error, not a runtime one, because
// `XML.Node` does not conform to `JSONCollectible`. The mismatch is caught where it is
// written rather than discovered on a malformed production payload.
//
// One protocol per format, deliberately, rather than one generic `Collectible`. A format
// that cannot produce a type should not be able to claim it can, and a shared protocol
// with a format parameter would erase exactly that distinction.
//===----------------------------------------------------------------------===//

/// A type that can be built from JSON at the reader's current position.
///
/// Conformed to by `RawValue` (portable, lossy) and `JSON.Value` (full fidelity) in this
/// module. `YAML.Node` and `XML.Node` deliberately do **not** conform — they will conform
/// to their own format's protocol instead.
public protocol JSONCollectible {
    /// Consume one JSON value and return it, or nil if it was malformed.
    static func _collectJSON(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self?
}

extension JSON.Value: JSONCollectible {
    @inlinable
    public static func _collectJSON(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> JSON.Value? {
        reader.scanJSONValue(&sink, path)
    }
}

extension RawValue: JSONCollectible {
    @inlinable
    public static func _collectJSON(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> RawValue? {
        // JSON -> RawValue is total, so this cannot lose anything. The lossy projections
        // are YAML's and XML's.
        reader.scanJSONValue(&sink, path).map(RawValue.init)
    }
}

// MARK: - Unknown-key handling

/// What to do with a key the schema did not declare. `EXPERIENCE.md` §4.
public enum UnknownKeyPolicy: Sendable, Hashable {
    /// Skip it structurally without decoding. The `Codable` behaviour, and the default.
    case ignore
    /// A warning per key, decoding proceeds. Surfaces only through `diagnose`.
    case warn
    /// An issue per key.
    case reject
    /// Routed to the `@Extras` field.
    case collect
}

extension AssayReader {

    /// Materialise an unknown key as a `String`.
    ///
    /// This is the one place the decoder builds a `String` for a key, and it is
    /// unavoidable: an unknown key has no compile-time literal to compare against, so
    /// there is nothing to match it to. It happens only on the `.collect`, `.warn` and
    /// `.reject` paths — never on `.ignore`, which is the default and stays allocation-free.
    @inlinable
    public func keyString(_ key: KeyRange) -> String {
        unsafe String(unsafeUninitializedCapacity: key.len) { buffer in
            unsafe buffer.baseAddress!.update(from: base + key.lo, count: key.len)
            return key.len
        }
    }

    /// Report an unknown key, with a did-you-mean when one is close enough to be useful.
    ///
    /// Cold: only reached for keys the schema did not declare, and never on the default
    /// `.ignore` policy.
    @inline(never)
    public mutating func reportUnknownKey(
        _ sink: inout IssueSink,
        _ path: [PathComponent],
        _ key: KeyRange,
        known: [String],
        reject: Bool
    ) {
        let name = keyString(key)
        var params: [String: IssueValue] = [:]
        if let suggestion = Self.didYouMean(name, in: known) {
            params["didYouMean"] = .string(suggestion)
        }
        params["received"] = .string(name)
        let span = SourceSpan(lo: key.lo, len: key.len)
        if reject {
            sink.add(Issue(code: .unknownKey, path: path,
                           params: params, received: name, location: span))
        } else {
            sink.add(warning: Warning(code: .unknownKey, path: path,
                                      params: params, location: span))
        }
    }

    /// Closest declared key within a small edit distance, or nil.
    ///
    /// Bounded rather than exhaustive: the threshold scales with length (1 edit for short
    /// keys, 2 for longer), so `tiemout` suggests `timeout` and `xyzzy` suggests nothing.
    /// A suggestion that is wrong is worse than no suggestion.
    public static func didYouMean(_ name: String, in known: [String]) -> String? {
        guard !known.isEmpty else { return nil }
        let threshold = name.count <= 4 ? 1 : 2
        var best: (key: String, distance: Int)?
        for candidate in known {
            // Cheap rejects before the O(n*m) matrix.
            if abs(candidate.count - name.count) > threshold { continue }
            let d = editDistance(Array(name.utf8), Array(candidate.utf8), limit: threshold)
            guard d <= threshold else { continue }
            if best == nil || d < best!.distance { best = (candidate, d) }
        }
        return best?.key
    }

    /// Damerau-Levenshtein (optimal string alignment), abandoning once every cell in a
    /// row exceeds `limit`. Adjacent transpositions cost 1 — "tiemout" and "hgih" are THE
    /// typo class, and plain Levenshtein charging 2 for them misses exactly the
    /// suggestions a human would make.
    @usableFromInline
    static func editDistance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var d = min(previous[j] + 1,
                            current[j - 1] + 1,
                            previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d = min(d, prev2[j - 2] + 1)
                }
                current[j] = d
                rowMin = min(rowMin, d)
            }
            if rowMin > limit { return limit + 1 }
            (prev2, previous, current) = (previous, current, prev2)
        }
        return previous[b.count]
    }
}

/// Collect a value of type `T` from JSON.
///
/// Generated code calls this rather than `T._collectJSON` directly, purely for the
/// diagnostic. Calling the protocol requirement on a non-conforming type produces
///
///     type 'XML.Node' has no member '_collectJSON'
///
/// which leaks an underscored internal and says nothing useful. Routing through a
/// constrained generic produces
///
///     global function '_assayCollect' requires that 'XML.Node' conform to 'JSONCollectible'
///
/// which names the actual problem. Purpose-written diagnostics are the product.
@inlinable
public func _assayCollect<T: JSONCollectible>(
    _ type: T.Type,
    from reader: inout AssayReader,
    into sink: inout IssueSink,
    at path: [PathComponent]
) -> T? {
    T._collectJSON(from: &reader, into: &sink, at: path)
}
