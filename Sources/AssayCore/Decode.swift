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

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeString(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
        , _ element: Int = -1
    ) -> String? {
        beginValue()
        if let s = scanString() { return s }
        failed(&sink, path, key, "string", element)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeInt(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
        , _ element: Int = -1
    ) -> Int? {
        beginValue()
        if let v = scanInt64(), let n = Int(exactly: v) { return n }
        failed(&sink, path, key, "integer", element)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeInt64(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
        , _ element: Int = -1
    ) -> Int64? {
        beginValue()
        if let v = scanInt64() { return v }
        failed(&sink, path, key, "integer", element)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeInt32(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
        , _ element: Int = -1
    ) -> Int32? {
        beginValue()
        if let v = scanInt64(), let n = Int32(exactly: v) { return n }
        failed(&sink, path, key, "integer", element)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeUInt(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
        , _ element: Int = -1
    ) -> UInt? {
        beginValue()
        if let v = scanInt64(), let n = UInt(exactly: v) { return n }
        failed(&sink, path, key, "unsigned integer", element)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeDouble(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
        , _ element: Int = -1
    ) -> Double? {
        beginValue()
        if let v = scanDouble() { return v }
        failed(&sink, path, key, "number", element)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeFloat(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
        , _ element: Int = -1
    ) -> Float? {
        beginValue()
        if let v = scanDouble() { return Float(v) }
        failed(&sink, path, key, "number", element)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeBool(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
        , _ element: Int = -1
    ) -> Bool? {
        beginValue()
        if let v = scanBool() { return v }
        failed(&sink, path, key, "boolean", element)
        return nil
    }

    /// `null` is *presence with a null value*, which for an optional field means nil and
    /// for a required field is a type mismatch. Kept distinct from absence on purpose —
    /// conflating the two is the single costliest ambiguity in `Codable`.
    @_documentation(visibility: internal)
    @inlinable @inline(__always)
    public mutating func _consumeNullIfPresent() -> Bool {
        scanNull()
    }

    /// Cold. Never inlined into the field loop.
    @inline(never)
    @usableFromInline
    /// - Parameter element: the index of the failing element when this value is inside an
    ///   array, or `-1` when it is a plain field. Passed as a scalar and consumed HERE,
    ///   inside a cold `@inline(never)` function, so the hot path carries one extra
    ///   register-passed `Int` and allocates nothing. An `[Int32]` element that does not fit
    ///   used to report `[.key("xs")]` and name no element at all.
    ///
    ///   Deliberately NOT the empty-`StaticString` sentinel the rule engine uses for the
    ///   same purpose: the XML projection stores an `@XML(.text)` field under a reserved
    ///   EMPTY key, so a sentinel spelled that way has a real collision waiting in it.
    mutating func failed(
        _ sink: inout IssueSink,
        _ path: [PathStep],
        _ key: StaticString,
        _ expected: String,
        _ element: Int = -1
    ) {
        var p = path
        p.append(.key(String(describing: key)))
        if element >= 0 { p.append(.index(element)) }
        if numberRangeErrorAt >= 0 {
            // Syntactically a number, and not representable. Saying "must be a double"
            // would be false — it IS a double-shaped literal — and saying nothing would
            // ship infinity.
            sink.add(Issue(code: .numberOverflow, path: p,
                           location: SourceSpan(lo: numberRangeErrorAt,
                                                len: numberRangeErrorLength)))
            numberRangeErrorAt = -1
            return
        }
        if escapeErrorAt >= 0 {
            // The string was scanned to its closing quote already; say what was wrong
            // with it rather than that it was not a string.
            sink.add(Issue(code: .invalidEscape, path: p,
                           location: SourceSpan(lo: escapeErrorAt, len: 2)))
            escapeErrorAt = -1
            return
        }
        sink.add(Issue(
            code: .typeMismatch,
            path: p,
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
    @_documentation(visibility: internal)
    @inline(never)
    public mutating func _missingRequired(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) {
        sink.add(Issue(code: .missing, path: path + [.key(String(describing: key))]))
    }
}

//===----------------------------------------------------------------------===//
// Null-aware variants, for optional fields.
//
// These exist for a COMPILE-TIME reason, not a runtime one. The macro previously wrapped
// every field in `if reader._consumeNullIfPresent() { ... } else { ... }`, which doubled
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

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeStringOrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> String?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let s = scanString() { return .some(s) }
        failed(&sink, path, key, "string")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeIntOrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Int?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanInt64(), let n = Int(exactly: v) { return .some(n) }
        failed(&sink, path, key, "integer")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeInt64OrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Int64?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanInt64() { return .some(v) }
        failed(&sink, path, key, "integer")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeInt32OrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Int32?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanInt64(), let n = Int32(exactly: v) { return .some(n) }
        failed(&sink, path, key, "integer")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeUIntOrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> UInt?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanInt64(), let n = UInt(exactly: v) { return .some(n) }
        failed(&sink, path, key, "unsigned integer")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeDoubleOrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Double?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanDouble() { return .some(v) }
        failed(&sink, path, key, "number")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeFloatOrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Float?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanDouble() { return .some(Float(v)) }
        failed(&sink, path, key, "number")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeBoolOrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Bool?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = scanBool() { return .some(v) }
        failed(&sink, path, key, "boolean")
        return nil
    }

    /// Required-field null handling: an explicit null where a value is required.
    @_documentation(visibility: internal)
    @inline(never)
    public mutating func _nullNotAllowed(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString, _ expected: String
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

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeIntCoercing(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Int? {
        beginValue()
        if let v = scanInt64(), let n = Int(exactly: v) { return n }
        if let s = scanString(), let n = Int(s) { return n }
        if let d = scanDouble(), d == d.rounded(), let n = Int(exactly: d) { return n }
        failed(&sink, path, key, "integer")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeInt64Coercing(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Int64? {
        return _decodeIntCoercing(&sink, path, key).map(Int64.init)
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeInt32Coercing(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Int32? {
        guard let v = _decodeIntCoercing(&sink, path, key) else { return nil }
        guard let n = Int32(exactly: v) else {
            overflowed(&sink, path, key, v)
            return nil
        }
        return n
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeUIntCoercing(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> UInt? {
        guard let v = _decodeIntCoercing(&sink, path, key) else { return nil }
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
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString, _ value: Int
    ) {
        sink.add(Issue(
            code: .numberOverflow,
            path: path + [.key(String(describing: key))],
            received: String(value),
            location: lastValueSpan))
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeDoubleCoercing(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Double? {
        beginValue()
        if let d = scanDouble() { return d }
        if let s = scanString(), let d = Double(s) { return d }
        failed(&sink, path, key, "number")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeFloatCoercing(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
    ) -> Float? {
        beginValue()
        return _decodeDoubleCoercing(&sink, path, key).map(Float.init)
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeBoolCoercing(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
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

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeStringCoercing(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString
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

// MARK: - The narrow fixed-width integers

// Int8/Int16/UInt8/UInt16/UInt32/UInt64, added 2026-08-31. Int, Int32, Int64 and UInt were
// the whole set before that, which meant `var b: UInt8` did not compile in ANY `@Schema`
// type -- and with it `[UInt8]`, the obvious way to carry a blob. That is what blocked the
// `[UInt8]` from having a usable field type.
//
// Spelled out one width at a time rather than written once over `FixedWidthInteger`. The
// header of `CodeGen.scalarCall` states the reason as a rule -- "monomorphic per type;
// there is no generic FixedWidthInteger dispatch anywhere on the decode path, which is the
// whole reason a macro decoder can be fast here" -- and a generic helper here would put one
// back at the leaf, where it is hottest and where `@inlinable` has to carry it across the
// module boundary into the user's code.
//
// UInt64 CANNOT REPRESENT ITS FULL RANGE, and that is inherited rather than introduced:
// `scanInt64` returns `Int64`, so any unsigned value above `Int64.max` fails to scan. `UInt`
// has had exactly this ceiling since it was added and this width matches it. Lifting it
// needs a `scanUInt64` in the number parser, which is its own change with its own tests.
//
// The code for those widths is DecodeWidths.swift, generated by gen-decode-widths.sh.
