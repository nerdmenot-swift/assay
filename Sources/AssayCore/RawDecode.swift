// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Decoding a schema from RawValue — the YAML and XML path.
//
// ARCHITECTURE, and its cost stated plainly. JSON decodes *direct to struct*: the macro's
// generated body reads bytes straight into fields, which is where the measured 5.59x over
// Foundation comes from. YAML and XML do not: they parse to their own full-fidelity model,
// project to `RawValue`, and decode from that.
//
// That is a DOM hop, and PERFORMANCE.md §1.3 measures a DOM at 2-7x against
// direct-to-struct. It is accepted here for three reasons:
//
//   1. Neither format can use a JSON-style structural index anyway. perf-state-of-the-art
//      §7.1: YAML's `:` and `-` have no byte-local classification, and "the single most
//      valuable SIMD primitive in JSON — find the next quote — has no YAML analogue".
//      YAML tops out around 200 MB/s in the best C implementations.
//   2. One extra generated body instead of two keeps the compile-time budget
//      (docs/COMPILE-TIME.md: ~7.3 ms per field, driven by body size).
//   3. It reuses the projections that already exist and are already tested.
//
// The JSON path does not touch any of this.
//
// COERCION. XML has no numbers and no booleans — every leaf is text. So decoding
// `var port: Int` from XML requires coercion, and EXPERIENCE.md §7 already specifies the
// shape: never implicit, never global, written on the struct as `@Coerce` or
// `@Schema(coerceScalars: true)`. The rules below are "written down and boring", which is
// the property that matters.
//===----------------------------------------------------------------------===//

extension RawValue {

    // MARK: Scalars

