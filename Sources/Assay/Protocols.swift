// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The conformances `@Schema` emits, and nothing else. Every protocol here is a seam the
// macro writes an implementation for; the entry points that call them are in Entry.swift,
// ContextEntry.swift and AsyncEntry.swift.
//
// Split out of Assay.swift on 2026-09-10, which had grown to 747 lines of protocols,
// attached-macro declarations, option types and the async entry points interleaved.
//===----------------------------------------------------------------------===//

public import AssayCore


/// The capability. A marker protocol refining `Sendable`, which costs *exactly* zero at
/// runtime — no witness table, no calling-convention change, no generic requirement
/// recorded — and buys two things:
///
///   * conforming types are excluded from `-default-isolation MainActor` inference, so a
///     user who turns that on does not find every schema type silently main-actor-bound;
///   * `Sendable` is checked, so a `Diagnosis` can cross an actor boundary.
/// A type that can write itself as JSON — emitted by `@Schema(encodes: true)`.
///
/// Opt-in because generated body size is what dominates expansion cost, so a type that
/// only decodes must not pay for an encoder it never calls (`docs/COMPILE-TIME.md`).
public protocol JSONEncodableSchema: Assayable {
    nonisolated func _assayEncode(
        into w: inout JSONWriter,
        into sink: inout IssueSink,
        at path: [PathComponent]
    )
}


/// A type that can project itself into `RawValue` — the seam every non-JSON encoder
/// writes through, emitted by `@Schema(encodes: true)` when `formats:` includes a
/// RawValue-based format.
///
/// Mirrors the decode architecture: YAML and XML decode by projecting *to* `RawValue`, so
/// they encode by projecting *from* it. The macro therefore never learns about YAML, and
/// a new format needs no macro change.
public protocol RawEncodableSchema: Assayable {
    nonisolated func _assayEncodeRaw(
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> RawValue
}


/// A type that hands its fields to a `RowSink` in manifest order — emitted by
/// `@Schema(encodes: true, sources: true)`. The write side of the row path: no tree, one
/// call per field, column names from `_assayManifest.keys`. `docs/ROWS.md` §D.
public protocol RowEncodableSchema: Assayable {
    nonisolated func _assayEncodeRow<S: RowSink & ~Copyable>(into sink: inout S)
}

extension RowEncodableSchema {
    /// Write this value's fields to `sink`, one call per field in manifest order.
    @inlinable
    public func encodeRow<S: RowSink & ~Copyable>(into sink: inout S) {
        _assayEncodeRow(into: &sink)
    }
}

/// A type that can decode a batch from a column-first source — Parquet, Arrow, a column
/// store — emitted by `@Schema(sources: true)`. See `docs/KEYED-SOURCE.md`.
public protocol SourceDecodable: Assayable {
    /// Every field this type declares, in order, resolved at compile time. A source binds
    /// against this ONCE per stream rather than resolving keys per record.
    nonisolated static var _assayManifest: FieldManifest { get }

