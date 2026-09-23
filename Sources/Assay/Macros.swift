// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Every attached macro, with its documentation. The implementations live in the
// AssayMacros target; this file is the declared surface a user reads.
//
// Split out of Assay.swift on 2026-09-10.
//===----------------------------------------------------------------------===//

public import AssayCore

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
@attached(
    extension, conformances: JSONAssayable, RawDecodable, Validatable, AsyncCheckAssayable,
    JSONEncodableSchema, RawEncodableSchema, XMLEncodableSchema, XMLRooted, ContextualJSONAssayable,
    ContextualRawDecodable, ContextualValidatable, ContextualAsyncCheckAssayable, SchemaDescribing,
    names: arbitrary)
public macro Schema(
    keys: KeyNamingStyle = .camelCase,
    unknownKeys: UnknownKeys = .ignore,
    coerceScalars: Bool = false,
    formats: SchemaFormats = .json,
    encodes: Bool = false,
    describes: Bool = false,
    discriminator: Discriminator? = nil
) = #externalMacro(module: "AssayMacros", type: "SchemaMacro")

/// `@Schema(context: AppContext.self)` — the contextual form. `EXPERIENCE.md` §10.
///
/// An OVERLOAD rather than a defaulted parameter on the declaration above, and the reason is
/// blast radius: `context:` needs a generic parameter to accept an arbitrary metatype, and
/// adding one to the existing declaration changes how every `@Schema` in every project
/// type-checks its arguments. This way a type that declares no context resolves to the exact
/// declaration it always did.
///
/// `C` is unconstrained. Not even `Sendable`: `parse` is synchronous and the context is
/// passed by value to statics on the same thread, so requiring it would refuse a perfectly
/// good `NSManagedObjectContext`-shaped handle for a concurrency property nothing here
/// needs. The `async` door is the one place it crosses an isolation boundary, and Swift's
/// own `Sendable` checking reports that at the call site, where it is legible.
@attached(
    extension, conformances: JSONAssayable, RawDecodable, Validatable,
    AsyncCheckAssayable, JSONEncodableSchema, RawEncodableSchema,
    XMLEncodableSchema, XMLRooted, ContextualJSONAssayable,
    ContextualRawDecodable, ContextualValidatable, ContextualAsyncCheckAssayable,
    SchemaDescribing, names: arbitrary)
public macro Schema<C>(
    context: C.Type,
    keys: KeyNamingStyle = .camelCase,
    unknownKeys: UnknownKeys = .ignore,
    coerceScalars: Bool = false,
    formats: SchemaFormats = .json,
    encodes: Bool = false,
    describes: Bool = false,
    discriminator: Discriminator? = nil
) = #externalMacro(module: "AssayMacros", type: "SchemaMacro")

/// The forward-compatibility catch-all case of an open enum. `docs/ENCODING.md` q2.
///
///     @Schema enum Status {
///         case active, suspended
///         @Unknown case other(String)          // a v2 server's new variant
///     }
///
/// A **closed** enum needs no macro: `enum P: String, JSONAssayable { … }` already
/// decodes and reports the case list on a bad value. `@Schema` on an enum exists only for
/// this, and says so if the `@Unknown` case is missing.
///
/// **Encoding an unrecognised value is refused by default.** Writing it back round-trips
/// faithfully — and lets an arbitrary attacker-supplied value pass through a type that
/// reads, at every use site, as a closed set. `@Unknown(roundTrips: true)` opts in, the
/// same shape as `accepting:` being required with no default on content negotiation: the
/// dangerous capability is real, it is narrower than what people reach for, and it must
/// not arrive unasked.
@attached(peer)
public macro Unknown(roundTrips: Bool = false) =
    #externalMacro(module: "AssayMacros", type: "UnknownMacro")

