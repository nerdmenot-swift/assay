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
// TAGGED FIRST, and that was a build-order decision rather than a partial one.
// `docs/UNIONS.md` §6: three of that document's four hard questions do not apply to a
// discriminated union. There is no composed failure to report (once the tag is read exactly
// one branch is possible, so the branch's issues *are* the union's issues), no backtracking to
// bound (one attempt, always), and no round-trip exception (the tag names the branch, so
// encoding is unambiguous). The untagged form has all three, rests on the same rewind
// primitive, and followed the same day — `untaggedBody` below. Encoding for both forms landed
// 2026-09-10; the emitters are at the bottom of this file.
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

    static func unionExpansion(
        of node: AttributeSyntax,
        enumDecl: EnumDeclSyntax,
        config: SchemaConfig,
        typeName: String,
        tag: String?,
        in context: some MacroExpansionContext
    ) -> [ExtensionDeclSyntax] {

        let keyStyle = config.keyStyle
        let formats = config.formats

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
                                       wireName: wireOverride ?? keyStyle.apply(Self.unbackticked(name)),
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

        // A union decodes from JSON and only from JSON, so asking for YAML or XML must be
        // refused rather than quietly answered with less than was asked for. `formats.raw`
        // and not just `!formats.json`: `formats: .all` sets both, and testing only the
        // first let `.all` through to emit a JSON-only body — the exact trap the paragraph
        // below says this refusal exists to prevent.
        guard formats.json, !formats.raw else {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "@Schema(discriminator:) is built for the JSON path. The RawValue path — YAML "
                + "and XML — is not built for unions; docs/UNIONS.md.")))
            return []
        }

        // THE OTHER OPTIONS A UNION DOES NOT IMPLEMENT, refused for the reason `encodes:`
        // was until this was built: an option that is accepted and then does nothing is
        // worse than one that is refused. `formats: .all` is the standing proof — the guard
        // above existed, tested the wrong half, and quietly emitted a JSON-only body for
        // `.all` from the day it was written.
        //
        // `context:` is the worst of the two and is why they are checked here rather than
        // left to the call site. `describes:` promises a member that will not
        // exist, so the type checker eventually says so; a contextual union would simply
        // stay NON-contextual — `parse(json:)` still resolves, no error anywhere, and the
        // context silently never reaches a check. That is the same shape as the `@XML(root:)`
        // trap: it compiles and checks nothing.
        if config.describes {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "@Schema(describes: true) is not built for unions — a JSON Schema `oneOf` "
                + "with a discriminator is its own design question, and describing a union "
                + "as anything less exact would break the rule that a description says MORE "
                + "than the type accepts, never less. `jsonSchema(for:)` on the variants "
                + "works today.")))
            return []
        }
        if config.isContextual {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "@Schema(context:) is not built for unions. Accepting it would leave the type "
                + "non-contextual with no error anywhere — `parse(json:)` would still resolve "
                + "and the context would never reach a check. Put the context on the variant "
                + "types, which is where the checks that read it live.")))
            return []
        }

        let wantsEncoding = config.encodes

        var body = untagged
            ? untaggedBody(typeName: typeName, cases: cases)
            : taggedBody(typeName: typeName, cases: cases, tag: tag!)

        var conformances = "Assay.JSONAssayable"
        if wantsEncoding {
            conformances += ", Assay.JSONEncodableSchema"
            body += "\n\n" + (untagged
                ? untaggedEncodeBody(cases: cases)
                : taggedEncodeBody(cases: cases, tag: tag!))
        }

        let ext = try? ExtensionDeclSyntax(
            "extension \(raw: typeName): \(raw: conformances)") {
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
            guard let __tag = reader._scanDiscriminator(&sink, "\(tag)", path) else {
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
            reader._unknownVariant(&sink, path, "\(tag)", __tag, Self.__assayVariants)
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
            \(indent)guard reader._chargeUnionAttempt(&sink, path) else { return nil }
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
            reader._noVariantMatched(&sink, path, "\(typeName)", __closest,
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

// MARK: - Encoding
//
// `docs/UNIONS.md` §4, built 2026-09-10. Both forms, JSON only — which is the same surface
// decoding has, because a union has no `RawValue` path to encode through.
//
// THE TAGGED FORM WRITES THE PAYLOAD'S OBJECT WITH THE TAG ADDED, and the tag is spelled
// from the CASE name through the type's `keys:` style — the same `wireName` the decoder
// dispatches on, so the two cannot drift. That it is one stored spelling rather than two
// derivations is the point: a union that encoded `page_view` and decoded `pageView` would
// satisfy every test written against one side.
//
// THE TAG GOES FIRST. `scanDiscriminator` reads keys until it finds the tag, so a document
// this library wrote is one the fast path finds on its first key. Tag-last would have been
// free (pop the payload's closing brace back off the buffer and append) and would have made
// every round trip pay a full pre-scan.
//
// THE UNTAGGED FORM WRITES THE PAYLOAD ALONE, which is where `ENCODING.md`'s round-trip law
// takes its one union exception: two cases whose payloads accept the same documents make the
// second unreachable on the way back in. The macro refuses the half it can see (the same
// payload TOKEN twice, above); the half it cannot see — two distinct types accepting the same
// documents — is the stated exception in §4.
extension SchemaMacro {

    /// The tagged encoder. `_assayEncodeMembers` exists so a union can be a variant of
    /// another union: the outer one opens the object, writes its tag, and the inner one
    /// writes its own tag and its payload's members into the same object.
    static func taggedEncodeBody(cases: [UnionCase], tag: String) -> String {
        var arms = ""
        for c in cases {
            arms += """
                    case .\(c.identifier)(let __v):
                        w.key("\(tag)")
                        w.write("\(c.wireName)")
                        __v._assayEncodeMembers(into: &w, into: &sink, at: path)

            """
        }
        return """
        nonisolated public func _assayEncodeMembers(
            into w: inout Assay.JSONWriter,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) {
            switch self {
        \(arms)    }
        }

        nonisolated public func _assayEncode(
            into w: inout Assay.JSONWriter,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) {
            w.beginObject()
            self._assayEncodeMembers(into: &w, into: &sink, at: path)
            w.endObject()
        }
        """
    }

    /// The untagged encoder — the payload, and nothing else.
    ///
    /// No `_assayEncodeMembers`, deliberately: a scalar variant has no members, so the
    /// function could only exist for some untagged unions and not others. Emitting it
    /// conditionally would mean an untagged union nested inside a tagged one compiles or
    /// does not depending on a payload type three declarations away, which is worse than
    /// the error the type checker gives for a member that is never emitted.
    static func untaggedEncodeBody(cases: [UnionCase]) -> String {
        var arms = ""
        for c in cases {
            let type = c.payloadType ?? ""
            let write: String
            // WHICH TYPES ARE SCALARS IS ASKED OF `scalarCall`, not restated here. It is
            // what the decode path branches on, so a scalar this encoder did not know about
            // would be a type that decodes and cannot be written back — and the list is
            // exactly the kind that grows (six integer widths arrived in one commit).
            if scalarCall(type, key: c.identifier) == nil {
                // A schema variant. Its own `encodes: true` is enforced by the compiler,
                // and the path does NOT gain a component: a union member has no key.
                write = "__v._assayEncode(into: &w, into: &sink, at: path)"
            } else if type == "Double" || type == "Float" {
                // Q4: NaN and infinity have no JSON spelling. The case name stands in for
                // the key, exactly as it does in the decode path's issues.
                write = "w.write(__v, &sink, path, \"\(c.identifier)\")"
            } else {
                write = "w.write(__v)"
            }
            arms += """
                    case .\(c.identifier)(let __v):
                        \(write)

            """
        }
        return """
        nonisolated public func _assayEncode(
            into w: inout Assay.JSONWriter,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) {
            switch self {
        \(arms)    }
        }
        """
    }
}
