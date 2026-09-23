// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Emitting the decode body.
//
// The shape follows serde's, which simdjson's new reflective path has independently
// converged on: single pass, document order, one local per field, a presence bitmask,
// never rewind. Two state-of-the-art implementations arriving at the same design is
// confirmation, not coincidence — and simdjson explicitly *abandoned* its rewinding
// `find_field_unordered` (O(N^2) worst case) for exactly this.
//
// Presence is a `UInt64` bitmask: missing-required is `~mask & requiredMask`, one AND-NOT
// and one compare against zero, and the fields to report are the set bits, walked only
// in the failure case.
//
// Everything the macro generates is fully qualified (`Assay.AssayReader`, not
// `AssayReader`) because macros are not hygienic.
//===----------------------------------------------------------------------===//

/// The presence bit for field `i`, as a `UInt64` for the generated source.
///
/// **Not `1 << UInt64(i)`.** Inside a string interpolation that expression has no type
/// context, so the `1` defaults to `Int` and bit 63 lands on the sign bit: the macro then
/// emitted `-9223372036854775808` into a `UInt64` presence mask, and a 64-field type — the
/// documented maximum, named in `@Schema`'s own refusal message — did not compile at all.
/// 63 fields worked and 64 did not, which is the kind of boundary nothing reaches by
/// accident. Found 2026-09-13 by a field-count sweep built to test something else.
@inlinable
func presenceBit(_ i: Int) -> UInt64 { UInt64(1) << UInt64(i) }

extension SchemaMacro {

    static func decodeBody(
        typeName: String,
        fields: [SchemaField],
        plan: WindowPlan?,
        extras: SchemaField? = nil,
        policy: String = "ignore",
        ordered: [SchemaField]? = nil,
        validation: String = "",
        checks: String = "",
        /// `@Key(path:)` groups. Empty for the overwhelming majority of schemas, and when
        /// it is empty nothing below emits a byte that was not emitted before.
        groups: [PathGroup] = [],
        /// The `@Schema(context:)` type name, or `""` when none was declared. Empty is the
        /// overwhelming case and must emit BYTE-IDENTICAL code to before, or every existing
        /// type pays for a feature it does not use.
        ctx: String = ""
    ) -> String {
        var out = ""
        // `, context: <T>` on the signature when a context was declared. `ctx` is the
        // matching ARGUMENT text for nested calls; they are always both set or both empty.
        let ctxParam = ctx.isEmpty ? "" : ",\n            context: \(ctx)"

        // The known-key list, for did-you-mean. Emitted ONLY for the policies that need
        // it — docs/COMPILE-TIME.md §3 rule 1: never emit code a schema will not use, and
        // N string literals per type is not free.
        if policy == "warn" || policy == "reject" {
            let names = fields.flatMap { [$0.wireKey] + $0.aliases }
                .map { "\"\($0)\"" }.joined(separator: ", ")
            out += """
            nonisolated static let __assayKnownKeys: [String] = [\(names)]


            """
        }

        // The 256-entry window table, when the search succeeded. A `static let` global is
        // `swift_once`-protected and free after the first access.
        if let plan {
            // Emit only the POPULATED entries and fill the rest at static-init time.
            //
            // The obvious encoding — a 256-element array literal — is a compile-time
            // trap: the type checker has to check 256 integer literals per schema type,
            // and that dominated the measured per-expansion cost (see
            // Experiments/03-compile-time/RESULTS.md). A struct has at most 64 fields, so
            // the sparse form is at most 64 assignments and usually 5-15.
            //
            // Runtime behaviour is identical: a contiguous 256-byte table, one indexed
            // load. The `static let` is swift_once-protected and free after first access.
            //
            // The sentinel is the number of DISPATCH ARMS, not the number of fields, and
            // those differ the moment `@Key(path:)` is used — two fields under one prefix
            // share one arm. Getting it wrong is not a correctness bug (the `default:` arm
            // still catches it) but a compile-time one: the sparse emitter writes every
            // entry that differs from the sentinel, so a mismatched sentinel writes 253 of
            // them. Caught by expanding a path schema and reading the output, which is the
            // only way it shows up.
            let sentinel = fields.filter { $0.pathSegments == nil }.count + groups.count
            var assigns = ""
            for (value, index) in plan.table.enumerated()
            where index != UInt8(sentinel) {
                assigns += "        t[\(value)] = \(index)\n"
            }
            out += """
            nonisolated static let __assayKeyTable: [UInt8] = {
                var t = [UInt8](repeating: \(sentinel), count: 256)
            \(assigns)    return t
            }()


            """
        }

        // Locals: one per field. A default initialiser goes straight in, because `= 3` is
        // consulted on absence only.
        var locals = ""
        var requiredMask: UInt64 = 0
        for (i, f) in fields.enumerated() {
            let base = f.decodedType
            if let d = f.defaultExpr {
                locals += "    var __f\(i): \(base)? = \(d)\n"
            } else {
                locals += "    var __f\(i): \(base)? = nil\n"
            }
            // Required = not optional, no default, no fallback. All three are absent-safe.
            if !f.isOptional && f.defaultExpr == nil && f.fallback == nil {
                requiredMask |= (1 << UInt64(i))
            }
        }

        for (i, f) in fields.enumerated() where f.needsSpan {
            locals += "    var __sp\(i): Assay.SourceSpan? = nil\n"
        }
        if let e = extras {
            let value = stripOptional(e.typeName)
            locals += "    \(policy == "collect" ? "var" : "let") __extras: \(value) = [:]\n"
        }

        // Dispatch.
        let unknown = unknownArm(policy: policy, extras: extras)
        let entries = dispatchEntries(fields: fields, groups: groups, ctx: ctx,
                                      salt: shapeSalt(typeName))
        let dispatch = plan.map { windowDispatch(entries: entries, plan: $0, unknown: unknown) }
            ?? lengthBucketDispatch(entries: entries, unknown: unknown)

        // Missing-required reporting, walked only when the mask says something is absent.
        // A `@Key(path:)` field is NOT reported here: its absence has three meanings, and
        // `PathTree.presenceChecks` emits the nested tests that tell them apart.
        var missing = PathTree.presenceChecks(groups, fields: fields, indent: 8)
        for (i, f) in fields.enumerated()
        where f.pathSegments == nil && (requiredMask & (1 << UInt64(i))) != 0 {
            missing += """
                    if __presence & \(presenceBit(i)) == 0 {
                        reader._missingRequired(&sink, path, "\(f.wireKey)")
                    }

            """
        }

        // Construction: locals into one memberwise init. Preferred over field-by-field
        // mutation, which triggers `begin_cow_mutation` per assignment on any struct
        // holding an Array, and pays release-old/retain-new per field.
        // Arguments in DECLARATION order, which is what the synthesised memberwise
        // initializer requires — @Extras sits wherever the user wrote it, not first.
        var indexOf: [String: Int] = [:]
        for (i, f) in fields.enumerated() { indexOf[f.identifier] = i }

        let args = Self.constructionArgs(fields: fields, ordered: ordered, indexOf: indexOf)

        var unwraps = ""
        for (i, f) in fields.enumerated() where !f.isOptional {
            unwraps += "        guard let __v\(i) = __f\(i) else { return nil }\n"
        }

        // NOT @inlinable, and that is deliberate rather than an omission.
        //
        // docs/PERFORMANCE.md §8.2 requires @inlinable on Assay's *runtime primitives*,
        // because those live in the Assay module and must reach the user's SILModule to
        // specialize. This body is different: it is already emitted into the user's
        // module and is already concrete and monomorphic, so there is nothing for
        // inlinability to buy.
        //
        // It also actively breaks. SE-0193 restricts an @inlinable body to referencing
        // ABI-public declarations, and the memberwise initializer of a public struct is
        // *internal*. Marking this @inlinable makes every public @Schema type fail to
        // compile with "initializer ... is internal and cannot be referenced from an
        // '@inlinable' function". Found by the compile-time harness, not by reasoning.
        // One assertion per nested type, so a type that is not a schema fails with a
        // diagnostic naming `JSONAssayable` rather than `has no member '_assay'`. Skipped
        // for a contextual parent: its nested types may conform to the contextual
        // protocol instead and resolve through the defaulted overload.
        let requires = ctx.isEmpty
            ? nestedNominalTypes(fields).map { "    Assay._assayRequireJSON(\($0).self)\n" }.joined()
            : ""
        // Every "wrong type for a container" arm below CONSUMES the value after reporting
        // it, as a scalar mismatch always did: the entry check here, the array arm and the
        // dictionary arm. Until 2026-09-19 none of them did, so the caller read the value
        // where it expected ',' or '}', and every later issue in the document was replaced by
        // one false `malformed_document` — `diagnose` stopped collecting at the first
        // wrong-typed array, object or map. InoutPathTests pins it.
        out += """
        nonisolated public static func _assay(
            from reader: inout Assay.AssayReader,
            into sink: inout Assay.IssueSink,
            at path: inout [Assay.PathComponent]\(ctxParam)
        ) -> \(typeName)? {
        \(requires)\(groups.isEmpty ? "" : """
            let __pathDepth = path.count
            defer { if path.count > __pathDepth { path.removeSubrange(__pathDepth...) } }

        """)    guard reader.tryConsume(0x7B) else {
                reader.reportTypeMismatch(&sink, path, expected: "object")
                _ = reader.skipValue(&sink)
                return nil
            }
            guard reader.enterContainer(&sink) else { return nil }
            // Issues THIS decode added, not issues that exist. `sink.isValid` asks "has
            // anything ever failed?", which is wrong the moment one sink spans more than
            // one decode — a driver collecting every issue from a result set would find
            // one bad row silently discarding every good row after it.
            let __ck0 = sink.checkpoint()

        \(locals)    var __presence: UInt64 = 0\(groups.isEmpty ? "" : "\n    var __gpresence: UInt64 = 0")

            if !reader.tryConsume(0x7D) {
                while true {
                    guard let __key = reader.scanKey() else {
                        reader.reportMalformed(&sink, path, expected: "a key in double quotes")
                        reader.leaveContainer()
                        return nil
                    }
                    guard reader.expect(0x3A) else {
                        reader.reportMalformed(&sink, path, expected: "':' after the key")
                        reader.leaveContainer()
                        return nil
                    }
        \(dispatch)
                    if reader.tryConsume(0x2C) { continue }
                    break
                }
                guard reader.tryConsume(0x7D) else {
                    reader.reportMalformed(&sink, path, expected: "',' or '}'")
                    reader.leaveContainer()
                    return nil
                }
            }
            reader.leaveContainer()

        \(missing)
        \(validation)
        \(unwraps)    let __result = \(typeName)(\(args.joined(separator: ", ")))
        \(checks)
            guard sink.checkpoint() == __ck0 else { return nil }
            return __result
        }
        """

        return out
    }

