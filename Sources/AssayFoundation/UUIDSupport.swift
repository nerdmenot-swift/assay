// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `UUID` as a field type. docs/COLUMN-DECODABLE.md.
//
// THIS FILE IS BIGGER THAN THE `Date` ONE BECAUSE `UUID` STARTED FURTHER BACK. `Date` is
// already a field type -- the macro special-cases it and `Dates.swift` implements it -- so
// its columnar conformance was the only missing half. `UUID` was not a field type at all:
// `var id: UUID` in any `@Schema` failed with "type 'UUID' has no member '_assay'", so a
// `ColumnDecodable` conformance alone would have been unreachable, which is exactly the
// trap that stopped `[UInt8]` from shipping.
//
// So there are two halves here, and they are independent:
//
//   * the TREE path -- `_assay(from:)` for the JSON reader and for `RawValue`, which is
//     what makes `var id: UUID` compile and work from JSON, YAML and XML;
//   * the COLUMNAR path -- `ColumnDecodable`, which is what makes it work from a column
//     store.
//
// ACCEPTANCE IS THE `.uuid` RULE'S, EXACTLY. `FormatValidators.isUUID` already settles what
// Assay considers a UUID: "exactly 8-4-4-4-12 hex with hyphens. No braces, no urn:uuid:, no
// bare 32-hex -- the canonical text form and nothing else, identically on every platform."
// Decoding must not be more permissive than validating, or `@Validate(.uuid) var s: String`
// would reject a string that `var u: UUID` accepts in the same document.
//
// That strictness is also why this does not simply call `UUID(uuidString:)` and stop.
// `FormatValidators`' own header records the reason: that initialiser has TWO different C
// implementations selected by platform, and the non-Darwin one is sscanf-based with
// libc-dependent edge cases -- a UUID your Mac accepts can be rejected on Linux. The shape
// check happens here, against bytes, so the answer is bit-identical everywhere; Foundation
// is then handed a string it has already been proven to accept.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

// MARK: - Parsing, against bytes

/// The canonical 36-byte text form, parsed without allocating.
///
/// Accumulates into two `UInt64`s rather than writing a `uuid_t` through a pointer: the
/// tuple cannot be subscripted, and reaching for `withUnsafeMutableBytes` to fill it would
/// put unsafe code in a module built with `.strictMemorySafety()` for the sake of sixteen
/// bytes. Shifts cost nothing and stay safe.
@usableFromInline
func _assayUUIDFromCanonical(_ b: ArraySlice<UInt8>) -> UUID? {
    guard b.count == 36 else { return nil }
    var hi: UInt64 = 0, lo: UInt64 = 0
    var seen = 0
    let base = b.startIndex
    for k in 0..<36 {
        let c = b[base + k]
        // 8-4-4-4-12: the hyphens are structure, and their positions are checked rather
        // than skipped. "0-1-2-3..." must not parse just because it has 32 hex digits in it.
        if k == 8 || k == 13 || k == 18 || k == 23 {
            guard c == UInt8(ascii: "-") else { return nil }
            continue
        }
        let v: UInt64
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): v = UInt64(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): v = UInt64(c - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): v = UInt64(c - UInt8(ascii: "A")) + 10
        default: return nil
        }
        if seen < 16 { hi = hi << 4 | v } else { lo = lo << 4 | v }
        seen += 1
    }
    guard seen == 32 else { return nil }
    return UUID(uuid: _assayUUIDBytes(hi, lo))
}

/// Sixteen raw bytes, as a binary column holds them.
@usableFromInline
func _assayUUIDFromRaw(_ b: ArraySlice<UInt8>) -> UUID? {
    guard b.count == 16 else { return nil }
    let i = b.startIndex
    return UUID(uuid: (b[i], b[i+1], b[i+2], b[i+3], b[i+4], b[i+5], b[i+6], b[i+7],
                       b[i+8], b[i+9], b[i+10], b[i+11], b[i+12], b[i+13], b[i+14], b[i+15]))
}

