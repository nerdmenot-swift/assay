// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// What the macro can tell about a type from its SPELLING — which is all a macro has.
//
// `scalarCall` is the table every decode emitter consults: which runtime primitive
// decodes a given scalar token, and therefore which tokens ARE scalars. The shape helpers
// take a type string apart: `Optional<T>`/`T?`, `[T]`, `[K: V]`. Every emitter — decode,
// raw, encode, XML, union, source, describe — imports these; they were in CodeGen.swift by
// accident of history. Split out on 2026-09-10.
//===----------------------------------------------------------------------===//

extension SchemaMacro {

    /// Monomorphic per type — there is no generic `FixedWidthInteger` dispatch anywhere
    /// on the decode path, which is the whole reason a macro decoder can be fast here.
    /// - Parameter elementIndex: a generated expression naming the element's position when
    ///   this scalar is an ARRAY ELEMENT, or nil for a plain field. It becomes one extra
    ///   argument on the call, consumed inside the cold failure path -- no concat is emitted
    ///   at the call site and nothing is allocated on the hot path. Before this, an
    ///   out-of-range `[Int32]` element reported `[.key("xs")]` and named no element.
    static func scalarCall(
        _ type: String, key: String, orNull: Bool = false,
        coerce: Bool = false, elementIndex: String? = nil
    ) -> String? {
        // Coercion and the null-aware variant are separate axes; an optional coercing
        // field takes the coercing call and handles null at the call site.
        let suffix = coerce ? "Coercing" : (orNull ? "OrNull" : "")
        let base: String
        switch type {
        case "String": base = "_decodeString"
        case "Int": base = "_decodeInt"
        case "Int64": base = "_decodeInt64"
        case "Int32": base = "_decodeInt32"
        case "Int8": base = "_decodeInt8"
        case "Int16": base = "_decodeInt16"
        case "UInt8": base = "_decodeUInt8"
        case "UInt16": base = "_decodeUInt16"
        case "UInt32": base = "_decodeUInt32"
        case "UInt64": base = "_decodeUInt64"
        case "UInt": base = "_decodeUInt"
        case "Double": base = "_decodeDouble"
        case "Float": base = "_decodeFloat"
        case "Bool": base = "_decodeBool"
        default: return nil
        }
        let idx = elementIndex.map { ", \($0)" } ?? ""
        return "\(base)\(suffix)(&sink, path, \"\(key)\"\(idx))"
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

    /// The distinct nominal types a field list decodes through `T._assay`, in first-seen
    /// order — everything that is not a scalar, a date, an open map, or a collection of
    /// those, unwrapped through arrays, dictionaries and optionals. Each gets one
    /// `_assayRequire…` assertion at the top of the body.
    static func nestedNominalTypes(_ fields: [SchemaField]) -> [String] {
        var seen: [String] = []
        func visit(_ t: String) {
            let base = stripOptional(t)
            if let e = arrayElement(base) { visit(e); return }
            if let v = dictionaryValue(base) { visit(v); return }
            if scalarCall(base, key: "") != nil || isDateType(base) || isCollectible(base) {
                return
            }
            // `UUID` decodes through a static `_assay` that AssayFoundation adds WITHOUT a
            // `JSONAssayable` conformance — the type is Foundation's, and a conformance
            // would give it `parse(json:)` as a document. The assertion would refuse it.
            if base == "UUID" || base == "Foundation.UUID" { return }
            // A tuple, a function type, `Any`: refused earlier; never emit a `.self` on one.
            if base.hasPrefix("(") || base.containsSubstring("->") { return }
            if !seen.contains(base) { seen.append(base) }
        }
        for f in fields where !f.isExtras && !f.isIgnored { visit(f.decodedType) }
        return seen
    }
}
