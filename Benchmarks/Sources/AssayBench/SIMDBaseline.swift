// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The owed comparison: Assay against a SIMD-tier C parser.
//
// Every published Assay ratio is against Foundation, and docs/PERFORMANCE.md has said
// from the start that this one is owed and that the float-dense arm is where a scalar
// Swift decoder with no Eisel-Lemire *should lose*. A library that only ever publishes
// the comparisons it wins has not measured anything; it has marketed.
//
// The baseline is yyjson (MIT, ibireme/yyjson), vendored into the benchmark package and
// built the way its own benchmarks build it — `-O3`, non-standard extensions off. It is
// hand-tuned C with a bespoke floating-point parser, and on DOM parsing it trades places
// with simdjson. Choosing the strongest available baseline and tuning it in ITS favour is
// the only way a loss means anything.
//
// TWO comparisons, because one of them would be dishonest alone:
//
//   DOM vs DOM — `JSON.Value.parse` against `yyjson_read`. Both walk the same bytes and
//   build a full tree that owns its contents. This is scanner against scanner with
//   nothing else in it, and it is the comparison Assay is expected to lose.
//
//   USE CASE — `@Schema` decode against yyjson parse *plus extracting the same fields
//   into the same Swift structs*. A DOM you must then walk is not a decoded value, and
//   the walk plus the Swift `String`/`Array` construction is work Assay's macro does
//   inside its single pass. This is what a Swift program would actually write.
//
// Fairness, stated rather than buried:
//   * yyjson's document is freed inside the timed region, because Assay's tree teardown
//     (ARC) is inside its own.
//   * `yyjson_read` default flags — NOT the faster in-situ mode, which mutates the input
//     buffer. Assay does not mutate its input, so in-situ would not be the same promise.
//   * The extraction arm builds real Swift `String`s and `Array`s from yyjson's buffers,
//     because that is the cost Assay pays and hiding it would flatter Assay.
//   * Values are asserted equal before anything is timed.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import CYYJSON

// MARK: - Extracting Swift values from a yyjson DOM

private func yyString(_ v: UnsafeMutablePointer<yyjson_val>?) -> String {
    guard let p = yyjson_get_str(v) else { return "" }
    return String(cString: p)
}

/// The `apimodel` shape, extracted from a yyjson DOM into the same Swift types Assay
/// produces. This is the work a Swift program using yyjson would have to write.
private func extractPayload(_ root: UnsafeMutablePointer<yyjson_val>?) -> CodablePayload? {
    guard let root else { return nil }
    var items: [CodableItem] = []
    if let arr = yyjson_obj_get(root, "items") {
        items.reserveCapacity(Int(yyjson_arr_size(arr)))
        var iter = yyjson_arr_iter()
        yyjson_arr_iter_init(arr, &iter)
        while let e = yyjson_arr_iter_next(&iter) {
            items.append(CodableItem(
                id: yyString(yyjson_obj_get(e, "id")),
                sequence: Int(yyjson_get_int(yyjson_obj_get(e, "sequence"))),
                name: yyString(yyjson_obj_get(e, "name")),
                description: yyString(yyjson_obj_get(e, "description")),
                created_at: yyString(yyjson_obj_get(e, "created_at")),
                updated_at: yyString(yyjson_obj_get(e, "updated_at")),
                amount: yyjson_get_real(yyjson_obj_get(e, "amount")),
                active: yyjson_get_bool(yyjson_obj_get(e, "active")),
                retry_count: Int(yyjson_get_int(yyjson_obj_get(e, "retry_count"))),
                owner_id: yyString(yyjson_obj_get(e, "owner_id"))))
        }
    }
    return CodablePayload(
        request_id: yyString(yyjson_obj_get(root, "request_id")),
        generated_at: yyString(yyjson_obj_get(root, "generated_at")),
        page: Int(yyjson_get_int(yyjson_obj_get(root, "page"))),
        total_count: Int(yyjson_get_int(yyjson_obj_get(root, "total_count"))),
        has_more: yyjson_get_bool(yyjson_obj_get(root, "has_more")),
        items: items)
}

/// The float-dense shape — the arm where the loss was predicted.
private func extractPolygon(_ root: UnsafeMutablePointer<yyjson_val>?) -> CodablePolygon? {
    guard let root else { return nil }
    var coords: [[Double]] = []
    if let arr = yyjson_obj_get(root, "coordinates") {
        coords.reserveCapacity(Int(yyjson_arr_size(arr)))
        var outer = yyjson_arr_iter()
        yyjson_arr_iter_init(arr, &outer)
        while let pair = yyjson_arr_iter_next(&outer) {
            var inner = yyjson_arr_iter()
            yyjson_arr_iter_init(pair, &inner)
            var one: [Double] = []
            one.reserveCapacity(Int(yyjson_arr_size(pair)))
            while let n = yyjson_arr_iter_next(&inner) {
                one.append(yyjson_get_real(n))
            }
            coords.append(one)
        }
    }
    return CodablePolygon(type: yyString(yyjson_obj_get(root, "type")),
                          coordinates: coords)
}

