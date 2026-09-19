// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// ONE VERB PER TASK.
//
// A task does one thing to one fixture, in its own process, so the number belongs to that
// verb and not to a pipeline. Writing the list out is itself the exercise: it is how you
// find the doors nothing has ever timed. It found several here — `diagnose` (the verb the
// library's whole pitch rests on) had no arm of its own anywhere, and neither did
// `validate` against a decoded value on these shapes, nor the RawValue projection of a JSON
// document.
//
// Not every task applies to every shape; `applies(to:)` says which, and the runner prints a
// blank rather than pretending.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayYAML
import AssayTOML
import AssayXML
import CorpusRender
import AssayCore

/// Keeps a decoded value alive across the measurement without the optimiser proving the
/// work dead. One allocation per call on every task equally, so it cancels in a comparison.
final class Keep<T> { let v: T; init(_ v: T) { self.v = v } }

@inline(never)
func consume<T>(_ v: T?) -> Bool { v != nil }

/// A task is built in two stages, and the split is the point.
///
/// `make` does the setup — decoding the document for a task whose verb operates on a
/// VALUE — and returns the closure that is actually timed. The first version of this file
/// had one closure doing both, so `encode` and `validate` were timing a parse plus the
/// verb, and reported `validate` at 2.7× the cost of decoding when most of that number was
/// the decode itself. A harness that measures the wrong thing is worse than no harness,
/// because it is believed.
///
/// `make` returns nil when the verb does not apply to this document, which the runner
/// prints as `declined` rather than hiding.
struct Task {
    let name: String
    let summary: String
    let make: (_ shape: String, _ bytes: [UInt8]) -> (() -> Int?)?
    let applies: (_ shape: String) -> Bool
}

// MARK: - Shape → type dispatch
//
// A switch over the shape name, because a schema-driven decoder needs the type at compile
// time. Kept in one place so a new shape without a type is a compile error here rather than
// a silent gap in the matrix.

private func decodeStruct(_ shape: String, _ b: [UInt8]) -> Int? {
    switch shape {
    case "fields-2":          return (try? Doc2.parse(json: b)).map { $0.items.count }
    case "fields-20":         return (try? Doc20.parse(json: b)).map { $0.items.count }
    case "keys-long":         return (try? DocLongKeys.parse(json: b)).map { $0.items.count }
    case "values-int":        return (try? DocInt.parse(json: b)).map { $0.items.count }
    case "values-double":     return (try? DocDouble.parse(json: b)).map { $0.items.count }
    case "values-bool":       return (try? DocBool.parse(json: b)).map { $0.items.count }
    case "nested-3":          return (try? DocNested.parse(json: b)).map { $0.items.count }
    case "array-10":          return (try? DocArray.parse(json: b)).map { $0.items.count }
    case "optional-absent", "optional-null":
                              return (try? DocOptional.parse(json: b)).map { $0.items.count }
    default:                  return (try? Doc5.parse(json: b)).map { $0.items.count }
    }
}

private func diagnoseStruct(_ shape: String, _ b: [UInt8]) -> Int? {
    switch shape {
    case "fields-2":          return Doc2.diagnose(json: b).value?.items.count
    case "fields-20":         return Doc20.diagnose(json: b).value?.items.count
    case "keys-long":         return DocLongKeys.diagnose(json: b).value?.items.count
    case "values-int":        return DocInt.diagnose(json: b).value?.items.count
    case "values-double":     return DocDouble.diagnose(json: b).value?.items.count
    case "values-bool":       return DocBool.diagnose(json: b).value?.items.count
    case "nested-3":          return DocNested.diagnose(json: b).value?.items.count
    case "array-10":          return DocArray.diagnose(json: b).value?.items.count
    case "optional-absent", "optional-null":
                              return DocOptional.diagnose(json: b).value?.items.count
    default:                  return Doc5.diagnose(json: b).value?.items.count
    }
}

