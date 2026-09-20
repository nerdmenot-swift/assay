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
    /// OWNED, not an `Array`. A write is a store: no uniqueness check, no closure, no
    /// generic sequence machinery. Through an `Array` those checks were 36,004 per
    /// `base/encode` call even after the run and key-literal work, because `Array` cannot
    /// know the writer is its only owner. `finish()` hands the buffer to `EncodedBytes`
    /// (`discard self`), so nothing is copied on the way out either; `EncodedBytes`'s header
    /// carries the argument for the API this shape requires.
    @usableFromInline var buf: UnsafeMutablePointer<UInt8>
    @usableFromInline var capacity: Int
    @usableFromInline var length: Int = 0
    /// Whether the container currently being written has had a member yet, so commas are
    /// emitted between members and never before the first.
    @usableFromInline var needsComma: Bool = false
    @usableFromInline let pretty: Bool
    @usableFromInline var depth: Int = 0
    /// Pretty output only: a key was just written, so the value goes on the key's line.
    /// Without it every value after a key started a new line (`"page": ` then `1` below
    /// it), valid JSON that no one would call pretty, and the only test round-tripped it.
    @usableFromInline var afterKey: Bool = false

    @inlinable
    public init(pretty: Bool = false, reservingCapacity capacity: Int = 512) {
        self.pretty = pretty
        let cap = Swift.max(capacity, 16)
        unsafe self.buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        self.capacity = cap
    }

    /// Frees the buffer if the writer is dropped without finishing — an encode that threw
    /// part-way, for instance.
    deinit { unsafe buf.deallocate() }

    /// The bytes written, handed over. `discard self` suppresses the `deinit` above, so the
    /// allocation moves to `EncodedBytes` rather than being copied or freed.
    ///
    /// NOT `@inlinable`: `discard` is not allowed in an inlinable member of a type that is not
    /// `@frozen`, and this runs once per encode, where a call costs nothing measurable.
    public consuming func finish() -> EncodedBytes {
        let p = unsafe buf
        let n = length
        discard self
        return unsafe EncodedBytes(taking: p, count: n)
    }

    // MARK: Structure

    /// Room for `n` more bytes.
    @inlinable @inline(__always)
    mutating func ensure(_ n: Int) {
        if length &+ n > capacity { grow(n) }
    }

    /// Doubling, as `Array` itself grew, so the block count is what it was before the buffer
    /// became owned.
    @inline(never) @usableFromInline
    mutating func grow(_ n: Int) {
        let target = Swift.max(capacity &* 2, length &+ n)
        let fresh = unsafe UnsafeMutablePointer<UInt8>.allocate(capacity: target)
        unsafe fresh.update(from: buf, count: length)
        unsafe buf.deallocate()
        unsafe buf = fresh
        capacity = target
    }

    @inlinable @inline(__always)
    mutating func byte(_ b: UInt8) {
        ensure(1)
        unsafe buf[length] = b
        length &+= 1
    }

    /// `n` bytes from `p`, one copy.
    @inlinable @inline(__always)
    mutating func put(_ p: UnsafePointer<UInt8>, _ n: Int) {
        guard n > 0 else { return }
        ensure(n)
        unsafe (buf + length).update(from: p, count: n)
        length &+= n
    }

    @inlinable @inline(__always)
    mutating func put(_ literal: StaticString) {
        unsafe put(literal.utf8Start, literal.utf8CodeUnitCount)
    }

    @inlinable
    mutating func newlineAndIndent() {
        guard pretty else { return }
        if afterKey { afterKey = false; return }
        guard length > 0 else { return }            // no newline before the first byte
        byte(0x0A)
        for _ in 0..<depth { byte(0x20); byte(0x20) }
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
        let p = unsafe k.utf8Start
        var i = 0
        while i < n {
            let c = unsafe p[i]
            if c < 0x20 || c == 0x22 || c == 0x5C {
                writeEscaped(c)
            } else {
                byte(c)
            }
            i &+= 1
        }
        byte(0x22)
        byte(0x3A)                              // :
        if pretty { byte(0x20); afterKey = true }
        needsComma = false
    }

    /// A key the MACRO has already encoded: the complete JSON text `"name":`, quotes, escapes
    /// and colon included, as one literal. One append instead of `key(_:)`'s one per byte.
    /// Every `Array.append` re-checks uniqueness, and on `base/encode` keys were most of the
    /// ~42 such checks left per element after 2026-09-19's string-run fix.
    @inlinable
    public mutating func _key(encoded k: StaticString) {
        separate()
        unsafe put(k.utf8Start, k.utf8CodeUnitCount)
        if pretty { byte(0x20); afterKey = true }
        needsComma = false
    }

    /// `_key(separated:)` for a `String` field, whose literal also OPENS the value:
    /// `,"name":"`. `_writeStringOpened` then writes the text and the closing quote. One
    /// append for separator, key and quote, where there were three.
    @inlinable
    public mutating func _key(separatedOpeningString k: StaticString) {
        let start = unsafe k.utf8Start
        let n = k.utf8CodeUnitCount
        if !pretty {
            let skip = needsComma ? 0 : 1
            unsafe put(start + skip, n &- skip)
        } else {
            separate()
            unsafe put(start + 1, n &- 2)
            byte(0x20)
            byte(0x22)
        }
        needsComma = false
    }

    /// The rest of a string value whose opening quote a `_key(separatedOpeningString:)`
    /// literal already wrote.
    @inlinable
    public mutating func _writeStringOpened(_ v: String) {
        writeStringRest(v)
        needsComma = true
    }

    /// `_key(encoded:)` with the SEPARATOR in the literal too: `,"name":`. Compact output
    /// appends it whole when a comma is due and from its second byte when it is not, so a
    /// key is one append instead of two (the comma was its own). Pretty output separates as
    /// usual and appends from the second byte.
    @inlinable
    public mutating func _key(separated k: StaticString) {
        let start = unsafe k.utf8Start
        let n = k.utf8CodeUnitCount
        if !pretty && needsComma {
            unsafe put(start, n)
        } else {
            separate()
            unsafe put(start + 1, n &- 1)
            if pretty { byte(0x20); afterKey = true }
        }
        needsComma = false
    }

    /// A runtime key — dictionary fields and `@Extras`.
    @inlinable
    public mutating func key(_ k: String) {
        separate()
        needsComma = false
        writeStringBody(k)
        byte(0x3A)
        if pretty { byte(0x20); afterKey = true }
        needsComma = false
    }

    // MARK: Scalars

    @inlinable
    public mutating func write(_ v: String) {
        separate()
        writeStringBody(v)
        needsComma = true
    }

    /// RUNS, not bytes. Until 2026-09-19 this appended one byte at a time, and every
    /// `Array.append` re-checks that the buffer is uniquely referenced: `count.py` measured
    /// 90,008 uniqueness checks per `base/encode` call in this function alone, about 4.5 per
    /// string written. Now the bytes between two characters that need escaping go in with one
    /// `append(contentsOf:)`, which for real payload text is the whole string.
    @inlinable
    mutating func writeStringBody(_ v: String) {
        byte(0x22)
        writeStringRest(v)
    }

    /// A string's text and closing quote, the opening one already written.
    @inlinable
    mutating func writeStringRest(_ v: String) {
        // BORROWED, not copied. `var v = v; v.withUTF8` did the same job and cost a String
        // retain per string written (count.py: +2,000 per call on fields-2/encode). A native
        // String always has contiguous UTF-8, so the copy is only for a bridged one.
        let borrowed: Void? = unsafe v.utf8.withContiguousStorageIfAvailable { unsafe appendEscaping($0) }
        if borrowed == nil {
            var copy = v
            copy.withUTF8 { unsafe appendEscaping($0) }
        }
        byte(0x22)
    }

    @inlinable
    mutating func appendEscaping(_ bytes: UnsafeBufferPointer<UInt8>) {
        var run = 0
        var i = 0
        while i < bytes.count {
            let c = unsafe bytes[i]
            if c < 0x20 || c == 0x22 || c == 0x5C {
                if i > run {
                    unsafe put(bytes.baseAddress! + run, i &- run)
                }
                writeEscaped(c)
                run = i &+ 1
            }
            i &+= 1
        }
        if run < bytes.count {
            unsafe put(bytes.baseAddress! + run, bytes.count &- run)
        }
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
            put("true")
        } else {
            put("false")
        }
        needsComma = true
    }

    @inlinable
    public mutating func writeNull() {
        separate()
        put("null")
        needsComma = true
    }

    @inlinable
    public mutating func write(_ v: Int) { writeInteger(Int64(v)) }
    @inlinable
    public mutating func write(_ v: Int64) { writeInteger(v) }
    @inlinable
    public mutating func write(_ v: Int32) { writeInteger(Int64(v)) }
    @inlinable
    public mutating func write(_ v: Int8) { writeInteger(Int64(v)) }
    @inlinable
    public mutating func write(_ v: Int16) { writeInteger(Int64(v)) }
    @inlinable
    public mutating func write(_ v: UInt8) { writeInteger(Int64(v)) }
    @inlinable
    public mutating func write(_ v: UInt16) { writeInteger(Int64(v)) }
    @inlinable
    public mutating func write(_ v: UInt32) { writeInteger(Int64(v)) }

    // UInt and UInt64 need their own path. This used to read
    // `writeInteger(Int64(bitPattern: UInt64(v)))`, which REINTERPRETS rather than converts:
    // `UInt.max` encoded as `-1`, and every unsigned value above `Int64.max` came out
    // negative. docs/ENCODING.md states round-trip as a law, and that broke it silently --
    // the document was well-formed JSON, just a different number. Found 2026-08-31 while
    // adding the narrow widths, because the obvious way to write `UInt64` was to copy this.
    //
    // The values are not reachable through DECODING -- `scanInt64` caps the input at
    // `Int64.max` -- so this only bit a value the program constructed itself and then
    // encoded. That is exactly the case an encoder must get right.
    @inlinable
    public mutating func write(_ v: UInt) { writeUnsignedInteger(UInt64(v)) }
    @inlinable
    public mutating func write(_ v: UInt64) { writeUnsignedInteger(v) }

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
        while i >= 0 { byte(digits[i]); i &-= 1 }
    }

    /// The same digits-backwards trick as `writeInteger`, over the full unsigned range.
    ///
    /// Separate rather than folded in, because the negative-accumulation trick that lets
    /// `writeInteger` handle `Int64.min` without a special case has no unsigned analogue --
    /// and routing unsigned values through it is what produced `-1` for `UInt.max`.
    @inlinable
    mutating func writeUnsignedInteger(_ v: UInt64) {
        separate()
        needsComma = true
        if v == 0 { byte(0x30); return }
        var digits = [UInt8]()
        digits.reserveCapacity(20)
        var n = v
        while n != 0 {
            digits.append(UInt8(0x30 &+ Int(n % 10)))
            n /= 10
        }
        var i = digits.count - 1
        while i >= 0 { byte(digits[i]); i &-= 1 }
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
            put("null")
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
            while i >= 0 { byte(digits[i]); i &-= 1 }
            return
        }
        var text = String(v)
        text.withUTF8 { unsafe put($0.baseAddress!, $0.count) }
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
            code: .unrepresentableValue,
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

