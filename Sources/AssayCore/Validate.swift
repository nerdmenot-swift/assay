// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Rule application — the runtime half of @Validate.
//
// The macro emits, per validated field, a `static let` rule array (built once,
// swift_once-protected, zero per-decode allocation) and ONE call into an overload here.
// That is docs/COMPILE-TIME.md §3 rule 3 — everything conditional lives in the runtime,
// the expansion emits a call — applied to validation before it could become the thing
// that makes every user's build slower.
//
// Every violation is an Issue with a stable code and params; the sentence comes from
// Messages.swift at render time. The value's source span, captured during decode, rides
// along — which is what makes `replicas: 0` render with a caret under the 0.
//===----------------------------------------------------------------------===//

extension Rule {

    // MARK: String

    @usableFromInline
    func applyString(
        _ v: String, _ override: String?, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathComponent], _ sink: inout IssueSink
    ) {
        switch kind {
        case .min(let n):
            if v.count < Int(n) {
                emit(&sink, "too_small", field, span, path, override,
                     ["minimum": .int(Int(n)), "unit": .string("characters")], v)
            }
        case .max(let n):
            if v.count > Int(n) {
                emit(&sink, "too_large", field, span, path, override,
                     ["maximum": .int(Int(n)), "unit": .string("characters")], v)
            }
        case .length(let n):
            if v.count != n {
                emit(&sink, "wrong_length", field, span, path, override,
                     ["length": .int(n)], v)
            }
        case .notEmpty:
            if v.isEmpty {
                emit(&sink, "empty", field, span, path, override, [:], v)
            }
        case .regex(let pattern):
            applyRegex(pattern, to: v, override, field, span, path, &sink)
        case .email:
            if !FormatValidators.isEmail(v) {
                emit(&sink, "invalid_email", field, span, path, override, [:], v)
            }
        case .url:
            if !FormatValidators.isURL(v) {
                emit(&sink, "invalid_url", field, span, path, override, [:], v)
            }
        case .uuid:
            if !FormatValidators.isUUID(v) {
                emit(&sink, "invalid_uuid", field, span, path, override, [:], v)
            }
        case .hostname:
            if !FormatValidators.isHostname(v) {
                emit(&sink, "invalid_hostname", field, span, path, override, [:], v)
            }
        case .ascii:
            if !FormatValidators.isASCII(v) {
                emit(&sink, "not_ascii", field, span, path, override, [:], v)
            }
        case .trimmed:
            if !FormatValidators.isTrimmed(v) {
                emit(&sink, "not_trimmed", field, span, path, override, [:], v)
            }
        case .lowercased:
            if v != v.lowercased() {
                emit(&sink, "not_lowercased", field, span, path, override, [:], v)
            }
        case .prefix(let p):
            if !v.hasPrefix(p) {
                emit(&sink, "missing_prefix", field, span, path, override,
                     ["prefix": .string(p)], v)
            }
        case .suffix(let sfx):
            if !v.hasSuffix(sfx) {
                emit(&sink, "missing_suffix", field, span, path, override,
                     ["suffix": .string(sfx)], v)
            }
        case .contains(let sub):
            if !FormatValidators.containsSubstring(v, sub) {
                emit(&sink, "missing_substring", field, span, path, override,
                     ["substring": .string(sub)], v)
            }
        case .oneOf(let options):
            if !options.contains(v) {
                emit(&sink, "not_one_of", field, span, path, override,
                     ["options": .string(options.map { "\"\($0)\"" }.joined(separator: ", "))],
                     v)
            }
        case .all(let rules):
            for r in rules { r.applyString(v, override, field, span, path, &sink) }
        case .messageOnly:
            break                                     // carried via the override channel
        default:
            break                                     // numeric/collection kinds: macro-prevented
        }
    }

    /// `.regex`, stored as a `String`, compiled on demand.
    ///
    /// The availability cliff is real and handled by failing CLOSED: on an Apple OS older
    /// than the stdlib `Regex` floor the rule reports `regex_unavailable` rather than
    /// silently passing — a validator that stops validating is worse than one that
    /// refuses. On Linux, Windows and Wasm the engine ships with the toolchain and the
    /// check is inert. (cross-platform-audit.md §3; EXPERIENCE.md §20 question 3.)
    @usableFromInline
    func applyRegex(
        _ pattern: String, to v: String, _ override: String?, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathComponent], _ sink: inout IssueSink
    ) {
        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            guard let regex = try? Regex(pattern) else {
                emit(&sink, "invalid_regex_pattern", field, span, path, override,
                     ["pattern": .string(pattern)], v)
                return
            }
            if (try? regex.firstMatch(in: v)) == nil {
                emit(&sink, "pattern_mismatch", field, span, path, override,
                     ["pattern": .string(pattern)], v)
            }
        } else {
            emit(&sink, "regex_unavailable", field, span, path, override,
                 ["pattern": .string(pattern)], v)
        }
    }

    // MARK: Numbers

    @usableFromInline
    func applyNumber(
        _ v: Double, isInteger: Bool, _ override: String?, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathComponent], _ sink: inout IssueSink
    ) {
        switch kind {
        case .min(let n):
            if v < n {
                emit(&sink, "too_small", field, span, path, override,
                     ["minimum": numberParam(n, isInteger)], display(v, isInteger))
            }
        case .max(let n):
            if v > n {
                emit(&sink, "too_large", field, span, path, override,
                     ["maximum": numberParam(n, isInteger)], display(v, isInteger))
            }
        case .range(let lo, let hi):
            if v < lo || v > hi {
                emit(&sink, "not_in_range", field, span, path, override,
                     ["minimum": numberParam(lo, isInteger),
                      "maximum": numberParam(hi, isInteger)], display(v, isInteger))
            }
        case .positive:
            if !(v > 0) {
                emit(&sink, "not_positive", field, span, path, override, [:],
                     display(v, isInteger))
            }
        case .negative:
            if !(v < 0) {
                emit(&sink, "not_negative", field, span, path, override, [:],
                     display(v, isInteger))
            }
        case .nonNegative:
            if v < 0 {
                emit(&sink, "negative", field, span, path, override, [:],
                     display(v, isInteger))
            }
        case .multipleOf(let m):
            let remainder = v.truncatingRemainder(dividingBy: m)
            if abs(remainder) > 1e-9 && abs(abs(remainder) - abs(m)) > 1e-9 {
                emit(&sink, "not_multiple", field, span, path, override,
                     ["multipleOf": numberParam(m, isInteger)], display(v, isInteger))
            }
        case .finite:
            if !v.isFinite {
                emit(&sink, "not_finite", field, span, path, override, [:], String(v))
            }

        // Dates reach this overload as epoch seconds (the generated code passes
        // `.timeIntervalSince1970`); the received value renders back as ISO-8601 so a
        // violation reads as a date, never as 1786363800.0.
        case .before(let bound, let display):
            if !(v < bound) {
                emit(&sink, "date_not_before", field, span, path, override,
                     ["bound": .string(display)], formatEpochISO(v))
            }
        case .after(let bound, let display):
            if !(v > bound) {
                emit(&sink, "date_not_after", field, span, path, override,
                     ["bound": .string(display)], formatEpochISO(v))
            }
        case .betweenDates(let lo, let hi, let displayLo, let displayHi):
            if v < lo || v > hi {
                emit(&sink, "date_not_between", field, span, path, override,
                     ["minimum": .string(displayLo), "maximum": .string(displayHi)],
                     formatEpochISO(v))
            }
        case .invalidRuleDate(let bound):
            emit(&sink, "invalid_rule_date", field, span, path, override,
                 ["bound": .string(bound)], nil)

        case .all(let rules):
            for r in rules {
                r.applyNumber(v, isInteger: isInteger, override, field, span, path, &sink)
            }
        case .messageOnly:
            break
        default:
            break
        }
    }

    private func numberParam(_ n: Double, _ isInteger: Bool) -> IssueValue {
        isInteger && n == n.rounded() ? .int(Int(n)) : .double(n)
    }

    private func display(_ v: Double, _ isInteger: Bool) -> String {
        isInteger && v == v.rounded() && abs(v) < 9e15 ? String(Int(v)) : String(v)
    }

    // MARK: Collections

    /// Count-shaped rules, applicable to any array.
    @usableFromInline
    func applyCollectionCount(
        _ count: Int, _ override: String?, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathComponent], _ sink: inout IssueSink
    ) {
        switch kind {
        case .min(let n):
            if count < Int(n) {
                emit(&sink, "too_small", field, span, path, override,
                     ["minimum": .int(Int(n)), "unit": .string("items")], "\(count) items")
            }
        case .max(let n):
            if count > Int(n) {
                emit(&sink, "too_large", field, span, path, override,
                     ["maximum": .int(Int(n)), "unit": .string("items")], "\(count) items")
            }
        case .count(let lo, let hi):
            if count < lo || count > hi {
                emit(&sink, "wrong_count", field, span, path, override,
                     ["minimum": .int(lo), "maximum": .int(hi)], "\(count) items")
            }
        case .notEmpty:
            if count == 0 {
                emit(&sink, "empty", field, span, path, override, [:], "0 items")
            }
        case .all(let rules):
            for r in rules {
                r.applyCollectionCount(count, override, field, span, path, &sink)
            }
        default:
            break
        }
    }

    @usableFromInline
    var eachRules: [Rule]? {
        if case .each(let rules) = kind { return rules }
        return nil
    }

    @usableFromInline
    var isUnique: Bool {
        if case .unique = kind { return true }
        return false
    }

    // MARK: Emission

    /// Cold. The `message` on the rule (from `or:`) beats the attribute override, which
    /// beats the derived sentence — the precedence EXPERIENCE.md §5 specifies.
    @usableFromInline
    func emit(
        _ sink: inout IssueSink, _ code: String, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathComponent], _ override: String?,
        _ params: [String: IssueValue], _ received: String?
    ) {
        var params = params
        if let m = message ?? override {
            params["message"] = .string(m)
        }
        // `.each` passes an empty field name because the element path already ends in the
        // field and index; an empty key would render as "recipients[1]." with a bare dot.
        let name = String(describing: field)
        sink.add(Issue(
            code: .custom(code),
            path: name.isEmpty ? path : path + [.key(name)],
            params: params,
            received: received,
            location: span))
    }
}

