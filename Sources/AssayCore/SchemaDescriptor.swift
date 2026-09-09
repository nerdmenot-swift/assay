// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The machine-readable description of a schema — `EXPERIENCE.md` §14, `ROADMAP.md` §11.
//
//     let doc = Article.jsonSchema(for: .input)      // JSON Schema 2020-12
//
// A DESCRIPTOR, NOT DOCUMENT TEXT, and that choice is the whole design of this feature.
//
// The obvious implementation emits the JSON Schema string from the macro. It is also the wrong
// one, for a reason `docs/COMPILE-TIME.md` measured rather than guessed: cost tracks generated
// body size, and emitting text would put the entire rule-to-keyword mapping — every `.email`
// becomes `"format": "email"`, every `.min` becomes `minLength` or `minimum` depending on the
// field's type — into *every user's expansion*, once per type. Rule 1 of the hard constraints
// exists because a 256-element array literal cost 16% of expansion time; a schema renderer per
// type is far larger than that.
//
// So the macro emits a small VALUE naming what it already knows, and the rendering lives here,
// once, in `AssayCore`. The generated descriptor also **reuses the `__assayRules_i_j` statics
// the validator already needs**, so a rule-carrying field costs the descriptor nothing extra:
// the array is already there, and the descriptor points at it.
//
// NESTED TYPES USE THE METATYPE TRICK, which is the only sound route. A macro reads the token
// `Author` and cannot know whether `Author` is a `@Schema` type, a typealias, or a struct that
// happens to be named that. Holding `Author.self` as an `any SchemaDescribing.Type` makes the
// TYPE CHECKER verify the conformance the macro cannot see — the same device `ColumnDecodable`
// already uses. A non-describing nested type is then a compile error at the use site naming
// the actual problem, rather than a schema that silently describes it as `{}`.
//
// `.input` VS `.output`, which is not decoration. They differ exactly when `@Transform` is
// involved: the wire type is what a producer must send, the property type is what a consumer
// receives. Zod shipped a single-document version first and added the distinction in v4 after
// finding it wrong; describing a transformed field with one shape is describing one of the two
// audiences incorrectly.
//
// WHAT THIS DOES NOT DO. It does not validate the emitted document against the JSON Schema
// meta-schema — that would need a JSON Schema validator, which is a different product. The
// tests check the emitted keywords directly.
//===----------------------------------------------------------------------===//

/// A type that can describe its own shape. Emitted by `@Schema(describes: true)`.
///
/// Opt-in for the same reason `encodes:` is: generated body size dominates expansion cost, and
/// a type that never emits a schema document must not carry the descriptor for one.
public protocol SchemaDescribing: Sendable {
    nonisolated static var _assaySchemaDescriptor: SchemaDescriptor { get }
}

/// Which side of a transform to describe. `EXPERIENCE.md` §14.
public enum SchemaFace: Sendable, Equatable {
    /// What a producer must send — the wire type. `@Transform`'s input.
    case input
    /// What a consumer receives — the declared property type. `@Transform`'s output.
    case output
}

/// One schema, as the macro knows it.
public struct SchemaDescriptor: Sendable {
    public var typeName: String
    public var fields: [FieldDescriptor]
    /// `@Schema(unknownKeys:)`. `.reject` is the only policy that means
    /// `additionalProperties: false` — `.warn` and `.collect` both still *accept* the
    /// document, and a schema that said otherwise would refuse documents this type reads.
    public var rejectsUnknownKeys: Bool

    public init(typeName: String, fields: [FieldDescriptor], rejectsUnknownKeys: Bool = false) {
        self.typeName = typeName
        self.fields = fields
        self.rejectsUnknownKeys = rejectsUnknownKeys
    }
}

public struct FieldDescriptor: Sendable {
    public var wireKey: String
    public var aliases: [String]
    public var propertyName: String
    /// The declared property's shape — what `.output` describes.
    public var type: TypeDescriptor
    /// `@Transform`'s wire type, when there is one. What `.input` describes instead.
    public var wireType: TypeDescriptor?
    /// Required in the JSON Schema sense: no default, not optional, no `@Fallback`.
    public var isRequired: Bool
    /// The rules, pointing at the array the validator already holds.
    public var rules: [Rule]

    public init(wireKey: String, aliases: [String] = [], propertyName: String,
                type: TypeDescriptor, wireType: TypeDescriptor? = nil,
                isRequired: Bool, rules: [Rule] = []) {
        self.wireKey = wireKey
        self.aliases = aliases
        self.propertyName = propertyName
        self.type = type
        self.wireType = wireType
        self.isRequired = isRequired
        self.rules = rules
    }
}

/// A field's shape. `indirect` for the collection cases.
public indirect enum TypeDescriptor: Sendable {
    case string
    case integer
    case number
    case boolean
    /// A `Date`. Rendered as `"type": "string", "format": "date-time"` — which is true of the
    /// ISO-8601 formats and a lie about `.unixSeconds`, so `dateIsNumeric` says which.
    case date(numeric: Bool)
    case array(TypeDescriptor)
    case dictionary(TypeDescriptor)
    case optional(TypeDescriptor)
    /// A nested `@Schema(describes: true)` type. The metatype is what makes the type checker
    /// verify a conformance the macro could not see.
    case nested(any SchemaDescribing.Type)
    /// A type token the macro did not recognise and could not constrain. Rendered as `{}` —
    /// "any value" — because describing it as anything narrower would be a guess, and a JSON
    /// Schema that rejects valid documents is worse than one that accepts too much.
    case opaque(String)
}
