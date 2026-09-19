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

    @_documentation(visibility: internal)

    @inlinable
    public func _assayString(
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

    @_documentation(visibility: internal)

    @inlinable
    public func _assayInt(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int? {
        if case .int(let i) = self, let n = Int(exactly: i) { return n }
        if coerce, let n = _coercedInt() { return n }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayInt64(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int64? {
        if case .int(let i) = self { return i }
        if coerce, let n = _coercedInt() { return Int64(n) }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayInt32(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int32? {
        if case .int(let i) = self, let n = Int32(exactly: i) { return n }
        if coerce, let n = _coercedInt(), let v = Int32(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayUInt(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt? {
        if case .int(let i) = self, let n = UInt(exactly: i) { return n }
        if coerce, let n = _coercedInt(), let v = UInt(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayInt8(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int8? {
        if case .int(let i) = self, let n = Int8(exactly: i) { return n }
        if coerce, let n = _coercedInt(), let v = Int8(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayInt16(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Int16? {
        if case .int(let i) = self, let n = Int16(exactly: i) { return n }
        if coerce, let n = _coercedInt(), let v = Int16(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayUInt8(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt8? {
        if case .int(let i) = self, let n = UInt8(exactly: i) { return n }
        if coerce, let n = _coercedInt(), let v = UInt8(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayUInt16(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt16? {
        if case .int(let i) = self, let n = UInt16(exactly: i) { return n }
        if coerce, let n = _coercedInt(), let v = UInt16(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayUInt32(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt32? {
        if case .int(let i) = self, let n = UInt32(exactly: i) { return n }
        if coerce, let n = _coercedInt(), let v = UInt32(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayUInt64(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> UInt64? {
        if case .int(let i) = self, let n = UInt64(exactly: i) { return n }
        if coerce, let n = _coercedInt(), let v = UInt64(exactly: n) { return v }
        Self.mismatch(&sink, path, key, "unsigned integer", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayDouble(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)                  // widening is not coercion
        default: break
        }
        if coerce, case .string(let s) = self, let d = _assayCoerceDouble(s) { return d }
        Self.mismatch(&sink, path, key, "number", self, span)
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayFloat(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Float? {
        _assayDouble(&sink, path, key, coerce: coerce, at: span).map(Float.init)
    }

    @_documentation(visibility: internal)

    @inlinable
    public func _assayBool(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        coerce: Bool = false, at span: SourceSpan? = nil
    ) -> Bool? {
        if case .bool(let b) = self { return b }
        if coerce {
            switch self {
            case .string(let s):
                if let b = _assayCoerceBool(s) { return b }
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
    @_documentation(visibility: internal)
    @inlinable
    public func _coercedInt() -> Int? {
        switch self {
        case .string(let s):
            return _assayCoerceInt64(s).flatMap { Int(exactly: $0) }
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

    @_documentation(visibility: internal)

    @inline(never)
    public static func _missing(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) {
        sink.add(Issue(code: .missing, path: path + [.key(String(describing: key))]))
    }

    @_documentation(visibility: internal)

    @inline(never)
    public static func _notAnObject(
        _ sink: inout IssueSink, _ path: [PathComponent], _ found: RawValue
    ) {
        sink.add(Issue(code: .typeMismatch, path: path,
                       params: ["expected": .string("object")],
                       received: found.describe()))
    }

    /// Report an unknown key found while decoding a mapping, with a did-you-mean.
    ///
    /// `span` is the member's, so the report carries a caret. It did not until
    /// 2026-09-11: an unknown key pointed at the byte on JSON and at nothing at all on
    /// YAML, XML, TOML and property lists. Same family as the type-mismatch caret fixed a
    /// day earlier, and found the same way — by showing the same example in another format.
    ///
    /// One honest difference remains. `RawValue.Member` carries the span of the VALUE, so
    /// the caret lands under `30` in `timeout_secs = 30` where the JSON body puts it under
    /// the key. Right line, right member, wrong half of it. Closing that means a second
    /// span on every member, paid by every document, to improve one cold diagnostic — so
    /// it is recorded here rather than done.
    @_documentation(visibility: internal)
    @inline(never)
    public static func _unknownKey(
        _ sink: inout IssueSink, _ path: [PathComponent], _ name: String,
        known: [String], reject: Bool, span: SourceSpan? = nil
    ) {
        var params: [String: IssueValue] = [:]
        // See `Collectible._reportUnknownKey`: not computed once the sink is full.
        if !sink.isFull, let suggestion = AssayReader._didYouMean(name, in: known) {
            params["didYouMean"] = .string(suggestion)
        }
        params["received"] = .string(name)
        if reject {
            sink.add(Issue(code: .unknownKey, path: path,
                           params: params, received: name, location: span))
        } else {
            sink.add(warning: Warning(code: .unknownKey, path: path,
                                      params: params, location: span))
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
/// Push `key`, run `body` with the path, pop. For a nested decode the generated RawValue body
/// has to write as an EXPRESSION (an array or dictionary element, inside `compactMap`), where
/// push, call, pop cannot be spelled as statements. `body` is non-escaping, so capturing the
/// sink inside it is statically enforced exclusivity, not a box (CLAUDE.md rule 3).
@_documentation(visibility: internal)
@inlinable @inline(__always)
public func _assayPushed<T>(
    _ path: inout [PathComponent], _ key: String, _ body: (inout [PathComponent]) -> T?
) -> T? {
    path.append(.key(key))
    defer { path.removeLast() }
    return body(&path)
}

/// The path is `inout` since 2026-09-19, as on the JSON side (`JSONAssayable`): a nested
/// decode pushes, calls, and pops on one buffer, instead of allocating `path + [.key(k)]` per
/// nested value per element (2 blocks per record on `nested-3/yaml-struct`).
public protocol RawDecodable: Assayable {
    static func _assay(
        from raw: RawValue,
        into sink: inout IssueSink,
        at path: inout [PathComponent]
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
    @_documentation(visibility: internal)
    @inline(never)
    public static func _mismatchPublic(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString,
        _ expected: String, _ found: RawValue, _ span: SourceSpan? = nil
    ) {
        mismatch(&sink, path, key, expected, found, span)
    }
}

// MARK: - Text to scalar, the one definition
//
// `coerceScalars` / `@Coerce` accept a string where a number or boolean was declared. The
// rules live here and nowhere else, so the RawValue path (YAML, XML, TOML, plists) and the
// tree path cannot drift: "8080.5" is not an
// integer on either, and "yes" is a boolean on both.

/// `"8080"` → 8080. Sign allowed; no fraction, no exponent, no whitespace.
@_documentation(visibility: internal)
@inlinable
public func _assayCoerceInt64(_ s: String) -> Int64? { Int64(s) }

/// `"1.5"`, `"1e3"`, `"inf"`. The stdlib's parser, which is correctly rounded.
@_documentation(visibility: internal)
@inlinable
public func _assayCoerceDouble(_ s: String) -> Double? { Double(s) }

/// The spellings a config file or a form uses for a boolean — `true`/`false`, `yes`/`no`,
/// `on`/`off` in lowercase, Capitalised or UPPERCASE, and `1`/`0` — compared by bytes
/// rather than a `String` switch, which is a linear scan with a full compare per case
/// (CLAUDE.md rule 1). Exactly the set the RawValue path accepted before 2026-09-10;
/// `tRuE` is still not a boolean.
@_documentation(visibility: internal)
@inlinable
public func _assayCoerceBool(_ s: String) -> Bool? {
    var it = s.utf8.makeIterator()
    guard let a = it.next() else { return nil }
    let b = it.next(), c = it.next(), d = it.next(), e = it.next()
    guard it.next() == nil else { return nil }
    if b == nil { return a == 0x31 ? true : (a == 0x30 ? false : nil) }              // 1 / 0
    // The casing must be one of three shapes: all lower, all upper, or first upper only.
    // No array here.
    let firstUpper = a & 0x20 == 0
    var restUpper = true, restLower = true
    func fold(_ x: UInt8?) {
        guard let x else { return }
        if x & 0x20 == 0 { restLower = false } else { restUpper = false }
    }
    fold(b); fold(c); fold(d); fold(e)
    guard (firstUpper && restUpper) || restLower else { return nil }
    switch (a | 0x20, b.map { $0 | 0x20 }, c.map { $0 | 0x20 }, d.map { $0 | 0x20 }, e.map { $0 | 0x20 }) {
    case (0x74, 0x72, 0x75, 0x65, nil): return true                                     // true
    case (0x66, 0x61, 0x6C, 0x73, 0x65): return false                                   // false
    case (0x79, 0x65, 0x73, nil, nil): return true                                      // yes
    case (0x6E, 0x6F, nil, nil, nil): return false                                      // no
    case (0x6F, 0x6E, nil, nil, nil): return true                                       // on
    case (0x6F, 0x66, 0x66, nil, nil): return false                                     // off
    default: return nil
    }
}
