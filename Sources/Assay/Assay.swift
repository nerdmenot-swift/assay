//===----------------------------------------------------------------------===//
// The public surface.
//
// "Assay is not a validation library that also decodes. It is the decoder that tells you
// what went wrong." Zero-rule @Schema is a first-class mode, not an on-ramp.
//===----------------------------------------------------------------------===//

@_exported import AssayCore

/// The capability. A marker protocol refining `Sendable`, which costs *exactly* zero at
/// runtime — no witness table, no calling-convention change, no generic requirement
/// recorded — and buys two things:
///
///   * conforming types are excluded from `-default-isolation MainActor` inference, so a
///     user who turns that on does not find every schema type silently main-actor-bound;
///   * `Sendable` is checked, so a `Diagnosis` can cross an actor boundary.
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

/// Attach to a struct to make it decodable.
///
///     @Schema(keys: .snakeCase)
///     struct Article {
///         var title: String
///         var readingMinutes: Int
///         var tags: [String] = []
///     }
///
/// `keys:` converts at *compile* time from the declared identifier, so `avatarURL`
/// round-trips through `avatar_url` exactly — unlike `.convertFromSnakeCase`, which runs
/// on the wire key at runtime and is lossy on every acronym.
// `Assayable` is deliberately absent from this list: both `JSONAssayable` and
// `RawDecodable` refine it, so declaring it here would promise a conformance the expansion
// does not itself emit.
@attached(extension, conformances: JSONAssayable, RawDecodable, names: arbitrary)
public macro Schema(
    keys: KeyNamingStyle = .camelCase,
    unknownKeys: UnknownKeys = .ignore,
    coerceScalars: Bool = false,
    formats: SchemaFormats = .json
) = #externalMacro(module: "AssayMacros", type: "SchemaMacro")

/// Which formats a schema can decode from.
///
/// **Opt-in, defaulting to `.json`**, because generated code is not free. `docs/COMPILE-TIME.md`
/// measures the YAML/XML decode body at ~34 ms per type — about 41% of total expansion
/// cost — and emitting it for a type that only ever sees JSON would make every JSON user
/// pay for a capability they do not use. `EXPERIENCE.md` §12's "JSON users never pay for
/// XML" is a linking claim; this is what makes it a *compile-time* claim too.
///
///     @Schema                                   // JSON only
///     @Schema(formats: [.json, .yaml])          // both
///     @Schema(formats: .all)                    // JSON, YAML and XML
///     @Schema(formats: [.yaml])                 // YAML only — no JSON body emitted
///
/// Calling `parse(yaml:)` on a type that did not opt into `.yaml` is a **compile** error,
/// not a runtime one, because the conformance that entry point requires is simply absent.
public struct SchemaFormats: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Direct-to-struct byte decoding. The fast path.
    public static let json = SchemaFormats(rawValue: 1 << 0)
    /// Via `YAML.Node` and the `RawValue` projection.
    public static let yaml = SchemaFormats(rawValue: 1 << 1)
    /// Via `XML.Document` and the `RawValue` projection.
    public static let xml = SchemaFormats(rawValue: 1 << 2)

    public static let all: SchemaFormats = [.json, .yaml, .xml]
}

/// What to do with a key the schema did not declare.
///
/// `.ignore` is the default and the `Codable` behaviour. It is also the only one that
/// stays allocation-free: the other three must materialise the unknown key as a `String`,
/// because an unknown key by definition has no compile-time literal it was matched against.
public enum UnknownKeys: Sendable {
    /// Skip the value structurally without decoding it.
    case ignore
    /// A warning per key, decoding proceeds. Visible only through `diagnose`.
    case warn
    /// An issue per key.
    case reject
    /// Route the key and value to the `@Extras` property.
    case collect
}

/// How declared identifiers become wire keys.
public enum KeyNamingStyle: Sendable {
    case camelCase
    case snakeCase
    case kebabCase
    case pascalCase
    case screamingSnakeCase
}

/// Override the wire key for one property.
@attached(peer)
public macro Key(_ name: String, or aliases: String...) =
    #externalMacro(module: "AssayMacros", type: "KeyMacro")

/// Exclude a stored property the macro would otherwise decode.
@attached(peer)
public macro Ignore() = #externalMacro(module: "AssayMacros", type: "IgnoreMacro")

/// The sink for keys the schema did not declare, used with
/// `@Schema(unknownKeys: .collect)`.
///
///     @Schema(unknownKeys: .collect)
///     struct Response {
///         var id: String
///         @Extras var rest: [String: RawValue]
///     }
///
/// Explicit, because the macro cannot guess which dictionary is the sink.
///
/// The value type decides the fidelity/portability trade (see docs/VALUE-MODELS.md):
/// `RawValue` is format-neutral and lossy, so the same struct parses from JSON, YAML or
/// XML; `JSON.Value` is full fidelity and JSON-only. Declaring a type the format cannot
/// produce is a **compile** error rather than a runtime surprise, because the collection
/// is dispatched through a per-format protocol.
@attached(peer)
public macro Extras() = #externalMacro(module: "AssayMacros", type: "ExtrasMacro")

/// Declare what "valid" means for one field.
///
///     @Validate(.min(3), .max(20), .regex(#"^[a-z0-9_]+$"#))  var username: String
///     @Validate(.email)                                        var email: String
///     @Validate(.min(12), "must be at least 12 characters")    var password: String
///     @Validate(.range(13...120))                              var age: Int
///     @Validate(.count(1...10), .each(.email))                 var recipients: [String]
///
/// The bare string literal is a rule — one that carries no check and overrides the
/// message for every other rule in the same attribute. (A parameter after a variadic
/// must be labelled in Swift, so `message:` could never keep this shape; the literal
/// can.) Per-rule messages use `or:`: `.min(3, or: "too short")`.
///
/// `Rule` is deliberately non-generic, so the type system does not stop
/// `@Validate(.email) var age: Int` — the macro does, at expansion, with a message
/// naming the rule and the type. Rules compose without any machinery:
///
///     extension Rule { static let slug = Rule.all(.min(3), .regex("^[a-z-]+$")) }
///     @Validate(.slug) var slug: String
///
/// Optionals validate the wrapped value; nil skips the rules. Defaults are validated.
@attached(peer)
public macro Validate(_ rules: Rule...) =
    #externalMacro(module: "AssayMacros", type: "ValidateMacro")

/// Allow a scalar of the wrong type through the documented conversion rules.
///
///     @Coerce var port: Int          // "8080" -> 8080
///     var host: String               // 8080 stays an error
///
/// Never implicit and never global: a struct means the same thing regardless of what is
/// configured elsewhere. The rules are deliberately boring — `"8080"` becomes 8080,
/// `"8080.5"` is an **error** rather than a truncation, `1.0` converts and `1.5` does not,
/// and nothing consults a locale, which is what makes it behave identically on Linux and
/// on a Mac.
///
/// `@Schema(coerceScalars: true)` applies the same thing to every field, which is what a
/// format with no types at all needs — XML has no numbers and no booleans, so every leaf
/// arrives as text.
@attached(peer)
public macro Coerce() = #externalMacro(module: "AssayMacros", type: "CoerceMacro")
