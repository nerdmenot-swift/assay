// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The interpreter behind `Assayer<T>`. docs/ASSAYER.md.
//
// SPLIT FROM `Assayer.swift` DELIBERATELY, and the split is the performance design rather
// than filing. `AssayerPlan` is NON-GENERIC: one copy of the interpreter exists in this
// module, no specialisation pressure, no code-size multiplication per `T`. The generic
// parameter enters only at the last step, when `Assayer<T>.build` turns the interpreted
// `RawValue` into the caller's type.
//
// That is the same shape that made `ColumnDecodable` free: the generic work happens once,
// the per-value work is concrete. It is also what keeps the `@inlinable` shims in
// `AssayerBacked` thin enough to stay inside the escape-analysis complexity budget that
// CLAUDE.md's constraint 4 is about.
//
// TWO INTERPRETERS, mirroring the split the macro already emits:
//
//   * `run(_ reader:)` walks bytes. Scalar leaves come straight off the reader with no tree
//     built at all, so a wrapper field costs what a plain field costs.
//   * `run(_ raw:)` walks a `RawValue`. This is what makes YAML and XML work with no
//     additional code — they already project to `RawValue`, so an `AssayerBacked` type
//     decodes from all three formats the moment it conforms.
//===----------------------------------------------------------------------===//

public import AssayCore

/// One node of a schema, interpreted rather than compiled.
///
/// A `final class` with `let`-only storage: trivially `Sendable` without `@unchecked`, one
/// retain to copy an `Assayer`, and `.lazy` can express a recursive schema without an
/// infinitely-sized struct.
public final class AssayerPlan: Sendable {

    @usableFromInline
    enum Node: Sendable {
        case string([Rule])
        case int([Rule])
        case double([Rule])
        /// Rules are accepted and unused; see the interpreter.
        case bool([Rule])
        /// Anything, unvalidated — the escape hatch and the dynamic case's leaf.
        case raw
        /// A `@Schema` type's generated body, reached as a leaf. See `Assayer.schema(_:)`.
        case schema(@Sendable (RawValue, inout IssueSink, [PathComponent]) -> RawValue?)
        indirect case array(AssayerPlan)
        indirect case object([Field])
        indirect case optional(AssayerPlan)
        /// Deferred, for recursive schemas. Recomputed rather than memoised — a lock on the
        /// decode path would cost more than rebuilding a plan node.
        case lazy(@Sendable () -> AssayerPlan)
    }

    @usableFromInline
    struct Field: Sendable {
        @usableFromInline let key: String
        @usableFromInline let plan: AssayerPlan
        @usableFromInline let isOptional: Bool
        @usableFromInline
        init(key: String, plan: AssayerPlan, isOptional: Bool) {
            self.key = key
            self.plan = plan
            self.isOptional = isOptional
        }
    }

    @usableFromInline let node: Node

    @usableFromInline
    init(_ node: Node) { self.node = node }
}

// MARK: - The RawValue interpreter

extension AssayerPlan {

    /// Interpret against the format-neutral projection. This is the arm YAML and XML reach.
    ///
    /// - Parameter depth: charged against `Limits.maxDepth`. **The bytes path gets this from
    ///   `AssayReader.enterContainer`; this one has to do it itself**, and it is not
    ///   optional: a plan built at runtime can contain a `.lazy` cycle that no macro-emitted
    ///   schema can, so this is a denial-of-service surface the static door does not have.
    ///   Closed here rather than later.
    public func run(
        _ raw: RawValue, _ sink: inout IssueSink, _ path: [PathComponent],
        _ limits: Limits, _ depth: Int = 0
    ) -> RawValue? {
        guard depth < limits.maxDepth else {
            sink.add(Issue(code: .depthExceeded, path: path,
                           params: ["maxDepth": .int(limits.maxDepth)]))
            return nil
        }

        switch node {
        case .raw:
            return raw

        case .string(let rules):
            guard case .string(let s) = raw else {
                return Self.mismatch(&sink, path, "string", raw)
            }
            _assayValidate(s, rules, override: nil, field: "", at: nil, path: path, &sink)
            return raw

        case .int(let rules):
            guard case .int(let i) = raw else {
                return Self.mismatch(&sink, path, "integer", raw)
            }
            _assayValidate(i, rules, override: nil, field: "", at: nil, path: path, &sink)
            return raw

        case .double(let rules):
            let d: Double
            switch raw {
            case .double(let x): d = x
            case .int(let i): d = Double(i)          // an integer is a valid double
            default: return Self.mismatch(&sink, path, "number", raw)
            }
            _assayValidate(d, rules, override: nil, field: "", at: nil, path: path, &sink)
            return raw

        case .bool:
            // No rules arm: the rule engine has no `Bool` overload of `_assayValidate`,
            // because there is no rule that applies to a boolean — `.min`, `.range`,
            // `.email` and the rest are all about strings, numbers or collections. The
            // payload is kept so `.bool` has the same shape as its siblings and a future
            // rule needs no signature change.
            guard case .bool = raw else {
                return Self.mismatch(&sink, path, "boolean", raw)
            }
            return raw

        case .schema(let decode):
            return decode(raw, &sink, path)

        case .optional(let inner):
            if case .null = raw { return raw }
            return inner.run(raw, &sink, path, limits, depth)

        case .array(let element):
            guard case .sequence(let xs) = raw else {
                return Self.mismatch(&sink, path, "array", raw)
            }
            var out: [RawValue] = []
            out.reserveCapacity(xs.count)
            for (i, x) in xs.enumerated() {
                guard let v = element.run(x, &sink, path + [.index(i)], limits, depth + 1)
                else { return nil }
                out.append(v)
            }
            return .sequence(out)

        case .object(let fields):
            guard case .mapping(let members) = raw else {
                return Self.mismatch(&sink, path, "object", raw)
            }
            var out: [RawValue.Member] = []
            out.reserveCapacity(fields.count)
            for f in fields {
                let p = path + [.key(f.key)]
                guard let member = members.first(where: { $0.key == f.key }) else {
                    if !f.isOptional {
                        sink.add(Issue(code: .missing, path: p))
                    }
                    continue
                }
                guard let v = f.plan.run(member.value, &sink, p, limits, depth + 1) else {
                    continue
                }
                out.append(RawValue.Member(key: f.key, value: v))
            }
            return .mapping(out)

        case .lazy(let make):
            return make().run(raw, &sink, path, limits, depth + 1)
        }
    }

    @inline(never)
    static func mismatch(
        _ sink: inout IssueSink, _ path: [PathComponent], _ expected: String, _ found: RawValue
    ) -> RawValue? {
        RawValue.mismatchAt(&sink, path, expected, found)
        return nil
    }
}