// MARK: - The entry points generated code calls

/// One call per @Validate attribute; the rules array is a `static let` on the schema type.
@inlinable
public func _assayValidate(
    _ v: String, _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathComponent], _ sink: inout IssueSink
) {
    for r in rules { r.applyString(v, override, field, span, path, &sink) }
}

@inlinable
public func _assayValidate(
    _ v: Int64, _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathComponent], _ sink: inout IssueSink
) {
    for r in rules {
        r.applyNumber(Double(v), isInteger: true, override, field, span, path, &sink)
    }
}

@inlinable
public func _assayValidate(
    _ v: UInt64, _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathComponent], _ sink: inout IssueSink
) {
    for r in rules {
        r.applyNumber(Double(v), isInteger: true, override, field, span, path, &sink)
    }
}

@inlinable
public func _assayValidate(
    _ v: Double, _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathComponent], _ sink: inout IssueSink
) {
    for r in rules {
        r.applyNumber(v, isInteger: false, override, field, span, path, &sink)
    }
}

/// String arrays: count rules, `.unique`, and `.each` with string rules per element.
@inlinable
public func _assayValidate(
    _ v: [String], _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathComponent], _ sink: inout IssueSink
) {
    for r in rules {
        if let inner = r.eachRules {
            for (i, element) in v.enumerated() {
                let elementPath = path + [.key(String(describing: field)), .index(i)]
                for rule in inner {
                    rule.applyString(element, r.message ?? override, "", span,
                                     elementPath, &sink)
                }
            }
        } else if r.isUnique {
            if Set(v).count != v.count {
                r.emit(&sink, "not_unique", field, span, path, override, [:], nil)
            }
        } else {
            r.applyCollectionCount(v.count, override, field, span, path, &sink)
        }
    }
}

