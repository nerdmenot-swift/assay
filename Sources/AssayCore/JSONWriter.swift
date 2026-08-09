// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The JSON writer. docs/ENCODING.md.
//
// Shaped like `AssayReader`'s mirror image and constrained the same way: generated code
// emits ONE line per field calling an `@inlinable` primitive here, so encoding costs the
// compile-time budget the same discipline decoding does (docs/COMPILE-TIME.md §3 — body
// size is what dominates, and this file exists so that conditional logic lives in the
// runtime rather than in every expansion).
//
// THE ERROR CHANNEL IS THE DECODER'S. docs/ENCODING.md question 4: `Issue`, `IssueSink`,
// the same codes table, the same renderers. `location` is nil because there is no source
// document to point at, which is a state the renderer already handles — a missing-field
// issue has never had one. What survives and matters is `path`: "coordinates[3] cannot be
// represented in JSON" is the sentence worth producing.
//
// Encoding COLLECTS rather than throwing on the first problem, because that is the
// library's whole identity and breaking it on one side would be surprising. The output
// buffer is still returned on failure, truncated wherever the writer got to, so
// `diagnoseEncode` can show what it managed.
//===----------------------------------------------------------------------===//

/// Accumulates JSON bytes. A struct passed `inout`, like `IssueSink` — static exclusivity,
/// no boxing, no escaping capture.
public struct JSONWriter: ~Copyable {
    @usableFromInline var out: [UInt8]
    /// Whether the container currently being written has had a member yet, so commas are
    /// emitted between members and never before the first.
    @usableFromInline var needsComma: Bool = false
    @usableFromInline let pretty: Bool
    @usableFromInline var depth: Int = 0

    @inlinable
    public init(pretty: Bool = false, reservingCapacity capacity: Int = 512) {
        self.pretty = pretty
        self.out = []
        self.out.reserveCapacity(capacity)
    }

    /// The bytes written so far. Consuming, because the writer owns the buffer and there is
    /// no reason to copy it out.
    @inlinable
    public consuming func finish() -> [UInt8] { out }

    // MARK: Structure

    @inlinable @inline(__always)
    mutating func byte(_ b: UInt8) { out.append(b) }

    @inlinable
    mutating func newlineAndIndent() {
        guard pretty else { return }
        out.append(0x0A)
        for _ in 0..<depth { out.append(0x20); out.append(0x20) }
    }

    @inlinable
    public mutating func beginObject() {
        separate()
        byte(0x7B)                              // {
        depth &+= 1
        needsComma = false
    }

    @inlinable
    public mutating func endObject() {
        depth &-= 1
        if needsComma { newlineAndIndent() }
        byte(0x7D)                              // }
        needsComma = true
    }

    @inlinable
    public mutating func beginArray() {
        separate()
        byte(0x5B)                              // [
        depth &+= 1
        needsComma = false
    }

    @inlinable
    public mutating func endArray() {
        depth &-= 1
        if needsComma { newlineAndIndent() }
        byte(0x5D)                              // ]
        needsComma = true
    }

    /// Comma and indentation before the next member of the current container.
    @inlinable @inline(__always)
    mutating func separate() {
        if needsComma { byte(0x2C) }
        newlineAndIndent()
    }

    /// A key. `StaticString` because generated code always has a literal, which means the
    /// escape scan is over compile-time-constant bytes and folds away for ordinary keys.
    @inlinable
    public mutating func key(_ k: StaticString) {
        separate()
        needsComma = false
        byte(0x22)
        let n = k.utf8CodeUnitCount
        let p = k.utf8Start
        var i = 0
        while i < n {
            let c = unsafe p[i]
            if c < 0x20 || c == 0x22 || c == 0x5C {
                writeEscaped(c)
            } else {
                out.append(c)
            }
            i &+= 1
        }
        byte(0x22)
        byte(0x3A)                              // :
        if pretty { byte(0x20) }
        needsComma = false
    }

    /// A runtime key — dictionary fields and `@Extras`.
    @inlinable
    public mutating func key(_ k: String) {
        separate()
        needsComma = false
        writeStringBody(k)
        byte(0x3A)
        if pretty { byte(0x20) }
        needsComma = false
    }

    // MARK: Scalars

    @inlinable
    public mutating func write(_ v: String) {
        separate()
        writeStringBody(v)
        needsComma = true
    }

