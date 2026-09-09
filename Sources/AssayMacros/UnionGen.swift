// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Schema(discriminator: "type")` — discriminated unions. `docs/UNIONS.md`, EXPERIENCE §9.
//
//     @Schema(discriminator: "type")
//     enum Event {
//         case click(ClickEvent)
//         case pageView(PageViewEvent)
//         case purchase(PurchaseEvent)
//     }
//
// THE TAGGED FORM ONLY, and that is a build-order decision rather than a partial one.
// `docs/UNIONS.md` §6: three of that document's four hard questions do not apply to a
// discriminated union. There is no composed failure to report (once the tag is read exactly
// one branch is possible, so the branch's issues *are* the union's issues), no backtracking to
// bound (one attempt, always), and no round-trip exception (the tag names the branch, so
// encoding is unambiguous). The untagged form has all three and rests on the same rewind
// primitive; it is a strictly larger job and is not built.
//
// SCAN, REWIND, DECODE. `{"a": 1, "type": "click"}` is legal, so the tag can arrive last and
// the branch cannot be chosen by reading forward. `scanDiscriminator` reads keys and skips
// values until it finds the tag; the reader is then restored and the chosen branch decodes the
// whole object from the start, tag included. `AssayCore/Discriminator.swift` records what that
// costs and what the alternative (decode to `RawValue` first) would have cost.
//
// `restore(_:)` rather than `seek(to:)`, and the difference is measured — see
// `Tests/AssayTests/RewindTests.swift` and `AssayReader.Mark`. The scan enters a container; a
// malformed document can leave that unbalanced, and depth is not something `seek` puts back.
//
// THE TAG DISPATCH IS A STRING COMPARISON CHAIN, which looks like a violation of hard
// constraint 1 ("never switch over a String") and is not. That rule is about **per-field**
// dispatch inside the decode loop, where it runs once per key of every object and where
// `_findStringSwitchCase`'s linear scan with a full `String ==` per case is the entire cost
// being avoided. This runs **once per union value**, against a handful of variants, on a
// string that has already been materialised. Building a window table for three comparisons
// would cost more in generated code than it could ever save — which is the same trade
// `PathKeys.swift` made for inner path segments, for the same reason.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

struct UnionCase {
    var identifier: String
    /// The wire spelling of the tag, `keys:`-transformed unless `@Key` overrode it.
    var wireName: String
    /// The associated value's type, or nil for a payload-free case.
    var payloadType: String?
}

extension SchemaMacro {

    /// `@Schema(discriminator:)`, or nil when the type is not a union.
    ///
    /// Returns the tag key for the tagged form, and `""` for `.none` — distinguished from
    /// "no discriminator at all" by the outer Optional, because those are three states and
    /// two of them must not be confused.
    static func discriminator(from node: AttributeSyntax) -> String?? {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for arg in args where arg.label?.text == "discriminator" {
            if let lit = arg.expression.as(StringLiteralExprSyntax.self) {
                return .some(lit.segments.description)
            }
            // `.none` — and note this is `Discriminator.none`, not `Optional.none`, which is
            // why the return type is doubly-optional rather than a plain `String?`.
            return .some(nil)
        }
        return nil
    }

    static func unionExpansion(
        of node: AttributeSyntax,
        enumDecl: EnumDeclSyntax,
        typeName: String,
        tag: String?,
        in context: some MacroExpansionContext
    ) -> [ExtensionDeclSyntax] {

        let keyStyle = Self.keyStyle(from: node)
        let formats = Self.formats(from: node)

        let untagged = (tag == nil || tag!.isEmpty)

        var cases: [UnionCase] = []
        var bad = false
        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            let attrs = caseDecl.attributes.compactMap { $0.as(AttributeSyntax.self) }
            var wireOverride: String?
            for a in attrs where a.attributeName.trimmedDescription == "Key" {
                if let args = a.arguments?.as(LabeledExprListSyntax.self),
                   let lit = args.first?.expression.as(StringLiteralExprSyntax.self) {
                    wireOverride = lit.segments.description
                }
            }
            if attrs.contains(where: { $0.attributeName.trimmedDescription == "Unknown" }) {
                context.diagnose(Diagnostic(node: Syntax(caseDecl), message: SimpleDiagnostic(
                    "@Unknown is for a closed string enum's catch-all, and a union's variants "
                    + "carry payloads. An unrecognised tag is reported as "
                    + "`union_unknown_variant` with a did-you-mean; there is nothing for a "
                    + "catch-all case to hold.")))
                bad = true
            }
            for element in caseDecl.elements {
                let name = element.name.text
                guard let params = element.parameterClause?.parameters, params.count == 1 else {
                    context.diagnose(Diagnostic(node: Syntax(element),
                        message: SimpleDiagnostic(
                            "case '\(name)' of a union must carry exactly one associated "
                            + "value — the type that decodes when the tag names this variant.")))
                    bad = true
                    continue
                }
                cases.append(UnionCase(identifier: name,
                                       wireName: wireOverride ?? keyStyle.apply(name),
                                       payloadType: params.first!.type.trimmedDescription))
            }
        }

