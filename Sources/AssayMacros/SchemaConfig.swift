// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Everything `@Schema(...)` was asked for, parsed ONCE.
//
// Until 2026-09-10 each option had its own `static func x(from: node)` and each consumer
// called the ones it remembered. That is how `formats: .all` on a union emitted a JSON-only
// body (the union path tested `formats.json` and not `formats.raw`), and how `sources:`,
// `describes:` and `context:` on a union were accepted and ignored — nobody called those
// three. One struct, built up front and handed to both the struct path and the union path,
// makes "which options does this path honour?" a question with one answer.
//
// `effectiveUnknownKeys` is the one place a declared option is REWRITTEN: `@Extras` with
// `.ignore` or `.warn` becomes `.collect`, because the sink is the declaration of intent and
// a sink that stays empty is a trap. `.reject` + `@Extras` is contradictory and is refused in
// `SchemaRefusals`.
//===----------------------------------------------------------------------===//

import SwiftSyntax

struct SchemaConfig {
    var keyStyle: KeyStyle
    /// `"ignore"`, `"warn"`, `"reject"` or `"collect"` — as DECLARED. See
    /// `effectiveUnknownKeys(hasExtras:)` for the one the bodies are emitted against.
    var unknownKeys: String
    var coerceScalars: Bool
    var formats: (json: Bool, raw: Bool, xml: Bool)
    var encodes: Bool
    var sources: Bool
    var describes: Bool
    /// The context type's NAME, or `""` for the overwhelming majority of types that declare
    /// none. `""` rather than nil because every consumer interpolates it into generated text
    /// and `""` is the identity there: a context-free type must expand to BYTE-IDENTICAL
    /// code to what it expanded to before contexts existed.
    var context: String
    /// `nil`: not a union. `.some(nil)`: `discriminator: .untagged`. `.some("type")`: tagged.
    var discriminator: String??
    /// `@XML(root: "book")` on the TYPE, or nil.
    var xmlRoot: String?

    init(node: AttributeSyntax, declaration: some DeclGroupSyntax) {
        keyStyle = SchemaConfig.keyStyle(from: node)
        unknownKeys = SchemaConfig.unknownKeys(from: node)
        coerceScalars = SchemaConfig.bool("coerceScalars", from: node)
        formats = SchemaConfig.formats(from: node)
        encodes = SchemaConfig.bool("encodes", from: node)
        sources = SchemaConfig.bool("sources", from: node)
        describes = SchemaConfig.bool("describes", from: node)
        context = SchemaConfig.contextType(from: node)
        discriminator = SchemaConfig.discriminator(from: node)
        xmlRoot = SchemaConfig.xmlRoot(from: declaration)
    }

    var isContextual: Bool { !context.isEmpty }

    /// The policy the bodies are emitted against. `@Extras` implies `.collect`: declaring a
    /// sink IS asking for unknown keys to be collected, and until 2026-09-10 the default
    /// `.ignore` won silently and the sink stayed empty forever.
    func effectiveUnknownKeys(hasExtras: Bool) -> String {
        if hasExtras, unknownKeys == "ignore" || unknownKeys == "warn" { return "collect" }
        return unknownKeys
    }

    // MARK: - Attribute parsing

    private static func args(_ node: AttributeSyntax) -> LabeledExprListSyntax? {
        node.arguments?.as(LabeledExprListSyntax.self)
    }

    private static func bool(_ label: String, from node: AttributeSyntax) -> Bool {
        guard let args = args(node) else { return false }
        for arg in args where arg.label?.text == label {
            return arg.expression.trimmedDescription == "true"
        }
        return false
    }

    static func keyStyle(from node: AttributeSyntax) -> KeyStyle {
        guard let args = args(node) else { return .camelCase }
        for arg in args where arg.label?.text == "keys" {
            var text = arg.expression.trimmedDescription
            while text.hasPrefix(".") { text.removeFirst() }
            return KeyStyle(rawValue: text) ?? .camelCase
        }
        return .camelCase
    }

    private static func unknownKeys(from node: AttributeSyntax) -> String {
        guard let args = args(node) else { return "ignore" }
        for arg in args where arg.label?.text == "unknownKeys" {
            var text = arg.expression.trimmedDescription
            while text.hasPrefix(".") { text.removeFirst() }
            if ["ignore", "warn", "reject", "collect"].contains(text) { return text }
        }
        return "ignore"
    }

    /// Which decode bodies to emit. The default is JSON alone; `formats: []` is a real
    /// configuration (a type decoded by something else that still wants `validate(_:)`) and
    /// is guarded where the diagnostic can name the fix rather than by quietly turning the
    /// empty set back into JSON.
    static func formats(from node: AttributeSyntax) -> (json: Bool, raw: Bool, xml: Bool) {
        guard let args = args(node) else { return (true, false, false) }
        for arg in args where arg.label?.text == "formats" {
            var names: [String] = []
            if let array = arg.expression.as(ArrayExprSyntax.self) {
                for element in array.elements {
                    var t = element.expression.trimmedDescription
                    while t.hasPrefix(".") { t.removeFirst() }
                    names.append(t)
                }
            } else {
                var t = arg.expression.trimmedDescription
                while t.hasPrefix(".") { t.removeFirst() }
                names.append(t)
            }
            if names.contains("all") { return (true, true, true) }
            if names.isEmpty { return (false, false, false) }
            let json = names.contains("json")
            let raw = names.contains("yaml") || names.contains("xml")
            // An unrecognised name falls back rather than silently emitting nothing.
            return (json || !raw, raw, names.contains("xml"))
        }
        return (true, false, false)
    }

    /// The macro reads a token. It cannot check that the context is a type, is `Sendable`,
    /// or has the members the checks call — the type checker does all three at the use
    /// site, which is also where the error is legible.
    private static func contextType(from node: AttributeSyntax) -> String {
        guard let args = args(node) else { return "" }
        for arg in args where arg.label?.text == "context" {
            var t = arg.expression.trimmedDescription
            if t.hasSuffix(".self") { t.removeLast(5) }
            return t
        }
        return ""
    }

    /// The tag key for the tagged form, `.some(nil)` for `.untagged`, nil for no union at
    /// all — three states, and the outer Optional keeps two of them from merging.
    private static func discriminator(from node: AttributeSyntax) -> String?? {
        guard let args = args(node) else { return nil }
        for arg in args where arg.label?.text == "discriminator" {
            if let lit = arg.expression.as(StringLiteralExprSyntax.self) {
                return .some(lit.segments.description)
            }
            // Any non-literal expression: the type admits exactly one other value.
            return .some(nil)
        }
        return nil
    }

    /// Read from the declaration's own attribute list rather than from `@Schema`'s
    /// arguments, because that is where the specified spelling puts it. The peer macro
    /// itself expands to nothing — it exists so the attribute is legal and so this can find
    /// it, exactly like `@XML(_ placement:)` on a var.
    private static func xmlRoot(from decl: some DeclGroupSyntax) -> String? {
        for attr in decl.attributes.compactMap({ $0.as(AttributeSyntax.self) })
        where attr.attributeName.trimmedDescription == "XML" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self),
                  let first = args.first, first.label?.text == "root",
                  let lit = first.expression.as(StringLiteralExprSyntax.self) else { continue }
            return lit.segments.trimmedDescription
        }
        return nil
    }
}
