//===----------------------------------------------------------------------===//
// Issues<Root> — the surface a cross-field @Check writes into.
//
//     @Check
//     static func endAfterStart(_ r: DateRange, _ issues: inout Issues<DateRange>) {
//         if r.end < r.start { issues.add("must be on or after start", at: \.end) }
//     }
//
// Generic over the root type, which is what makes `\.end` resolve — the first edition of
// the design wrote `inout Issues` and the key path had nothing to resolve against
// (EXPERIENCE.md §10). The key path does real work: the macro emits a keypath→wire-key
// table, so the issue lands on `end` with the right path.
//
// A struct passed `inout`, like the sink itself: static exclusivity, no boxing, and the
// collected issues merge into the sink after the check returns.
//===----------------------------------------------------------------------===//

public struct Issues<Root>: @unchecked Sendable {
    // @unchecked: the keypath→name table is immutable, and PartialKeyPath predates
    // Sendable; every stored property is either Sendable or never mutated.
    @usableFromInline var collected: [Issue] = []
    @usableFromInline let names: [PartialKeyPath<Root>: String]

    public init(names: [PartialKeyPath<Root>: String]) {
        self.names = names
    }

    /// Add an issue with a plain message. The message is the code — the one-off custom
    /// check case where forcing an invented code would be obnoxious.
    public mutating func add(_ message: String, at keyPath: PartialKeyPath<Root>? = nil) {
        collected.append(Issue(
            code: .custom(message),
            path: fieldPath(keyPath)))
    }

    /// Add an issue with a machine code, for checks whose failures clients branch on or
    /// localise: `issues.add(code: "company_domain", "must be a company address")`.
    public mutating func add(
        code: String,
        _ message: String,
        params: [String: IssueValue] = [:],
        at keyPath: PartialKeyPath<Root>? = nil
    ) {
        var params = params
        params["message"] = .string(message)
        collected.append(Issue(
            code: .custom(code),
            path: fieldPath(keyPath),
            params: params))
    }

    func fieldPath(_ keyPath: PartialKeyPath<Root>?) -> [PathComponent] {
        guard let kp = keyPath, let name = names[kp] else { return [] }
        return [.key(name)]
    }

    /// Called by generated code after the check returns.
    public func merge(into sink: inout IssueSink, at path: [PathComponent]) {
        for var issue in collected {
            issue.path = path + issue.path
            sink.add(issue)
        }
    }

    public var isEmpty: Bool { collected.isEmpty }
}
