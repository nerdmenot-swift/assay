// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Rule. docs/EXPERIENCE.md §5.
//
// **Non-generic, and that turns out to be an advantage.** Leading-dot syntax like
// `.min(1)` inside an attribute has no type context from which Swift could infer a
// generic parameter, so `Rule<Value>` would force `Rule<String>.min(1)` at every call
// site. The cost — the type system no longer stops `@Validate(.email) var age: Int` —
// is paid at a better layer: the macro sees both the rule text and the declared type,
// and emits a purpose-written diagnostic. Swift's generic diagnostics are not its strong
// suit; a purpose-written one beats them.
//
// The same non-genericity is what makes composition work with no machinery:
//
//     extension Rule {
//         static let companySlug = Rule.all(.min(3), .max(40), .regex("^[a-z][a-z0-9-]*$"))
//     }
//
// `static let` on a plain extension, found by leading-dot syntax. That is the direct
// payoff for not being generic.
//
// **`Rule: ExpressibleByStringLiteral`** is what lets `@Validate(.min(12), "message")`
// compile at all: a parameter after a variadic must have a label in Swift (there are
// eight separate compiler tests asserting exactly that), so the literal *is* a rule —
// one that carries no check, only a message that overrides every other rule in the same
// attribute.
//===----------------------------------------------------------------------===//

/// A validation rule. Polymorphic in the way Zod users expect — `.min(1)` is length on a
/// `String`, count on an `Array`, magnitude on a number — with the resolution done by the
/// macro at expansion time, not by the type system.

/// A pattern compiled ONCE, at `Rule` construction, rather than once per validated value.
///
/// `@Validate(.regex(...))` used to call `try? Regex(pattern)` for every value, so a rule
/// reached through `.each` on an array paid a full regex compilation per element. The rule
/// arrays are `nonisolated static let`, so construction happens once per process under
/// `swift_once` — which makes construction the obvious place to compile, and is exactly
/// where `.before(_:)` already parses its ISO bound.
///
/// WHY A CLASS, AND WHY `@unchecked`. `Regex` carries no `Sendable` conformance — checked
/// against the shipped `.swiftinterface`, not assumed — and `Rule` must be `Sendable` to be
/// the element type of a `static let` under Swift 6. That mismatch is the whole of what
/// `ROADMAP.md` meant by "a cache needs synchronisation the validation path currently has
/// none of". The `@unchecked` is EARNED rather than asserted, in two steps: the initialiser
/// warms the matching program with one throwaway match before the value can be shared, so
/// nothing is lowered lazily on a shared instance afterwards; and
/// `Tests/AssayTests/ConcurrencyTests.swift` hammers a regex-carrying schema from a task
/// group, which the suite runs under `--sanitize=thread`.
///
/// A global pattern-to-`Regex` cache was the other option and was rejected: it hashes the
/// pattern per value — the SipHash-per-value cost `docs/PERFORMANCE.md` §1.2 criticises
/// Foundation for — needs a lock on a path `docs/VALIDATE.md` §4 documents as
/// allocation-free and synchronous, and grows without bound.
@usableFromInline
final class CompiledPattern: @unchecked Sendable {
    @usableFromInline let pattern: String
    /// `Regex<AnyRegexOutput>` where the platform has one, erased so no stored property
    /// needs an availability annotation. `nil` means unavailable or did not compile.
    @usableFromInline let compiled: Any?
    /// The pattern was reached on a platform that has an engine and did not compile.
    @usableFromInline let invalid: Bool

    @usableFromInline
    init(_ pattern: String) {
        self.pattern = pattern
        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            if let r = try? Regex(pattern) {
                // Warm the matching program here, while this instance is still local. The
                // stdlib lowers it lazily on first match; doing it now means a shared
                // instance never mutates, whatever the stdlib's internal synchronisation
                // does or does not promise.
                _ = try? r.firstMatch(in: "")
                self.compiled = r
                self.invalid = false
            } else {
                self.compiled = nil
                self.invalid = true
            }
        } else {
            self.compiled = nil
            self.invalid = false
        }
    }
}

public struct Rule: Sendable, ExpressibleByStringLiteral {

