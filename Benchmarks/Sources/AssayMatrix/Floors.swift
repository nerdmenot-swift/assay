// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// FLOORS — the least heap a verb's RESULT can occupy, derived from the result itself.
//
// Every other number in Benchmarks/ compares Assay with something: Foundation, ZippyJSON,
// yyjson, itself last week. None says how much is LEFT. A floor does: `count.py` reports each
// cell's measured heap against it, and a cell at 1.0× has nothing to win while a cell at 5×
// has most of it still on the table.
//
// The floor is what the decoded value must hold, walked with `Mirror`:
//   * one block per non-empty Array, holding a 32-byte object header plus count × stride;
//   * one block per String longer than 15 UTF-8 bytes (shorter ones are stored inline, the
//     small-string representation), holding the header plus the bytes and a terminator;
//   * nothing else. Structs, Ints, Doubles, Bools and short Strings live inline.
//
// It is a lower bound, not an estimate: malloc's size classes round up, so a measured cell
// can never reach exactly 1.0× on bytes. Blocks can. The verbs that build a generic tree
// (`value`, `raw`) get no floor, because the data does not need anything a tree adds, and
// holding a tree to a struct's floor would just measure the tree.
//===----------------------------------------------------------------------===//

import Assay

struct Floor { var blocks = 0; var bytes = 0 }

private let objectHeader = 32

private protocol ElementStride { static var elementStride: Int { get } }
extension Array: ElementStride { static var elementStride: Int { MemoryLayout<Element>.stride } }

private func walk(_ v: Any, _ f: inout Floor) {
    if let s = v as? String {
        let n = s.utf8.count
        if n > 15 { f.blocks += 1; f.bytes += objectHeader + n + 1 }
        return
    }
    let m = Mirror(reflecting: v)
    switch m.displayStyle {
    case .collection?:
        let children = Array(m.children)
        if !children.isEmpty, let t = type(of: v) as? ElementStride.Type {
            f.blocks += 1
            f.bytes += objectHeader + children.count * t.elementStride
        }
        for c in children { walk(c.value, &f) }
    default:
        for c in m.children { walk(c.value, &f) }
    }
}

func floor(of value: Any) -> Floor { var f = Floor(); walk(value, &f); return f }

/// The value a decode verb produces on this shape, for the floor walk. The switch mirrors
/// `decodeStruct` in Tasks.swift, and must: a floor computed from a different type would be
/// a floor for a different decode.
private func decodedValue(_ shape: String, _ b: [UInt8]) -> Any? {
    switch shape {
    case "fields-2":          return try? Doc2.parse(json: b)
    case "fields-20":         return try? Doc20.parse(json: b)
    case "keys-long":         return try? DocLongKeys.parse(json: b)
    case "values-int":        return try? DocInt.parse(json: b)
    case "values-double":     return try? DocDouble.parse(json: b)
    case "values-bool":       return try? DocBool.parse(json: b)
    case "nested-3":          return try? DocNested.parse(json: b)
    case "array-10":          return try? DocArray.parse(json: b)
    case "optional-absent", "optional-null": return try? DocOptional.parse(json: b)
    default:                  return try? Doc5.parse(json: b)
    }
}

/// nil when the verb has no floor on this shape.
func floor(shape: String, task: String, bytes b: [UInt8]) -> Floor? {
    switch task {
    case "struct", "diagnose": return decodedValue(shape, b).map { floor(of: $0) }
    case "skip":               return (try? DocPrefix.parse(json: b)).map { floor(of: $0) }
    case "validate":           return Floor()
    case "encode":
        // One contiguous output buffer, exactly as long as the document it writes.
        let n: Int?
        switch shape {
        case "fields-2": n = (try? Doc2.parse(json: b)).flatMap { try? $0.encodedJSON() }?.count
        case "fields-20": n = (try? Doc20.parse(json: b)).flatMap { try? $0.encodedJSON() }?.count
        case "nested-3": n = (try? DocNested.parse(json: b)).flatMap { try? $0.encodedJSON() }?.count
        default: n = (try? Doc5.parse(json: b)).flatMap { try? $0.encodedJSON() }?.count
        }
        return n.map { Floor(blocks: 1, bytes: objectHeader + $0) }
    default:                   return nil
    }
}
