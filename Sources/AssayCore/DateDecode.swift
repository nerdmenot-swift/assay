// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Where dates meet the two decode paths: the reader primitive the JSON body calls, and
// the `RawValue` path YAML and XML come through. Both return EPOCH SECONDS; the macro
// wraps them in `Date(timeIntervalSince1970:)` in the USER's module, which is the seam
// that keeps this target Foundation-free. Split out of Dates.swift on 2026-09-10.
//===----------------------------------------------------------------------===//

// MARK: - The JSON reader primitive

extension AssayReader {

    /// Decode a date value: a string tried against each text-shaped format in order, or
    /// a bare number for `.unixSeconds`/`.unixMillis`. Returns EPOCH SECONDS — the
    /// generated code wraps them in `Date(timeIntervalSince1970:)`, which resolves in
    /// the user's module (see the header).
    ///
    /// A match on any format after the first adds a warning naming which one matched —
    /// the same contract as `@Key(_:or:)`, and for the same reason: silent tolerance is
    /// how a payload drifts formats without anyone noticing.
    @_documentation(visibility: internal)
    @inlinable
    public mutating func _decodeDate(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString,
        _ formats: [DateFormat]
    ) -> Double? {
        beginValue()
        if currentByte == 0x22 {
            let start = cursor
            guard let text = scanString() else {
                failed(&sink, path, key, "date")
                return nil
            }
            return dateFromText(text, formats, &sink, path, key, valueStart: start)
        }
        let start = cursor
        if let v = scanDouble() {
            return dateFromNumber(v, formats, &sink, path, key, valueStart: start)
        }
        failed(&sink, path, key, "date")
        return nil
    }

    @_documentation(visibility: internal)

    @inlinable
    public mutating func _decodeDateOrNull(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString,
        _ formats: [DateFormat]
    ) -> Double?? {
        beginValue()
        if scanNull() { return .some(nil) }
        if let v = _decodeDate(&sink, path, key, formats) { return .some(v) }
        return nil
    }

    @usableFromInline
    mutating func dateFromText(
        _ text: String, _ formats: [DateFormat], _ sink: inout IssueSink,
        _ path: [PathStep], _ key: StaticString, valueStart: Int
    ) -> Double? {
        var primary: DateParseFailure? = nil
        for (i, format) in formats.enumerated() {
            switch DateParser.parse(text, as: format) {
            case .success(let seconds):
                if i > 0 {
                    warnDateFallback(&sink, path, key, matched: format, primary: formats[0])
                }
                return seconds
            case .failure(let failure):
                if primary == nil { primary = failure }
            }
        }
        // +1 skips the opening quote, so the caret lands on the failing byte INSIDE the
        // string — "day 31 is out of range" points at the 31.
        reportInvalidDate(
            &sink, path, key, formats, received: text,
            failure: primary ?? DateParseFailure("no formats to try", at: 0),
            caretAt: valueStart + 1 + (primary?.offset ?? 0))
        return nil
    }

    @usableFromInline
    mutating func dateFromNumber(
        _ value: Double, _ formats: [DateFormat], _ sink: inout IssueSink,
        _ path: [PathStep], _ key: StaticString, valueStart: Int
    ) -> Double? {
        var primary: DateParseFailure? = nil
        for (i, format) in formats.enumerated() where format.acceptsNumber {
            switch DateParser.parse(seconds: value, as: format) {
            case .success(let seconds):
                if i > 0 {
                    warnDateFallback(&sink, path, key, matched: format, primary: formats[0])
                }
                return seconds
            case .failure(let failure):
                if primary == nil { primary = failure }
            }
        }
        reportInvalidDate(
            &sink, path, key, formats, received: shortDouble(value),
            failure: primary
                ?? DateParseFailure("value is a number; \(formats[0].displayName) is text", at: 0),
            caretAt: valueStart)
        return nil
    }

    @inline(never)
    @usableFromInline
    mutating func reportInvalidDate(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString,
        _ formats: [DateFormat], received: String, failure: DateParseFailure, caretAt: Int
    ) {
        sink.add(
            Issue(
                code: .invalidDate,
                path: path + [.key(String(describing: key))],
                params: [
                    "expected": .string(formats.map(\.displayName).joined(separator: ", or ")),
                    "reason": .string(failure.reason),
                    "offset": .int(failure.offset)
                ],
                received: received.count > 64 ? String(received.prefix(61)) + "..." : received,
                location: SourceSpan(lo: caretAt, len: 1)))
    }

