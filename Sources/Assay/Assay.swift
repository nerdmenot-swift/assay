// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

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
@attached(extension, conformances: JSONAssayable, RawDecodable, AsyncCheckAssayable, JSONEncodableSchema, names: arbitrary)
public macro Schema(
    keys: KeyNamingStyle = .camelCase,
    unknownKeys: UnknownKeys = .ignore,
    coerceScalars: Bool = false,
    formats: SchemaFormats = .json,
    encodes: Bool = false
) = #externalMacro(module: "AssayMacros", type: "SchemaMacro")

/// The encode direction of a `@Transform`. `docs/ENCODING.md` question 3.
///
///     @Transform({ (a: [String]) in Set(a) })
///     @Inverse({ (s: Set<String>) in Array(s) })
///     var tags: Set<String>
///
/// A transform with no inverse is *lossy* — that is arithmetic, not a design failure — so
/// a type carrying one cannot be encoded, and `@Schema(encodes: true)` says so at
/// expansion rather than at runtime.
@attached(peer)
public macro Inverse<Value, Wire>(_ inverse: (Value) -> Wire) =
    #externalMacro(module: "AssayMacros", type: "InverseMacro")

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

/// How a `Date` property reads its wire value. Without this attribute, `Date` fields
/// expect ISO-8601.
///
///     var createdAt: Date                                // ISO 8601, the default
///     @DateFormat(.unixSeconds)          var ts: Date
///     @DateFormat(.unixMillis)           var ms: Date
///     @DateFormat(.rfc9110)              var expires: Date   // HTTP dates, all 3 forms
///     @DateFormat(.pattern("yyyy-MM-dd")) var day: Date
///
/// **Several formats are a candidate chain**, tried in order — for the API that emits
/// ISO-8601 but has one legacy producer still sending epoch millis:
///
///     @DateFormat(.iso8601, .unixMillis) var updated: Date
///
/// The first match wins. A match on any format after the first adds a *warning* naming
/// which one matched — the same contract as `@Key(_:or:)`, and for the same reason:
/// silent tolerance is how a payload drifts formats without anyone noticing. A total
/// miss reports one issue naming every format tried, the reason the primary one failed,
/// and the byte where it failed — with the caret inside the value.
///
/// `.pattern` is not `DateFormatter` (EXPERIENCE.md §11): the fields are exactly
/// `yyyy MM dd HH mm ss SSS Z` plus literals (letters quoted UTS-35 style: `'T'`), the
/// pattern is CHECKED AT COMPILE TIME with a purpose-written diagnostic, a pattern with
/// no `Z` reads as UTC on every platform, and nothing consults a locale or ICU.
/// Timestamps out at ±2^53 seconds are rejected, non-finite ones too. `:60` leap
/// seconds are accepted and carry into the next minute (the POSIX reading).
@attached(peer)
public macro DateFormat(_ formats: AssayCore.DateFormat...) =
    #externalMacro(module: "AssayMacros", type: "DateFormatMacro")

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

/// A validation function with real types, breakpoints and its own tests.
///
/// Field form — the issue lands on the field, with its path and span:
///
///     @Check(\Signup.workEmail)
///     static func companyDomain(_ email: String) -> String? {
///         email.hasSuffix("@acme.com") ? nil : "must be a company address"
///     }
///
/// Cross-field form — some things are only wrong in combination:
///
///     @Check
///     static func endAfterStart(_ r: DateRange, _ issues: inout Issues<DateRange>) {
///         if r.end < r.start { issues.add("must be on or after start", at: \.end) }
///     }
///
/// **A `@Check` in an extension is a compile error, not a silent no-op.** An attached
/// macro only receives the members declared in the type's own body — that is a hard limit
/// of how macros receive input — so the check would never run. The attribute detects the
/// placement and says so.
@attached(peer)
public macro Check() = #externalMacro(module: "AssayMacros", type: "CheckMacro")

