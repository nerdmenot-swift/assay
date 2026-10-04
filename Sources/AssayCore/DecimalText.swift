// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Text to `Double`, for text nobody has checked yet.
//
// `Double(String)` is the right converter — correctly rounded, and not worth re-deriving —
// but it is the wrong GATEKEEPER. Six places hand it a string that arrived from outside:
// a YAML plain scalar being resolved, a `YAML.Node` asked for a number, the YAML writer
// deciding whether a string needs quotes, a `@Coerce`d string on either decode path, and a
// plist `<real>`. Two things follow from asking it first and looking at the answer after.
//
//   * It accepts more than a document format means: `0x1p3` is 8.0 and `infinity` is +inf,
//     neither of which YAML's core schema, a config-file coercion or a plist intends.
//   * It is a parser run on attacker-chosen bytes, so its behaviour on MALFORMED input is
//     part of this library's attack surface. On the nightly-main toolchain of 2026-10-04,
//     `Double("12e3-4")` — exponent digits followed by `-` — traps inside libswiftCore
//     instead of returning nil. A UUID that happens to open `123e4567-…` is such a string,
//     and CI found it by crashing.
//
// So the grammar is checked here, in a dozen lines over bytes, and `Double(String)` is only
// ever shown text that is a well-formed decimal float. That is the same arrangement the
// JSON scanner and the TOML parser already have; these six call sites were the exceptions.
//===----------------------------------------------------------------------===//

/// Whether `text` is a decimal floating-point literal:
/// `[-+]? ( digits [ "." digits* ] | "." digits ) ( [eE] [-+]? digits )?`.
///
/// The YAML 1.2 core schema's float grammar, minus `.inf` and `.nan`, which a caller that
/// wants them spells out. No hexadecimal, no `inf`/`nan` words, no surrounding whitespace.
@_documentation(visibility: internal)
public func _assayIsDecimalFloat(_ text: String.UTF8View) -> Bool {
    var i = text.startIndex
    let end = text.endIndex
    @inline(__always) func digit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    func digits() -> Int {
        var n = 0
        while i < end, digit(text[i]) { i = text.index(after: i); n += 1 }
        return n
    }
    guard i < end else { return false }
    if text[i] == 0x2B || text[i] == 0x2D { i = text.index(after: i) }
    let whole = digits()
    var fraction = 0
    if i < end, text[i] == 0x2E {
        i = text.index(after: i)
        fraction = digits()
    }
    // `1.` and `.5` are floats; a lone `.` or a lone sign is not.
    guard whole > 0 || fraction > 0 else { return false }
    if i < end, text[i] == 0x65 || text[i] == 0x45 {
        i = text.index(after: i)
        if i < end, text[i] == 0x2B || text[i] == 0x2D { i = text.index(after: i) }
        guard digits() > 0 else { return false }
    }
    return i == end
}

/// `text` as a `Double`, if and only if it is a decimal floating-point literal.
///
/// With `allowingNonFinite`, the words `nan`, `inf` and `infinity` are also read, signed or
/// not, in any letter case — the spellings a coerced config value or a property list uses.
/// They are matched here rather than handed on.
@_documentation(visibility: internal)
public func _assayDecimalDouble(_ text: String, allowingNonFinite: Bool = false) -> Double? {
    if _assayIsDecimalFloat(text.utf8) { return Double(text) }
    guard allowingNonFinite else { return nil }
    var word = Substring(text)
    var negative = false
    if let first = word.utf8.first, first == 0x2B || first == 0x2D {
        negative = first == 0x2D
        word = word.dropFirst()
    }
    let lowered = word.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
    if lowered == Array("inf".utf8) || lowered == Array("infinity".utf8) {
        return negative ? -.infinity : .infinity
    }
    if lowered == Array("nan".utf8) { return .nan }
    return nil
}
