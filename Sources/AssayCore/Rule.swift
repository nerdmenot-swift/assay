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

    @usableFromInline var kind: Kind
    /// Per-rule message, from `or:`. Beats the attribute-level override.
    @usableFromInline var message: String?

    @usableFromInline
    init(_ kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }

    /// The string literal IS a rule: no check, only a message. EXPERIENCE.md §5.
    public init(stringLiteral value: String) {
        self.init(.messageOnly(value))
    }

    /// A copy with this message, applied recursively into `.all` children that have none.
    public func withMessage(_ m: String) -> Rule {
        var r = self
        if case .all(let children) = kind {
            r.kind = .all(children.map { $0.message == nil ? $0.withMessage(m) : $0 })
        }
        if r.message == nil { r.message = m }
        return r
    }

    // MARK: - Constructors, matching EXPERIENCE.md §5's table

    public static func min(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.min(Double(n)), message: message)
    }
    public static func min(_ n: Double, or message: String? = nil) -> Rule {
        Rule(.min(n), message: message)
    }
    public static func max(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.max(Double(n)), message: message)
    }
    public static func max(_ n: Double, or message: String? = nil) -> Rule {
        Rule(.max(n), message: message)
    }
    public static func range(_ r: ClosedRange<Int>, or message: String? = nil) -> Rule {
        Rule(.range(Double(r.lowerBound), Double(r.upperBound)), message: message)
    }
    public static func range(_ r: ClosedRange<Double>, or message: String? = nil) -> Rule {
        Rule(.range(r.lowerBound, r.upperBound), message: message)
    }

    public static func length(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.length(n), message: message)
    }
    public static let notEmpty = Rule(.notEmpty)
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

    public static let email = Rule(.email)
    public static func email(or message: String? = nil) -> Rule { Rule(.email, message: message) }
    public static let url = Rule(.url)
    public static func url(or message: String? = nil) -> Rule { Rule(.url, message: message) }
    public static let uuid = Rule(.uuid)
    public static func uuid(or message: String? = nil) -> Rule { Rule(.uuid, message: message) }
    public static let hostname = Rule(.hostname)
    public static func hostname(or message: String? = nil) -> Rule { Rule(.hostname, message: message) }
    public static let ascii = Rule(.ascii)
    public static func ascii(or message: String? = nil) -> Rule { Rule(.ascii, message: message) }
    public static let trimmed = Rule(.trimmed)
    public static let lowercased = Rule(.lowercased)

    public static func prefix(_ s: String, or message: String? = nil) -> Rule {
        Rule(.prefix(s), message: message)
    }
    public static func suffix(_ s: String, or message: String? = nil) -> Rule {
        Rule(.suffix(s), message: message)
    }
    public static func contains(_ s: String, or message: String? = nil) -> Rule {
        Rule(.contains(s), message: message)
    }
    public static func oneOf(_ options: [String], or message: String? = nil) -> Rule {
        Rule(.oneOf(options), message: message)
    }

    public static let positive = Rule(.positive)
    public static let negative = Rule(.negative)
    public static let nonNegative = Rule(.nonNegative)
    public static func multipleOf(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.multipleOf(Double(n)), message: message)
    }
    public static func multipleOf(_ n: Double, or message: String? = nil) -> Rule {
        Rule(.multipleOf(n), message: message)
    }
    public static let finite = Rule(.finite)

    public static func count(_ r: ClosedRange<Int>, or message: String? = nil) -> Rule {
        Rule(.count(r.lowerBound, r.upperBound), message: message)
    }
    public static func count(_ n: Int, or message: String? = nil) -> Rule {
        Rule(.count(n, n), message: message)
    }
    public static let unique = Rule(.unique)
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
