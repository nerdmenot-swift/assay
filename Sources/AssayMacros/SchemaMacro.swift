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
    /// `@OneOrMany` — accept a single value where an array is declared.
    var oneOrMany: Bool = false
    /// Set on every field spliced in by `@Inline`: the property to reconstruct and the type
    /// to reconstruct it as. The fields decode from the OUTER key namespace; construction
    /// gathers them back into one nested value.
    var inlineOwner: (identifier: String, typeName: String)?
    /// `@Inverse({ ... })` — the encode-direction closure paired with `@Transform`.
    /// docs/ENCODING.md question 3: a transform with no inverse is lossy by arithmetic,
    /// so the type simply cannot be encoded and the macro says so at expansion.
    var inverse: String?
    /// `@DateFormat(...)` — the ordered candidate formats, as source expressions
    /// (`.iso8601`, `.pattern("yyyy-MM-dd")`). Nil means the shared default. The
    /// expressions are validated by the DateFormat peer macro; here they are re-emitted
    /// verbatim into a `[Assay.DateFormat]` literal.
    var dateFormats: [String]?
    /// `@Key(path: "profile.display_name")` — the dot-separated segments, or nil for the
    /// overwhelming majority of fields. `wireKey` stays the LAST segment, so every existing
    /// consumer that names a key in a message keeps naming the right one.
    var pathSegments: [String]?
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

        // Nested type declarations, by name. `@Inline` reads members out of these -- which
        // is the whole reason it requires the type to be nested. See the macro's doc comment.
        var nestedTypes: [String: StructDeclSyntax] = [:]
        for member in structDecl.memberBlock.members {
            if let nested = member.decl.as(StructDeclSyntax.self) {
                nestedTypes[nested.name.text] = nested
            }
        }

        var fields: [SchemaField] = []
        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isInline = varDecl.attributes.compactMap { $0.as(AttributeSyntax.self) }
                .contains { $0.attributeName.trimmedDescription == "Inline" }
            for f in try Self.fields(from: varDecl, keyStyle: keyStyle, context: context) {
                guard isInline else { fields.append(f); continue }

                let base = Self.stripOptional(f.typeName)
                guard let nested = nestedTypes[base] else {
                    context.diagnose(Diagnostic(node: Syntax(varDecl), message: SimpleDiagnostic(
                        "@Inline requires '\(base)' to be declared inside '\(typeName)'. A "
                        + "macro receives only the syntax of the declaration it is attached "
                        + "to, so it cannot see another type's members -- in any module, "
                        + "including this one -- and a key collision between the two could "
                        + "not be detected. Nest the type, or declare its fields directly.")))
                    return []
                }
                guard !f.isOptional else {
                    context.diagnose(Diagnostic(node: Syntax(varDecl), message: SimpleDiagnostic(
                        "@Inline cannot be optional. Its keys are read from this level, so "
                        + "'all absent' and 'some absent' are indistinguishable and there is "
                        + "no honest answer for which one means nil.")))
                    return []
                }
                // Flatten. The nested fields keep their own `@Key` renames and rules; only
                // their namespace changes, which is what makes collision detection fall out
                // of the duplicate-key check that already runs below.
                for nestedMember in nested.memberBlock.members {
                    guard let nv = nestedMember.decl.as(VariableDeclSyntax.self) else { continue }
                    for var inner in try Self.fields(from: nv, keyStyle: keyStyle,
                                                     context: context) {
                        inner.inlineOwner = (f.identifier, base)
                        fields.append(inner)
                    }
                }
            }
        }

        let policy = Self.unknownKeys(from: node)
        let wantsEncoding = Self.encodes(from: node)
        let wantsSources = Self.sources(from: node)
        let xmlRootName = Self.xmlRoot(from: declaration)
        let coerceAll = Self.coerceScalars(from: node)
        let formats = Self.formats(from: node)
        let ctxType = Self.contextType(from: node)

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
        // `@Key(path:)`. A path field does NOT appear in the top-level dispatch — its key
        // lives one or more levels down — so its group's FIRST segment takes an arm instead,
        // and two fields under the same prefix share that one arm. PathKeys.swift.
        let pathGroups = PathTree.build(active)

        var seenKeys = Set<String>()
        var entryIndex = 0
        for f in active where f.pathSegments == nil {
            for key in [f.wireKey] + f.aliases {
                if !seenKeys.insert(key).inserted {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: SimpleDiagnostic(SchemaError.duplicateKey(key).description)))
                    return []
                }
                candidates.append(Candidate(wireKey: key, fieldIndex: entryIndex))
            }
            entryIndex += 1
        }
        for g in pathGroups {
            // A group's segment collides with a declared key for a real reason, not a
            // bookkeeping one: one arm cannot both descend into an object and decode a
            // value. Caught by the same check, so the diagnostic is the one people know.
            if !seenKeys.insert(g.segment).inserted {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: SimpleDiagnostic(SchemaError.duplicateKey(g.segment).description)))
                return []
            }
            candidates.append(Candidate(wireKey: g.segment, fieldIndex: entryIndex))
            entryIndex += 1
        }

        let plan = formats.json
            ? WindowSearch.search(candidates, fieldCount: entryIndex)
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

        // Spelled out rather than left to associated-type inference. Inference across a
        // protocol refinement stops working the moment a type conforms to two of the
        // contextual protocols, and its failure mode is a wall of "does not conform".
        var body = ctxType.isEmpty ? "" : """
        public typealias AssayContext = \(ctxType)


        """
        body += Self.ruleArrays(activeS)
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
                                                            spans: true, ctx: ctxType),
                                    groups: pathGroups, ctx: ctxType)
        }
        if formats.raw {
            if !body.isEmpty { body += "\n\n" }
            // `spans: true` here as well as on the JSON path. The span locals are filled
            // from `RawValue.Member.span`, which the YAML and XML parsers record; a
            // producer that tracks no offsets leaves them nil, and a nil span renders the
            // same span-less issue it always did.
            body += Self.rawDecodeBody(typeName: typeName, fields: activeS,
                                       extras: extras, policy: policy, ordered: ordered,
                                       emitKnownKeys: !formats.json,
                                       validation: Self.postDecodeSection(activeS, spans: true),
                                       checks: Self.checkCalls(typeName, checkDecls, activeS,
                                                               spans: true, ctx: ctxType),
                                       groups: pathGroups, ctx: ctxType)
        }
        if wantsEncoding {
            for message in Self.encodeDiagnostics(activeS) {
                context.diagnose(Diagnostic(node: Syntax(node),
                                            message: SimpleDiagnostic(message)))
            }
            guard Self.encodeDiagnostics(activeS).isEmpty else { return [] }
            body += "\n\n" + Self.inverseClosures(activeS)
            body += Self.declaredKeys(activeS, extras, groups: pathGroups)
            if formats.json {
                body += Self.encodeBody(typeName: typeName, fields: activeS, extras: extras,
                                        groups: pathGroups)
            }
            if formats.raw {
                if formats.json { body += "\n\n" }
                body += Self.rawEncodeBody(typeName: typeName, fields: activeS,
                                           extras: extras, groups: pathGroups)
            }
            if formats.xml {
                for message in Self.xmlDiagnostics(activeS) {
                    context.diagnose(Diagnostic(node: Syntax(node),
                                                message: SimpleDiagnostic(message)))
                }
                guard Self.xmlDiagnostics(activeS).isEmpty else { return [] }
                body += "\n\n" + Self.xmlEncodeBody(typeName: typeName, fields: activeS,
                                                     extras: extras, root: xmlRootName)
            }
        }
        // The decode-side half of `@XML(root:)`. Emitted only when the attribute is present,
        // so an unannotated type carries nothing and checks nothing — a root element is very
        // often a wrapper the schema does not model, and rejecting one nobody declared would
        // refuse documents that are fine.
        if let r = xmlRootName, formats.xml {
            if !body.isEmpty { body += "\n\n" }
            body += """
            nonisolated public static var _assayXMLExpectedRoot: String? { "\(r)" }
            """
        }

        if wantsSources {
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
                                      checks: checkDecls, ctx: ctxType)
        }
        body += Self.asyncCheckRunner(typeName, checkDecls, ctx: ctxType)

        // A type that would expand to NOTHING AT ALL is always a mistake, and it is the
        // only reason `formats: []` needs guarding — said here, where the diagnostic can
        // name the fix, rather than by quietly turning the empty set back into JSON.
        //
        // Every way of generating a body has to be listed, and `sources` belongs in that
        // list: `@Schema(formats: [], sources: true)` emits `_assayManifest` and
        // `_assayBatch`, so refusing it told the truth about `formats: []` and a falsehood
        // about the declaration in front of it. That mattered more than a missing clause
        // usually does, because there was no other correct spelling. A columnar-only type
        // carrying a consumer's own scalar cannot say `formats: .json` either — the JSON
        // byte path calls `T._assay(from: AssayReader…)`, which is not a public protocol
        // requirement — so the only thing that compiled was `formats: .yaml, sources: true`
        // plus a `RawDecodable` conformance per custom type that would never be called, to
        // obtain a columnar decoder. That workaround would have ended up in real code.
        //
        // It is also the argument `ROADMAP.md` §1 already makes for `encodes:` being
        // opt-in: a decode-only type must not pay for an encoder it never calls. A
        // columnar-only type not paying for a JSON decoder it never calls is the same
        // claim, and the guard was inconsistent with the design around it.
        if !formats.json, !formats.raw, !formats.xml, !wantsEncoding, !wantsSources,
           !Self.hasValidation(activeS, checkDecls) {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: SimpleDiagnostic(
                    "@Schema(formats: []) emits no decode body, and this type declares no "
                    + "@Validate, no @Check, no `encodes: true` and no `sources: true`, so "
                    + "the macro would generate nothing. Add a rule if you want "
                    + "`\(typeName).validate(_:)`, `sources: true` to decode from a column "
                    + "store, or remove `formats: []` to decode JSON.")))
            return []
        }

        var conformances: [String] = []
        if formats.json {
            conformances.append(ctxType.isEmpty
                ? "Assay.JSONAssayable" : "Assay.ContextualJSONAssayable")
        }
        if formats.raw {
            conformances.append(ctxType.isEmpty
                ? "Assay.RawDecodable" : "Assay.ContextualRawDecodable")
        }
        if Self.hasValidation(activeS, checkDecls) {
            conformances.append(ctxType.isEmpty
                ? "Assay.Validatable" : "Assay.ContextualValidatable")
        }
        if checkDecls.contains(where: \.isAsync) {
            conformances.append(ctxType.isEmpty
                ? "Assay.AsyncCheckAssayable" : "Assay.ContextualAsyncCheckAssayable")
        }
        if wantsEncoding && formats.json { conformances.append("Assay.JSONEncodableSchema") }
        if wantsEncoding && formats.raw { conformances.append("Assay.RawEncodableSchema") }
        if wantsEncoding && formats.xml { conformances.append("Assay.XMLEncodableSchema") }
        if wantsSources { conformances.append("Assay.SourceDecodable") }
        if xmlRootName != nil && formats.xml { conformances.append("Assay.XMLRooted") }

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
            // `formats: []` means NO decode body, and it is a real configuration rather
            // than a mistake to correct. A type decoded by something else — a Parquet or
            // CSV reader that knows its own layout — still wants `@Validate` rules and
            // `T.validate(_:)`, and making it carry a JSON decoder it will never call costs
            // it the full per-field expansion (docs/VALIDATE.md §4). The case where this
            // really would produce nothing useful is caught at expansion instead, where the
            // diagnostic can say so.
            if names.isEmpty { return (false, false, false) }
            let json = names.contains("json")
            let raw = names.contains("yaml") || names.contains("xml")
            // An unrecognised name falls back rather than silently emitting nothing.
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

    /// `@XML(root: "book")` on the TYPE, or nil when unannotated.
    ///
    /// Read from the declaration's own attribute list rather than from `@Schema`'s
    /// arguments, because that is where the specified spelling puts it. The peer macro
    /// itself expands to nothing — it exists so the attribute is legal and so this can find
    /// it, exactly like `@XML(_ placement:)` on a var.
    static func xmlRoot(from decl: some DeclGroupSyntax) -> String? {
        for attr in decl.attributes.compactMap({ $0.as(AttributeSyntax.self) })
        where attr.attributeName.trimmedDescription == "XML" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self),
                  let first = args.first, first.label?.text == "root",
                  let lit = first.expression.as(StringLiteralExprSyntax.self) else { continue }
            return lit.segments.trimmedDescription
        }
        return nil
    }

    /// `@Schema(context: AppContext.self)` — EXPERIENCE.md §10.
    ///
    /// Returns the context type's NAME, or `""` for the overwhelming majority of types that
    /// declare none. `""` rather than `nil` because every consumer interpolates it into
    /// generated text, and `""` is the identity there: a context-free type must expand to
    /// BYTE-IDENTICAL code to what it expanded to before this feature existed.
    ///
    /// The macro reads a token. It cannot check that `AppContext` is a type, is `Sendable`,
    /// or has the members the checks call — the type checker does all three at the use site,
    /// which is also where the error is legible.
    static func contextType(from node: AttributeSyntax) -> String {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return "" }
        for arg in args where arg.label?.text == "context" {
            var t = arg.expression.trimmedDescription
            if t.hasSuffix(".self") { t.removeLast(5) }
            return t
        }
        return ""
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
        let oneOrMany = attrNames.contains("OneOrMany")
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
        var pathSegments: [String]?
        for attr in attrs where attr.attributeName.trimmedDescription == "Key" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self) else { continue }
            for (i, arg) in args.enumerated() {
                guard let lit = arg.expression.as(StringLiteralExprSyntax.self) else { continue }
                let value = lit.segments.description
                if arg.label?.text == "path" {
                    guard let segs = Self.pathSegments(value, node: Syntax(attr),
                                                       context: context) else { return nil }
                    pathSegments = segs
                    // The LAST segment is the wire key. Every message that names a key —
                    // did-you-mean, `.missing`, the renderers' carets — then names the key
                    // that was actually looked for, with the path components carrying where.
                    wireKey = segs[segs.count - 1]
                } else if i == 0 && arg.label == nil {
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
            oneOrMany: oneOrMany,
            inverse: inverse,
            dateFormats: dateFormats,
            pathSegments: pathSegments)
    }

    /// Split and check a `@Key(path:)` string. Returns nil having diagnosed.
    ///
    /// Everything refused here is refused because the generated walk could not honour it,
    /// not because it is unusual — and each diagnostic names what to write instead, since a
    /// macro that says only "invalid" leaves the author to guess at the model.
    static func pathSegments(
        _ raw: String, node: Syntax, context: some MacroExpansionContext
    ) -> [String]? {
        func fail(_ m: String) -> [String]? {
            context.diagnose(Diagnostic(node: node, message: SimpleDiagnostic(m)))
            return nil
        }
        // No Foundation in the macro target, so this splits by hand.
        var segments: [String] = []
        var current = ""
        for ch in raw {
            if ch == "." { segments.append(current); current = "" } else { current.append(ch) }
        }
        segments.append(current)

        guard segments.count >= 2 else {
            return fail("@Key(path: \"\(raw)\") has no `.` in it, so it names a top-level key "
                + "— write @Key(\"\(raw)\") instead. A path exists to reach THROUGH an "
                + "intermediate object.")
        }
        guard !segments.contains(where: \.isEmpty) else {
            return fail("@Key(path: \"\(raw)\") has an empty segment. Every segment must name "
                + "a key.")
        }
        if let bad = segments.first(where: { $0.contains("[") || $0.contains("]") }) {
            return fail("@Key(path: \"\(raw)\") uses an index segment (`\(bad)`), which is not "
                + "built. Walking a key and indexing an array are different operations: an "
                + "index needs the element counted during the array's own decode, and needs a "
                + "fourth answer for \"the array was shorter than that\". Declare the array and "
                + "take the element in Swift, or use a nested @Schema type.")
        }
        return segments
    }
}