    @inline(never)
    @usableFromInline
    mutating func warnDateFallback(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString,
        matched: DateFormat, primary: DateFormat
    ) {
        sink.add(
            warning: Warning(
                code: .dateFormatFallback,
                path: path + [.key(String(describing: key))],
                params: [
                    "matched": .string(matched.displayName),
                    "primary": .string(primary.displayName)
                ]))
    }
}

/// A short rendering of a numeric wire value for error text; `String(_: Double)` says
/// `1.691234567e9`, which is not what the payload said.
@usableFromInline
func shortDouble(_ d: Double) -> String {
    if d == d.rounded(), abs(d) < 1e15 {
        return String(Int64(d))
    }
    return String(d)
}

// MARK: - The RawValue path (YAML and XML)

extension RawValue {

    /// The format-neutral projection has already resolved scalars, so a YAML `1691234567`
    /// arrives as `.int` and an XML `<ts>1691234567</ts>` as `.string` — both must reach
    /// `.unixSeconds`, which is why the text parser accepts digit strings.
    @_documentation(visibility: internal)
    @inlinable
    public func _assayDate(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString,
        _ formats: [DateFormat]
    ) -> Double? {
        switch self {
        case .string(let text):
            var primary: DateParseFailure? = nil
            for (i, format) in formats.enumerated() {
                switch DateParser.parse(text, as: format) {
                case .success(let seconds):
                    if i > 0 {
                        Self.warnDateFallback(
                            &sink, path, key,
                            matched: format, primary: formats[0])
                    }
                    return seconds
                case .failure(let failure):
                    if primary == nil { primary = failure }
                }
            }
            Self.reportInvalidDate(
                &sink, path, key, formats, received: text,
                failure: primary ?? DateParseFailure("no formats to try", at: 0))
            return nil

        case .int(let i):
            return numberDate(Double(i), formats, &sink, path, key, received: String(i))
        case .double(let d):
            return numberDate(d, formats, &sink, path, key, received: shortDouble(d))

        default:
            Self.mismatch(&sink, path, key, "date", self)
            return nil
        }
    }

    @usableFromInline
    func numberDate(
        _ value: Double, _ formats: [DateFormat], _ sink: inout IssueSink,
        _ path: [PathStep], _ key: StaticString, received: String
    ) -> Double? {
        var primary: DateParseFailure? = nil
        for (i, format) in formats.enumerated() where format.acceptsNumber {
            switch DateParser.parse(seconds: value, as: format) {
            case .success(let seconds):
                if i > 0 {
                    Self.warnDateFallback(
                        &sink, path, key,
                        matched: format, primary: formats[0])
                }
                return seconds
            case .failure(let failure):
                if primary == nil { primary = failure }
            }
        }
        Self.reportInvalidDate(
            &sink, path, key, formats, received: received,
            failure: primary
                ?? DateParseFailure("value is a number; \(formats[0].displayName) is text", at: 0))
        return nil
    }

    /// No `location`: the node trees drop byte offsets when they are built. That is
    /// ROADMAP.md §12, not a decision made here.
    @inline(never)
    @usableFromInline
    static func reportInvalidDate(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString,
        _ formats: [DateFormat], received: String, failure: DateParseFailure
    ) {
        sink.add(
            Issue(
                code: .invalidDate,
                path: keyed(path, key),
                params: [
                    "expected": .string(formats.map(\.displayName).joined(separator: ", or ")),
                    "reason": .string(failure.reason),
                    "offset": .int(failure.offset)
                ],
                received: received.count > 64 ? String(received.prefix(61)) + "..." : received))
    }

    @inline(never)
    @usableFromInline
    static func warnDateFallback(
        _ sink: inout IssueSink, _ path: [PathStep], _ key: StaticString,
        matched: DateFormat, primary: DateFormat
    ) {
        sink.add(
            warning: Warning(
                code: .dateFormatFallback,
                path: keyed(path, key),
                params: [
                    "matched": .string(matched.displayName),
                    "primary": .string(primary.displayName)
                ]))
    }
}