@inlinable
public func _assayValidate(
    _ v: [Int], _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathComponent], _ sink: inout IssueSink
) {
    for r in rules {
        if let inner = r.eachRules {
            for (i, element) in v.enumerated() {
                let elementPath = path + [.key(String(describing: field)), .index(i)]
                for rule in inner {
                    rule.applyNumber(Double(element), isInteger: true,
                                     r.message ?? override, "", span, elementPath, &sink)
                }
            }
        } else if r.isUnique {
            if Set(v).count != v.count {
                r.emit(&sink, "not_unique", field, span, path, override, [:], nil)
            }
        } else {
            r.applyCollectionCount(v.count, override, field, span, path, &sink)
        }
    }
}

@inlinable
public func _assayValidate(
    _ v: [Double], _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathComponent], _ sink: inout IssueSink
) {
    for r in rules {
        if let inner = r.eachRules {
            for (i, element) in v.enumerated() {
                let elementPath = path + [.key(String(describing: field)), .index(i)]
                for rule in inner {
                    rule.applyNumber(element, isInteger: false,
                                     r.message ?? override, "", span, elementPath, &sink)
                }
            }
        } else if r.isUnique {
            if Set(v).count != v.count {
                r.emit(&sink, "not_unique", field, span, path, override, [:], nil)
            }
        } else {
            r.applyCollectionCount(v.count, override, field, span, path, &sink)
        }
    }
}

/// Any other element type: count-shaped rules only. The macro refuses `.unique`/`.each`
/// on element types without a typed overload, with a diagnostic naming the type.
@inlinable
public func _assayValidate<T>(
    countOf v: [T], _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathComponent], _ sink: inout IssueSink
) {
    for r in rules {
        r.applyCollectionCount(v.count, override, field, span, path, &sink)
    }
}