/// Read a nested type's keys from THIS level. `EXPERIENCE.md` §4.
///
/// ```swift
/// @Schema
/// struct Response {
///     struct Pagination { var page: Int; @Key("per_page") var perPage: Int }
///     @Inline var page: Pagination
///     var items: [Item]
/// }
/// ```
///
/// serde's `flatten`, except that the keys are known at compile time — so unknown-key
/// handling works correctly through the inline, which serde's runtime version cannot do,
/// and the runtime cost is zero: one dispatch table, one presence mask, one pass.
///
/// **The inlined type must be declared in the body of the `@Schema` type**, and that
/// restriction is what makes the feature possible rather than a limitation bolted onto it.
/// Two structs sharing one key namespace can collide, and a compile-time error is the right
/// answer — but an attached macro receives the syntax of the declaration it is attached to
/// and *nothing else*. It cannot see another type's members in **any** module, including one
/// declared three lines above: there is no lexical peer access and no compile-time string
/// evaluation with which to compare two key sets.
///
/// `ROADMAP.md` §3 recorded the blocker as cross-module detection cost. That was the wrong
/// diagnosis — there is no module in which it works — and correcting it is what produced
/// this spelling. A nested type's members *are* visible, so collision detection here is
/// total and at expansion, with no asymmetry to be silent about.
///
/// A `@Inline` naming a type that is not nested gets a diagnostic saying so.
@attached(peer)
public macro Inline() =
    #externalMacro(module: "AssayMacros", type: "InlineMacro")

/// Accept a single value where an array is declared. `EXPERIENCE.md` §9.
///
/// ```swift
/// @OneOrMany var tags: [String]     // "swift" and ["swift"] both decode
/// ```
///
/// **Only affects the JSON byte path, and that is a statement about the other paths rather
/// than a limitation of this one.** The `RawValue` path — YAML and XML — already accepts a
/// single value for an array unconditionally, because it has to: XML spells a sequence as
/// repeated sibling elements, each arriving as its own decode call with the same key, and at
/// that layer a lone `<tag>a</tag>` is indistinguishable from YAML's `tags: swift`. Making
/// the tree path strict would break every XML array.
///
/// So `@OneOrMany` is where the tolerance is a genuine choice rather than a consequence, and
/// `docs/CONFORMANCE.md` states the asymmetry as a contract. Removing it would mean grouping
/// repeated members into a `.sequence` in the XML projection — see `ROADMAP.md` §5.
///
/// Encoding always writes an array. The tolerant shape is input-only, which keeps
/// `docs/ENCODING.md`'s round-trip law intact: an array is a valid input, so the encoder
/// never has to guess which form the document used.
@attached(peer)
public macro OneOrMany() =
    #externalMacro(module: "AssayMacros", type: "OneOrManyMacro")

/// Sugar for the validated-scalar wrapper. `EXPERIENCE.md` §8.
///
/// ```swift
/// @Wraps(String.self, .email)
/// struct EmailAddress {}
///
/// @Schema struct User { var email: EmailAddress }   // just works
/// ```
///
/// Generates the storage, a failable `init?(_:)`, `Equatable`, `Hashable`,
/// `CustomStringConvertible`, and the `AssayerBacked` conformance that makes the type a
/// legal field of any `@Schema` type — from JSON, YAML and XML.
///
/// This is an attribute on a **type declaration**. The first edition of `EXPERIENCE.md`
/// wrote `@Wraps(String.self, .email) var EmailAddress` — a variable named like a type, with
/// no annotation and no value — which is illegal three ways over.
///
/// `init?(_:)` and the decode path run the **same rule array**, which is what makes "this
/// type cannot hold an invalid value" true rather than nearly true. The wrapped type is
/// restricted to `String`, `Int64`, `Double` and `Bool`: a macro sees a type's name and
/// nothing else, so it cannot emit a reader for one it does not recognise. For anything
/// else, write the `AssayerBacked` conformance by hand — this macro is only sugar over it.
@attached(member, names: named(raw), named(__assayWrapRules), named(init))
@attached(
    extension, conformances: AssayerBacked, Equatable, Hashable,
    CustomStringConvertible, names: arbitrary)
public macro Wraps(_ wrapped: Any.Type, _ rules: Rule...) =
    #externalMacro(module: "AssayMacros", type: "WrapsMacro")

