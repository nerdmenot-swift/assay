// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Lexing helpers: line position, inline space, comments, tokens. Nothing here allocates
// or builds a node.
//===----------------------------------------------------------------------===//

import AssayCore

extension YAML.Parser {

    // MARK: Lexing

    func atLineStart(_ r: inout AssayReader) -> Bool {
        r.byteOffset == 0 || r.byte(at: -1) == 0x0A
    }

    func currentColumn(_ r: inout AssayReader) -> Int {
        r._columnSinceNewline()
    }

    mutating func skipInlineSpace(_ r: inout AssayReader) {
        while let c = r.currentByte, c == 0x20 || c == 0x09 { r.advance(by: 1) }
    }

    mutating func skipLine(_ r: inout AssayReader) {
        while let c = r.currentByte, c != 0x0A { r.advance(by: 1) }
        if r.currentByte == 0x0A { r.advance(by: 1) }
    }

    mutating func skipBlanksAndComments(_ r: inout AssayReader) {
        while let c = r.currentByte {
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                r.advance(by: 1)
                continue
            }
            // A comment starts at line start or after whitespace — `a#b` is a scalar.
            if c == UInt8(ascii: "#") {
                let p = r.byte(at: -1)
                if p == nil || p == 0x20 || p == 0x09 || p == 0x0A {
                    skipLine(&r)
                    continue
                }
            }
            break
        }
    }

    mutating func scanToken(_ r: inout AssayReader) -> String? {
        let start = r.byteOffset
        while let c = r.currentByte,
            c != 0x20, c != 0x09, c != 0x0A, c != 0x0D,
            c != UInt8(ascii: ","), c != UInt8(ascii: "["), c != UInt8(ascii: "]"),
            c != UInt8(ascii: "{"), c != UInt8(ascii: "}")
        {
            r.advance(by: 1)
        }
        return r.byteOffset > start ? r.string(from: start, to: r.byteOffset) : nil
    }
}
