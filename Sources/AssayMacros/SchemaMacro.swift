// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// @Schema — the attached macro.
//
// What it emits, and why each choice is forced (docs/PERFORMANCE.md §3.2, §8.2, §8.3):
//
//   * Into an *extension*, not the type body. A macro that emits an `init` into the type
//     silently deletes the memberwise initializer Swift would have synthesised. Emitting
//     into an extension keeps both.
//
//   * Concrete and monomorphic. The generated decode body has no generic parameter, so
//     there is nothing for cross-module specialization to fail at. This is the single
//     most important structural reason a macro decoder can be fast in Swift.
//
//   * Many medium functions, not one flat body. Escape analysis budgets
//     `1_000_000 / estimatedFunctionSize` and divides by ten again for ARC queries;
//     budget exhaustion is indistinguishable from "it escapes" and the retains simply
//     stay, with no diagnostic. Per-field decoding therefore goes through small helpers.
//
//   * `nonisolated`, and the protocol refines `Sendable`, so `-default-isolation
//     MainActor` cannot infer main-actor isolation onto a conforming type.
//
// Compile-time budget: see docs/COMPILE-TIME.md. Every expansion is a round trip to a
// separate plugin process, so this file avoids gratuitous syntax-tree walking and does
// all key analysis in one pass over the members.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - Field model

struct SchemaField {
    var identifier: String
    var typeName: String          // normalised, e.g. "Int", "String?", "[Int]"
    var wireKey: String
    var aliases: [String]
    var isOptional: Bool
    var defaultExpr: String?      // `= 3` — consulted on absence only, still validated
    var isIgnored: Bool
    /// `@Extras` — the sink for keys the schema did not declare. Never in the dispatch
    /// table, never in the presence mask, but still in the memberwise init.
    var isExtras: Bool
    /// `@Coerce` — allow a scalar of the wrong type through the documented, locale-free
    /// conversion rules. Never implicit; always written on the property or the type.
    var coerce: Bool
    /// Parsed `@Validate` attributes, in declaration order.
    var validations: [ValidationAttr] = []
    /// `@Preprocess` op expressions, applied to the wire value before rules.
    var preprocess: [String] = []
    /// `@Transform`: the closure source and the wire type its parameter declares. The
    /// declared property type is the output; decoding and validation use the wire type.
    var transform: (closure: String, wireType: String)?
    /// `@Fallback(expr)`: assigned on absence OR any issue at this field, with a warning.
    var fallback: String?
    /// `@XML(...)` placement: "attribute", "text", or "wrapped". Nil is the default —
    /// an element, and for arrays repeated sibling elements. docs/ENCODING.md.
    var xmlPlacement: String?
    /// `@Inverse({ ... })` — the encode-direction closure paired with `@Transform`.
    /// docs/ENCODING.md question 3: a transform with no inverse is lossy by arithmetic,
    /// so the type simply cannot be encoded and the macro says so at expansion.
    var inverse: String?
    /// `@DateFormat(...)` — the ordered candidate formats, as source expressions
    /// (`.iso8601`, `.pattern("yyyy-MM-dd")`). Nil means the shared default. The
    /// expressions are validated by the DateFormat peer macro; here they are re-emitted
    /// verbatim into a `[Assay.DateFormat]` literal.
    var dateFormats: [String]?
    /// Whether generated code captures this field's value span (set during expansion:
    /// validated fields, and fields targeted by a field-form @Check).
    var needsSpan: Bool = false

    /// The type decode and validation operate on — the transform's wire type when one
    /// exists, otherwise the declared type with optionality stripped.
    var decodedType: String {
        transform?.wireType ?? SchemaMacro.stripOptional(typeName)
    }
}

enum SchemaError: Error, CustomStringConvertible {
    case notAStruct
    case needsTypeAnnotation(String)
    case letWithInitializer(String)
    case duplicateKey(String)
    case tooManyFields(Int)
    case collectWithoutExtras
    case extrasWrongType(String)
    case multipleExtras