    @inlinable
    public func assayString(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> String? {
        if case .string(let s) = self { return s }
        if coerce {
            switch self {
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return b ? "true" : "false"
            default: break
            }
        }
        Self.mismatch(&sink, path, key, "string", self, span)
        return nil
    }

    @inlinable
    public func assayInt(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int? {
        if case .int(let i) = self, let n = Int(exactly: i) { return n }
        if coerce, let n = coercedInt() { return n }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @inlinable
    public func assayInt64(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int64? {
        if case .int(let i) = self { return i }
        if coerce, let n = coercedInt() { return Int64(n) }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @inlinable
    public func assayInt32(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int32? {
        if case .int(let i) = self, let n = Int32(exactly: i) { return n }
        if coerce, let n = coercedInt(), let v = Int32(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @inlinable
    public func assayUInt(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt? {
        if case .int(let i) = self, let n = UInt(exactly: i) { return n }
        if coerce, let n = coercedInt(), let v = UInt(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @inlinable
    public func assayInt8(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int8? {
        if case .int(let i) = self, let n = Int8(exactly: i) { return n }
        if coerce, let n = coercedInt(), let v = Int8(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @inlinable
    public func assayInt16(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int16? {
        if case .int(let i) = self, let n = Int16(exactly: i) { return n }
        if coerce, let n = coercedInt(), let v = Int16(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @inlinable
    public func assayUInt8(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt8? {
        if case .int(let i) = self, let n = UInt8(exactly: i) { return n }
        if coerce, let n = coercedInt(), let v = UInt8(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @inlinable
    public func assayUInt16(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt16? {
        if case .int(let i) = self, let n = UInt16(exactly: i) { return n }
        if coerce, let n = coercedInt(), let v = UInt16(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @inlinable
    public func assayUInt32(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt32? {
        if case .int(let i) = self, let n = UInt32(exactly: i) { return n }
        if coerce, let n = coercedInt(), let v = UInt32(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @inlinable
    public func assayUInt64(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt64? {
        if case .int(let i) = self, let n = UInt64(exactly: i) { return n }
        if coerce, let n = coercedInt(), let v = UInt64(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @inlinable
    public func assayDouble(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)                  // widening is not coercion
        default: break
        }
        if coerce, case .string(let s) = self, let d = Double(s) { return d }
        Self.mismatch(&sink, path, key, "number", self, span)
        return nil
    }

    @inlinable
    public func assayFloat(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Float? {
        assayDouble(&sink, path, key, coerce: coerce, at: span).map(Float.init)
    }

    @inlinable
    public func assayBool(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Bool? {
        if case .bool(let b) = self { return b }
        if coerce {
            switch self {
            case .string(let s):
                switch s {
                case "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON", "1":
                    return true
                case "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF", "0":
                    return false
                default: break
                }
            case .int(let i):
                if i == 1 { return true }
                if i == 0 { return false }
            default: break
            }
        }
        Self.mismatch(&sink, path, key, "boolean", self, span)
        return nil
    }

    /// `"8080"` becomes 8080. `"8080.5"` does **not** become 8080 — that is a truncation,
    /// and silently truncating is exactly the class of quiet wrongness this library exists
    /// to avoid. `1.0` does convert, because it is exactly integral; `1.5` does not.
    ///
    /// Nothing here consults a locale, which is what makes it behave identically on Linux
    /// and on a Mac.
    @inlinable
    public func coercedInt() -> Int? {
        switch self {
        case .string(let s):
            return Int(s)                                    // rejects "8080.5" outright
        case .double(let d):
            guard d == d.rounded(), let n = Int(exactly: d) else { return nil }
            return n
        case .bool(let b):
            return b ? 1 : 0
        default:
            return nil
        }
    }

    @inline(never)
    @usableFromInline
    static func mismatch(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        _ expected: String, _ found: RawValue, _ span: SourceSpan? = nil
    ) {
        sink.add(Issue(
            code: .typeMismatch,
            path: path + [.key(String(describing: key))],
            params: ["expected": .string(expected)],
            received: found.describe(),
            location: span))
    }

    @inline(never)
    @usableFromInline
    func describe() -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return "\"\(s)\""
        case .sequence: return "an array"
        case .mapping: return "an object"
        }
    }

    @inline(never)
    public static func missing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) {
        sink.add(Issue(code: .missing, path: path + [.key(String(describing: key))]))
    }

    @inline(never)
    public static func notAnObject(
        _ sink: inout IssueSink, _ path: [PathComponent], _ found: RawValue
    ) {
        sink.add(Issue(code: .typeMismatch, path: path,
                       params: ["expected": .string("object")],
                       received: found.describe()))
    }

    /// Report an unknown key found while decoding a mapping, with a did-you-mean.
    @inline(never)
    public static func unknownKey(
        _ sink: inout IssueSink, _ path: [PathComponent], _ name: String,
        known: [String], reject: Bool
    ) {
        var params: [String: IssueValue] = [:]
        if let suggestion = AssayReader.didYouMean(name, in: known) {
            params["didYouMean"] = .string(suggestion)
        }
        params["received"] = .string(name)
        if reject {
            sink.add(Issue(code: .unknownKey, path: path,
                           params: params, received: name))
        } else {
            sink.add(warning: Warning(code: .unknownKey, path: path,
                                      params: params))
        }
    }
}

/// The capability marker.
///
/// A marker protocol refining `Sendable`, which costs *exactly* zero at runtime — no
/// witness table, no calling-convention change, no generic requirement recorded — and buys
/// two things: conforming types are excluded from `-default-isolation MainActor`
/// inference, and a `Diagnosis` can cross an actor boundary.
///
/// It lives here rather than in `Assay` so that `RawDecodable` can refine it without the
/// core depending on the public surface.
public protocol Assayable: Sendable {}

/// A type that can be decoded from a `RawValue` — the YAML/XML entry point, generated by
/// `@Schema` alongside the JSON one.
public protocol RawDecodable: Assayable {
    static func _assay(
        from raw: RawValue,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self?
}

extension RawValue {
    /// Type mismatch at a path that already names the field — the enum decode case.
    @inline(never)
    public static func mismatchAt(
        _ sink: inout IssueSink, _ path: [PathComponent],
        _ expected: String, _ found: RawValue
    ) {
        sink.add(Issue(code: .typeMismatch, path: path,
                       params: ["expected": .string(expected)],
                       received: found.describe()))
    }

    /// Public spelling of `mismatch`, for generated code.
    @inline(never)
    public static func mismatchPublic(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        _ expected: String, _ found: RawValue, _ span: SourceSpan? = nil
    ) {
        mismatch(&sink, path, key, expected, found, span)
    }
}