/// Place a field in an XML document. See `XMLPlacement`.
@attached(peer)
public macro XML(_ placement: XMLPlacement) =
    #externalMacro(module: "AssayMacros", type: "XMLMacro")

/// Name the document's root element. Goes on the TYPE, not on a var.
///
/// ```swift
/// @Schema(formats: .xml, encodes: true) @XML(root: "book")
/// struct Book { var title: String }
/// ```
///
/// Two directions, and they are deliberately asymmetric:
///
/// - **Encoding** writes this name instead of the type's. Without the attribute the type's
///   own name is used, which is what `_assayXMLRoot` already did.
/// - **Decoding** *checks* it, and a mismatch is an issue rather than a warning. Without the
///   attribute decoding does not look at the root at all — a root element is very often a
///   wrapper the schema does not model (`<soap:Envelope>`, `<response>`), so checking one
///   nobody declared would reject documents that are fine. But if you wrote it down, you
///   asserted a fact about the wire, and an assertion that is silently tolerated is the
///   class of thing this library exists to remove.
///
/// Matched on the local name only, consistent with the projection, which keys members by
/// `local` and not by namespace URI.
@attached(peer)
public macro XML(root: String) =
    #externalMacro(module: "AssayMacros", type: "XMLMacro")

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

/// Override the wire key for one property.
@attached(peer)
public macro Key(_ name: String, or aliases: String...) =
    #externalMacro(module: "AssayMacros", type: "KeyMacro")

/// Reach a field through intermediate objects. `EXPERIENCE.md` §4, `ROADMAP.md` §3.
///
///     @Key(path: "profile.display_name") var displayName: String
///
/// A separate overload rather than a defaulted `path:` on the declaration above, so that
/// `@Key("id")` resolves to exactly the declaration it always did. Writing both on one
/// property is refused at expansion — one field has one wire location. (Until 2026-09-10
/// it was accepted and whichever came last won, silently; this comment said "cannot be
/// combined" while the macro let it be.)
///
/// Dot-separated keys only. An index segment (`meta.tags[0]`) is refused at expansion with a
/// diagnostic naming the alternative: indexing an array is a different operation from walking
/// a key, and half-building it would leave the caret rules with a case they cannot answer.
@attached(peer)
public macro Key(path: String) = #externalMacro(module: "AssayMacros", type: "KeyMacro")

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
/// on a Mac. On a `String` the conversion runs the other way: `@Coerce var host: String`
/// accepts `8080` as `"8080"`, which is what an XML document — where every leaf is text —
/// needs in reverse when a JSON producer sends the number.
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

/// The field form, for a check that needs a round trip to answer — "is this address
/// already registered?" is a field check that happens to need a database:
///
///     @AsyncCheck(\Signup.email)
///     static func unique(_ email: String) async -> String? {
///         await db.exists(email) ? "is already registered" : nil
///     }
///
/// This overload exists because `@Check` has one and writing the sibling by analogy is
/// what a developer does. Until 2026-09-13 it did not, and `@AsyncCheck(\S.a)` produced
/// "argument passed to macro expansion that takes no arguments" followed by a type error
/// and a warning INSIDE the expansion — four diagnostics for one reasonable guess.
@attached(peer)
public macro AsyncCheck<Root, Value>(_ keyPath: KeyPath<Root, Value>) =
    #externalMacro(module: "AssayMacros", type: "CheckMacro")

/// Normalise a string before its rules run: `@Preprocess(.trim, .lowercase)`.
/// Runs on the wire value, before validation — the other side of `@Transform`.
@attached(peer)
public macro Preprocess(_ ops: PreprocessStep...) =
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
///
/// On an optional property (`@Fallback(1) var a: Int?`) the fallback fires on absence,
/// on `null` and on an invalid value alike, so the property is never `nil` after a decode
/// — the `?` is then only a statement about the Swift type, not about the wire. If absence
/// should mean `nil`, drop the attribute; an optional already tolerates absence.
@attached(peer)
public macro Fallback<T>(_ value: T) =
    #externalMacro(module: "AssayMacros", type: "FallbackMacro")