    /// What the `default:` arm does with a key the schema did not declare.
    ///
    /// `.ignore` is the default and stays allocation-free: the key is never materialised
    /// as a `String`, the value is skipped structurally. The other three all need the key
    /// as a String, which is unavoidable — an unknown key has no compile-time literal to
    /// have been matched against.
    static func unknownArm(policy: String, extras: SchemaField?) -> String {
        switch policy {
        case "collect":
            guard let e = extras else { return "_ = reader.skipValue(&sink)" }
            let value = elementType(stripOptional(e.typeName))
            return """
            let __uk = reader._keyString(__key)
                                if let __uv = Assay._assayCollect(
                                    \(value).self,
                                    from: &reader, into: &sink, at: path + [.key(__uk)]) {
                                    __extras[__uk] = __uv
                                }
            """
        case "warn":
            return """
            reader._reportUnknownKey(&sink, path, __key,
                                                        known: Self.__assayKnownKeys,
                                                        reject: false)
                                _ = reader.skipValue(&sink)
            """
        case "reject":
            return """
            reader._reportUnknownKey(&sink, path, __key,
                                                        known: Self.__assayKnownKeys,
                                                        reject: true)
                                _ = reader.skipValue(&sink)
            """
        default:
            return "_ = reader.skipValue(&sink)"
        }
    }

    /// `[String: RawValue]` -> `RawValue`.
    static func elementType(_ dict: String) -> String {
        guard dict.hasPrefix("["), dict.hasSuffix("]"),
              let colon = dict.firstIndex(of: ":") else { return "Assay.RawValue" }
        return String(dict[dict.index(after: colon)..<dict.index(before: dict.endIndex)])
            .trimmingWhitespace()
    }