@attached(peer)
public macro Check<Root, Value>(_ keyPath: KeyPath<Root, Value>) =
    #externalMacro(module: "AssayMacros", type: "CheckMacro")

/// An asynchronous check — a database lookup, a network round trip.
///
/// A type with any `@AsyncCheck` gets an `async` `parse`/`diagnose`; a type without one
/// does not — decided by counting attributes at compile time, so there is no `await` on
/// schemas that never need it. All synchronous work runs first and collects everything;
/// async checks run only if the sync pass was clean (spending a round trip to ask about a
/// value you already know is invalid is waste), and then all of them run concurrently.
@attached(peer)
public macro AsyncCheck() = #externalMacro(module: "AssayMacros", type: "CheckMacro")

/// Normalise a string before its rules run: `@Preprocess(.trim, .lowercase)`.
/// Runs on the wire value, before validation — the other side of `@Transform`.
@attached(peer)
public macro Preprocess(_ ops: PreprocessOp...) =
    #externalMacro(module: "AssayMacros", type: "PreprocessMacro")

/// Change the type after validation. The closure's parameter annotation names the wire
/// type the value arrives as; the declared property type is what it becomes:
///
///     @Transform({ (a: [String]) in Set(a) })
///     var tags: Set<String>
///
/// The parameter type is required — it is what the macro decodes by. Runs last, after
/// every rule and check, per the fixed ordering in EXPERIENCE.md §11.
@attached(peer)
public macro Transform<In, Out>(_ transform: (In) -> Out) =
    #externalMacro(module: "AssayMacros", type: "TransformMacro")

/// Salvage: on absence OR any issue at this field, assign this value and record a
/// warning. The fallback value is trusted without re-validation — silently swallowing
/// bad data is the point, and the warning (visible through `diagnose`, discarded by
/// `parse`) is how you find out it happened.
@attached(peer)
public macro Fallback<T>(_ value: T) =
    #externalMacro(module: "AssayMacros", type: "FallbackMacro")

// MARK: - Async checks

/// Conformance generated when a schema declares any `@AsyncCheck`.
public protocol AsyncCheckAssayable: Assayable {
    static func _assayAsyncChecks(_ value: Self, at path: [PathComponent]) async -> [Issue]
}

extension JSONAssayable where Self: AsyncCheckAssayable {

    /// The async verb pair. Sync first, collecting everything; async checks only on a
    /// clean sync pass, concurrently.
    public static func parse(
        json bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async throws -> Self {
        try await diagnose(json: bytes, limits: limits, sourceName: sourceName).get()
    }

    public static func parse(
        json text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async throws -> Self {
        try await parse(json: Array(text.utf8), limits: limits, sourceName: sourceName)
    }

    public static func diagnose(
        json bytes: [UInt8],
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async -> Diagnosis<Self> {
        // The synchronous pass — the decode itself stays synchronous, in the swifterror
        // register, exactly as PERFORMANCE.md §3.2 requires. Only the checks await.
        // The non-async function type pins overload resolution to the sync diagnose;
        // without it, an async context prefers this very function and recurses.
        let syncDiagnose: ([UInt8], Limits, String) -> Diagnosis<Self> =
            Self.diagnose(json:limits:sourceName:)
        let d = syncDiagnose(bytes, limits, sourceName)
        guard let value = d.value, d.isValid else { return d }

        let asyncIssues = await Self._assayAsyncChecks(value, at: [])
        guard !asyncIssues.isEmpty else { return d }
        return Diagnosis(value: nil,
                         issues: d.issues + asyncIssues,
                         warnings: d.warnings,
                         truncatedIssues: d.truncatedIssues,
                         source: d.source, sourceName: d.sourceName)
    }

    public static func diagnose(
        json text: String,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async -> Diagnosis<Self> {
        await diagnose(json: Array(text.utf8), limits: limits, sourceName: sourceName)
    }
}
