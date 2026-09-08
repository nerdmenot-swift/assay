// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `Assayer<T>` — the runtime value API. docs/ASSAYER.md, ROADMAP §7.
//
// THE OPEN QUESTION, AND ITS ANSWER. ROADMAP §7 held this back not on difficulty but on
// whether it belongs in a 1.0 at all: "shipping it means committing to maintaining two
// front doors forever, and the domain-type use case that motivates half of it might be
// covered by a narrower protocol."
//
// It is ONE front door with two receivers, and it is a conformance-authoring API rather
// than a second parse API. The static verbs are spelled on a TYPE (`User.parse(json:)`);
// these are spelled on a VALUE (`schema.parse(json:)`). Same `Diagnosis`, same `Issue`
// codes, same `AssayError`, same renderers, same `Limits`. Nothing about the vocabulary
// forks. What forks is the receiver, and it forks for two things the static door cannot
// express at all:
//
//   * THERE IS NO DECLARATION. A form schema in a database row, a plugin manifest, a
//     JSON-Schema document fetched at runtime. There is no `T` to call `.parse` on. A macro
//     reads syntax; this is structurally out of its reach.
//   * THERE IS NO OBJECT TO DECODE. `EmailAddress` is a validated `String`. `@Schema`
//     decodes an object with keys and has no spelling for "this type IS a constrained
//     scalar". Today the only way to make `var email: EmailAddress` legal inside a schema is
//     to hand-write `_assay(from: inout AssayReader, ...)` — an underscored requirement
//     taking a `~Copyable` reader and threading a path array. No user should write that, and
//     every user who wants a domain type needs it.
//
// The narrower protocol the roadmap suspected is real, and it does not compete: it is the
// REQUIREMENT (`AssayerBacked`), and `Assayer` is the only ergonomic value that can fill it.
//
// TWO LAWS KEEP THE DOORS FROM BECOMING REDUNDANT:
//
//   1. No `Assayer` constructor rebuilds a `@Schema` type's fields. `Assayer.schema(User.self)`
//      exists only as a LEAF that calls the generated body, so a dynamic schema can embed a
//      static one and it is impossible to express a declared struct as a hand-built
//      combinator with subtly different semantics.
//   2. Once a conformance is installed, the type is used through the ordinary door.
//      `var email: EmailAddress` emits the same generated line as any other nested type.
//
// THE LOAD-BEARING CONSEQUENCE OF (2): the macro needs no change at all. `CodeGen.swift`
// already emits `Base._assay(from:into:at:)` for any type token it does not recognise, so
// an `Assayer`-backed type is ALREADY, syntactically, a nested schema type. Zero new
// generated code per field, zero added expansion cost, no movement against the 100 ms gate.
// If making this work required touching the macro, the design would be wrong.
//===----------------------------------------------------------------------===//

public import AssayCore

/// A schema as a value.
///
/// The generic parameter enters only at the last step: `plan` is non-generic and does all
/// the work, `build` turns the result into `T`. See `AssayerPlan` for why.
public struct Assayer<T: Sendable>: Sendable {
    @usableFromInline let plan: AssayerPlan
    @usableFromInline let build: @Sendable (RawValue) -> T?

    @usableFromInline
    init(plan: AssayerPlan, build: @escaping @Sendable (RawValue) -> T?) {
        self.plan = plan
        self.build = build
    }
}

// MARK: - Leaves

extension Assayer where T == String {
    /// A string, optionally validated. `Assayer.string` resolves — verified before this was
    /// written, because the spelling `EXPERIENCE.md` §8 documents depends on Swift inferring
    /// `T` from a constrained static member.
    public static var string: Assayer<String> {
        Assayer(plan: AssayerPlan(.string([]))) { if case .string(let s) = $0 { return s }; return nil }
    }
}

extension Assayer where T == Int64 {
    public static var int: Assayer<Int64> {
        Assayer(plan: AssayerPlan(.int([]))) { if case .int(let i) = $0 { return i }; return nil }
    }
}

extension Assayer where T == Double {
    public static var double: Assayer<Double> {
        Assayer(plan: AssayerPlan(.double([]))) {
            switch $0 {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }
    }
}

extension Assayer where T == Bool {
    public static var bool: Assayer<Bool> {
        Assayer(plan: AssayerPlan(.bool([]))) { if case .bool(let b) = $0 { return b }; return nil }
    }
}

extension Assayer where T == RawValue {
    /// Anything, unvalidated. The dynamic case's leaf and the escape hatch.
    public static var raw: Assayer<RawValue> {
        Assayer(plan: AssayerPlan(.raw)) { $0 }
    }

    /// An object whose fields are named at runtime.
    ///
    /// Fields take `Assayer<RawValue>` rather than `Assayer<U>` deliberately: an object's
    /// output IS a `RawValue`, so a child's `build` would have nowhere to go. Taking
    /// `Assayer<RawValue>` makes the type say that instead of silently discarding a `.map`.
    public static func object(_ fields: [Assayer.Field]) -> Assayer<RawValue> {
        Assayer(plan: AssayerPlan(.object(fields.map {
            AssayerPlan.Field(key: $0.key, plan: $0.value.plan, isOptional: $0.isOptional)
        }))) { $0 }
    }

    /// One field of a runtime-built object.
    public struct Field: Sendable {
        let key: String
        let value: Assayer<RawValue>
        let isOptional: Bool
        public init(_ key: String, _ value: Assayer<RawValue>, optional: Bool = false) {
            self.key = key
            self.value = value
            self.isOptional = optional
        }
    }
}

// MARK: - Combinators

extension Assayer {