    /// A per-type offset into the reader's container-size hint table, so two types' field 0
    /// do not fight over one slot. FNV-1a over the type name, and a collision is harmless
    /// anyway: a hint only sizes a reservation, and no decoded value depends on it.
    static func shapeSalt(_ typeName: String) -> Int {
        var h: UInt32 = 2_166_136_261
        for b in typeName.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Int(h & 0xFF)
    }

    // MARK: Dispatch shapes

    /// Build the top-level arms: one per ordinary field, one per `@Key(path:)` group.
    ///
    /// A field that belongs to a group does NOT get an arm of its own — its key never
    /// appears at the top level. It is reached through the group's descent, which is what
    /// keeps this single-pass.
    static func dispatchEntries(
        fields: [SchemaField], groups: [PathGroup], ctx: String, salt: Int = 0
    ) -> [DispatchEntry] {
        let pad = String(repeating: " ", count: 24)
        var out: [DispatchEntry] = []
        for (i, f) in fields.enumerated() where f.pathSegments == nil {
            out.append(DispatchEntry(
                keys: [f.wireKey] + f.aliases,
                body: pad + "__presence |= \(presenceBit(i))\n"
                    + decodeStatement(field: f, index: i, indent: 24, ctx: ctx, salt: salt)))
        }
        for (g, group) in groups.enumerated() {
            out.append(DispatchEntry(
                keys: [group.segment],
                body: pad + "__gpresence |= \(presenceBit(g))\n"
                    + pathDescent(group.node, fields: fields, prefix: [group.segment],
                                  depth: 0, indent: 24, ctx: ctx, salt: salt)))
        }
        return out
    }

    /// The descent for one path group: consume an object and dispatch on the next segment.
    ///
    /// `path` is PUSHED on entry to the block and popped on the way out, so every nested
    /// emitter reports at the deeper path with no change to any of them. Until 2026-09-19 it
    /// was shadowed (`let path = path + [.key("profile")]`), which allocated a new array per
    /// group per element; the path is `inout` now (see `JSONAssayable`). An early `return`
    /// inside the block — a malformed object, or a malformed array anywhere below — skips the
    /// pop, so a body with groups also restores the path's depth in a `defer` (`decodeBody`).
    ///
    /// The three failure shapes are the three branches, and their reasoning is in
    /// `PathKeys.swift`'s header: an object descends, a null or absence leaves the slots
    /// unset (absence, handled by the presence rules), anything else is a type mismatch
    /// reported at the segment and skipped so the outer loop stays synchronised.
    static func pathDescent(
        _ node: PathNode, fields: [SchemaField], prefix: [String],
        depth: Int, indent: Int, ctx: String, salt: Int = 0
    ) -> String {
        let pad = String(repeating: " ", count: indent)
        let key = "__pk\(depth)"
        let segment = prefix[prefix.count - 1]

        var arms = ""
        for (seg, i) in node.leaves {
            arms += """
            \(pad)                if reader.keyMatches(\(key), "\(seg)") {
            \(pad)                    __presence |= \(presenceBit(i))
            \(decodeStatement(field: fields[i], index: i, indent: indent + 20, ctx: ctx, salt: salt))
            \(pad)                } else

            """
        }
        for (seg, child) in node.children {
            arms += """
            \(pad)                if reader.keyMatches(\(key), "\(seg)") {
            \(pad)                    __gpresence |= \(presenceBit(child.bit))
            \(pathDescent(child, fields: fields, prefix: prefix + [seg],
                          depth: depth + 1, indent: indent + 20, ctx: ctx, salt: salt))
            \(pad)                } else

            """
        }

        return """
        \(pad)if reader.tryConsume(0x7B) {
        \(pad)    path.append(.key("\(segment)"))
        \(pad)    if !reader.tryConsume(0x7D) {
        \(pad)        while true {
        \(pad)            guard let \(key) = reader.scanKey(), reader.expect(0x3A) else {
        \(pad)                reader.reportMalformed(&sink, path, expected: "a key and ':'")
        \(pad)                reader.leaveContainer()
        \(pad)                return nil
        \(pad)            }
        \(arms)\(pad)                {
        \(pad)                    _ = reader.skipValue(&sink)
        \(pad)                }
        \(pad)            if reader.tryConsume(0x2C) { continue }
        \(pad)            break
        \(pad)        }
        \(pad)        guard reader.tryConsume(0x7D) else {
        \(pad)            reader.reportMalformed(&sink, path, expected: "',' or '}'")
        \(pad)            reader.leaveContainer()
        \(pad)            return nil
        \(pad)        }
        \(pad)    }
        \(pad)    path.removeLast()
        \(pad)} else if reader._consumeNullIfPresent() {
        \(pad)    // An explicit null intermediate is absence, same as a missing one: the
        \(pad)    // slots below stay unset and the presence rules decide what that means.
        \(pad)} else {
        \(pad)    reader.reportTypeMismatch(&sink, path + [.key("\(segment)")], expected: "object")
        \(pad)    _ = reader.skipValue(&sink)
        \(pad)}
        """
    }

    /// One arm of the top-level key dispatch.
    ///
    /// Introduced for `@Key(path:)`, and the reason it exists is that an arm is no longer
    /// one-to-one with a field. A path group — every field whose path starts `profile.` —
    /// is a single arm that descends and may fill several slots, so the dispatcher can no
    /// longer index `fields` by the case number. Making the arm carry its own body is what
    /// lets a path be a *tree of the existing dispatch table* rather than a second pass.
    ///
    /// `body` arrives pre-indented to 24 columns, which is where the dispatchers splice it.
    struct DispatchEntry {
        /// The wire keys that select this arm — a field's key and its aliases, or a path
        /// group's first segment.
        var keys: [String]
        var body: String
    }

    /// The match for one wire key. An alias's match also records which alias it was —
    /// through the reader, in one expression, so the decode body is emitted once.
    static func keyCondition(_ key: String, primary: String, isAlias: Bool) -> String {
        isAlias
            ? "reader._aliasMatched(__key, \"\(key)\", &sink, path, \"\(primary)\")"
            : "reader.keyMatches(__key, \"\(key)\")"
    }