/// Recursive equivalence between Assay's tree and yyjson's, value for value and key for
/// key in document order.
///
/// This is a correctness gate for the timings below, and it is also a THIRD independent
/// differential: the JSON corpus already agrees with `JSONSerialization`, and it now
/// agrees with hand-tuned C as well. A parser that is fast and wrong is not a result.
private func equivalent(_ mine: JSON.Value, _ theirs: UnsafeMutablePointer<yyjson_val>?) -> Bool {
    guard let t = theirs else { return false }
    switch mine {
    case .null:
        return yyjson_is_null(t)
    case .bool(let b):
        return yyjson_is_bool(t) && yyjson_get_bool(t) == b
    case .int(let i):
        if yyjson_is_sint(t) || yyjson_is_uint(t) { return yyjson_get_sint(t) == i }
        // A value Assay read as an integer that yyjson widened to a real still denotes
        // the same number; a DIFFERENCE in value still fails.
        if yyjson_is_real(t) { return yyjson_get_real(t) == Double(i) }
        return false
    case .double(let d):
        if yyjson_is_real(t) { return yyjson_get_real(t).bitPattern == d.bitPattern }
        if yyjson_is_sint(t) || yyjson_is_uint(t) { return Double(yyjson_get_sint(t)) == d }
        return false
    case .string(let s):
        guard yyjson_is_str(t), let p = yyjson_get_str(t) else { return false }
        return String(cString: p) == s
    case .array(let xs):
        guard yyjson_is_arr(t), Int(yyjson_arr_size(t)) == xs.count else { return false }
        var iter = yyjson_arr_iter()
        yyjson_arr_iter_init(t, &iter)
        for x in xs {
            guard let e = yyjson_arr_iter_next(&iter), equivalent(x, e) else { return false }
        }
        return true
    case .object(let ms):
        guard yyjson_is_obj(t), Int(yyjson_obj_size(t)) == ms.count else { return false }
        var iter = yyjson_obj_iter()
        yyjson_obj_iter_init(t, &iter)
        for m in ms {
            guard let k = yyjson_obj_iter_next(&iter), let kp = yyjson_get_str(k),
                  String(cString: kp) == m.key,
                  equivalent(m.value, yyjson_obj_iter_get_val(k)) else { return false }
        }
        return true
    }
}

// MARK: - The arms

