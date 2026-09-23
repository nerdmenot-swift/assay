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

// THE METHODS LIVE ON `Storage`, NOT ON `Rule` (2026-09-20).
//
// A validation applies its rules straight out of a `static let` array, and a `Rule` is a
// struct holding one reference: copying it out per application was 10,000 retain/release
// pairs per `base/validate` call. Reaching the methods through the box lets the loops below
// BORROW it (`_assayEachRule`) instead. `kind` and `message` are `Storage`'s own stored
// properties, so every body below is unchanged from when it sat on `Rule`.
extension Rule.Storage {

    // MARK: String

    @usableFromInline
    func applyString(
        _ v: String, _ override: String?, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathStep], _ sink: inout IssueSink
    ) {
        // Grapheme clusters, via the shortcut in FormatValidators.characterCount, and
        // computed ONLY in the three arms that need it. Hoisting it above the switch reads
        // better and made `.email`, `.url` and `.uuid` each pay a full character count they
        // never look at — 36 ns on a UUID, which is more than the UUID check itself.
        switch kind {
        case .min(let n):
            if FormatValidators.characterCount(v) < Int(n) {
                emit(
                    &sink, .tooSmall, field, span, path, override,
                    ["minimum": .int(Int(n)), "unit": .string("characters")], v)
            }
        case .max(let n):
            if FormatValidators.characterCount(v) > Int(n) {
                emit(
                    &sink, .tooLarge, field, span, path, override,
                    ["maximum": .int(Int(n)), "unit": .string("characters")], v)
            }
        case .length(let n):
            if FormatValidators.characterCount(v) != n {
                emit(
                    &sink, .wrongLength, field, span, path, override,
                    ["length": .int(n)], v)
            }
        case .notEmpty:
            if v.isEmpty {
                emit(&sink, .empty, field, span, path, override, [:], v)
            }
        case .regex(let pattern):
            applyRegex(pattern, to: v, override, field, span, path, &sink)
        case .email:
            if !FormatValidators.isEmail(v) {
                emit(&sink, .invalidEmail, field, span, path, override, [:], v)
            }
        case .url:
            if !FormatValidators.isURL(v) {
                emit(&sink, .invalidUrl, field, span, path, override, [:], v)
            }
        case .uuid:
            if !FormatValidators.isUUID(v) {
                emit(&sink, .invalidUuid, field, span, path, override, [:], v)
            }
        case .hostname:
            if !FormatValidators.isHostname(v) {
                emit(&sink, .invalidHostname, field, span, path, override, [:], v)
            }
        case .ascii:
            if !FormatValidators.isASCII(v) {
                emit(&sink, .notAscii, field, span, path, override, [:], v)
            }
        case .trimmed:
            if !FormatValidators.isTrimmed(v) {
                emit(&sink, .notTrimmed, field, span, path, override, [:], v)
            }
        case .lowercased:
            if v != v.lowercased() {
                emit(&sink, .notLowercased, field, span, path, override, [:], v)
            }
        case .prefix(let p):
            if !v.hasPrefix(p) {
                emit(
                    &sink, .missingPrefix, field, span, path, override,
                    ["prefix": .string(p)], v)
            }
        case .suffix(let sfx):
            if !v.hasSuffix(sfx) {
                emit(
                    &sink, .missingSuffix, field, span, path, override,
                    ["suffix": .string(sfx)], v)
            }
        case .contains(let sub):
            if !FormatValidators.containsSubstring(v, sub) {
                emit(
                    &sink, .missingSubstring, field, span, path, override,
                    ["substring": .string(sub)], v)
            }
        case .oneOf(let options):
            if !options.contains(v) {
                emit(
                    &sink, .notOneOf, field, span, path, override,
                    ["options": .string(options.map { "\"\($0)\"" }.joined(separator: ", "))],
                    v)
            }
        case .all(let rules):
            _assayEachRule(rules) { $0.applyString(v, override, field, span, path, &sink) }
        case .messageOnly:
            break  // carried via the override channel
        default:
            break  // numeric/collection kinds: macro-prevented
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
        _ p: CompiledPattern, to v: String, _ override: String?, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathStep], _ sink: inout IssueSink
    ) {
        // Every branch reports exactly what it reported before this was compiled once
        // instead of per value — same three codes, same params, same messages. Only the
        // compilation moved.
        if p.invalid {
            emit(
                &sink, .invalidRegexPattern, field, span, path, override,
                ["pattern": .string(p.pattern)], v)
            return
        }
        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            guard let regex = p.compiled as? Regex<AnyRegexOutput> else {
                emit(
                    &sink, .regexUnavailable, field, span, path, override,
                    ["pattern": .string(p.pattern)], v)
                return
            }
            if (try? regex.firstMatch(in: v)) == nil {
                emit(
                    &sink, .patternMismatch, field, span, path, override,
                    ["pattern": .string(p.pattern)], v)
            }
        } else {
            emit(
                &sink, .regexUnavailable, field, span, path, override,
                ["pattern": .string(p.pattern)], v)
        }
    }

    // MARK: Numbers

    @usableFromInline
    func applyNumber(
        _ v: Double, isInteger: Bool, _ override: String?, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathStep], _ sink: inout IssueSink
    ) {
        switch kind {
        case .min(let n):
            if v < n {
                emit(
                    &sink, .tooSmall, field, span, path, override,
                    ["minimum": numberParam(n, isInteger)], display(v, isInteger))
            }
        case .max(let n):
            if v > n {
                emit(
                    &sink, .tooLarge, field, span, path, override,
                    ["maximum": numberParam(n, isInteger)], display(v, isInteger))
            }
        case .range(let lo, let hi):
            if v < lo || v > hi {
                emit(
                    &sink, .notInRange, field, span, path, override,
                    [
                        "minimum": numberParam(lo, isInteger),
                        "maximum": numberParam(hi, isInteger)
                    ], display(v, isInteger))
            }
        case .positive:
            if !(v > 0) {
                emit(
                    &sink, .notPositive, field, span, path, override, [:],
                    display(v, isInteger))
            }
        case .negative:
            if !(v < 0) {
                emit(
                    &sink, .notNegative, field, span, path, override, [:],
                    display(v, isInteger))
            }
        case .nonNegative:
            if v < 0 {
                emit(
                    &sink, .negative, field, span, path, override, [:],
                    display(v, isInteger))
            }
        case .multipleOf(let m):
            let remainder = v.truncatingRemainder(dividingBy: m)
            if abs(remainder) > 1e-9 && abs(abs(remainder) - abs(m)) > 1e-9 {
                emit(
                    &sink, .notMultiple, field, span, path, override,
                    ["multipleOf": numberParam(m, isInteger)], display(v, isInteger))
            }
        case .finite:
            if !v.isFinite {
                emit(&sink, .notFinite, field, span, path, override, [:], String(v))
            }

        // Dates reach this overload as epoch seconds (the generated code passes
        // `.timeIntervalSince1970`); the received value renders back as ISO-8601 so a
        // violation reads as a date, never as 1786363800.0.
        case .before(let bound, let display):
            if !(v < bound) {
                emit(
                    &sink, .dateNotBefore, field, span, path, override,
                    ["bound": .string(display)], formatEpochISO(v))
            }
        case .after(let bound, let display):
            if !(v > bound) {
                emit(
                    &sink, .dateNotAfter, field, span, path, override,
                    ["bound": .string(display)], formatEpochISO(v))
            }
        case .betweenDates(let lo, let hi, let displayLo, let displayHi):
            if v < lo || v > hi {
                emit(
                    &sink, .dateNotBetween, field, span, path, override,
                    ["minimum": .string(displayLo), "maximum": .string(displayHi)],
                    formatEpochISO(v))
            }
        case .invalidRuleDate(let bound):
            emit(
                &sink, .invalidRuleDate, field, span, path, override,
                ["bound": .string(bound)], nil)

        case .all(let rules):
            _assayEachRule(rules) {
                $0.applyNumber(v, isInteger: isInteger, override, field, span, path, &sink)
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
        _ span: SourceSpan?, _ path: [PathStep], _ sink: inout IssueSink
    ) {
        switch kind {
        case .min(let n):
            if count < Int(n) {
                emit(
                    &sink, .tooSmall, field, span, path, override,
                    ["minimum": .int(Int(n)), "unit": .string("items")], "\(count) items")
            }
        case .max(let n):
            if count > Int(n) {
                emit(
                    &sink, .tooLarge, field, span, path, override,
                    ["maximum": .int(Int(n)), "unit": .string("items")], "\(count) items")
            }
        case .count(let lo, let hi):
            if count < lo || count > hi {
                emit(
                    &sink, .wrongCount, field, span, path, override,
                    ["minimum": .int(lo), "maximum": .int(hi)], "\(count) items")
            }
        case .notEmpty:
            if count == 0 {
                emit(&sink, .empty, field, span, path, override, [:], "0 items")
            }
        case .all(let rules):
            _assayEachRule(rules) {
                $0.applyCollectionCount(count, override, field, span, path, &sink)
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
        _ sink: inout IssueSink, _ code: IssueCode, _ field: StaticString,
        _ span: SourceSpan?, _ path: [PathStep], _ override: String?,
        _ params: [String: IssueValue], _ received: String?
    ) {
        var params = params
        if let m = message ?? override {
            params["message"] = .string(m)
        }
        // `.each` passes an empty field name because the element path already ends in the
        // field and index; an empty key would render as "recipients[1]." with a bare dot.
        let name = String(describing: field)
        sink.add(
            Issue(
                code: code,
                path: name.isEmpty ? path : path + [.key(name)],
                params: params,
                received: received,
                location: span))
    }
}

// MARK: - Borrowing a rule out of its array

/// Apply `body` to each rule's storage WITHOUT copying the rule out of the array.
///
/// `for r in rules` loads a `Rule` out of the buffer, which retains its box and releases it
/// again per application — 10,000 pairs per `base/validate` call, for a value the callee only
/// reads. The rules live in a `static let` on the schema type, which outlives every call made
/// here, so an unretained reference to the box cannot dangle; `_withUnsafeGuaranteedRef` is
/// what tells the optimiser that. The closure is non-escaping, so capturing `&sink` inside it
/// is statically enforced exclusivity, not a box (CLAUDE.md rule 3).
///
/// `_withUnsafeGuaranteedRef` is underscored stdlib API. It is used here and nowhere else, and
/// `docs/EFFICIENCY.md` row 4 records what it bought.
@inlinable
func _assayEachRule(_ rules: [Rule], _ body: (Rule.Storage) -> Void) {
    unsafe rules.withUnsafeBufferPointer { buf in
        for i in buf.indices {
            unsafe Unmanaged.passUnretained(buf[i].storage)._withUnsafeGuaranteedRef(body)
        }
    }
}

// MARK: - The entry points generated code calls

/// One call per @Validate attribute; the rules array is a `static let` on the schema type.
@inlinable
public func _assayValidate(
    _ v: String, _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathStep], _ sink: inout IssueSink
) {
    _assayEachRule(rules) { $0.applyString(v, override, field, span, path, &sink) }
}

@inlinable
public func _assayValidate(
    _ v: Int64, _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathStep], _ sink: inout IssueSink
) {
    _assayEachRule(rules) {
        $0.applyNumber(Double(v), isInteger: true, override, field, span, path, &sink)
    }
}

@inlinable
public func _assayValidate(
    _ v: UInt64, _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathStep], _ sink: inout IssueSink
) {
    _assayEachRule(rules) {
        $0.applyNumber(Double(v), isInteger: true, override, field, span, path, &sink)
    }
}