    @inlinable
    mutating func writeStringBody(_ v: String) {
        byte(0x22)
        for c in v.utf8 {
            if c < 0x20 || c == 0x22 || c == 0x5C {
                writeEscaped(c)
            } else {
                out.append(c)
            }
        }
        byte(0x22)
    }

    /// The six escapes JSON names, and `\u00XX` for every other control byte. Cold: real
    /// payload text takes the straight-line append above.
    @inline(never)
    @usableFromInline
    mutating func writeEscaped(_ c: UInt8) {
        byte(0x5C)
        switch c {
        case 0x22: byte(0x22)
        case 0x5C: byte(0x5C)
        case 0x08: byte(0x62)                   // \b
        case 0x0C: byte(0x66)                   // \f
        case 0x0A: byte(0x6E)                   // \n
        case 0x0D: byte(0x72)                   // \r
        case 0x09: byte(0x74)                   // \t
        default:
            byte(0x75)                          // u
            let hex: [UInt8] = Array("0123456789abcdef".utf8)
            byte(0x30); byte(0x30)
            byte(hex[Int(c >> 4)]); byte(hex[Int(c & 0x0F)])
        }
    }

    @inlinable
    public mutating func write(_ v: Bool) {
        separate()
        if v {
            out.append(contentsOf: [0x74, 0x72, 0x75, 0x65])
        } else {
            out.append(contentsOf: [0x66, 0x61, 0x6C, 0x73, 0x65])
        }
        needsComma = true
    }

    @inlinable
    public mutating func writeNull() {
        separate()
        out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
        needsComma = true
    }

    @inlinable
    public mutating func write(_ v: Int) { writeInteger(Int64(v)) }
    @inlinable
    public mutating func write(_ v: Int64) { writeInteger(v) }
    @inlinable
    public mutating func write(_ v: Int32) { writeInteger(Int64(v)) }
    @inlinable
    public mutating func write(_ v: UInt) { writeInteger(Int64(bitPattern: UInt64(v))) }

    /// Digits written backwards into a fixed stack buffer, then reversed — no `String`,
    /// no allocation, and `Int64.min` needs no special case because the accumulation is
    /// negative (the same trick `scanInt64` uses on the way in).
    @inlinable
    mutating func writeInteger(_ v: Int64) {
        separate()
        needsComma = true
        if v == 0 { byte(0x30); return }
        var digits = [UInt8]()
        digits.reserveCapacity(20)
        var n = v
        if n < 0 { byte(0x2D) } else { n = -n }
        while n != 0 {
            digits.append(UInt8(0x30 &+ Int(-(n % 10))))
            n /= 10
        }
        var i = digits.count - 1
        while i >= 0 { out.append(digits[i]); i &-= 1 }
    }

    /// `Double`, with the two values JSON cannot express reported rather than emitted.
    ///
    /// This is docs/ENCODING.md question 4's motivating case: NaN and ±Infinity are
    /// perfectly good `Double`s and simply have no JSON spelling. Writing `null`, as some
    /// encoders do, silently changes the value; writing `NaN` produces a document no
    /// conforming parser accepts. Both are worse than saying so.
    @inlinable
    public mutating func write(
        _ v: Double, _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) {
        guard v.isFinite else {
            unrepresentable(&sink, path, key, v)
            separate()
            out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
            needsComma = true
            return
        }
        separate()
        needsComma = true
        // An integral double writes without the trailing ".0" a `String(Double)` would add;
        // otherwise defer to the stdlib, which is shortest-round-trippable by construction.
        if v == v.rounded(), abs(v) < 9_007_199_254_740_992 {
            var n = Int64(v)
            if n == 0 { byte(0x30); if v.sign == .minus { } ; return }
            var digits = [UInt8]()
            digits.reserveCapacity(20)
            if n < 0 { byte(0x2D) } else { n = -n }
            while n != 0 {
                digits.append(UInt8(0x30 &+ Int(-(n % 10))))
                n /= 10
            }
            var i = digits.count - 1
            while i >= 0 { out.append(digits[i]); i &-= 1 }
            return
        }
        out.append(contentsOf: Array(String(v).utf8))
    }

    @inlinable
    public mutating func write(
        _ v: Float, _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) {
        write(Double(v), &sink, path, key)
    }

    @inline(never)
    @usableFromInline
    mutating func unrepresentable(
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString, _ v: Double
    ) {
        sink.add(Issue(
            code: .custom("unrepresentable_value"),
            path: path + [.key(String(describing: key))],
            params: ["format": .string("JSON")],
            received: v.isNaN ? "NaN" : (v > 0 ? "Infinity" : "-Infinity")))
    }