    @usableFromInline
    enum Kind: Sendable {
        // Polymorphic bounds. Stored as Double; integer comparisons stay exact within
        // 2^53, far past any realistic validation threshold.
        case min(Double)
        case max(Double)
        case range(Double, Double)

        // Strings.
        case length(Int)
        case notEmpty
        case regex(CompiledPattern)
        case email, url, uuid, hostname, ascii
        case trimmed, lowercased
        case prefix(String), suffix(String), contains(String)
        case oneOf([String])

        // Numbers.
        case positive, negative, nonNegative
        case multipleOf(Double)
        case finite

        // Collections.
        case count(Int, Int)
        case unique
        case each([Rule])

        // Dates. The bound is epoch seconds, computed ONCE when the rule array's
        // `static let` initialises; the String is the bound as the user wrote it, for
        // the message. `.past`/`.future` are deliberately absent: they need "now", the
        // core has no clock, and a clock seam is a design decision — ROADMAP.md.
        case before(Double, String)
        case after(Double, String)
        case betweenDates(Double, Double, String, String)
        /// The bound string did not parse. Fires on every validation, loudly, so a bad
        /// bound cannot pass silently — the macro cannot check a non-literal expression.
        case invalidRuleDate(String)

        // Composition and messages.
        case all([Rule])
        case messageOnly(String)
    }

    /// The rule's contents, IMMUTABLE and shared, so copying a `Rule` is one retain.
    ///
    /// `Rule` stays a value type — nothing can change a rule once built — but its fields
    /// moved behind one reference on 2026-09-20. Every validation copies each rule out of
    /// its `static let` array to call it (the ledger's row 4: `rules[i]`, a buffer pointer
    /// and `pointee` all copied alike), and copying the struct went through `Rule`'s value
    /// witness: the multi-payload `Kind` and the optional message, several retains each.
    /// That was more than half of `base/validate` (callgrind).
    @usableFromInline
    final class Storage: Sendable {
        @usableFromInline let kind: Kind
        /// Per-rule message, from `or:`. Beats the attribute-level override.
        @usableFromInline let message: String?

        @usableFromInline
        init(kind: Kind, message: String?) {
            self.kind = kind
            self.message = message
        }
    }

    @usableFromInline let storage: Storage

    @usableFromInline var kind: Kind { storage.kind }
    /// Per-rule message, from `or:`. Beats the attribute-level override.
    @usableFromInline var message: String? { storage.message }

    @usableFromInline
    init(_ kind: Kind, message: String? = nil) {
        self.storage = Storage(kind: kind, message: message)
    }

    /// The string literal IS a rule: no check, only a message. EXPERIENCE.md §5.
    public init(stringLiteral value: String) {
        self.init(.messageOnly(value))
    }

    /// A copy with this message, applied recursively into `.all` children that have none.
    public func withMessage(_ m: String) -> Rule {
        var k = kind
        if case .all(let children) = kind {
            k = .all(children.map { $0.message == nil ? $0.withMessage(m) : $0 })
        }
        return Rule(k, message: message ?? m)
    }

    // MARK: - Constructors, matching EXPERIENCE.md §5's table