    static func windowDispatch(entries: [DispatchEntry], plan: WindowPlan,
                               unknown: String = "_ = reader.skipValue(&sink)") -> String {
        var arms = ""
        for (i, e) in entries.enumerated() {
            let cond = e.keys.enumerated().map { keyCondition($1, primary: e.keys[0], isAlias: $0 > 0) }
                .joined(separator: " || ")
            arms += """
                            case \(i):
                                if \(cond) {
            \(e.body)
                                } else {
                                    \(unknown)
                                }

            """
        }
        return """
                        let __w = reader._keyWindow(
                            __key,
                            byteOffset: \(plan.byteOffset),
                            shift: \(plan.shift))
                        switch Self.__assayKeyTable[Int(__w)] {
        \(arms)                default:
                            \(unknown)
                        }
        """
    }

    /// The smallest length bucket that gets its own window instead of a linear chain.
    /// Two keys are at most two compares, which a window load plus a switch does not beat.
    static let bucketWindowMinimum = 3

    /// The expected chain cost, in bytes compared (`WindowSearch.chainCost`), above which a
    /// bucket gets a window. Calibrated on the field sweep: every bucket of a 48-name
    /// realistic set scores 1.0-4.2 and gained nothing; `k00…` scores 14.8 at 12 keys
    /// (gained 6%) and 18.8 at 16 (10%). The gap between them is where this sits.
    static let bucketWindowCost = 8.0

    /// The fallback when no single 8-bit window separates the key set: bucket by length,
    /// then dispatch within the bucket. Length bucketing separates `created_at` from
    /// `created_at_ms` for free.
    ///
    /// Inside a bucket of three or more keys whose chain would be EXPENSIVE — keys sharing
    /// long prefixes, like `k00…k63` or `created_at/created_by/created_on` — the dispatch
    /// is a window again, a per-bucket one from `WindowSearch.bucketSearch`, so what remains
    /// linear is a collision group, not the bucket. A cheap chain is left alone: the window
    /// costs compile time on every type it is emitted into, and on keys whose first bytes
    /// differ it buys no runtime at all. Until 2026-09 it was the bucket: the global window gives out at
    /// about a dozen fields, and past that every lookup was a chain of `keyMatches` whose
    /// length grew with the struct. The inner switch is over `UInt8` literals, which rule 2
    /// (experiment #1) says lowers to a search tree or a jump table, never a scan.
    static func lengthBucketDispatch(entries: [DispatchEntry],
                                     unknown: String = "_ = reader.skipValue(&sink)") -> String {
        var byLength: [Int: [(DispatchEntry, String)]] = [:]
        for e in entries {
            for key in e.keys {
                byLength[key.utf8.count, default: []].append((e, key))
            }
        }
        func chain(_ members: [(DispatchEntry, String)]) -> String {
            var checks = ""
            for (e, key) in members {
                checks += """
                                    if \(keyCondition(key, primary: e.keys[0], isAlias: key != e.keys[0])) {
                \(e.body)
                                    } else
                """
            }
            return """
            \(checks) {
                                    \(unknown)
                                }
            """
        }
        var arms = ""
        for len in byLength.keys.sorted() {
            let bucket = byLength[len]!
            if bucket.count >= bucketWindowMinimum,
               WindowSearch.chainCost(bucket.map(\.1)) >= bucketWindowCost,
               let plan = WindowSearch.bucketSearch(bucket.map(\.1)) {
                var inner = ""
                for g in plan.groups {
                    inner += """
                                    case \(g.value):
                    \(chain(g.members.map { bucket[$0] }))

                    """
                }
                arms += """
                                case \(len):
                                    switch reader._keyWindow(__key, byteOffset: \(plan.byteOffset), shift: \(plan.shift)) {
                \(inner)                    default:
                                        \(unknown)
                                    }

                """
                continue
            }
            arms += """
                            case \(len):
                \(chain(bucket))

            """
        }
        return """
                        switch __key.len {
        \(arms)                default:
                            \(unknown)
                        }
        """
    }

    // MARK: Per-field decode

    /// One line per scalar field. Body size is what dominates @Schema's compile cost
    /// (~9ms per field measured, against ~9ms fixed per type), so null handling lives in
    /// the runtime rather than in an `if/else` wrapper emitted per field.
    /// A collection field's span, when a rule needs one: from its first byte to the byte
    /// after its closing bracket, so `.count(1...10)` on an array puts a caret under the
    /// whole array. Scalars take `lastValueSpan` instead; a collection's decode calls
    /// `beginValue` once per ELEMENT and the last one would win. Until 2026-09-10 the
    /// span slot for a rule-carrying array was declared and never written — a caret-less
    /// issue, and a "never mutated" warning in every user's build.
    static func collectionSpan(_ f: SchemaField, _ i: Int, _ pad: String,
                               _ decode: String) -> String {
        guard f.needsSpan else { return decode }
        return """
        \(pad)reader.skipWhitespace()
        \(pad)let __ss\(i) = reader.byteOffset
        \(decode)
        \(pad)__sp\(i) = Assay.SourceSpan(lo: __ss\(i), len: reader.byteOffset &- __ss\(i))
        """
    }