@inlinable
public func _assayValidate(
    _ v: Double, _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathStep], _ sink: inout IssueSink
) {
    _assayEachRule(rules) {
        $0.applyNumber(v, isInteger: false, override, field, span, path, &sink)
    }
}

/// String arrays: count rules, `.unique`, and `.each` with string rules per element.
@inlinable
public func _assayValidate(
    _ v: [String], _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathStep], _ sink: inout IssueSink
) {
    _assayEachRule(rules) { r in
        if let inner = r.eachRules {
            // ONE PATH PER FIELD, NOT ONE PER ELEMENT, and the index written in place.
            //
            // This built `path + [.key(String(describing: field)), .index(i)]` per element,
            // unconditionally — a `StaticString`→`String` conversion and an array concat,
            // both on the SUCCESS path, where `applyString` reads `path` only inside
            // `emit`. `r.message ?? override` was per element per rule too.
            //
            // MEASURED HONESTLY, because the first attempt was not. An end-to-end
            // `parse(json:)` A/B said 65 ns/element and did not move when this was
            // hoisted — but that probe was timing JSON decode of every element as well,
            // so most of what it measured had nothing to do with `.each`. Isolating
            // `_assayValidate` gives the real numbers: **29.9 ns/element for `.each`
            // against 22.7 for the same rule called once per element** — 7.2 ns of
            // machinery, not 47. Hoisting takes that to ~3.
            var elementPath = path
            elementPath.append(.key(String(describing: field)))
            elementPath.append(.index(0))
            let last = elementPath.count &- 1
            let message = r.message ?? override
            for (i, element) in v.enumerated() {
                elementPath[last] = .index(i)
                _assayEachRule(inner) {
                    $0.applyString(element, message, "", span, elementPath, &sink)
                }
            }
        } else if r.isUnique {
            if Set(v).count != v.count {
                r.emit(&sink, .notUnique, field, span, path, override, [:], nil)
            }
        } else {
            r.applyCollectionCount(v.count, override, field, span, path, &sink)
        }
    }
}