    /// At least `n`: characters for a `String`, elements for an array, magnitude for a
    /// number. Reports `too_small` with `minimum` and, for strings and arrays, `unit`.
    /// `or:` replaces the derived message.
    public static func min(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.min(Double(n)), message: message)
    }
    /// At least `n`, for a `Double` or `Float` field.
    public static func min(_ n: Double, or message: String? = nil) -> Rule {
        Rule(.min(n), message: message)
    }
    /// At most `n`: characters, elements, or magnitude. Reports `too_large`.
    public static func max(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.max(Double(n)), message: message)
    }
    /// At most `n`, for a `Double` or `Float` field.
    public static func max(_ n: Double, or message: String? = nil) -> Rule {
        Rule(.max(n), message: message)
    }
    /// Within `r`, inclusive. Numbers only; reports `not_in_range` with both bounds.
    public static func range(_ r: ClosedRange<Int>, or message: String? = nil) -> Rule {
        Rule(.range(Double(r.lowerBound), Double(r.upperBound)), message: message)
    }
    /// Within `r`, inclusive, for a `Double` or `Float` field.
    public static func range(_ r: ClosedRange<Double>, or message: String? = nil) -> Rule {
        Rule(.range(r.lowerBound, r.upperBound), message: message)
    }

    /// Exactly `n` characters. Strings only; reports `wrong_length`.
    public static func length(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.length(n), message: message)
    }
    /// Not `""` and not `[]`. Strings and arrays; reports `empty`.
    public static let notEmpty = Rule(.notEmpty)
    /// `.notEmpty` with a message of your own.
    public static func notEmpty(or message: String? = nil) -> Rule {
        Rule(.notEmpty, message: message)
    }

    /// The pattern is a `String`, never a `Regex` — a `Regex` in a public signature would
    /// spread `@available(macOS 13, …)` onto every call site that touches a schema
    /// (cross-platform-audit.md §3). The pattern is validated on first use; an invalid
    /// pattern reports `invalid_regex_pattern` rather than silently passing.
    public static func regex(_ pattern: String, or message: String? = nil) -> Rule {
        Rule(.regex(CompiledPattern(pattern)), message: message)
    }

    /// A syntactically plausible email address — one `@`, a local part, a dotted domain.
    /// Deliberately not RFC 5322: that grammar accepts things no mail server delivers to.
    /// Reports `invalid_email`.
    public static let email = Rule(.email)
    public static func email(or message: String? = nil) -> Rule { Rule(.email, message: message) }
    /// An absolute URL with a scheme and a host. Reports `invalid_url`.
    public static let url = Rule(.url)
    public static func url(or message: String? = nil) -> Rule { Rule(.url, message: message) }
    /// The canonical 8-4-4-4-12 hex form, either case. Reports `invalid_uuid`.
    public static let uuid = Rule(.uuid)
    public static func uuid(or message: String? = nil) -> Rule { Rule(.uuid, message: message) }
    /// An RFC 1123 hostname: dotted labels of letters, digits and hyphens, none longer
    /// than 63, the whole no longer than 253. Reports `invalid_hostname`.
    public static let hostname = Rule(.hostname)
    public static func hostname(or message: String? = nil) -> Rule {
        Rule(.hostname, message: message)
    }
    /// Every scalar below U+0080. Reports `not_ascii`.
    public static let ascii = Rule(.ascii)
    public static func ascii(or message: String? = nil) -> Rule { Rule(.ascii, message: message) }
    /// **An assertion, not a normalisation**: the value must ALREADY be free of leading and
    /// trailing whitespace, and one that is not reports `not_trimmed`. `@Preprocess(.trim)`
    /// is the normalisation. Named `.trimmed` until 2026-09-10, which read as the other
    /// thing — a test caught that once and the rename makes the test unnecessary.
    public static let isTrimmed = Rule(.trimmed)
    public static func isTrimmed(or message: String? = nil) -> Rule {
        Rule(.trimmed, message: message)
    }
    /// An assertion: the value must already equal its own lowercase form. Full Unicode case
    /// folding, so `"straße".lowercased()` is itself and `"STRASSE"` is not.
    /// `@Preprocess(.lowercase)` is the normalisation.
    public static let isLowercase = Rule(.lowercased)
    public static func isLowercase(or message: String? = nil) -> Rule {
        Rule(.lowercased, message: message)
    }

    /// Starts with `s`. Reports `missing_prefix` with `prefix`.
    public static func prefix(_ s: String, or message: String? = nil) -> Rule {
        Rule(.prefix(s), message: message)
    }
    /// Ends with `s`. Reports `missing_suffix` with `suffix`.
    public static func suffix(_ s: String, or message: String? = nil) -> Rule {
        Rule(.suffix(s), message: message)
    }
    /// Contains `s` somewhere. Reports `missing_substring` with `substring`.
    public static func contains(_ s: String, or message: String? = nil) -> Rule {
        Rule(.contains(s), message: message)
    }
    /// Exactly one of `options`, compared as whole strings. For a closed set that is
    /// known at compile time an `enum … : String, JSONAssayable` is the better tool — it
    /// gives the typed value and the same did-you-mean. Reports `not_one_of`.
    public static func oneOf(_ options: [String], or message: String? = nil) -> Rule {
        Rule(.oneOf(options), message: message)
    }

    /// Strictly greater than zero. Reports `not_positive`.
    public static let positive = Rule(.positive)
    public static func positive(or message: String? = nil) -> Rule {
        Rule(.positive, message: message)
    }
    /// Strictly less than zero. Reports `not_negative`.
    public static let negative = Rule(.negative)
    public static func negative(or message: String? = nil) -> Rule {
        Rule(.negative, message: message)
    }
    /// Zero or more. Reports `negative`.
    public static let nonNegative = Rule(.nonNegative)
    public static func nonNegative(or message: String? = nil) -> Rule {
        Rule(.nonNegative, message: message)
    }
    /// Divisible by `n`. Reports `not_multiple` with `divisor`.
    public static func multipleOf(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.multipleOf(Double(n)), message: message)
    }
    /// A multiple of `n`, for a `Double` field — `0.25` for a quarter-step, say.
    public static func multipleOf(_ n: Double, or message: String? = nil) -> Rule {
        Rule(.multipleOf(n), message: message)
    }
    /// Not NaN and not infinite. A JSON document cannot spell either, so this matters
    /// for `T.validate(_:)` on a value some other reader produced. Reports `not_finite`.
    public static let finite = Rule(.finite)
    public static func finite(or message: String? = nil) -> Rule { Rule(.finite, message: message) }

    /// Between `r.lowerBound` and `r.upperBound` elements, inclusive. Arrays only;
    /// reports `wrong_count` with both bounds.
    public static func count(_ r: ClosedRange<Int>, or message: String? = nil) -> Rule {
        Rule(.count(r.lowerBound, r.upperBound), message: message)
    }
    /// Exactly `n` elements.
    public static func count(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.count(n, n), message: message)
    }
    /// No two elements equal. Elements must be `String`, `Int` or `Double`. Reports
    /// `not_unique`.
    public static let unique = Rule(.unique)
    public static func unique(or message: String? = nil) -> Rule { Rule(.unique, message: message) }
    /// Apply `rules` to every element. The issue path carries the element index —
    /// `recipients[2]` — and `or:` sets the message for every element that fails.
    public static func each(_ rules: Rule..., or message: String? = nil) -> Rule {
        Rule(.each(rules), message: message)
    }

    // MARK: Dates
    //
    // Bounds are written as ISO-8601 — full date-time, or bare `yyyy-MM-dd` read as
    // midnight UTC — and parsed once, when the rule array's `static let` initialises.
    // A bound that does not parse becomes `.invalidRuleDate`, which fails EVERY value
    // with a message naming the bound: a misspelled bound must not validate anything.

    /// Strictly earlier than the bound. `@Validate(.before("2030-01-01")) var d: Date`
    public static func before(_ iso: String, or message: String? = nil) -> Rule {
        guard let bound = dateBound(iso) else {
            return Rule(.invalidRuleDate(iso), message: message)
        }
        return Rule(.before(bound, iso), message: message)
    }

    /// Strictly later than the bound.
    public static func after(_ iso: String, or message: String? = nil) -> Rule {
        guard let bound = dateBound(iso) else {
            return Rule(.invalidRuleDate(iso), message: message)
        }
        return Rule(.after(bound, iso), message: message)
    }

    /// Inclusive on both ends.
    public static func between(
        _ lo: String, _ hi: String, or message: String? = nil
    ) -> Rule {
        guard let l = dateBound(lo), let h = dateBound(hi) else {
            return Rule(.invalidRuleDate(dateBound(lo) == nil ? lo : hi), message: message)
        }
        return Rule(.betweenDates(l, h, lo, hi), message: message)
    }

    @usableFromInline
    static func dateBound(_ s: String) -> Double? {
        if case .success(let v) = DateParser.parse(s, as: .iso8601) { return v }
        if case .success(let v) = DateParser.parse(s, as: .pattern("yyyy-MM-dd")) { return v }
        return nil
    }

    /// Composition: all of these, as one value. What makes `static let companySlug` work.
    public static func all(_ rules: Rule...) -> Rule {
        Rule(.all(rules))
    }
}