    static func decodeStatement(field f: SchemaField, index i: Int, indent: Int,
                             ctx: String = "", salt: Int = 0) -> String {
        let ctxArg = ctx.isEmpty ? "" : ", context: context"
        let pad = String(repeating: " ", count: indent)
        let base = f.decodedType
        let key = f.wireKey

        if let element = arrayElement(base) {
            return collectionSpan(f, i, pad, arrayDecode(
                element: element, index: i, key: key,
                optional: f.isOptional, pad: pad,
                oneOrMany: f.oneOrMany,
                dateFormatsRef: dateFormatsRef(f, i), ctx: ctx, salt: salt))
        }

        if let value = dictionaryValue(base) {
            return collectionSpan(f, i, pad, dictDecode(
                value: value, index: i, key: key,
                optional: f.isOptional, pad: pad,
                dateFormatsRef: dateFormatsRef(f, i), ctx: ctx, salt: salt))
        }

        // Fields carrying @Validate capture their value's span right after the decode,
        // while the cursor still sits just past it — that is what puts a caret under a
        // failing value rather than only under a malformed one.
        let spanCapture = f.needsSpan ? "\n\(pad)__sp\(i) = reader.lastValueSpan" : ""

        // Date. The runtime returns epoch seconds; `Date(timeIntervalSince1970:)`
        // resolves in the USER's module, where `var x: Date` already required a
        // Foundation flavour to be imported — the seam that keeps the core
        // Foundation-free (Sources/AssayCore/DateFormat.swift's header).
        if isDateType(base) {
            let formats = dateFormatsRef(f, i)
            let wrap = ".map { \(base)(timeIntervalSince1970: $0) }"
            if f.fallback != nil {
                return """
                \(pad)let __fck\(i) = sink.checkpoint()
                \(pad)__f\(i) = reader._decodeDate(&sink, path, "\(key)", \(formats))\(wrap)\(spanCapture)
                \(pad)if __f\(i) == nil { sink.rollback(to: __fck\(i)) }
                """
            }
            if f.isOptional {
                return "\(pad)if let __r = reader._decodeDateOrNull(&sink, path, \"\(key)\", \(formats)) { __f\(i) = __r\(wrap) }"
                    + spanCapture
            }
            return "\(pad)__f\(i) = reader._decodeDate(&sink, path, \"\(key)\", \(formats))\(wrap)"
                + spanCapture
        }

        if f.fallback != nil, let call = scalarCall(base, key: key, coerce: f.coerce) {
            // On any decode issue: roll the issues back and leave the local nil, so the
            // post-loop fallback application fires. "Absent OR invalid becomes the
            // fallback, with a warning" — and parse discards the warning by design.
            return """
            \(pad)let __fck\(i) = sink.checkpoint()
            \(pad)__f\(i) = reader.\(call)\(spanCapture)
            \(pad)if __f\(i) == nil { sink.rollback(to: __fck\(i)) }
            """
        }

        if let call = scalarCall(base, key: key, orNull: f.isOptional, coerce: f.coerce) {
            // The OrNull variants return T?? — .some(nil) for an explicit JSON null,
            // nil for a failure that has already been reported.
            if f.isOptional && f.coerce {
                return """
                \(pad)if reader._consumeNullIfPresent() { __f\(i) = nil } else {
                \(pad)    __f\(i) = reader.\(call)
                \(pad)}\(spanCapture)
                """
            }
            return (f.isOptional
                ? "\(pad)if let __r = reader.\(call) { __f\(i) = __r }"
                : "\(pad)__f\(i) = reader.\(call)") + spanCapture
        }

        // An open value model as a DECLARED field — `var meta: RawValue`. Dictionaries of
        // these already worked; a bare one fell through to the nested-schema branch below
        // and failed with "type 'RawValue' has no member '_assay'". Found by the encoder
        // differential, which needed exactly this shape.
        if isCollectible(base) {
            let call = """
            Assay._assayCollect(
            \(pad)    \(base).self, from: &reader, into: &sink,
            \(pad)    at: path + [.key("\(key)")])
            """
            if f.isOptional {
                return """
                \(pad)if reader._consumeNullIfPresent() { __f\(i) = nil } else {
                \(pad)    __f\(i) = \(call)
                \(pad)}
                """
            }
            return "\(pad)__f\(i) = \(call)"
        }

        // Nested @Schema type. The outer schema knows where it asked the inner one to
        // look, which is how errors keep the right path.
        return """
        \(pad)if reader._consumeNullIfPresent() {
        \(pad)    \(f.isOptional
                    ? "__f\(i) = nil"
                    : "reader._nullNotAllowed(&sink, path, \"\(key)\", \"\(base)\")")
        \(pad)} else {
        \(pad)    path.append(.key("\(key)"))
        \(pad)    __f\(i) = \(base)._assay(
        \(pad)        from: &reader, into: &sink, at: &path\(ctxArg))
        \(pad)    path.removeLast()
        \(pad)}
        """
    }