/// Element count regardless of whether a value came out — the error shapes produce issues
/// and no value, and the thing being timed is still 2,000 elements' worth of work.
private func diagnoseElements(_ shape: String, _ b: [UInt8]) -> Int? {
    if let n = diagnoseStruct(shape, b) { return n }
    return elementCount
}

/// Shapes whose values are strings, so the two-field prefix type is a genuine skip rather
/// than a type mismatch.
let stringValuedShapes: Set<String> = [
    "base", "fields-2", "fields-20", "values-long",
    "escapes-10", "escapes-100", "nested-3", "array-10", "unknown-5", "pretty",
    "errors-1", "errors-10", "errors-100",
]

/// Shapes whose element type is the plain 5-string `M5`, so the encode and validate tasks
/// (which need one concrete type) can run on them.
private let fiveStringShapes: Set<String> = [
    "base", "values-long", "escapes-10", "escapes-100", "unknown-5", "pretty",
    "errors-1", "errors-10", "errors-100",
]

// MARK: - The tasks

func allTasks() -> [Task] {
    var out: [Task] = []
    func add(_ name: String, _ summary: String,
             applies: @escaping (String) -> Bool = { _ in true },
             _ make: @escaping (String, [UInt8]) -> (() -> Int?)?) {
        out.append(Task(name: name, summary: summary, make: make, applies: applies))
    }

    // The thesis: bytes straight into a struct.
    add("struct", "T.parse(json:) — the monomorphic decode body") { shape, b in
        { decodeStruct(shape, b) }
    }

    // The verb the library's pitch rests on, which had no arm of its own. On a clean
    // document it should cost what `parse` costs; on `errors-*` it is the only one that
    // still returns, which is the whole point of the pair.
    // ON A CLEAN DOCUMENT this should cost what `parse` costs. On `errors-*` it is the
    // only decode verb that still returns, which is the entire reason the pair exists — so
    // it counts ELEMENTS SEEN rather than values produced. Counting values would report
    // "declined" for exactly the shapes the error axis was built to measure, which is what
    // the first run of this matrix did.
    add("diagnose", "T.diagnose(json:) — collect everything, never throw") { shape, b in
        { diagnoseElements(shape, b) }
    }

    // The prefix path: two fields declared, everything else skipped structurally.
    // Only where the two declared fields are actually strings: on `values-int` and friends
    // the prefix type would be a type mismatch, not a skip, and "declined" on half the
    // matrix hides that the task never ran.
    add("skip", "prefix type — the unknown-key structural skip",
        applies: { stringValuedShapes.contains($0) }) { _, b in
        { (try? DocPrefix.parse(json: b)).map { $0.items.count } }
    }

    // The generic value model, for the shapes where "what does a DOM cost here" is the
    // question the struct number cannot answer.
    add("value", "JSON.Value.decode — the generic tree") { _, b in
        {
            var sink = IssueSink(limits: .default)
            guard let v = JSON.Value.decode(b, into: &sink, limits: .default) else { return nil }
            if case .array(let a)? = v["items"] { return a.count }
            return 0
        }
    }

    // The format-neutral projection, which every YAML/XML/TOML/plist decode goes through
    // and which no arm measured until the `coverage` arm, and then only for XML.
    // The projection ALONE: the tree is built once in `make`, so this number is the
    // `JSON.Value → RawValue` step and not the parse underneath it. That separation is
    // exactly what was missing when a 4× regression in the XML projection shipped.
    add("raw", "JSON.Value → RawValue projection only") { _, b in
        var sink = IssueSink(limits: .default)
        guard let v = JSON.Value.decode(b, into: &sink, limits: .default) else { return nil }
        return {
            let r = RawValue(v)
            if case .sequence(let a)? = r["items"] { return a.count }
            return 0
        }
    }

    // The write side, on the shapes with one concrete type.
    // The write path, with the READ done once in `make`. It also returns the element count
    // rather than the byte count: returning bytes made ns/element mean "ns per output byte"
    // and put `encode` in a different unit from every other row in the table.
    add("encode", "encodedJSON() — the write path",
        applies: { (fiveStringShapes.contains($0) && !$0.hasPrefix("errors"))
                    || $0 == "fields-2" || $0 == "fields-20" || $0 == "nested-3" }) { shape, b in
        switch shape {
        case "nested-3":
            guard let d = try? DocNested.parse(json: b) else { return nil }
            return { (try? d.encodedJSON()) != nil ? d.items.count : nil }
        case "fields-2":
            guard let d = try? Doc2.parse(json: b) else { return nil }
            return { (try? d.encodedJSON()) != nil ? d.items.count : nil }
        case "fields-20":
            guard let d = try? Doc20.parse(json: b) else { return nil }
            return { (try? d.encodedJSON()) != nil ? d.items.count : nil }
        default:
            guard let d = try? Doc5.parse(json: b) else { return nil }
            return { (try? d.encodedJSON()) != nil ? d.items.count : nil }
        }
    }

    // Rules against an already-decoded value — the seam a fast external reader uses, and
    // the one the rows/columns removal made the only answer.
    // `validate` needs a type that HAS rules: a rule-free `@Schema` does not conform to
    // `Validatable` at all, which is the right design (nothing to run) and worth knowing.
    // `DocValidated` is the base shape with one rule per field.
    add("validate", "T.validate(_:) — rules against a decoded value",
        applies: { fiveStringShapes.contains($0) && !$0.hasPrefix("errors") }) { _, b in
        // The BATCH overload, over the elements, with the decode done once in `make` —
        // this is `T.validate(_:)` alone, which is the seam a fast external reader uses.
        // The wrapper declares no rule of its own, so it is not `Validatable`; rules live
        // on `MValidated`.
        guard let d = try? DocValidated.parse(json: b) else { return nil }
        return { MValidated.diagnose(d.items).issues.count &+ d.items.count }
    }

    // The other tree parsers. The fixture is rendered into the format in `make`, OUTSIDE the
    // timed region, by the library's own writers, so the parse sees realistic block YAML and
    // `[[items]]` TOML rather than YAML's JSON-compatible flow style. The count is the root's
    // item count, which also checks the rendering survived.
    add("yaml", "YAML.parse — the block-style tree", applies: { treeFormatShapes.contains($0) }) { _, b in
        var sink = IssueSink(limits: .default)
        guard let v = JSON.Value.decode(b, into: &sink, limits: .default) else { return nil }
        let text = YAML.encode(RawValue(v))
        return {
            guard let n = try? YAML.parse(text) else { return nil }
            if case .mapping(let pairs) = n, case .sequence(let xs)? = pairs.first?.value { return xs.count }
            return nil
        }
    }
    add("toml", "TOML.parse — array-of-tables", applies: { treeFormatShapes.contains($0) }) { _, b in
        var sink = IssueSink(limits: .default)
        guard let v = JSON.Value.decode(b, into: &sink, limits: .default) else { return nil }
        let text = TOML.encode(RawValue(v), into: &sink)
        return {
            guard let n = try? TOML.parse(text) else { return nil }
            if case .table(let t) = n, case .array(let xs)? = t.first(where: { $0.key == "items" })?.value { return xs.count }
            return nil
        }
    }

    add("xml", "XML.parse — the element tree", applies: { treeFormatShapes.contains($0) }) { _, b in
        var sink = IssueSink(limits: .default)
        guard let v = JSON.Value.decode(b, into: &sink, limits: .default) else { return nil }
        let text = Array(renderXML(RawValue(v)).utf8)
        return {
            guard let doc = try? XML.parse(text),
                  case .element(let items)? = doc.root.children.first else { return nil }
            return items.children.count
        }
    }

    return out
}

/// Shapes the YAML, TOML and XML tasks run on: enough to separate record width, nesting, arrays,
/// long values and escapes, without paying Valgrind for every shape twice more.
private let treeFormatShapes: Set<String> = [
    "base", "fields-20", "nested-3", "array-10", "values-long", "escapes-10", "values-int",
]
