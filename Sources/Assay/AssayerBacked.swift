// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The narrow protocol ROADMAP §7 suspected might cover the domain-type case on its own.
// It does — and it does not compete with `Assayer<T>`, it is the requirement `Assayer`
// fills. Ship both; they are one feature.
//
// ```swift
// struct EmailAddress { var raw: String }
//
// extension EmailAddress: AssayerBacked {
//     static let schema = Assayer.string.validate(.email).map(EmailAddress.init(raw:))
// }
//
// @Schema struct User { var email: EmailAddress }   // just works
// ```
//
// A CORRECTION TO EXPERIENCE.md §8 AND §19, which both write `struct EmailAddress:
// Assayable { static let schema = ... }`. That cannot work: `Assayable` is a marker protocol
// with no requirements, so nothing would ever call `schema`. The spelling has to name a
// protocol that actually requires it.
//
// THE CHECKPOINT THIS FILE EXISTS TO PROVE: no macro change. `CodeGen.swift` already emits
// `Base._assay(from: &reader, into: &sink, at: path + [.key(...)])` for any type token it
// does not recognise, so a conforming type is ALREADY, syntactically, a nested schema type.
// The two default implementations below are what that emitted call lands on.
//
// `@inlinable` on them is legal and load-bearing. SE-0193's restriction bites GENERATED
// bodies referencing a user's internal memberwise init; these are generic over `Self`, live
// in a source package, are called from the user's module, and reference only public API —
// which is exactly the case CLAUDE.md's constraint 5 says to mark. The bodies stay thin
// (fetch the schema, call the non-generic interpreter) so the caller stays inside the
// escape-analysis complexity budget.
//===----------------------------------------------------------------------===//

public import AssayCore

/// A type whose decoding is described by an `Assayer` value rather than by `@Schema`.
///
/// Conform, and the type is a legal field of any `@Schema` type — from JSON, YAML and XML,
/// with no further work, because both tree paths route through the same plan.
public protocol AssayerBacked: JSONAssayable, RawDecodable {
    /// The schema. A `static let` is the intended spelling, which is why `Assayer` is
    /// `Sendable` and owns no mutable state.
    nonisolated static var assaySchema: Assayer<Self> { get }
}

extension AssayerBacked {

    /// The `RawValue` path: YAML, XML, and any nested use inside another schema.
    @inlinable
    public nonisolated static func _assay(
        from raw: RawValue, into sink: inout IssueSink, at path: [PathComponent]
    ) -> Self? {
        let s = Self.assaySchema
        guard let out = s.plan.run(raw, &sink, path, .default) else { return nil }
        guard let value = s.build(out) else {
            // The plan accepted the shape and the rules passed, but the caller's own
            // conversion refused it. That is a real outcome — `map` is failable precisely so
            // a type can say "this is a String I cannot represent" — and it has to be
            // reported rather than swallowed into a nil the caller cannot explain.
            sink.add(Issue(code: .custom("assayer_conversion_failed"), path: path,
                           received: nil))
            return nil
        }
        return value
    }

    /// The bytes path.
    ///
    /// Collects the value first and then interprets, rather than driving the reader from the
    /// plan. That is a deliberate first increment: the fast shape reads scalar leaves
    /// straight off the reader with no tree at all, and it is worth building against a
    /// measurement rather than a prediction. `docs/ASSAYER.md` records what is owed.
    @inlinable
    public nonisolated static func _assay(
        from reader: inout AssayReader, into sink: inout IssueSink, at path: [PathComponent]
    ) -> Self? {
        guard let raw = RawValue._collectJSON(from: &reader, into: &sink, at: path) else {
            return nil
        }
        return _assay(from: raw, into: &sink, at: path)
    }
}