    /// Decode a whole batch from a COLUMN-first source, one sequential pass per column.
    nonisolated static func _assayBatch<C: ColumnarSource & ~Copyable>(
        from source: borrowing C,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> [Self]
}


/// A type that can write itself as XML — emitted by `@Schema(encodes: true)` when
/// `formats:` includes `.xml`.
///
/// XML does not go through the `RawValue` seam that YAML uses, because placement
/// (`@XML(.attribute)`) is not expressible in `RawValue` and never will be — it is the
/// narrow intersection of the three formats. Placement is compile-time knowledge, so the
/// macro bakes it into the emitted calls. See `XMLWriter`.
/// A type that declared `@XML(root:)` and therefore wants its root element checked.
///
/// Separate from `RawDecodable` deliberately. Widening that protocol would put an
/// XML-shaped requirement on every `formats: [.yaml]` type, which is a format a YAML user
/// has no business knowing about. Conformance is emitted only when the attribute is present,
/// so an unannotated type does not participate and nothing checks its root.
public protocol XMLRooted {
    nonisolated static var _assayXMLExpectedRoot: String? { get }
}


public protocol XMLEncodableSchema: Assayable {
    nonisolated func _assayEncodeXML(
        into w: inout XMLWriter,
        into sink: inout IssueSink,
        at path: [PathComponent],
        element name: String
    )
    /// The default root element name — the type's own name.
    nonisolated static var _assayXMLRoot: String { get }
}


/// The root of the contextual protocols, declaring `AssayContext` exactly once.
///
/// Four protocols each declaring their own `associatedtype AssayContext` compiles, and is
/// wrong: a type conforming to two of them has two, and a constrained extension spanning
/// both cannot say they are the same one without a same-type requirement that then has no
/// unambiguous spelling. Declaring it here removes the question. The generated body also
/// emits `typealias AssayContext = ...` explicitly rather than relying on inference across
/// the refinement, which stops working as soon as a second conformance is in play.
public protocol ContextualAssayable: Assayable {
    /// What `parse(json:context:)` takes. Unconstrained — see the `@Schema(context:)`
    /// overload's documentation for why not even `Sendable`.
    associatedtype AssayContext
}


/// A type whose decode and checks need something from outside — a database handle, a
/// feature flag, the current tenant. `EXPERIENCE.md` §10, `@Schema(context: AppContext.self)`.
///
/// A **separate protocol** rather than an extra parameter on `JSONAssayable`, and that is
/// what makes the guarantee hold: declaring a context makes `parse(json:context:)` the
/// *only* signature, because the context-free entry points are constrained on
/// `JSONAssayable` and this type does not conform to it. You cannot forget to pass it.
///
/// `AppContext` is a real type in the check — no casting, no optionals, no `userInfo`
/// dictionary.
///
/// **Why this is no longer deferred.** `ROADMAP.md` §8 held it back for having no users, and
/// an API shaped for imagined users is shaped wrong. That argument aged: `@Check` shipped, so
/// a cross-field rule needing a tenant ID has exactly one option today — a global or a
/// `static var`, in a library whose types are `Sendable` and whose whole posture is against
/// ambient state. And `@AsyncCheck`'s own motivating example in §10 (`ctx.users.exists(email:)`)
/// cannot be written at all without this. That is a hole a shipped feature created, not an
/// imagined user.
///
/// The type-erased *runtime* context `EXPERIENCE.md` §10 mentions for `Assayer<T>` is still
/// not built, and deliberately: it would be designing for an imaginary user twice over.
public protocol ContextualJSONAssayable: ContextualAssayable {
    nonisolated static func _assay(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent],
        context: AssayContext
    ) -> Self?
}


/// The `RawValue` counterpart, so a contextual type decodes from YAML and XML too.
public protocol ContextualRawDecodable: ContextualAssayable {
    nonisolated static func _assay(
        from raw: RawValue,
        into sink: inout IssueSink,
        at path: [PathComponent],
        context: AssayContext
    ) -> Self?
}


// A CONTEXTUAL TYPE CONTAINING A PLAIN NESTED ONE.
//
// The macro emits `Nested._assay(..., context: ctx)` unconditionally, because it is
// syntactic and cannot know whether `Nested` declared a context. A plain type has no such
// member, so these defaulted overloads absorb the argument and forward to the context-free
// requirement.
//
// This works only because the emitted call names the nested type CONCRETELY, so overload
// resolution sees the type's own `_assay(from:into:at:context:)` when it has one and falls
// back here when it does not. Probed before any of this was written, because the same shape
// silently failed for `@XML(root:)`: overloads resolve from the STATIC type, and inside a
// generic context the fallback would win for every type including the ones that opted in.
//
// The converse — a *contextual* type nested inside a plain one — is a compile error with a
// poor message ("does not conform to JSONAssayable"). The macro cannot detect it: it sees a
// token. Documented in `EXPERIENCE.md` §10 beside the `@Check`-in-an-extension trap, which
// is the same class of limitation.
extension JSONAssayable {
    @inlinable
    public nonisolated static func _assay<C>(
        from reader: inout AssayReader, into sink: inout IssueSink,
        at path: [PathComponent], context: C
    ) -> Self? {
        _assay(from: &reader, into: &sink, at: path)
    }
}


extension RawDecodable {
    @inlinable
    public nonisolated static func _assay<C>(
        from raw: RawValue, into sink: inout IssueSink,
        at path: [PathComponent], context: C
    ) -> Self? {
        _assay(from: raw, into: &sink, at: path)
    }
}


/// A type with a JSON decode body — emitted when `@Schema(formats:)` includes `.json`,
/// which is the default.
///
/// The requirement is concrete, monomorphic, and emitted into the *user's* module: there
/// is no generic parameter, so there is nothing for cross-module specialization to fail
/// at. That is the single most important structural reason a macro decoder can be fast.
public protocol JSONAssayable: Assayable {
    nonisolated static func _assay(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self?
}


/// Conformance generated when a schema declares any `@AsyncCheck`.
public protocol AsyncCheckAssayable: Assayable {
    static func _assayAsyncChecks(_ value: Self, at path: [PathComponent]) async -> [Issue]
}


/// The contextual counterpart. `@AsyncCheck`'s own motivating example in `EXPERIENCE.md`
/// §10 — `await ctx.users.exists(email:)` — cannot be written without this.
public protocol ContextualAsyncCheckAssayable: ContextualAssayable {
    static func _assayAsyncChecks(
        _ value: Self, at path: [PathComponent], context: AssayContext) async -> [Issue]
}

// MARK: - The nominal-type assertion
//
// A field whose type is a name the macro has never heard of — `var n: N` — is emitted as
// `N._assay(from:into:at:)` and the macro trusts the type checker to complain if `N` has
// no such member. It does, with "type 'N' has no member '_assay'": an underscored internal,
// at a line inside the expansion, and nothing about what to do. That was the single most
// common error in a 54-declaration newcomer probe battery (2026-09-10).
//
// So the body also calls one of these, once per distinct nested type, before any field is
// read. They are empty and `@inlinable`, so they are specialised away and cost nothing;
// what they buy is the type checker's OTHER diagnostic — "global function
// '_assayRequireJSON' requires that 'N' conform to 'JSONAssayable'" — which names the
// protocol to adopt. Hard constraint 6 is untouched: the decode call itself is still the
// concrete, monomorphic one.

@inlinable @inline(__always)
@_documentation(visibility: internal)
public func _assayRequireJSON<T: JSONAssayable>(_: T.Type) {}

@inlinable @inline(__always)
@_documentation(visibility: internal)
public func _assayRequireRaw<T: RawDecodable>(_: T.Type) {}