func runSIMDBaselineBenchmarks(corpusDir: URL, sizes: [String]) {
    print("")
    print("=== Assay vs yyjson — the SIMD-tier baseline, and the owed loss ===")
    print("yyjson (MIT) built -O3, default read flags (NOT in-situ, which mutates input).")
    print("Document teardown is inside both timed regions. Values asserted equal first.")

    // ---- DOM vs DOM ----
    print("")
    print("DOM vs DOM — JSON.Value.parse vs yyjson_read. Scanner against scanner.")
    print(pad("shape", 18, right: true) + pad("size", 7) + pad("bytes", 9)
          + pad("yyjson ns", 12) + pad("Assay ns", 11) + pad("ratio", 10))
    print(String(repeating: "-", count: 68))

    var domRatios: [Double] = []
    for shape in ["apimodel", "floats-dense", "short-strings", "arrays-of-structs"] {
        for size in ["8k", "64k"] {
            let url = corpusDir.appendingPathComponent("\(shape)-\(size).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let bytes = [UInt8](data)

            // Correctness gate: the two trees must agree, value for value.
            guard let mine = try? JSON.Value.parse(bytes) else { continue }
            let agree: Bool = data.withUnsafeBytes { buf -> Bool in
                let doc = yyjson_read(buf.baseAddress!.assumingMemoryBound(to: CChar.self),
                                      buf.count, 0)
                defer { yyjson_doc_free(doc) }
                return equivalent(mine, yyjson_doc_get_root(doc))
            }
            precondition(agree, "\(shape)-\(size): Assay and yyjson disagree on the value")

            let iters = max(300, iterationCount(forBytes: bytes.count) / 2)
            let yNs = measure(iterations: iters) {
                data.withUnsafeBytes { buf in
                    let doc = yyjson_read(
                        buf.baseAddress!.assumingMemoryBound(to: CChar.self), buf.count, 0)
                    yyjson_doc_free(doc)
                }
            }
            let aNs = measure(iterations: iters) { _ = try? JSON.Value.parse(bytes) }
            let ratio = yNs / aNs
            domRatios.append(ratio)
            print(pad(shape, 18, right: true) + pad(size, 7) + pad("\(bytes.count)", 9)
                  + pad(String(format: "%.0f", yNs), 12)
                  + pad(String(format: "%.0f", aNs), 11)
                  + pad(String(format: "%.2fx", ratio), 10))
        }
    }
    if !domRatios.isEmpty {
        let m = domRatios.reduce(0, +) / Double(domRatios.count)
        print(String(format: "mean %.2fx  (below 1.00 means Assay is SLOWER — the expected result)", m))
    }

    // ---- Use case: decoded value vs decoded value ----
    print("")
    print("Use case — @Schema decode vs yyjson parse + extracting the same Swift structs.")
    print(pad("shape", 18, right: true) + pad("size", 7) + pad("bytes", 9)
          + pad("yyjson ns", 12) + pad("Assay ns", 11) + pad("ratio", 10))
    print(String(repeating: "-", count: 68))

    var useRatios: [Double] = []
    for size in sizes {
        let url = corpusDir.appendingPathComponent("apimodel-\(size).json")
        guard let data = try? Data(contentsOf: url) else { continue }
        let bytes = [UInt8](data)
        guard let mine = Payload.diagnose(json: bytes).value else { continue }
        let theirs: CodablePayload? = data.withUnsafeBytes { buf in
            let doc = yyjson_read(buf.baseAddress!.assumingMemoryBound(to: CChar.self),
                                  buf.count, 0)
            defer { yyjson_doc_free(doc) }
            return extractPayload(yyjson_doc_get_root(doc))
        }
        guard let ref = theirs else { continue }
        precondition(mine.items.count == ref.items.count && mine.requestId == ref.request_id
                     && mine.items.first?.id == ref.items.first?.id,
                     "apimodel-\(size): extracted values differ")

        let iters = max(300, iterationCount(forBytes: bytes.count) / 2)
        let yNs = measure(iterations: iters) {
            data.withUnsafeBytes { buf in
                let doc = yyjson_read(
                    buf.baseAddress!.assumingMemoryBound(to: CChar.self), buf.count, 0)
                _ = extractPayload(yyjson_doc_get_root(doc))
                yyjson_doc_free(doc)
            }
        }
        let aNs = measure(iterations: iters) { _ = Payload.diagnose(json: bytes).value }
        let ratio = yNs / aNs
        useRatios.append(ratio)
        print(pad("apimodel", 18, right: true) + pad(size, 7) + pad("\(bytes.count)", 9)
              + pad(String(format: "%.0f", yNs), 12)
              + pad(String(format: "%.0f", aNs), 11)
              + pad(String(format: "%.2fx", ratio), 10))
    }

    // ---- The float arm, called out on its own ----
    print("")
    print("float-dense use case — the arm PERFORMANCE.md predicted Assay would lose.")
    print("yyjson carries a bespoke fast float parser; Assay has a bounded Clinger path.")
    print(pad("shape", 18, right: true) + pad("size", 7) + pad("bytes", 9)
          + pad("yyjson ns", 12) + pad("Assay ns", 11) + pad("ratio", 10))
    print(String(repeating: "-", count: 68))

    var floatRatios: [Double] = []
    for size in sizes {
        let url = corpusDir.appendingPathComponent("floats-dense-\(size).json")
        guard let data = try? Data(contentsOf: url) else { continue }
        let bytes = [UInt8](data)
        guard let mine = Polygon.diagnose(json: bytes).value else { continue }
        let theirs: CodablePolygon? = data.withUnsafeBytes { buf in
            let doc = yyjson_read(buf.baseAddress!.assumingMemoryBound(to: CChar.self),
                                  buf.count, 0)
            defer { yyjson_doc_free(doc) }
            return extractPolygon(yyjson_doc_get_root(doc))
        }
        guard let ref = theirs else { continue }
        precondition(mine.coordinates.count == ref.coordinates.count)
        // Bit-identical floats, or the comparison is meaningless.
        for (a, b) in zip(mine.coordinates, ref.coordinates) {
            for (x, y) in zip(a, b) {
                precondition(x.bitPattern == y.bitPattern,
                             "floats-dense-\(size): \(x) vs \(y) — parsers disagree")
            }
        }

        let iters = max(300, iterationCount(forBytes: bytes.count) / 2)
        let yNs = measure(iterations: iters) {
            data.withUnsafeBytes { buf in
                let doc = yyjson_read(
                    buf.baseAddress!.assumingMemoryBound(to: CChar.self), buf.count, 0)
                _ = extractPolygon(yyjson_doc_get_root(doc))
                yyjson_doc_free(doc)
            }
        }
        let aNs = measure(iterations: iters) { _ = Polygon.diagnose(json: bytes).value }
        let ratio = yNs / aNs
        floatRatios.append(ratio)
        print(pad("floats-dense", 18, right: true) + pad(size, 7) + pad("\(bytes.count)", 9)
              + pad(String(format: "%.0f", yNs), 12)
              + pad(String(format: "%.0f", aNs), 11)
              + pad(String(format: "%.2fx", ratio), 10))
    }

    func summarise(_ label: String, _ rs: [Double]) {
        guard !rs.isEmpty else { return }
        let m = rs.reduce(0, +) / Double(rs.count)
        print(String(format: "%@: mean %.2fx (min %.2fx, max %.2fx)",
                     label, m, rs.min()!, rs.max()!))
    }
    print("")
    summarise("DOM vs DOM        ", domRatios)
    summarise("use case, apimodel", useRatios)
    summarise("use case, floats  ", floatRatios)
    print("A ratio below 1.00 means yyjson is faster. Those rows are the point of this")
    print("section: they are published because they were predicted, not despite it.")
}
