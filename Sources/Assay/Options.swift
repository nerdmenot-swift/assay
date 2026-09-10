// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The value types `@Schema(...)` and the placement attributes take as arguments.
//
// Split out of Assay.swift on 2026-09-10.
//===----------------------------------------------------------------------===//

import AssayCore


/// Where a field lives in an XML document. `docs/ENCODING.md`.
///
///     @XML(.attribute) var id: String        // <user id="7">
///     @XML(.text)      var body: String      // <p>the text</p>
///     @XML(.wrapped)   var tags: [String]    // <tags><item>a</item></tags>
///
/// **Element is the default**, and for arrays **repeated sibling elements** —
/// `<tag>a</tag><tag>b</tag>`. Both defaults follow the field: Jackson, Go, .NET and
/// pydantic-xml all default a plain property to an element and none to an attribute, and
/// the two libraries whose XML support was designed rather than retrofitted (Go's
/// `encoding/xml`, serde-xml-rs) both chose unwrapped repeated siblings for sequences.
///
/// `.wrapped` exists for the one thing unwrapped genuinely cannot express: the difference
/// between an **absent** array and an **empty** one. `<tags/>` is unambiguously empty;
/// nothing at all is ambiguous. Assay distinguishes missing from empty everywhere else
/// (`EXPERIENCE.md` §6's five presence states), so the distinction gets an opt-in rather
/// than a caveat.
public enum XMLPlacement: Sendable {
    /// A child element. The default.
    case element
    /// An attribute on the parent. Scalars only — attributes cannot nest or repeat.
    case attribute
    /// The element's own character data.
    case text
    /// An array inside a wrapper element, so empty and absent stay distinguishable.
    case wrapped
}


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


/// `@Schema(discriminator:)` — how a union chooses its branch. `docs/UNIONS.md`.
///
/// Two spellings, one parameter, and the `ExpressibleByStringLiteral` conformance is what
/// makes that work — the same device `Rule` uses so `@Validate(.min(1), "message")` compiles:
///
///     @Schema(discriminator: "type")      // tagged: the branch is named in the document
///     @Schema(discriminator: .untagged)   // untagged: try each branch in order
///
/// **It was `.none` until 2026-09-10**, and that spelling warned on every use: the parameter
/// is `Discriminator?` so that "no discriminator" and "untagged" are distinguishable, and an
/// Optional parameter makes `.none` resolve to `Optional.none` first — "assuming you mean
/// 'Optional<Discriminator>.none'" in every file that declared an untagged union. The macro
/// read the token and worked regardless, which is how it shipped. `.untagged` cannot
/// collide with anything and says what it is.
public struct Discriminator: Sendable, Equatable, ExpressibleByStringLiteral {
    @usableFromInline enum Storage: Sendable, Equatable {
        case key(String)
        case untagged
    }
    @usableFromInline let storage: Storage

    /// An untagged union. `docs/UNIONS.md` §2.2 and §3: this is the form that needs a
    /// composed failure report and a backtracking budget, and the form that carries a
    /// round-trip exception. Prefer a tag whenever the wire format has one.
    public static let untagged = Discriminator(storage: .untagged)

    @usableFromInline init(storage: Storage) { self.storage = storage }

    public init(stringLiteral value: String) { self.storage = .key(value) }
}


/// How declared identifiers become wire keys.
public enum KeyNamingStyle: Sendable {
    case camelCase
    case snakeCase
    case kebabCase
    case pascalCase
    case screamingSnakeCase
}