        guard !bad, !cases.isEmpty else {
            if !bad {
                context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                    "@Schema(discriminator:) needs at least one case.")))
            }
            return []
        }

        if untagged {
            // `docs/UNIONS.md` §4: two cases carrying the SAME payload type make the second
            // unreachable and break round-trip — `.b(1)` encodes as `1` and decodes as
            // `.a(1)`. It is the one union check a macro can do without a conformance lookup,
            // because the tokens are all it needs.
            var seenPayloads = Set<String>()
            for c in cases where !seenPayloads.insert(c.payloadType ?? "").inserted {
                context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                    "two cases both carry a '\(c.payloadType ?? "")', so the second can never "
                    + "be chosen — an untagged union picks the first branch that decodes, and "
                    + "both accept the same documents. Give them a discriminator, or distinct "
                    + "payload types.")))
                return []
            }
        } else {
            // Two variants under one tag spelling would make the second unreachable, silently.
            var seen = Set<String>()
            for c in cases where !seen.insert(c.wireName).inserted {
                context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                    "two cases both spell their tag '\(c.wireName)', so the second can never "
                    + "be chosen. Use @Key on one of them to give it a different tag.")))
                return []
            }
        }

        // `encodes: true` on a union would be silently ignored — the body below emits no
        // encoder — and a silently-ignored option is worse than a refused one.
        if Self.encodes(from: node) {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "@Schema(encodes: true) is not built for unions. docs/UNIONS.md §4 settles "
                + "what it should mean — the payload plus the tag, spelled from the case name "
                + "through `keys:` — but it is design, not code, and emitting nothing while "
                + "accepting the option would be the worse failure.")))
            return []
        }

        guard formats.json else {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "@Schema(discriminator:) is built for the JSON path. The RawValue path — YAML "
                + "and XML — is not built for unions; docs/UNIONS.md.")))
            return []
        }

        let body = untagged
            ? untaggedBody(typeName: typeName, cases: cases)
            : taggedBody(typeName: typeName, cases: cases, tag: tag!)

        let ext = try? ExtensionDeclSyntax(
            "extension \(raw: typeName): Assay.JSONAssayable") {
            DeclSyntax(stringLiteral: body)
        }
        return ext.map { [$0] } ?? []
    }

    static func taggedBody(typeName: String, cases: [UnionCase], tag: String) -> String {
        let known = cases.map { "\"\($0.wireName)\"" }.joined(separator: ", ")
        var arms = ""
        for c in cases {
            arms += """
                    if __tag == "\(c.wireName)" {
                        guard let __v = \(c.payloadType!)._assay(
                            from: &reader, into: &sink, at: path) else { return nil }
                        return .\(c.identifier)(__v)
                    }

            """
        }

        return """
        nonisolated static let __assayVariants: [String] = [\(known)]

        nonisolated public static func _assay(
            from reader: inout Assay.AssayReader,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) -> \(typeName)? {
            // The whole reader state, not just the cursor: the scan enters a container and a
            // malformed document can leave that unbalanced. docs/UNIONS.md §1.
            let __mark = reader.mark
            guard let __tag = reader.scanDiscriminator(&sink, "\(tag)", path) else {
                // RESYNCHRONISE, or the caller reports a second issue this document does not
                // deserve. A failed pre-scan leaves the cursor part-way through the value; the
                // top-level entry point then finds bytes remaining and adds `trailingContent`,
                // and a missing tag is reported as two errors instead of one. Consuming the
                // value here is what the unknown-variant arm below already does, for the same
                // reason — found by a test asserting `issues.count == 1`.
                reader.restore(__mark)
                _ = reader.skipValue(&sink)
                return nil
            }
            reader.restore(__mark)

        \(arms)    // The tag was read and names nothing this enum declares. One issue, with a
            // did-you-mean — not a branch's issues, because no branch was chosen.
            reader.unknownVariant(&sink, path, "\(tag)", __tag, Self.__assayVariants)
            _ = reader.skipValue(&sink)
            return nil
        }
        """
    }
}