    /// Array decoding, recursive so that `[[Double]]` and deeper nest correctly.
    ///
    /// `slot` is the lvalue the result is assigned to and `depth` disambiguates the loop
    /// variables, so nesting does not collide on `__arr`/`__e`.
    /// - Parameter oneOrMany: `@OneOrMany` — accept a single value in place of an array.
    ///   Emitted only at depth 0 on the JSON byte path: the `RawValue` path is already
    ///   tolerant unconditionally, because XML spells a sequence as repeated siblings and a
    ///   lone one is indistinguishable from a YAML scalar at that layer.
    static func arrayDecode(element: String, index i: Int, key: String,
                            optional: Bool, pad: String,
                            slot: String? = nil, depth: Int = 0,
                            oneOrMany: Bool = false,
                            dateFormatsRef: String = "Assay.DateFormat.defaultFormats",
                             ctx: String = "", salt: Int = 0) -> String {
        let ctxArg = ctx.isEmpty ? "" : ", context: context"
        let target = slot ?? "__f\(i)"
        let arr = "__arr\(i)_\(depth)"
        let elt = "__e\(i)_\(depth)"
        // The element's POSITION, counted whether or not it decoded. This was `arr.count`,
        // the number decoded so far, until 2026-09-19, so every element after a failed one
        // was reported one index too low: element 2 of `[bad, ok, bad]` came out as
        // `items[1]`. Found by InoutPathTests; nothing had asserted a path past a failure.
        let ix = "__ix\(i)_\(depth)"
        // ONE PATH PER ARRAY, NOT ONE PER ELEMENT.
        //
        // This emitted `at: path + [.key("k"), .index(n)]` per element until 2026-09-13.
        // `Array.+` always heap-allocates and copies the parent — there is no elision —
        // and the result is read only when the document is malformed. Measured against the
        // same generated `_assay` over 200 three-field structs: **77.1 ns/element before,
        // 30.3 after**, so the array-of-nested-structs body was spending 60% of its time
        // building diagnostics for a document that decodes cleanly.
        //
        // It is the fourth place this exact mistake has been found and the first one on the
        // generated path — the one the performance thesis is about. `JSON.Value.parse` and
        // `validate(_:)` already carry the push/descend/pop shape, and their headers say so.
        //
        // Rewriting the last component in place keeps the buffer uniquely referenced, so
        // there is no CoW on the happy path. If an element DOES report an issue, `Issue`
        // retains the array and the next write copies once — correct, and only when
        // something has already gone wrong.
        let epath = "__ap\(i)_\(depth)"

        // `@OneOrMany`: one value where an array was declared. Emitted before the mismatch
        // arm so a scalar is taken rather than refused, and ONLY when the field asked --
        // silent tolerance is how a payload drifts shape without anyone noticing.
        var single = ""
        var singleClose = ""
        if oneOrMany, let call = scalarCall(element, key: key) {
            single = """
            if let \(elt) = reader.\(call) {
            \(pad)        \(target) = [\(elt)]
            \(pad)    } else {
            \(pad)
            """
            singleClose = "    }\n        \(pad)"
        }

        // A date, nested array or dictionary element reports against the FIELD (and, one
        // level in, its own index or key); the position in THIS array is put in after the
        // fact, on the failure path only. `grid[1][1]` read `grid[1]` (the inner index
        // alone) and a date element named no element at all until 2026-09-19.
        let ck = "__ack\(i)_\(depth)"
        let mark = "\(pad)        let \(ck) = sink.checkpoint()\n"
        let insertIndex = "\(pad)        if sink.checkpoint() != \(ck) { sink._insert(since: \(ck), .index(\(ix)), at: path.count + 1) }\n"
        let inner: String
        if isDateType(element) {
            inner = mark + "\(pad)        if let \(elt) = reader._decodeDate(&sink, path, \"\(key)\", \(dateFormatsRef)).map({ \(element)(timeIntervalSince1970: $0) }) { \(arr).append(\(elt)) }\n" + insertIndex
        } else if let call = scalarCall(element, key: key, elementIndex: ix) {
            // `arr.count` is the index this element is about to occupy, which is exactly
            // the position a reader needs to be told about.
            inner = "\(pad)        if let \(elt) = reader.\(call) { \(arr).append(\(elt)) }\n"
        } else if let sub = arrayElement(element) {
            // Nested array. Decode into a local, then append it.
            inner = mark + """
            \(pad)        var \(elt): [\(sub)]? = nil
            \(arrayDecode(element: sub, index: i, key: key, optional: false,
                          pad: pad + "        ", slot: elt, depth: depth + 1,
                          dateFormatsRef: dateFormatsRef, ctx: ctx, salt: salt))
            \(pad)        if let \(elt) = \(elt) { \(arr).append(\(elt)) }

            """ + insertIndex
        } else if let sub = dictionaryValue(element) {
            // [[String: Int]] — a dictionary element inside an array.
            inner = mark + """
            \(pad)        var \(elt): [String: \(sub)]? = nil
            \(dictDecode(value: sub, index: i, key: key, optional: false,
                         pad: pad + "        ", slot: elt, depth: depth + 1,
                         dateFormatsRef: dateFormatsRef, ctx: ctx, salt: salt))
            \(pad)        if let \(elt) = \(elt) { \(arr).append(\(elt)) }

            """ + insertIndex
        } else {
            inner = """
            \(pad)        \(epath)[\(epath).count &- 1] = .index(\(ix))
            \(pad)        if let \(elt) = \(element)._assay(
            \(pad)            from: &reader, into: &sink, at: &\(epath)\(ctxArg)) { \(arr).append(\(elt)) }

            """
        }

        // Emitted ONLY for the arm that reads it — a scalar or dictionary element never
        // touches `epath`, and an unused local is a warning in a consumer's build.
        let epathDecl = inner.containsSubstring(epath)
            ? """
              \(pad)    var \(epath) = path
              \(pad)    \(epath).append(.key("\(key)"))
              \(pad)    \(epath).append(.index(0))

              """
            : ""

        // EVERY ARRAY TAKES A HINT: what the last array at this site held, remembered on the
        // SINK for one parse (`_shapeHint`/`_noteShape`, whose comment says why the sink and
        // not the reader). A document of sibling records teaches the first record's size to
        // every record after it, and it cannot amplify — a container over-reserves only after
        // a larger one at the same site, by at most that one's size.
        //
        // AN ARRAY OF SCALARS RESERVED EXACTLY INSTEAD, from a structural pre-count
        // (`AssayReader._countArrayElements`), for one day. **That decision is REVERSED
        // 2026-09-20 and the reason is worth keeping** (docs/EFFICIENCY.md row 2): the
        // pre-count is a second pass over the array's bytes, and its cost grows with the
        // array while the reallocations it saves do not — a doubling chain is log(n) mallocs
        // and ~2n element copies of vectorised `memmove`, against n bytes of byte-at-a-time
        // structural scan. It measured as a WIN because the only matrix cell with an array of
        // scalars holds TEN elements per array (`array-10`): −18.2% instructions there. The
        // corpus, whose arrays run 73 to 9,510 elements, measured the truth —
        // `arrays-of-scalars` decode +22.8% to +39.5% slower, `floats-dense` +10%,
        // `long-strings` +19%, 45 cells slower against 25 faster by at most 5.7%, and the
        // published full-corpus mean 8.99× → 8.16×. A matrix cell (`array-640`) now carries a
        // long array so the counters see what the clock saw.
        //
        // The hint costs nothing per element and keeps the win where it was real: `array-10`
        // has 2,000 arrays at one site, so every one after the first reserves exactly.
        //
        // The slot is a literal: `(field index, depth)` is the unique compile-time identity of
        // every array and dictionary site in a body, plus a per-type salt.
        let slot = (salt ^ ((i << 3) | Swift.min(depth, 7))) & 0xFF
        let precount = "\(pad)        \(arr).reserveCapacity(sink._shapeHint(\(slot)))\n"
        let note = "\(pad)    sink._noteShape(\(arr).count, \(slot))\n"
        let usesIx = inner.containsSubstring(ix)
        let ixDecl = usesIx ? "\(pad)    var \(ix) = 0\n" : ""
        let ixStep = usesIx ? "\(pad)            \(ix) &+= 1\n" : ""
        return """
        \(pad)if reader.tryConsume(0x5B) {
        \(pad)    var \(arr): [\(element)] = []
        \(ixDecl)\(epathDecl)\(pad)    if !reader.tryConsume(0x5D) {
        \(precount)\(pad)        while true {
        \(inner)\(ixStep)\(pad)            if reader.tryConsume(0x2C) { continue }
        \(pad)            break
        \(pad)        }
        \(pad)        guard reader.tryConsume(0x5D) else {
        \(pad)            reader.reportMalformed(&sink, path, expected: "',' or ']'")
        \(pad)            reader.leaveContainer()
        \(pad)            return nil
        \(pad)        }
        \(pad)    }
        \(note)\(pad)    \(target) = \(arr)
        \(pad)} else if reader._consumeNullIfPresent() {
        \(pad)    \(optional ? "\(target) = nil" : "reader._nullNotAllowed(&sink, path, \"\(key)\", \"array\")")
        \(pad)} else {
        \(pad)\(single)    // Names the FIELD. This passed a bare `path` until 2026-09-08, so a
        \(pad)\(single.isEmpty ? "" : "    ")// whole-value mismatch on a collection reported an issue whose path
        \(pad)\(single.isEmpty ? "" : "    ")// was EMPTY at the top level -- worse than the missing element index
        \(pad)\(single.isEmpty ? "" : "    ")// this change set out to fix, and found by a test written for that.
        \(pad)\(single.isEmpty ? "" : "    ")reader.reportTypeMismatch(&sink, path + [.key("\(key)")], expected: "array")
        \(pad)\(single.isEmpty ? "" : "    ")_ = reader.skipValue(&sink)
        \(pad)\(singleClose)}

        """
    }

