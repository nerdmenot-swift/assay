// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Per-type decode entry points.
//
// These exist so that generated per-field code is *one call*, which is how the macro
// satisfies docs/PERFORMANCE.md §8.3: "Emit many medium-sized functions, not one giant
// flat body." Escape analysis budgets `1_000_000 / estimatedFunctionSize` and divides
// that by ten again for ARC queries; when the budget is exhausted the analysis bails,
// and bailing is indistinguishable from "it escapes" — the retains stay, with no
// diagnostic. A 60-field struct flattened into one enormous decode function may silently
// lose all ARC optimization.
//
// Every one is `@inlinable`, because the runtime lives in the Assay module and the
// generated code lives in the user's. Without the body in the client's SILModule there
// is no specialization — Foundation gets this free from whole-module optimization and
// Assay structurally cannot. A forums report measured `@inlinable` taking a workload
// from 92us to 3us where cross-module-optimization flags gave nothing.
//
// The failure branch is always a separate `@inline(never)` call, never inlined here.
//===----------------------------------------------------------------------===//

extension AssayReader {

    @inlinable
    public mutating func decodeString(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> String? {
        beginValue()
        if let s = scanString() { return s }
        failed(&sink, path, key, "string")
        return nil
    }

    @inlinable
    public mutating func decodeInt(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int? {
        beginValue()
        if let v = scanInt64(), let n = Int(exactly: v) { return n }
        failed(&sink, path, key, "integer")
        return nil
    }

    @inlinable
    public mutating func decodeInt64(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int64? {
        if let v = scanInt64() { return v }
        failed(&sink, path, key, "integer")
        return nil
    }

    @inlinable
    public mutating func decodeInt32(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int32? {
        if let v = scanInt64(), let n = Int32(exactly: v) { return n }
        failed(&sink, path, key, "integer")
        return nil
    }

    @inlinable
    public mutating func decodeUInt(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> UInt? {
        beginValue()
        if let v = scanInt64(), let n = UInt(exactly: v) { return n }
        failed(&sink, path, key, "unsigned integer")
        return nil
    }

    @inlinable
    public mutating func decodeDouble(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Double? {
        beginValue()
        if let v = scanDouble() { return v }
        failed(&sink, path, key, "number")
        return nil
    }

    @inlinable
    public mutating func decodeFloat(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Float? {
        beginValue()
        if let v = scanDouble() { return Float(v) }
        failed(&sink, path, key, "number")
        return nil
    }

    @inlinable
    public mutating func decodeBool(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Bool? {
        beginValue()
        if let v = scanBool() { return v }
        failed(&sink, path, key, "boolean")
        return nil
    }

    /// `null` is *presence with a null value*, which for an optional field means nil and
    /// for a required field is a type mismatch. Kept distinct from absence on purpose —
    /// conflating the two is the single costliest ambiguity in `Codable`.
    @inlinable @inline(__always)
    public mutating func consumeNullIfPresent() -> Bool {
        scanNull()
    }

    /// Cold. Never inlined into the field loop.
    @inline(never)
    @usableFromInline
    mutating func failed(
        _ sink: inout IssueSink,
        _ path: [PathComponent],
        _ key: StaticString,
        _ expected: String
    ) {
        sink.add(Issue(
            code: .typeMismatch,
            path: path + [.key(String(describing: key))],
            params: ["expected": .string(expected)],
            received: describeCurrentValue(),
            location: SourceSpan(lo: cursor, len: 1)))
        // Resynchronise so one bad field does not cascade into a hundred parse errors —
        // this is what makes "all the errors, all the time" produce a useful report
        // rather than noise.
        var throwaway = IssueSink(limits: Limits(maxIssues: 0))
        _ = skipValue(&throwaway)
    }

    /// Reported once per missing required field, from the presence bitmask, after the
    /// object closes.
    @inline(never)
    public mutating func missingRequired(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) {
        sink.add(Issue(code: .missing, path: path + [.key(String(describing: key))]))
    }
}

//===----------------------------------------------------------------------===//
// Null-aware variants, for optional fields.
//
// These exist for a COMPILE-TIME reason, not a runtime one. The macro previously wrapped
// every field in `if reader.consumeNullIfPresent() { ... } else { ... }`, which doubled
// the generated statement count per field — and measurement showed per-field body size,
// not plugin round-trips, is what dominates @Schema's compile cost (~9ms per field
// against ~9ms fixed per type). Folding the null case in here makes generated per-field
// code exactly one line.
//
// The distinction they encode is the one Codable blurs and EXPERIENCE.md §6 insists on:
// an explicit `null` is PRESENCE with a null value, which is fine for `String?` and an
// error for `String`.
//===----------------------------------------------------------------------===//

extension AssayReader {

    @inlinable
    public mutating func decodeStringOrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> String?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let s = scanString() { return .some(s) }
        failed(&sink, path, key, "string")
        return nil
    }

    @inlinable
    public mutating func decodeIntOrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanInt64(), let n = Int(exactly: v) { return .some(n) }
        failed(&sink, path, key, "integer")
        return nil
    }

    @inlinable
    public mutating func decodeInt64OrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int64?? {
        if scanNull() { return .some(nil) }
        if let v = scanInt64() { return .some(v) }
        failed(&sink, path, key, "integer")
        return nil
    }

    @inlinable
    public mutating func decodeInt32OrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int32?? {
        if scanNull() { return .some(nil) }
        if let v = scanInt64(), let n = Int32(exactly: v) { return .some(n) }
        failed(&sink, path, key, "integer")
        return nil
    }

    @inlinable
    public mutating func decodeUIntOrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> UInt?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanInt64(), let n = UInt(exactly: v) { return .some(n) }
        failed(&sink, path, key, "unsigned integer")
        return nil
    }

    @inlinable
    public mutating func decodeDoubleOrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Double?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanDouble() { return .some(v) }
        failed(&sink, path, key, "number")
        return nil
    }

    @inlinable
    public mutating func decodeFloatOrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Float?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanDouble() { return .some(Float(v)) }
        failed(&sink, path, key, "number")
        return nil
    }

    @inlinable
    public mutating func decodeBoolOrNull(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Bool?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanBool() { return .some(v) }
        failed(&sink, path, key, "boolean")
        return nil
    }

    /// Required-field null handling: an explicit null where a value is required.
    @inline(never)
    public mutating func nullNotAllowed(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString, _ expected: String
    ) {
        sink.add(Issue(
            code: .typeMismatch,
            path: path + [.key(String(describing: key))],
            params: ["expected": .string(expected)],
            received: "null",
            location: SourceSpan(lo: cursor, len: 4)))
    }
}

//===----------------------------------------------------------------------===//
// Coercing variants, for @Coerce and @Schema(coerceScalars: true) on the JSON path.
//
// The RawValue path (YAML/XML) coerces in RawDecode.swift; these are the direct-to-struct
// equivalents so `@Coerce` means the same thing whichever format arrived. Same rules, and
// they are deliberately boring: "8080" -> 8080, "8080.5" -> Int is an ERROR rather than a
// truncation, 1.0 converts and 1.5 does not, and nothing consults a locale — which is what
// makes the behaviour identical on Linux and on a Mac.
//
// Each scan* primitive rewinds the cursor on failure, so trying them in sequence is safe.
//===----------------------------------------------------------------------===//

extension AssayReader {

    @inlinable
    public mutating func decodeIntCoercing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int? {
        beginValue()
        if let v = scanInt64(), let n = Int(exactly: v) { return n }
        if let s = scanString(), let n = Int(s) { return n }
        if let d = scanDouble(), d == d.rounded(), let n = Int(exactly: d) { return n }
        failed(&sink, path, key, "integer")
        return nil
    }

    @inlinable
    public mutating func decodeInt64Coercing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int64? {
        return decodeIntCoercing(&sink, path, key).map(Int64.init)
    }

    @inlinable
    public mutating func decodeInt32Coercing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Int32? {
        guard let v = decodeIntCoercing(&sink, path, key) else { return nil }
        guard let n = Int32(exactly: v) else {
            overflowed(&sink, path, key, v)
            return nil
        }
        return n
    }

    @inlinable
    public mutating func decodeUIntCoercing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> UInt? {
        guard let v = decodeIntCoercing(&sink, path, key) else { return nil }
        guard let n = UInt(exactly: v) else {
            overflowed(&sink, path, key, v)
            return nil
        }
        return n
    }

    /// A value that decoded but does not fit the declared width.
    ///
    /// This must report. Returning nil silently made `diagnose` answer `isValid == true`
    /// with no value, and made `parse` throw an `AssayError` carrying **zero issues** —
    /// the one outcome this library exists to never produce.
    @inline(never)
    @usableFromInline
    mutating func overflowed(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString, _ value: Int
    ) {
        sink.add(Issue(
            code: .numberOverflow,
            path: path + [.key(String(describing: key))],
            received: String(value),
            location: lastValueSpan))
    }

    @inlinable
    public mutating func decodeDoubleCoercing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Double? {
        beginValue()
        if let d = scanDouble() { return d }
        if let s = scanString(), let d = Double(s) { return d }
        failed(&sink, path, key, "number")
        return nil
    }

    @inlinable
    public mutating func decodeFloatCoercing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Float? {
        beginValue()
        return decodeDoubleCoercing(&sink, path, key).map(Float.init)
    }

    @inlinable
    public mutating func decodeBoolCoercing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> Bool? {
        beginValue()
        if let b = scanBool() { return b }
        if let s = scanString() {
            switch s {
            case "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON", "1":
                return true
            case "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF", "0":
                return false
            default: break
            }
        }
        if let v = scanInt64() {
            if v == 1 { return true }
            if v == 0 { return false }
        }
        failed(&sink, path, key, "boolean")
        return nil
    }

    @inlinable
    public mutating func decodeStringCoercing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) -> String? {
        beginValue()
        if let s = scanString() { return s }
        if let v = scanInt64() { return String(v) }
        if let d = scanDouble() { return String(d) }
        if let b = scanBool() { return b ? "true" : "false" }
        failed(&sink, path, key, "string")
        return nil
    }
}
