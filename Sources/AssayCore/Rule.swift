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
        case regex(String)
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
        Rule(.regex(pattern), message: message)
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

    /// Composition: all of these, as one value. What makes `static let companySlug` work.
    public static func all(_ rules: Rule...) -> Rule {
        Rule(.all(rules))
    }
}