    var description: String {
        switch self {
        case .notAStruct:
            return "@Schema can be applied to a struct, or to an enum with an @Unknown case"
        case .needsTypeAnnotation(let n):
            // A macro only sees source text — it cannot ask the type checker what `3` is,
            // and guessing Int would be wrong the moment someone writes `var timeout = 1.5`
            // in a codebase where the wire type is a Duration.
            return "property '\(n)' needs an explicit type annotation; @Schema cannot infer a type from an initializer alone"
        case .letWithInitializer(let n):
            return "'let \(n)' with an initializer cannot be decoded; change it to 'var' to make it a default"
        case .duplicateKey(let k):
            return "duplicate wire key \"\(k)\"; two properties would read the same key"
        case .tooManyFields(let n):
            return "@Schema supports at most 64 fields in this release, found \(n)"
        case .collectWithoutExtras:
            return "@Schema(unknownKeys: .collect) requires an @Extras property to collect into; add `@Extras var extras: [String: RawValue]`"
        case .extrasWrongType(let t):
            return "@Extras must be a dictionary keyed by String, found '\(t)'"
        case .multipleExtras:
            return "only one @Extras property is allowed per @Schema type"
        }
    }
}

struct SimpleDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
    init(_ message: String, severity: DiagnosticSeverity = .error) {
        self.message = message
        self.diagnosticID = MessageID(domain: "Assay", id: "Schema")
        self.severity = severity
    }
}

// MARK: - The macro