    /// Attach rules. Reuses the `Rule` vocabulary the macro path already type-checks, so
    /// `.email` means the same thing here as in `@Validate(.email)` — including the fact
    /// that it is now compiled once rather than per value.
    public func validate(_ rules: Rule...) -> Assayer<T> {
        let node: AssayerPlan.Node
        switch plan.node {
        case .string(let r): node = .string(r + rules)
        case .int(let r): node = .int(r + rules)
        case .double(let r): node = .double(r + rules)
        case .bool(let r): node = .bool(r + rules)
        default: node = plan.node          // rules on a container are a no-op, as in @Validate
        }
        return Assayer(plan: AssayerPlan(node), build: build)
    }

    /// Turn the decoded value into something else. Fails the value if the closure returns nil.
    ///
    /// **A mapped `Assayer` gives up `Validatable`.** `T.validate(_ value:)` runs the
    /// schema's rules against a constructed value, and there is no way back from
    /// `EmailAddress` to the `String` the rules were type-checked against. That exclusion is
    /// deliberate and documented rather than discovered; `@Inverse` is the spelling that
    /// would lift it, and it belongs with `@Wraps`.
    public func map<U: Sendable>(_ f: @escaping @Sendable (T) -> U?) -> Assayer<U> {
        let inner = build
        return Assayer<U>(plan: plan) { raw in inner(raw).flatMap(f) }
    }

    /// `nil` when the value is null.
    public func optional() -> Assayer<T?> {
        let inner = build
        return Assayer<T?>(plan: AssayerPlan(.optional(plan))) { raw in
            if case .null = raw { return .some(nil) }
            return inner(raw).map { .some($0) }
        }
    }

    /// A homogeneous array.
    public static func array(of element: Assayer<T>) -> Assayer<[T]> {
        let inner = element.build
        return Assayer<[T]>(plan: AssayerPlan(.array(element.plan))) { raw in
            guard case .sequence(let xs) = raw else { return nil }
            var out: [T] = []
            out.reserveCapacity(xs.count)
            for x in xs { guard let v = inner(x) else { return nil }; out.append(v) }
            return out
        }
    }

    /// Deferred, for a recursive schema. Recomputed rather than memoised: a lock on the
    /// decode path would cost more than rebuilding a node, and a mutable cache would make
    /// `Assayer` non-`Sendable`, which would in turn make `static let schema` illegal.
    public static func lazy(_ make: @escaping @Sendable () -> Assayer<T>) -> Assayer<T> {
        Assayer(plan: AssayerPlan(.lazy { make().plan })) { raw in make().build(raw) }
    }
}

// `Assayer.schema(User.self)` — a `@Schema` type as a LEAF — is not in this increment.
//
// It is the only route this design would ever offer from an `Assayer` to a declared type,
// and law 1 above says it must call the generated body rather than rebuild its fields. The
// honest reason it is absent: the plan interprets to `RawValue` and `build` converts, so a
// schema leaf either decodes twice (once to report, once to produce) or `build` has to take
// the sink and the path. The second is right and is a signature change worth making
// deliberately rather than at the end of a long change.
//
// Nothing depends on it. The two cases this type exists for — a schema with no declaration,
// and a domain scalar with no object — both work without it, and law 1 holds more strongly
// while there is no route at all than while there is one.

// MARK: - The verbs

extension Assayer {

    /// Decode from a `RawValue` — the shape YAML, XML and the dynamic case share.
    public func diagnose(
        _ raw: RawValue, limits: Limits = .default, sourceName: String = "<value>"
    ) -> Diagnosis<T> {
        var sink = IssueSink(limits: limits)
        guard let out = plan.run(raw, &sink, [], limits), sink.isValid,
              let value = build(out) else {
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes([]), sourceName: sourceName)
        }
        return Diagnosis(value: value, issues: sink.issues, warnings: sink.warnings,
                         truncatedIssues: sink.truncatedIssues,
                         source: SourceBytes([]), sourceName: sourceName)
    }

    /// Decode from JSON bytes.
    public func diagnose(
        json bytes: [UInt8], limits: Limits = .default, sourceName: String = "<input>"
    ) -> Diagnosis<T> {
        var sink = IssueSink(limits: limits)
        guard let v = JSON.Value.decode(bytes, into: &sink, limits: limits), sink.isValid else {
            return Diagnosis(value: nil, issues: sink.issues, warnings: sink.warnings,
                             truncatedIssues: sink.truncatedIssues,
                             source: SourceBytes(bytes), sourceName: sourceName)
        }
        let d = diagnose(RawValue(v), limits: limits, sourceName: sourceName)
        return Diagnosis(value: d.value, issues: sink.issues + d.issues,
                         warnings: sink.warnings + d.warnings,
                         truncatedIssues: d.truncatedIssues,
                         source: SourceBytes(bytes), sourceName: sourceName)
    }

    public func parse(
        json bytes: [UInt8], limits: Limits = .default, sourceName: String = "<input>"
    ) throws -> T {
        try diagnose(json: bytes, limits: limits, sourceName: sourceName).get()
    }

    public func parse(
        _ raw: RawValue, limits: Limits = .default, sourceName: String = "<value>"
    ) throws -> T {
        try diagnose(raw, limits: limits, sourceName: sourceName).get()
    }
}