@inlinable
public func _assayValidate(
    _ v: [Int], _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathStep], _ sink: inout IssueSink
) {
    _assayEachRule(rules) { r in
        if let inner = r.eachRules {
            // One path per field and one message per rule, as the `[String]` overload
            // above has done since 2026-09-13; these two still built a path per element
            // and re-read `r.message` per element per rule until 2026-09-20.
            var elementPath = path
            elementPath.append(.key(String(describing: field)))
            elementPath.append(.index(0))
            let last = elementPath.count &- 1
            let message = r.message ?? override
            for (i, element) in v.enumerated() {
                elementPath[last] = .index(i)
                _assayEachRule(inner) {
                    $0.applyNumber(
                        Double(element), isInteger: true, message, "", span, elementPath, &sink)
                }
            }
        } else if r.isUnique {
            if Set(v).count != v.count {
                r.emit(&sink, .notUnique, field, span, path, override, [:], nil)
            }
        } else {
            r.applyCollectionCount(v.count, override, field, span, path, &sink)
        }
    }
}

/// Rules over a `[Double]`.
///
/// **`.unique` here uses `Double`'s own equality, not `RawValue`'s**, and the two disagree
/// in both directions. Swift says `NaN != NaN`, so `[.nan, .nan]` **passes** `.unique`; Swift
/// says `0.0 == -0.0`, so `[0.0, -0.0]` **fails** it. `RawValue.==` folds NaN and separates
/// the zeroes, giving the opposite answer on both.
///
/// Left that way deliberately, and the reason is whose value it is: this rule runs over the
/// user's own `[Double]`, whose element semantics are Swift's. Substituting a different
/// equality because a *different type in this library* needed one would be exactly the kind
/// of quiet surprise the library exists to remove. Stated so it is a contract; pinned by
/// tests in `Tests/AssayTests/ValueModelTests.swift`.
@inlinable
public func _assayValidate(
    _ v: [Double], _ rules: [Rule], override: String?, field: StaticString,
    at span: SourceSpan?, path: [PathStep], _ sink: inout IssueSink
) {
    _assayEachRule(rules) { r in
        if let inner = r.eachRules {
            // One path per field and one message per rule, as the `[String]` overload
            // above has done since 2026-09-13; these two still built a path per element
            // and re-read `r.message` per element per rule until 2026-09-20.
            var elementPath = path
            elementPath.append(.key(String(describing: field)))
            elementPath.append(.index(0))
            let last = elementPath.count &- 1
            let message = r.message ?? override
            for (i, element) in v.enumerated() {
                elementPath[last] = .index(i)
                _assayEachRule(inner) {
                    $0.applyNumber(element, isInteger: false, message, "", span, elementPath, &sink)
                }
            }
        } else if r.isUnique {
            if Set(v).count != v.count {
                r.emit(&sink, .notUnique, field, span, path, override, [:], nil)
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
    at span: SourceSpan?, path: [PathStep], _ sink: inout IssueSink
) {
    _assayEachRule(rules) {
        $0.applyCollectionCount(v.count, override, field, span, path, &sink)
    }
}