extension SchemaMacro {

    /// The untagged body. `docs/UNIONS.md` §§2.2 and 3.
    ///
    /// FIRST SUCCESS WINS, in declaration order — that is what "tries each representation in
    /// order" means, and it is why two cases with the same payload type are refused above.
    ///
    /// THE FAILURE PATH RUNS THE WINNER TWICE, and that is the cheaper of two designs. To
    /// report the closest branch's issues, those issues have to exist; the first pass rolls
    /// every branch back, so nothing survives it. The alternative is snapshotting each
    /// branch's issues into an array of arrays as it goes — an allocation per branch on every
    /// decode, including the ones that succeed on branch one. Replaying costs one extra decode
    /// of a single branch, and only when the whole union has already failed, which is not a
    /// path anything hot goes down.
    ///
    /// The replay deliberately does **not** charge the budget again: it is the same attempt
    /// being re-run for its diagnostics, not a new one.
    ///
    /// **`verboseUnions` suppresses the sink rollback and NOT the reader restore**, which is a
    /// distinction the first version of this got wrong. Verbose mode keeps every branch's
    /// *issues*; it must still rewind the *reader*, or branch two starts wherever branch one
    /// stopped and reports nonsense about a position it was never meant to see. Caught by a
    /// test asserting that verbose mode names a field only the non-closest branch has.
    static func untaggedBody(typeName: String, cases: [UnionCase]) -> String {
        let known = cases.map { "\"\($0.identifier)\"" }.joined(separator: ", ")

        /// One attempt. `keep` is false in the measuring pass and true in the replay.
        func attempt(_ c: UnionCase, indent: String, keep: Bool) -> String {
            let decode: String
            if let call = scalarCall(c.payloadType ?? "", key: c.identifier) {
                // A scalar branch — `case text(String)`, which is EXPERIENCE §9's own example.
                // The case name stands in for the key in any issue, since a union member has
                // no key of its own.
                decode = "reader.\(call)"
            } else {
                decode = "\(c.payloadType!)._assay(from: &reader, into: &sink, at: path)"
            }
            if keep {
                return """
                \(indent)if __closest == "\(c.identifier)" {
                \(indent)    _ = \(decode)
                \(indent)}
                """
            }
            return """
            \(indent)guard reader.chargeUnionAttempt(&sink, path) else { return nil }
            \(indent)if let __v = \(decode) {
            \(indent)    return .\(c.identifier)(__v)
            \(indent)}
            \(indent)__n = sink.checkpoint() - __ck
            \(indent)if __n < __best {
            \(indent)    __best = __n
            \(indent)    __closest = "\(c.identifier)"
            \(indent)}
            \(indent)reader.restore(__mark)
            \(indent)if !__verbose { sink.rollback(to: __ck) }
            """
        }

        let measuring = cases.map { attempt($0, indent: "        ", keep: false) }
            .joined(separator: "\n\n")
        let replay = cases.map { attempt($0, indent: "            ", keep: true) }
            .joined(separator: "\n")

        return """
        nonisolated static let __assayVariants: [String] = [\(known)]

        nonisolated public static func _assay(
            from reader: inout Assay.AssayReader,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) -> \(typeName)? {
            let __mark = reader.mark
            let __ck = sink.checkpoint()
            let __verbose = reader.activeLimits.verboseUnions
            var __best = Int.max
            var __n = 0
            var __closest = ""

        \(measuring)

            // Every branch failed. One summary naming the guess as a guess, then the closest
            // branch replayed so its detail follows it. docs/UNIONS.md §2.2.
            reader.restore(__mark)
            if !__verbose { sink.rollback(to: __ck) }
            reader.noVariantMatched(&sink, path, "\(typeName)", __closest,
                                    Self.__assayVariants)
            if !__verbose {
                reader.restore(__mark)
        \(replay)
            }
            reader.restore(__mark)
            _ = reader.skipValue(&sink)
            return nil
        }
        """
    }
}
