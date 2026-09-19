// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
@testable import AssayCore

//===----------------------------------------------------------------------===//
// `AssayReader._countArrayElements` — the structural pre-count behind exact-sized arrays of
// scalars (docs/EFFICIENCY.md row 2). A wrong count can only waste or under-reserve
// capacity, never change a decoded value, but a structural scanner has well-known ways to
// be wrong, and each one is pinned here: commas and brackets inside strings, escaped
// quotes, nesting, whitespace, and inputs with no closing bracket.
//===----------------------------------------------------------------------===//

@Suite("Array element pre-count")
struct ArrayPrecountTests {

    /// Count the array in `json`, starting just past its opening `[`, as the generated
    /// decode does.
    static func count(_ json: String) -> Int {
        let bytes = Array(json.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            var r = unsafe AssayReader(base: buf.baseAddress!, count: buf.count)
            _ = r.tryConsume(0x5B)
            return r._countArrayElements()
        }
    }

    @Test("counts match", arguments: [
        ("[]", 0),
        ("[ ]", 0),
        ("[1]", 1),
        ("[1,2,3]", 3),
        ("[ 1 , 2 ,\n 3 ]", 3),
        (#"["a,b", "c]d", "e[f"]"#, 3),
        (#"["say \"hi\", ok", "x"]"#, 2),
        (#"["back\\", "slash"]"#, 2),
        ("[[1,2],[3,4],[5]]", 3),
        (#"[{"a":1,"b":[1,2]}, {"c":"}"}]"#, 2),
        ("[true,false,null]", 3),
        (#"["x"]"#, 1),
    ])
    func counts(_ json: String, _ expected: Int) {
        #expect(Self.count(json) == expected, "\(json)")
    }

    @Test("no closing bracket counts nothing, and the decode reports it as before",
          arguments: ["[1,2", #"["unterminated"#, "[[1,2]"])
    func malformed(_ json: String) {
        #expect(Self.count(json) == 0)
    }

    @Test("the cursor does not move")
    func cursorUnmoved() {
        let bytes = Array("[1,2,3]".utf8)
        bytes.withUnsafeBufferPointer { buf in
            var r = unsafe AssayReader(base: buf.baseAddress!, count: buf.count)
            _ = r.tryConsume(0x5B)
            let before = r.byteOffset
            _ = r._countArrayElements()
            #expect(r.byteOffset == before)
        }
    }
}
