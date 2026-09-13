// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore

//===----------------------------------------------------------------------===//
// 64 FIELDS — `@Schema`'s documented maximum, which did not compile.
//
// The presence mask is a `UInt64` and the emitter wrote each bit as `\(1 << UInt64(i))`
// inside a string interpolation. With no type context there the `1` is an `Int`, so bit 63
// landed on the sign bit and the macro emitted `-9223372036854775808` into a `UInt64`:
// 63 fields compiled, 64 — the number `@Schema`'s own refusal message names — did not.
//
// Found 2026-09-13 by a field-count sweep built to measure something else entirely. The
// two tests below are the boundary and the thing the boundary bit is FOR: bit 63 has to
// carry presence, so the last field must decode and, when absent, must be reported.
//===----------------------------------------------------------------------===//

@Suite("The 64-field ceiling")
struct MaxFieldsTests {

    @Schema struct Wide: Equatable {
        var k00: String
        var k01: String
        var k02: String
        var k03: String
        var k04: String
        var k05: String
        var k06: String
        var k07: String
        var k08: String
        var k09: String
        var k10: String
        var k11: String
        var k12: String
        var k13: String
        var k14: String
        var k15: String
        var k16: String
        var k17: String
        var k18: String
        var k19: String
        var k20: String
        var k21: String
        var k22: String
        var k23: String
        var k24: String
        var k25: String
        var k26: String
        var k27: String
        var k28: String
        var k29: String
        var k30: String
        var k31: String
        var k32: String
        var k33: String
        var k34: String
        var k35: String
        var k36: String
        var k37: String
        var k38: String
        var k39: String
        var k40: String
        var k41: String
        var k42: String
        var k43: String
        var k44: String
        var k45: String
        var k46: String
        var k47: String
        var k48: String
        var k49: String
        var k50: String
        var k51: String
        var k52: String
        var k53: String
        var k54: String
        var k55: String
        var k56: String
        var k57: String
        var k58: String
        var k59: String
        var k60: String
        var k61: String
        var k62: String
        var k63: String
    }

    @Test("a type at the documented maximum decodes, bit 63 included")
    func decodesAtTheCeiling() throws {
        let d = Wide.diagnose(json: Array("{\"k00\":\"v0\",\"k01\":\"v1\",\"k02\":\"v2\",\"k03\":\"v3\",\"k04\":\"v4\",\"k05\":\"v5\",\"k06\":\"v6\",\"k07\":\"v7\",\"k08\":\"v8\",\"k09\":\"v9\",\"k10\":\"v10\",\"k11\":\"v11\",\"k12\":\"v12\",\"k13\":\"v13\",\"k14\":\"v14\",\"k15\":\"v15\",\"k16\":\"v16\",\"k17\":\"v17\",\"k18\":\"v18\",\"k19\":\"v19\",\"k20\":\"v20\",\"k21\":\"v21\",\"k22\":\"v22\",\"k23\":\"v23\",\"k24\":\"v24\",\"k25\":\"v25\",\"k26\":\"v26\",\"k27\":\"v27\",\"k28\":\"v28\",\"k29\":\"v29\",\"k30\":\"v30\",\"k31\":\"v31\",\"k32\":\"v32\",\"k33\":\"v33\",\"k34\":\"v34\",\"k35\":\"v35\",\"k36\":\"v36\",\"k37\":\"v37\",\"k38\":\"v38\",\"k39\":\"v39\",\"k40\":\"v40\",\"k41\":\"v41\",\"k42\":\"v42\",\"k43\":\"v43\",\"k44\":\"v44\",\"k45\":\"v45\",\"k46\":\"v46\",\"k47\":\"v47\",\"k48\":\"v48\",\"k49\":\"v49\",\"k50\":\"v50\",\"k51\":\"v51\",\"k52\":\"v52\",\"k53\":\"v53\",\"k54\":\"v54\",\"k55\":\"v55\",\"k56\":\"v56\",\"k57\":\"v57\",\"k58\":\"v58\",\"k59\":\"v59\",\"k60\":\"v60\",\"k61\":\"v61\",\"k62\":\"v62\",\"k63\":\"v63\"}".utf8))
        #expect(d.issues.isEmpty, "\(d.issues.map(\.message))")
        #expect(d.value?.k00 == "v0")
        #expect(d.value?.k63 == "v63", "the highest bit in the presence mask")
    }

    @Test("the 64th field missing is reported, which is what bit 63 is for")
    func missingAtTheCeiling() {
        let d = Wide.diagnose(json: Array("{\"k00\":\"v0\",\"k01\":\"v1\",\"k02\":\"v2\",\"k03\":\"v3\",\"k04\":\"v4\",\"k05\":\"v5\",\"k06\":\"v6\",\"k07\":\"v7\",\"k08\":\"v8\",\"k09\":\"v9\",\"k10\":\"v10\",\"k11\":\"v11\",\"k12\":\"v12\",\"k13\":\"v13\",\"k14\":\"v14\",\"k15\":\"v15\",\"k16\":\"v16\",\"k17\":\"v17\",\"k18\":\"v18\",\"k19\":\"v19\",\"k20\":\"v20\",\"k21\":\"v21\",\"k22\":\"v22\",\"k23\":\"v23\",\"k24\":\"v24\",\"k25\":\"v25\",\"k26\":\"v26\",\"k27\":\"v27\",\"k28\":\"v28\",\"k29\":\"v29\",\"k30\":\"v30\",\"k31\":\"v31\",\"k32\":\"v32\",\"k33\":\"v33\",\"k34\":\"v34\",\"k35\":\"v35\",\"k36\":\"v36\",\"k37\":\"v37\",\"k38\":\"v38\",\"k39\":\"v39\",\"k40\":\"v40\",\"k41\":\"v41\",\"k42\":\"v42\",\"k43\":\"v43\",\"k44\":\"v44\",\"k45\":\"v45\",\"k46\":\"v46\",\"k47\":\"v47\",\"k48\":\"v48\",\"k49\":\"v49\",\"k50\":\"v50\",\"k51\":\"v51\",\"k52\":\"v52\",\"k53\":\"v53\",\"k54\":\"v54\",\"k55\":\"v55\",\"k56\":\"v56\",\"k57\":\"v57\",\"k58\":\"v58\",\"k59\":\"v59\",\"k60\":\"v60\",\"k61\":\"v61\",\"k62\":\"v62\"}".utf8))
        #expect(d.value == nil)
        #expect(d.issues.count == 1, "\(d.issues.map(\.message))")
        #expect(d.issues.first?.code == .missing)
        #expect(d.issues.first?.path == [.key("k63")], "\(String(describing: d.issues.first?.path))")
    }
}