    // MARK: Value models

    /// `RawValue` — what `@Extras` holds, and what dictionary fields of open shape carry.
    public mutating func write(
        _ v: RawValue, _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) {
        switch v {
        case .null:            writeNull()
        case .bool(let b):     write(b)
        case .int(let i):      write(i)
        case .double(let d):   write(d, &sink, path, key)
        case .string(let s):   write(s)
        case .sequence(let xs):
            beginArray()
            for x in xs { write(x, &sink, path, key) }
            endArray()
        case .mapping(let ms):
            beginObject()
            for m in ms {
                self.key(m.key)
                write(m.value, &sink, path, key)
            }
            endObject()
        }
    }

    public mutating func write(
        _ v: JSON.Value, _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) {
        switch v {
        case .null:            writeNull()
        case .bool(let b):     write(b)
        case .int(let i):      write(i)
        case .double(let d):   write(d, &sink, path, key)
        case .string(let s):   write(s)
        case .array(let xs):
            beginArray()
            for x in xs { write(x, &sink, path, key) }
            endArray()
        case .object(let ms):
            beginObject()
            for m in ms {
                self.key(m.key)
                write(m.value, &sink, path, key)
            }
            endObject()
        }
    }

    // MARK: Dates

    /// Epoch seconds out, in the field's PRIMARY format — the first entry of the candidate
    /// chain. docs/ENCODING.md question 5: the encoder targets `.input`, and the primary
    /// format is the one `parse` is documented to expect, so writing it is what makes
    /// round-trip hold.
    public mutating func writeDate(
        _ seconds: Double, _ formats: [DateFormat],
        _ sink: inout IssueSink, _ path: [PathComponent], _ key: StaticString
    ) {
        switch formats.first ?? .iso8601 {
        case .unixSeconds:
            write(seconds, &sink, path, key)
        case .unixMillis:
            write(seconds * 1_000, &sink, path, key)
        case .iso8601, .rfc9110, .pattern:
            // ISO-8601 is written for every text format. A `.pattern` field round-trips
            // through its own pattern only if the pattern can express the instant, which
            // is not decidable here — writing ISO-8601 and saying so is honest; writing a
            // truncated pattern silently would not be.
            guard seconds.isFinite else {
                unrepresentable(&sink, path, key, seconds)
                writeNull()
                return
            }
            write(DateParser.formatISO8601(seconds))
        }
    }
}

// MARK: - Encode-side issue codes

extension IssueCode {
    /// A value with no spelling in the target format — `Double.nan` in JSON, and the
    /// motivating case for encoding having an error channel at all.
    public static let unrepresentableValue = IssueCode.custom("unrepresentable_value")
    /// An `@Extras` key that collides with a declared field's wire key. Writing both would
    /// produce a duplicate key; silently dropping one would lose data.
    public static let extrasKeyCollision = IssueCode.custom("extras_key_collision")
}


// MARK: - The RawValue encode seam

/// A `RawValue` for a date field, in its PRIMARY format — the first of the candidate
/// chain, which is the one `parse` is documented to expect. docs/ENCODING.md question 5.
@inlinable
public func _assayRawDate(_ seconds: Double, _ formats: [DateFormat]) -> RawValue {
    switch formats.first ?? .iso8601 {
    case .unixSeconds: return .double(seconds)
    case .unixMillis:  return .double(seconds * 1_000)
    case .iso8601, .rfc9110, .pattern:
        guard seconds.isFinite else { return .null }
        return .string(DateParser.formatISO8601(seconds))
    }
}


/// An `@Unknown` case reached the encoder without `roundTrips: true`.
///
/// docs/ENCODING.md question 2: writing it back is faithful round-tripping AND a way for
/// an attacker-supplied value to pass through a type that reads as closed. The default
/// refuses, loudly, naming the type and the value — an error at encode is immediate,
/// where a silent pass-through is something you learn about from a security report.
@inline(never)
public func _assayUnknownNotEncodable(
    _ typeName: String, _ value: String,
    _ sink: inout IssueSink, _ path: [PathComponent]
) {
    sink.add(Issue(
        code: .unknownNotEncodable,
        path: path,
        params: ["type": .string(typeName)],
        received: value))
}

extension IssueCode {
    /// An unrecognised enum variant reached the encoder without opting into round-tripping.
    public static let unknownNotEncodable = IssueCode.custom("unknown_not_encodable")
}