    /// Dictionary decoding, emitted like `arrayDecode` and mutually recursive with it,
    /// so `[String: [Int]]`, `[[String: Int]]` and `[String: [String: Int]]` all nest.
    /// JSON object keys are strings, so the key side needs no dispatch at all; duplicate
    /// keys keep the LAST value, which is what JSONDecoder does.
    ///
    /// A malformed pair aborts the whole decode (same contract as arrays: `failed()`
    /// resynchronised past the value, the close-brace guard reports the document).
    static func dictDecode(value: String, index i: Int, key: String,
                           optional: Bool, pad: String,
                           slot: String? = nil, depth: Int = 0,
                           dateFormatsRef: String = "Assay.DateFormat.defaultFormats",
                             ctx: String = "", salt: Int = 0) -> String {
        let ctxArg = ctx.isEmpty ? "" : ", context: context"
        let target = slot ?? "__f\(i)"
        let dict = "__dd\(i)_\(depth)"
        let kTok = "__dk\(i)_\(depth)"
        let elt = "__de\(i)_\(depth)"

        let inner: String
        // A nested schema or collectible value carries the entry key in its own path; the
        // other shapes name the field and get the key inserted after the fact, which needs
        // the checkpoint. Emitting it unread is a warning in every user's build.
        let usesCheckpoint = isDateType(value) || scalarCall(value, key: key) != nil
            || arrayElement(value) != nil || dictionaryValue(value) != nil
        if isDateType(value) {
            inner = "\(pad)            if let \(elt) = reader._decodeDate(&sink, path, \"\(key)\", \(dateFormatsRef)).map({ \(value)(timeIntervalSince1970: $0) }) { \(dict)[__dks\(i)_\(depth)] = \(elt) }\n\(pad)            if sink.checkpoint() != __dck\(i)_\(depth) { sink._insertKey(since: __dck\(i)_\(depth), __dks\(i)_\(depth), at: path.count + 1) }\n"
        } else if let call = scalarCall(value, key: key) {
            inner = "\(pad)            if let \(elt) = reader.\(call) { \(dict)[__dks\(i)_\(depth)] = \(elt) }\n\(pad)            if sink.checkpoint() != __dck\(i)_\(depth) { sink._insertKey(since: __dck\(i)_\(depth), __dks\(i)_\(depth), at: path.count + 1) }\n"
        } else if let sub = arrayElement(value) {
            inner = """
            \(pad)            var \(elt): [\(sub)]? = nil
            \(arrayDecode(element: sub, index: i, key: key, optional: false,
                          pad: pad + "            ", slot: elt, depth: depth + 1,
                          dateFormatsRef: dateFormatsRef, ctx: ctx, salt: salt))
            \(pad)            if let \(elt) = \(elt) { \(dict)[__dks\(i)_\(depth)] = \(elt) }
            \(pad)            if sink.checkpoint() != __dck\(i)_\(depth) { sink._insertKey(since: __dck\(i)_\(depth), __dks\(i)_\(depth), at: path.count + 1) }

            """
        } else if let sub = dictionaryValue(value) {
            inner = """
            \(pad)            var \(elt): [String: \(sub)]? = nil
            \(dictDecode(value: sub, index: i, key: key, optional: false,
                         pad: pad + "            ", slot: elt, depth: depth + 1,
                         dateFormatsRef: dateFormatsRef, ctx: ctx, salt: salt))
            \(pad)            if let \(elt) = \(elt) { \(dict)[__dks\(i)_\(depth)] = \(elt) }
            \(pad)            if sink.checkpoint() != __dck\(i)_\(depth) { sink._insertKey(since: __dck\(i)_\(depth), __dks\(i)_\(depth), at: path.count + 1) }

            """
        } else if isCollectible(value) {
            // [String: RawValue] / [String: JSON.Value] as an ordinary declared field —
            // the open-map case that is not @Extras.
            inner = """
            \(pad)            if let \(elt) = Assay._assayCollect(
            \(pad)                \(value).self, from: &reader, into: &sink,
            \(pad)                at: path + [.key("\(key)"), .key(__dks\(i)_\(depth))]) { \(dict)[__dks\(i)_\(depth)] = \(elt) }

            """
        } else {
            inner = """
            \(pad)            path.append(.key("\(key)"))
            \(pad)            path.append(.key(__dks\(i)_\(depth)))
            \(pad)            if let \(elt) = \(value)._assay(
            \(pad)                from: &reader, into: &sink, at: &path\(ctxArg)) { \(dict)[__dks\(i)_\(depth)] = \(elt) }
            \(pad)            path.removeLast(2)

            """
        }

        // Dictionaries reserved NOTHING until 2026-09-20 — no pre-count is possible (the
        // member count is not knowable without scanning the object) — so they take the same
        // hint arrays of objects take. See `arrayDecode`.
        let slot = (salt ^ ((i << 3) | Swift.min(depth, 7))) & 0xFF
        return """
        \(pad)if reader.tryConsume(0x7B) {
        \(pad)    var \(dict): [String: \(value)] = [:]
        \(pad)    \(dict).reserveCapacity(sink._shapeHint(\(slot)))
        \(pad)    if !reader.tryConsume(0x7D) {
        \(pad)        while true {
        \(pad)            guard let \(kTok) = reader.scanKey(), reader.expect(0x3A) else {
        \(pad)                reader.reportMalformed(&sink, path, expected: "a key and ':'")
        \(pad)                reader.leaveContainer()
        \(pad)                return nil
        \(pad)            }
        \(pad)            let __dks\(i)_\(depth) = reader._keyString(\(kTok))
        \(usesCheckpoint ? "\(pad)            let __dck\(i)_\(depth) = sink.checkpoint()\n" : "")\(inner)\(pad)            if reader.tryConsume(0x2C) { continue }
        \(pad)            break
        \(pad)        }
        \(pad)        guard reader.tryConsume(0x7D) else {
        \(pad)            reader.reportMalformed(&sink, path, expected: "',' or '}'")
        \(pad)            reader.leaveContainer()
        \(pad)            return nil
        \(pad)        }
        \(pad)    }
        \(pad)    sink._noteShape(\(dict).count, \(slot))
        \(pad)    \(target) = \(dict)
        \(pad)} else if reader._consumeNullIfPresent() {
        \(pad)    \(optional ? "\(target) = nil" : "reader._nullNotAllowed(&sink, path, \"\(key)\", \"dictionary\")")
        \(pad)} else {
        \(pad)    // Names the FIELD. This passed a bare `path` until 2026-09-08, so a
        \(pad)    // whole-value mismatch on a collection reported an issue whose path
        \(pad)    // was EMPTY at the top level -- worse than the missing element index
        \(pad)    // this change set out to fix, and found by a test written for that.
        \(pad)    reader.reportTypeMismatch(&sink, path + [.key("\(key)")], expected: "object")
        \(pad)    _ = reader.skipValue(&sink)
        \(pad)}

        """
    }