public struct SchemaMacro: ExtensionMacro {

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {

        // An enum takes a different path entirely: it decodes as a scalar, not a
        // mapping, and the only reason it needs a macro at all is @Unknown.
        if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            return Self.enumExpansion(of: node, enumDecl: enumDecl,
                                      typeName: type.trimmedDescription, in: context)
        }
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: SimpleDiagnostic(SchemaError.notAStruct.description)))
            return []
        }

        let keyStyle = Self.keyStyle(from: node)
        let typeName = type.trimmedDescription

        var fields: [SchemaField] = []
        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            for f in try Self.fields(from: varDecl, keyStyle: keyStyle, context: context) {
                fields.append(f)
            }
        }

        let policy = Self.unknownKeys(from: node)
        let wantsEncoding = Self.encodes(from: node)
        let coerceAll = Self.coerceScalars(from: node)
        let formats = Self.formats(from: node)

        // @Extras is a sink, not a field: it never enters the dispatch table, the
        // candidate key set, or the presence mask — but it is still passed to the
        // memberwise initializer.
        let extrasFields = fields.filter { $0.isExtras }
        guard extrasFields.count <= 1 else {
            context.diagnose(Diagnostic(node: Syntax(node),
                message: SimpleDiagnostic(SchemaError.multipleExtras.description)))
            return []
        }
        let extras = extrasFields.first
        if let e = extras, !e.typeName.hasPrefix("[String:") && !e.typeName.hasPrefix("[String :") {
            context.diagnose(Diagnostic(node: Syntax(node),
                message: SimpleDiagnostic(SchemaError.extrasWrongType(e.typeName).description)))
            return []
        }
        if policy == "collect" && extras == nil {
            context.diagnose(Diagnostic(node: Syntax(node),
                message: SimpleDiagnostic(SchemaError.collectWithoutExtras.description)))
            return []
        }

        let active = fields.filter { !$0.isIgnored && !$0.isExtras }
        guard !active.isEmpty || extras != nil else { return [] }

        // JSON object keys are strings; a dictionary field keyed by anything else would
        // fail inside generated code, pointing at nothing the user wrote.
        for f in active {
            if let bad = Self.firstNonStringDictKey(Self.stripOptional(f.typeName)) {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: SimpleDiagnostic(
                        "dictionary fields must be keyed by String — object keys are "
                        + "strings in every wire format; '\(f.identifier)' declares '\(bad)'")))
                return []
            }
        }
        guard active.count <= 64 else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: SimpleDiagnostic(SchemaError.tooManyFields(active.count).description)))
            return []
        }

        // Every alias is flattened into the candidate set before the window search, so an
        // alias costs one more table entry and nothing at runtime.
        var candidates: [Candidate] = []
        var seenKeys = Set<String>()
        for (i, f) in active.enumerated() {
            for key in [f.wireKey] + f.aliases {
                if !seenKeys.insert(key).inserted {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: SimpleDiagnostic(SchemaError.duplicateKey(key).description)))
                    return []
                }
                candidates.append(Candidate(wireKey: key, fieldIndex: i))
            }
        }

        let plan = formats.json
            ? WindowSearch.search(candidates, fieldCount: active.count)
            : nil
        // Declaration order, including @Extras, so the memberwise initializer's arguments
        // are emitted in the order Swift synthesised them.
        let ordered = fields.filter { !$0.isIgnored }
        // `coerceScalars` on the type is the same switch as `@Coerce` on every field.
        let activeC = active.map { f -> SchemaField in
            var g = f; g.coerce = f.coerce || coerceAll; return g
        }

        // @Check / @AsyncCheck members, and span requirements they add.
        let checkDecls = Self.checks(in: structDecl, context: context)
        let checkedFields = Set(checkDecls.compactMap(\.fieldIdentifier))
        var activeS = activeC
        for i in activeS.indices {
            activeS[i].needsSpan = !activeS[i].validations.isEmpty
                || checkedFields.contains(activeS[i].identifier)
        }

        guard Self.checkValidations(activeS, node: node, context: context) else {
            return []
        }

        var body = Self.ruleArrays(activeS)
        body += Self.dateFormatArrays(activeS)
        body += Self.preprocessArrays(activeS)
        body += Self.transformClosures(activeS)
        if checkDecls.contains(where: { $0.fieldIdentifier == nil }) || !checkDecls.filter(\.isAsync).isEmpty {
            body += Self.fieldNameTable(typeName, activeS)
        }
        if formats.json {
            body += Self.decodeBody(typeName: typeName, fields: activeS, plan: plan,
                                    extras: extras, policy: policy, ordered: ordered,
                                    validation: Self.postDecodeSection(activeS, spans: true),
                                    checks: Self.checkCalls(typeName, checkDecls, activeS,
                                                            spans: true))
        }
        if formats.raw {
            if !body.isEmpty { body += "\n\n" }
            body += Self.rawDecodeBody(typeName: typeName, fields: activeS,
                                       extras: extras, policy: policy, ordered: ordered,
                                       emitKnownKeys: !formats.json,
                                       validation: Self.postDecodeSection(activeS, spans: false),
                                       checks: Self.checkCalls(typeName, checkDecls, activeS,
                                                               spans: false))
        }
        if wantsEncoding {
            for message in Self.encodeDiagnostics(activeS) {
                context.diagnose(Diagnostic(node: Syntax(node),
                                            message: SimpleDiagnostic(message)))
            }
            guard Self.encodeDiagnostics(activeS).isEmpty else { return [] }
            body += "\n\n" + Self.inverseClosures(activeS)
            body += Self.declaredKeys(activeS, extras)
            if formats.json {
                body += Self.encodeBody(typeName: typeName, fields: activeS, extras: extras)
            }
            if formats.raw {
                if formats.json { body += "\n\n" }
                body += Self.rawEncodeBody(typeName: typeName, fields: activeS,
                                           extras: extras)
            }
            if formats.xml {
                for message in Self.xmlDiagnostics(activeS) {
                    context.diagnose(Diagnostic(node: Syntax(node),
                                                message: SimpleDiagnostic(message)))
                }
                guard Self.xmlDiagnostics(activeS).isEmpty else { return [] }
                body += "\n\n" + Self.xmlEncodeBody(typeName: typeName, fields: activeS,
                                                     extras: extras)
            }
        }
        if Self.sources(from: node) {
            for message in Self.sourceDiagnostics(activeS) {
                context.diagnose(Diagnostic(node: Syntax(node),
                                            message: SimpleDiagnostic(message)))
            }
            guard Self.sourceDiagnostics(activeS).isEmpty else { return [] }
            body += "\n\n" + Self.manifestBody(typeName: typeName, fields: activeS)
            body += "\n\n" + Self.batchBody(
                typeName: typeName, fields: activeS,
                validation: Self.postDecodeSection(activeS, spans: false))
        }
        if Self.hasValidation(activeS, checkDecls) {
            if !body.isEmpty { body += "\n\n" }
            body += Self.validateBody(typeName: typeName, fields: activeS,
                                      checks: checkDecls)
        }
        body += Self.asyncCheckRunner(typeName, checkDecls)

        var conformances: [String] = []
        if formats.json { conformances.append("Assay.JSONAssayable") }
        if formats.raw { conformances.append("Assay.RawDecodable") }
        if Self.hasValidation(activeS, checkDecls) {
            conformances.append("Assay.Validatable")
        }
        if checkDecls.contains(where: \.isAsync) {
            conformances.append("Assay.AsyncCheckAssayable")
        }
        if wantsEncoding && formats.json { conformances.append("Assay.JSONEncodableSchema") }
        if wantsEncoding && formats.raw { conformances.append("Assay.RawEncodableSchema") }
        if wantsEncoding && formats.xml { conformances.append("Assay.XMLEncodableSchema") }
        if Self.sources(from: node) { conformances.append("Assay.SourceDecodable") }

        let ext = try ExtensionDeclSyntax(
            "extension \(raw: typeName): \(raw: conformances.joined(separator: ", "))") {
            DeclSyntax(stringLiteral: body)
        }
        return [ext]
    }

    // MARK: Attribute parsing

    /// `@Schema(coerceScalars: true)` — for formats that have no types at all. XML is the
    /// motivating case: every leaf is text, so a schema with an `Int` field cannot decode
    /// from XML without it.
    static func coerceScalars(from node: AttributeSyntax) -> Bool {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return false }
        for arg in args where arg.label?.text == "coerceScalars" {
            return arg.expression.trimmedDescription == "true"
        }
        return false
    }

    /// Which decode bodies to emit. Opt-in, defaulting to JSON only, because generated
    /// code is not free — docs/COMPILE-TIME.md §4.5.
    static func formats(from node: AttributeSyntax) -> (json: Bool, raw: Bool, xml: Bool) {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else {
            return (true, false, false)
        }
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
            let json = names.contains("json")
            let raw = names.contains("yaml") || names.contains("xml")
            // An empty or unrecognised set would silently emit nothing decodable, so fall
            // back to the default rather than producing a type nobody can parse.
            return (json || !raw, raw, names.contains("xml"))
        }
        return (true, false, false)
    }

    /// `@Schema(encodes: true)`. Opt-in for a compile-time reason, not a taste one:
    /// generated body size dominates expansion cost, so a type that only decodes must not
    /// pay for an encoder it never calls.
    static func encodes(from node: AttributeSyntax) -> Bool {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return false }
        for arg in args where arg.label?.text == "encodes" {
            return arg.expression.trimmedDescription == "true"
        }
        return false
    }

    /// `@Schema(sources: true)` — the KeyedSource decode body. Opt-in like every other
    /// body: generated size dominates expansion cost.
    static func sources(from node: AttributeSyntax) -> Bool {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return false }
        for arg in args where arg.label?.text == "sources" {
            return arg.expression.trimmedDescription == "true"
        }
        return false
    }

    static func unknownKeys(from node: AttributeSyntax) -> String {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return "ignore" }
        for arg in args where arg.label?.text == "unknownKeys" {
            var text = arg.expression.trimmedDescription
            while text.hasPrefix(".") { text.removeFirst() }
            if ["ignore", "warn", "reject", "collect"].contains(text) { return text }
        }
        return "ignore"
    }

    static func keyStyle(from node: AttributeSyntax) -> KeyStyle {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return .camelCase }
        for arg in args where arg.label?.text == "keys" {
            // `.snakeCase` arrives as a member-access expression; drop the leading dot.
            // No Foundation in the macro target, so no `trimmingCharacters`.
            var text = arg.expression.trimmedDescription
            while text.hasPrefix(".") { text.removeFirst() }
            if let s = KeyStyle(rawValue: text) { return s }
        }
        return .camelCase
    }

    // MARK: Member analysis

    /// One declaration can introduce several properties — `var a: Int, b: String` is
    /// ordinary Swift, and reading only the first binding silently dropped the rest,
    /// producing an expansion that failed to compile with a message pointing at
    /// generated code. Attributes on the declaration apply to every binding it
    /// introduces, which is also how Swift itself reads them.
    static func fields(
        from varDecl: VariableDeclSyntax,
        keyStyle: KeyStyle,
        context: some MacroExpansionContext
    ) throws -> [SchemaField] {
        var out: [SchemaField] = []
        for binding in varDecl.bindings {
            if let f = try field(from: varDecl, binding: binding,
                                 keyStyle: keyStyle, context: context) {
                out.append(f)
            }
        }
        return out
    }

    static func field(
        from varDecl: VariableDeclSyntax,
        binding: PatternBindingSyntax,
        keyStyle: KeyStyle,
        context: some MacroExpansionContext
    ) throws -> SchemaField? {

        // Skip anything that is not a decodable stored property: static, computed,
        // `lazy var`, and accessor-bearing declarations all look wrong to the macro and
        // are silently excluded (§6). `@Ignore` is the explicit opt-out.
        if varDecl.modifiers.contains(where: {
            $0.name.text == "static" || $0.name.text == "class" || $0.name.text == "lazy"
        }) { return nil }

        let attrs = varDecl.attributes.compactMap { $0.as(AttributeSyntax.self) }
        let attrNames = Set(attrs.map { $0.attributeName.trimmedDescription })
        if attrNames.contains("Ignore") { return nil }
        let isExtras = attrNames.contains("Extras")
        let coerce = attrNames.contains("Coerce")
        let validations = Self.validations(from: attrs)
        let preprocess = Self.preprocessOps(from: attrs)
        let transform = Self.transform(from: attrs, context: context)
        let fallback = Self.fallbackExpr(from: attrs)

        var xmlPlacement: String? = nil
        for attr in attrs where attr.attributeName.trimmedDescription == "XML" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self),
                  let first = args.first else { continue }
            var t = first.expression.trimmedDescription
            while t.hasPrefix(".") { t.removeFirst() }
            if ["attribute", "text", "wrapped", "element"].contains(t) {
                xmlPlacement = t == "element" ? nil : t
            }
        }

        var inverse: String? = nil
        for attr in attrs where attr.attributeName.trimmedDescription == "Inverse" {
            if let args = attr.arguments?.as(LabeledExprListSyntax.self),
               let c = args.first?.expression.as(ClosureExprSyntax.self) {
                inverse = c.trimmedDescription
            }
        }

        var dateFormats: [String]? = nil
        for attr in attrs where attr.attributeName.trimmedDescription == "DateFormat" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self) else { continue }
            let exprs = args.map { $0.expression.trimmedDescription }
            if !exprs.isEmpty { dateFormats = exprs }
        }

        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            return nil
        }

        // A computed property has an accessor block; a stored one does not. `willSet`/
        // `didSet` observers are stored, so those are kept.
        if let accessor = binding.accessorBlock {
            if case .getter = accessor.accessors { return nil }
            if case .accessors(let list) = accessor.accessors {
                let names = list.map { $0.accessorSpecifier.text }
                if names.contains("get") || names.contains("_read") { return nil }
            }
        }

        let name = pattern.identifier.text
        let isLet = varDecl.bindingSpecifier.text == "let"

        guard let typeAnnotation = binding.typeAnnotation else {
            // `var x = 3` — a hard error rather than an inference.
            if binding.initializer != nil {
                context.diagnose(Diagnostic(
                    node: Syntax(varDecl),
                    message: SimpleDiagnostic(SchemaError.needsTypeAnnotation(name).description)))
            }
            return nil
        }

        if isLet && binding.initializer != nil {
            // Already assigned; no generated initializer can write to it.
            context.diagnose(Diagnostic(
                node: Syntax(varDecl),
                message: SimpleDiagnostic(SchemaError.letWithInitializer(name).description)))
            return nil
        }

        let typeName = typeAnnotation.type.trimmedDescription
        let isOptional = typeName.hasSuffix("?") || typeName.hasPrefix("Optional<")

        var wireKey = keyStyle.apply(name)
        var aliases: [String] = []
        for attr in attrs where attr.attributeName.trimmedDescription == "Key" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self) else { continue }
            for (i, arg) in args.enumerated() {
                guard let lit = arg.expression.as(StringLiteralExprSyntax.self) else { continue }
                let value = lit.segments.description
                if i == 0 && arg.label == nil {
                    wireKey = value
                } else if arg.label?.text == "or" || arg.label == nil {
                    aliases.append(value)
                }
            }
        }

        return SchemaField(
            identifier: name,
            typeName: typeName,
            wireKey: wireKey,
            aliases: aliases,
            isOptional: isOptional,
            defaultExpr: binding.initializer?.value.trimmedDescription,
            isIgnored: false,
            isExtras: isExtras,
            coerce: coerce,
            validations: validations,
            preprocess: preprocess,
            transform: transform,
            fallback: fallback,
            xmlPlacement: xmlPlacement,
            inverse: inverse,
            dateFormats: dateFormats)
    }
}
