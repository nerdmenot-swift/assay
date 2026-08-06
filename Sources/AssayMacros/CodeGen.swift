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

extension SchemaMacro {

    static func decodeBody(
        typeName: String,
        fields: [SchemaField],
        plan: WindowPlan?,
        extras: SchemaField? = nil,
        policy: String = "ignore",
        ordered: [SchemaField]? = nil,
        validation: String = "",
        checks: String = ""
    ) -> String {
        var out = ""

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
            var assigns = ""
            for (value, index) in plan.table.enumerated()
            where index != UInt8(fields.count) {
                assigns += "        t[\(value)] = \(index)\n"
            }
            out += """
            nonisolated static let __assayKeyTable: [UInt8] = {
                var t = [UInt8](repeating: \(fields.count), count: 256)
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
            locals += "    var __extras: \(value) = [:]\n"
        }

        // Dispatch.
        let unknown = unknownArm(policy: policy, extras: extras)
        let dispatch = plan.map { windowDispatch(fields: fields, plan: $0, unknown: unknown) }
            ?? lengthBucketDispatch(fields: fields, unknown: unknown)

        // Missing-required reporting, walked only when the mask says something is absent.
        var missing = ""
        for (i, f) in fields.enumerated() where (requiredMask & (1 << UInt64(i))) != 0 {
            missing += """
                    if __presence & \(1 << UInt64(i)) == 0 {
                        reader.missingRequired(&sink, path, "\(f.wireKey)")
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

        var args: [String] = []
        for f in (ordered ?? fields) {
            if f.isExtras {
                args.append("\(f.identifier): __extras")
            } else if let i = indexOf[f.identifier] {
                let raw = f.isOptional ? "__f\(i)" : "__v\(i)"
                if f.transform != nil {
                    // Transform runs last, after validation — EXPERIENCE §11's ordering.
                    let applied = f.isOptional
                        ? "\(raw).map(Self.__assayTransform_\(i))"
                        : "Self.__assayTransform_\(i)(\(raw))"
                    args.append("\(f.identifier): \(applied)")
                } else {
                    args.append("\(f.identifier): \(raw)")
                }
            }
        }

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
        out += """
        nonisolated public static func _assay(
            from reader: inout Assay.AssayReader,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) -> \(typeName)? {
            guard reader.tryConsume(0x7B) else {
                reader.reportTypeMismatch(&sink, path, expected: "object")
                return nil
            }
            guard reader.enterContainer(&sink) else { return nil }

        \(locals)    var __presence: UInt64 = 0

            if !reader.tryConsume(0x7D) {
                while true {
                    guard let __key = reader.scanKey() else {
                        reader.reportMalformed(&sink, path)
                        reader.leaveContainer()
                        return nil
                    }
                    guard reader.expect(0x3A) else {
                        reader.reportMalformed(&sink, path)
                        reader.leaveContainer()
                        return nil
                    }
        \(dispatch)
                    if reader.tryConsume(0x2C) { continue }
                    break
                }
                guard reader.tryConsume(0x7D) else {
                    reader.reportMalformed(&sink, path)
                    reader.leaveContainer()
                    return nil
                }
            }
            reader.leaveContainer()

        \(missing)
        \(validation)
        \(unwraps)    let __result = \(typeName)(\(args.joined(separator: ", ")))
        \(checks)
            guard sink.isValid else { return nil }
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
            let __uk = reader.keyString(__key)
                                if let __uv = Assay._assayCollect(
                                    \(value).self,
                                    from: &reader, into: &sink, at: path + [.key(__uk)]) {
                                    __extras[__uk] = __uv
                                }
            """
        case "warn":
            return """
            reader.reportUnknownKey(&sink, path, __key,
                                                        known: Self.__assayKnownKeys,
                                                        reject: false)
                                _ = reader.skipValue(&sink)
            """
        case "reject":
            return """
            reader.reportUnknownKey(&sink, path, __key,
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

    // MARK: Dispatch shapes

    static func windowDispatch(fields: [SchemaField], plan: WindowPlan,
                               unknown: String = "_ = reader.skipValue(&sink)") -> String {
        var arms = ""
        for (i, f) in fields.enumerated() {
            let keys = [f.wireKey] + f.aliases
            let cond = keys.map { "reader.keyMatches(__key, \"\($0)\")" }
                .joined(separator: " || ")
            arms += """
                            case \(i):
                                if \(cond) {
                                    __presence |= \(1 << UInt64(i))
            \(decodeStatement(field: f, index: i, indent: 24))
                                } else {
                                    \(unknown)
                                }

            """
        }
        return """
                        let __w = reader.keyWindow(
                            __key,
                            byteOffset: \(plan.byteOffset),
                            shift: \(plan.shift))
                        switch Self.__assayKeyTable[Int(__w)] {
        \(arms)                default:
                            \(unknown)
                        }
        """
    }

    /// The fallback when no single 8-bit window separates the key set: bucket by length,
    /// then compare within the bucket. Length bucketing separates `created_at` from
    /// `created_at_ms` for free.
    static func lengthBucketDispatch(fields: [SchemaField],
                                     unknown: String = "_ = reader.skipValue(&sink)") -> String {
        var byLength: [Int: [(Int, SchemaField, String)]] = [:]
        for (i, f) in fields.enumerated() {
            for key in [f.wireKey] + f.aliases {
                byLength[key.utf8.count, default: []].append((i, f, key))
            }
        }
        var arms = ""
        for len in byLength.keys.sorted() {
            var checks = ""
            for (i, f, key) in byLength[len]! {
                checks += """
                                    if reader.keyMatches(__key, "\(key)") {
                                        __presence |= \(1 << UInt64(i))
                \(decodeStatement(field: f, index: i, indent: 24))
                                    } else
                """
            }
            arms += """
                            case \(len):
                \(checks) {
                                    \(unknown)
                                }

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
    static func decodeStatement(field f: SchemaField, index i: Int, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let base = f.decodedType
        let key = f.wireKey

        if let element = arrayElement(base) {
            return arrayDecode(element: element, index: i, key: key,
                               optional: f.isOptional, pad: pad,
                               dateFormatsRef: dateFormatsRef(f, i))
        }

        if let value = dictionaryValue(base) {
            return dictDecode(value: value, index: i, key: key,
                              optional: f.isOptional, pad: pad,
                              dateFormatsRef: dateFormatsRef(f, i))
        }

        // Fields carrying @Validate capture their value's span right after the decode,
        // while the cursor still sits just past it — that is what puts a caret under a
        // failing value rather than only under a malformed one.
        let spanCapture = f.needsSpan ? "\n\(pad)__sp\(i) = reader.lastValueSpan" : ""

        // Date. The runtime returns epoch seconds; `Date(timeIntervalSince1970:)`
        // resolves in the USER's module, where `var x: Date` already required a
        // Foundation flavour to be imported — the seam that keeps the core
        // Foundation-free (Sources/AssayCore/Dates.swift's header).
        if isDateType(base) {
            let formats = dateFormatsRef(f, i)
            let wrap = ".map { \(base)(timeIntervalSince1970: $0) }"
            if f.fallback != nil {
                return """
                \(pad)let __fck\(i) = sink.checkpoint()
                \(pad)__f\(i) = reader.decodeDate(&sink, path, "\(key)", \(formats))\(wrap)\(spanCapture)
                \(pad)if __f\(i) == nil { sink.rollback(to: __fck\(i)) }
                """
            }
            if f.isOptional {
                return "\(pad)if let __r = reader.decodeDateOrNull(&sink, path, \"\(key)\", \(formats)) { __f\(i) = __r\(wrap) }"
                    + spanCapture
            }
            return "\(pad)__f\(i) = reader.decodeDate(&sink, path, \"\(key)\", \(formats))\(wrap)"
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
                \(pad)if reader.consumeNullIfPresent() { __f\(i) = nil } else {
                \(pad)    __f\(i) = reader.\(call)
                \(pad)}\(spanCapture)
                """
            }
            return (f.isOptional
                ? "\(pad)if let __r = reader.\(call) { __f\(i) = __r }"
                : "\(pad)__f\(i) = reader.\(call)") + spanCapture
        }

        // Nested @Schema type. The outer schema knows where it asked the inner one to
        // look, which is how errors keep the right path.
        return """
        \(pad)if reader.consumeNullIfPresent() {
        \(pad)    \(f.isOptional
                    ? "__f\(i) = nil"
                    : "reader.nullNotAllowed(&sink, path, \"\(key)\", \"\(base)\")")
        \(pad)} else {
        \(pad)    __f\(i) = \(base)._assay(
        \(pad)        from: &reader, into: &sink, at: path + [.key("\(key)")])
        \(pad)}
        """
    }

    /// Array decoding, recursive so that `[[Double]]` and deeper nest correctly.
    ///
    /// `slot` is the lvalue the result is assigned to and `depth` disambiguates the loop
    /// variables, so nesting does not collide on `__arr`/`__e`.
    static func arrayDecode(element: String, index i: Int, key: String,
                            optional: Bool, pad: String,
                            slot: String? = nil, depth: Int = 0,
                            dateFormatsRef: String = "Assay.DateFormat.defaultFormats") -> String {
        let target = slot ?? "__f\(i)"
        let arr = "__arr\(i)_\(depth)"
        let elt = "__e\(i)_\(depth)"

        let inner: String
        if isDateType(element) {
            inner = "\(pad)        guard let \(elt) = reader.decodeDate(&sink, path, \"\(key)\", \(dateFormatsRef)).map({ \(element)(timeIntervalSince1970: $0) }) else { break }\n"
        } else if let call = scalarCall(element, key: key) {
            inner = "\(pad)        guard let \(elt) = reader.\(call) else { break }\n"
        } else if let sub = arrayElement(element) {
            // Nested array. Decode into a local, then append it.
            inner = """
            \(pad)        var \(elt): [\(sub)]? = nil
            \(arrayDecode(element: sub, index: i, key: key, optional: false,
                          pad: pad + "        ", slot: elt, depth: depth + 1,
                          dateFormatsRef: dateFormatsRef))
            \(pad)        guard let \(elt) = \(elt) else { break }

            """
        } else if let sub = dictionaryValue(element) {
            // [[String: Int]] — a dictionary element inside an array.
            inner = """
            \(pad)        var \(elt): [String: \(sub)]? = nil
            \(dictDecode(value: sub, index: i, key: key, optional: false,
                         pad: pad + "        ", slot: elt, depth: depth + 1,
                         dateFormatsRef: dateFormatsRef))
            \(pad)        guard let \(elt) = \(elt) else { break }

            """
        } else {
            inner = """
            \(pad)        guard let \(elt) = \(element)._assay(
            \(pad)            from: &reader, into: &sink,
            \(pad)            at: path + [.key("\(key)"), .index(\(arr).count)]) else { break }

            """
        }

        // Geometric growth for now. Exact-sizing needs a counting pre-scan, and
        // docs/PERFORMANCE.md §9.2 says to measure that trade rather than assume it —
        // serde_json, the fastest general-purpose decoder in Rust, does not pre-count.
        return """
        \(pad)if reader.tryConsume(0x5B) {
        \(pad)    var \(arr): [\(element)] = []
        \(pad)    if !reader.tryConsume(0x5D) {
        \(pad)        while true {
        \(inner)\(pad)            \(arr).append(\(elt))
        \(pad)            if reader.tryConsume(0x2C) { continue }
        \(pad)            break
        \(pad)        }
        \(pad)        guard reader.tryConsume(0x5D) else {
        \(pad)            reader.reportMalformed(&sink, path)
        \(pad)            return nil
        \(pad)        }
        \(pad)    }
        \(pad)    \(target) = \(arr)
        \(pad)} else if reader.consumeNullIfPresent() {
        \(pad)    \(optional ? "\(target) = nil" : "reader.nullNotAllowed(&sink, path, \"\(key)\", \"array\")")
        \(pad)} else {
        \(pad)    reader.reportTypeMismatch(&sink, path, expected: "array")
        \(pad)}

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
                           dateFormatsRef: String = "Assay.DateFormat.defaultFormats") -> String {
        let target = slot ?? "__f\(i)"
        let dict = "__dd\(i)_\(depth)"
        let kTok = "__dk\(i)_\(depth)"
        let elt = "__de\(i)_\(depth)"

        let inner: String
        if isDateType(value) {
            inner = "\(pad)            guard let \(elt) = reader.decodeDate(&sink, path, \"\(key)\", \(dateFormatsRef)).map({ \(value)(timeIntervalSince1970: $0) }) else { break }\n"
        } else if let call = scalarCall(value, key: key) {
            inner = "\(pad)            guard let \(elt) = reader.\(call) else { break }\n"
        } else if let sub = arrayElement(value) {
            inner = """
            \(pad)            var \(elt): [\(sub)]? = nil
            \(arrayDecode(element: sub, index: i, key: key, optional: false,
                          pad: pad + "            ", slot: elt, depth: depth + 1,
                          dateFormatsRef: dateFormatsRef))
            \(pad)            guard let \(elt) = \(elt) else { break }

            """
        } else if let sub = dictionaryValue(value) {
            inner = """
            \(pad)            var \(elt): [String: \(sub)]? = nil
            \(dictDecode(value: sub, index: i, key: key, optional: false,
                         pad: pad + "            ", slot: elt, depth: depth + 1,
                         dateFormatsRef: dateFormatsRef))
            \(pad)            guard let \(elt) = \(elt) else { break }

            """
        } else if isCollectible(value) {
            // [String: RawValue] / [String: JSON.Value] as an ordinary declared field —
            // the open-map case that is not @Extras.
            inner = """
            \(pad)            guard let \(elt) = Assay._assayCollect(
            \(pad)                \(value).self, from: &reader, into: &sink,
            \(pad)                at: path + [.key("\(key)")]) else { break }

            """
        } else {
            inner = """
            \(pad)            guard let \(elt) = \(value)._assay(
            \(pad)                from: &reader, into: &sink,
            \(pad)                at: path + [.key("\(key)")]) else { break }

            """
        }

        return """
        \(pad)if reader.tryConsume(0x7B) {
        \(pad)    var \(dict): [String: \(value)] = [:]
        \(pad)    if !reader.tryConsume(0x7D) {
        \(pad)        while true {
        \(pad)            guard let \(kTok) = reader.scanKey(), reader.expect(0x3A) else {
        \(pad)                reader.reportMalformed(&sink, path)
        \(pad)                return nil
        \(pad)            }
        \(inner)\(pad)            \(dict)[reader.keyString(\(kTok))] = \(elt)
        \(pad)            if reader.tryConsume(0x2C) { continue }
        \(pad)            break
        \(pad)        }
        \(pad)        guard reader.tryConsume(0x7D) else {
        \(pad)            reader.reportMalformed(&sink, path)
        \(pad)            return nil
        \(pad)        }
        \(pad)    }
        \(pad)    \(target) = \(dict)
        \(pad)} else if reader.consumeNullIfPresent() {
        \(pad)    \(optional ? "\(target) = nil" : "reader.nullNotAllowed(&sink, path, \"\(key)\", \"dictionary\")")
        \(pad)} else {
        \(pad)    reader.reportTypeMismatch(&sink, path, expected: "object")
        \(pad)}

        """
    }

    /// Monomorphic per type — there is no generic `FixedWidthInteger` dispatch anywhere
    /// on the decode path, which is the whole reason a macro decoder can be fast here.
    static func scalarCall(_ type: String, key: String, orNull: Bool = false,
                           coerce: Bool = false) -> String? {
        // Coercion and the null-aware variant are separate axes; an optional coercing
        // field takes the coercing call and handles null at the call site.
        let suffix = coerce ? "Coercing" : (orNull ? "OrNull" : "")
        let base: String
        switch type {
        case "String":  base = "decodeString"
        case "Int":     base = "decodeInt"
        case "Int64":   base = "decodeInt64"
        case "Int32":   base = "decodeInt32"
        case "UInt":    base = "decodeUInt"
        case "Double":  base = "decodeDouble"
        case "Float":   base = "decodeFloat"
        case "Bool":    base = "decodeBool"
        default:        return nil
        }
        return "\(base)\(suffix)(&sink, path, \"\(key)\")"
    }

    /// Both spellings a user can reasonably write. The generated wrap uses the SAME
    /// spelling as the annotation, so whatever resolved there resolves in the expansion.
    static func isDateType(_ t: String) -> Bool {
        t == "Date" || t == "Foundation.Date"
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

    static func stripOptional(_ t: String) -> String {
        if t.hasSuffix("?") { return String(t.dropLast()) }
        if t.hasPrefix("Optional<") && t.hasSuffix(">") {
            return String(t.dropFirst("Optional<".count).dropLast())
        }
        return t
    }

    static func arrayElement(_ t: String) -> String? {
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = String(t.dropFirst().dropLast())
        // A TOP-LEVEL colon means dictionary. A nested one — `[[String: Int]]` — does
        // not; a naive `contains(":")` misread exactly that case.
        return topLevelColon(inner) == nil ? inner.trimmingWhitespace() : nil
    }

    /// `[String: V]` → `V`, nil for arrays, non-dictionaries, and non-String keys
    /// (which get their own diagnostic rather than silently missing this branch).
    static func dictionaryValue(_ t: String) -> String? {
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = String(t.dropFirst().dropLast())
        guard let colon = topLevelColon(inner) else { return nil }
        guard String(inner[..<colon]).trimmingWhitespace() == "String" else { return nil }
        return String(inner[inner.index(after: colon)...]).trimmingWhitespace()
    }

    /// The first colon not nested inside brackets, generics, or parens.
    static func topLevelColon(_ s: String) -> String.Index? {
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            switch s[i] {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            case ":" where depth == 0: return i
            default: break
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Walks a type expression and returns the first dictionary segment whose key type
    /// is not `String`, for the purpose-written diagnostic. JSON object keys ARE
    /// strings; an `[Int: String]` field would otherwise fail inside generated code
    /// with an error pointing at nothing the user wrote.
    static func firstNonStringDictKey(_ t: String) -> String? {
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = String(t.dropFirst().dropLast())
        if let colon = topLevelColon(inner) {
            guard String(inner[..<colon]).trimmingWhitespace() == "String" else { return t }
            return firstNonStringDictKey(
                String(inner[inner.index(after: colon)...]).trimmingWhitespace())
        }
        return firstNonStringDictKey(inner.trimmingWhitespace())
    }

    /// The value-model types `_assayCollect` can produce — the open-map value types a
    /// declared `[String: _]` field may carry outside of `@Extras`.
    static func isCollectible(_ t: String) -> Bool {
        t == "RawValue" || t == "Assay.RawValue"
            || t == "JSON.Value" || t == "Assay.JSON.Value"
    }
}

extension String {
    /// No Foundation in the macro target, so no `trimmingCharacters`.
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return String(s)
    }
}