@usableFromInline
func _assayUUIDBytes(_ hi: UInt64, _ lo: UInt64) -> uuid_t {
    (UInt8(truncatingIfNeeded: hi >> 56), UInt8(truncatingIfNeeded: hi >> 48),
     UInt8(truncatingIfNeeded: hi >> 40), UInt8(truncatingIfNeeded: hi >> 32),
     UInt8(truncatingIfNeeded: hi >> 24), UInt8(truncatingIfNeeded: hi >> 16),
     UInt8(truncatingIfNeeded: hi >>  8), UInt8(truncatingIfNeeded: hi),
     UInt8(truncatingIfNeeded: lo >> 56), UInt8(truncatingIfNeeded: lo >> 48),
     UInt8(truncatingIfNeeded: lo >> 40), UInt8(truncatingIfNeeded: lo >> 32),
     UInt8(truncatingIfNeeded: lo >> 24), UInt8(truncatingIfNeeded: lo >> 16),
     UInt8(truncatingIfNeeded: lo >>  8), UInt8(truncatingIfNeeded: lo))
}

extension UUID {
    /// The one text entry point, so JSON, YAML and XML cannot drift from each other or
    /// from `FormatValidators.isUUID`.
    @usableFromInline
    static func _assayParse(_ s: String) -> UUID? {
        guard FormatValidators.isUUID(s) else { return nil }
        return _assayUUIDFromCanonical(ArraySlice(Array(s.utf8)))
    }

    @usableFromInline
    static func _assayReport(_ sink: inout IssueSink, _ path: [PathComponent],
                             received: String?) {
        sink.add(Issue(code: .typeMismatch, path: path,
                       params: ["expected": .string("uuid")],
                       received: received))
    }
}

// MARK: - The tree path

// This is the seam the macro uses for any field type it does not special-case: it emits
// `UUID._assay(from: &reader, into: &sink, at: path + [.key("id")])` and lets member lookup
// find this. Nothing has to be added to the macro, which is the point -- a type outside the
// built-in set is decodable from JSON on exactly these terms.
extension UUID {

    nonisolated public static func _assay(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> UUID? {
        reader.beginValue()
        guard reader.currentByte == 0x22, let text = reader.scanString() else {
            reader.reportTypeMismatch(&sink, path, expected: "uuid")
            return nil
        }
        guard let u = _assayParse(text) else {
            // The cursor has moved past the string, so `reportTypeMismatch` would describe
            // whatever comes next. The scanned text is what the reader needs to see.
            _assayReport(&sink, path, received: text)
            return nil
        }
        return u
    }

    /// YAML and XML, through the format-neutral projection. Both deliver a UUID as a
    /// scalar, so `.string` is the only shape that can be right.
    nonisolated public static func _assay(
        from raw: RawValue,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> UUID? {
        guard case .string(let text) = raw else {
            RawValue.mismatchAt(&sink, path, "uuid", raw)
            return nil
        }
        guard let u = _assayParse(text) else {
            _assayReport(&sink, path, received: text)
            return nil
        }
        return u
    }
}

// MARK: - The columnar path

// `BytesColumn` rather than `ColumnBuffer<String>`, and the reason is the text case, not
// the binary one.
//
// Binary is the majority: Arrow stores a UUID as FixedSizeBinary(16), Parquet the same,
// Postgres' wire form is 16 bytes, DuckDB likewise. That alone would settle it.
//
// But a `String` carrier would be worse for the sources that DO hold text. A CSV or NDJSON
// reader already has the bytes in its file buffer, contiguously, with offsets -- which is
// precisely `BytesColumn`. Asking it for a `[String]` column forces one 36-byte `String`
// allocation per row (past the 15-byte small-string limit, so it really is a malloc) purely
// to be parsed and thrown away. Asking for bytes lets it hand over what it already has.
//
// Length disambiguates with no ambiguity to resolve: the canonical text form is 36 bytes
// and the raw form is 16, so a column can be either and a row is never both.
extension UUID: ColumnDecodable {

    public typealias Column = BytesColumn

    public init?(assayColumn c: borrowing BytesColumn, row: Int, metadata: ColumnMetadata) {
        guard let r = c.range(at: row) else { return nil }
        let slice = c.bytes[r]
        switch r.count {
        case 16: guard let u = _assayUUIDFromRaw(slice) else { return nil }; self = u
        case 36: guard let u = _assayUUIDFromCanonical(slice) else { return nil }; self = u
        default: return nil
        }
    }
}