    /// Both spellings a user can reasonably write. The generated wrap uses the SAME
    /// spelling as the annotation, so whatever resolved there resolves in the expansion.
    static func isDateType(_ t: String) -> Bool {
        t == "Date" || t == "Foundation.Date"
    }

    /// `UUID`, which decodes through the static `_assay` that `AssayFoundation` adds and
    /// therefore needs no macro support to READ. Writing is different: there is no
    /// `_assayEncode` on Foundation's type and there cannot be a conformance supplying one
    /// (it would hand `UUID` a `parse(json:)` of its own — `TypeShapes` says why), so the
    /// emitters special-case it exactly as they special-case `Date`. Without this, a
    /// `@Schema(encodes: true)` type with a `UUID` field did not compile, and the error
    /// named `_assayEncode` — an internal member the reader never wrote.
    static func isUUIDType(_ t: String) -> Bool {
        t == "UUID" || t == "Foundation.UUID"
    }

    /// The formats expression a date field's decode passes: the shared default when no
    /// `@DateFormat` was written, a per-field static when one was.
    static func dateFormatsRef(_ f: SchemaField, _ i: Int) -> String {
        f.dateFormats == nil ? "Assay.DateFormat.defaultFormats" : "Self.__assayDateFormats_\(i)"
    }

    /// The per-field candidate arrays, one `static let` each — swift_once-protected,
    /// allocated once, borrowed per decode. Emitted only for fields that wrote
    /// `@DateFormat`; the bare-`Date` majority shares `DateFormat.defaultFormats`.
    static func dateFormatArrays(_ fields: [SchemaField]) -> String {
        var out = ""
        for (i, f) in fields.enumerated() where f.dateFormats != nil {
            let exprs = f.dateFormats!.joined(separator: ", ")
            out += """
            nonisolated static let __assayDateFormats_\(i): [Assay.DateFormat] = [\(exprs)]


            """
        }
        return out
    }

    /// The memberwise-init argument list, shared by the JSON and `RawValue` bodies.
    ///
    /// Extracted when `@Inline` landed. The two construction blocks were near-identical
    /// copies, and adding group reconstruction to one and not the other is precisely the
    /// drift that produces a feature working on JSON and silently not on YAML -- which is
    /// what happened on the first run of the multi-format test.
    ///
    /// `@Inline` groups reconstruct HERE and nowhere else. The fields decoded from the OUTER
    /// key namespace, so the dispatch table, the presence mask and the known-key set all saw
    /// flat fields -- which is exactly why unknown-key handling works through an inline and
    /// serde's runtime `flatten` cannot manage it. Only the initialiser needs the nested
    /// value put back together.
    static func constructionArgs(
        fields: [SchemaField], ordered: [SchemaField]?, indexOf: [String: Int]
    ) -> [String] {
        var emittedInlineGroups: Set<String> = []
        var args: [String] = []
        for f in (ordered ?? fields) {
            if let owner = f.inlineOwner {
                guard emittedInlineGroups.insert(owner.identifier).inserted else { continue }
                let members = fields.filter { $0.inlineOwner?.identifier == owner.identifier }
                let inner = members.compactMap { m -> String? in
                    guard let j = indexOf[m.identifier] else { return nil }
                    return "\(m.name): \(m.isOptional ? "__f\(j)" : "__v\(j)")"
                }
                args.append("\(SchemaMacro.unbackticked(owner.identifier)): \(owner.typeName)"
                            + "(\(inner.joined(separator: ", ")))")
            } else if f.isExtras {
                args.append("\(f.name): __extras")
            } else if let i = indexOf[f.identifier] {
                let raw = f.isOptional ? "__f\(i)" : "__v\(i)"
                if f.transform != nil {
                    // Transform runs last, after validation — EXPERIENCE §11's ordering.
                    let applied = f.isOptional
                        ? "\(raw).map(Self.__assayTransform_\(i))"
                        : "Self.__assayTransform_\(i)(\(raw))"
                    args.append("\(f.name): \(applied)")
                } else {
                    args.append("\(f.name): \(raw)")
                }
            }
        }
        return args
    }
}

extension String {
    /// `String.contains(_: some StringProtocol)` is macOS 13; the macro target's floor is
    /// swift-syntax's 10.15. A byte scan is all a type spelling needs.
    func containsSubstring(_ needle: String) -> Bool {
        let h = Array(utf8), n = Array(needle.utf8)
        guard !n.isEmpty, h.count >= n.count else { return n.isEmpty }
        var i = 0
        while i + n.count <= h.count {
            if h[i] == n[0], Array(h[i..<i + n.count]) == n { return true }
            i += 1
        }
        return false
    }

    /// No Foundation in the macro target, so no `trimmingCharacters`.
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return String(s)
    }
}
