// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Issues are data, not sentences.
//
// docs/EXPERIENCE.md §3: an issue carries a code and a parameter dictionary; the
// English sentence is produced at render time. That is Ecto's {template, params}
// model and it is the difference between a library you can localise and one you
// cannot.
//
// docs/PERFORMANCE.md §7: all of this must cost nothing when the data is valid.
// The three rules that keep it free are enforced here and in the generated code:
//   1. `inout IssueSink` and nothing else — never captured by an escaping closure.
//   2. Issue construction lives in a separate, cold-marked function.
//   3. The Limits cap is checked in the failure branch only.
//===----------------------------------------------------------------------===//

/// A byte range into the source document.
///
/// Eight bytes, matching rustc's budget with none of its tagging complexity. Line and
/// column are **not** stored — they are derived on demand by `LineIndex`, because
/// everyone serious does it that way (Swift's `SourceLoc` is one pointer, Clang's is a
/// bare `uint32_t`, serde_json runs `memrchr` backwards at error-construction time).
@frozen
public struct SourceSpan: Sendable, Hashable {
    public var lo: UInt32
    public var len: UInt32

    @inlinable
    public init(lo: UInt32, len: UInt32) {
        self.lo = lo
        self.len = len
    }

    @inlinable
    public init(lo: Int, len: Int) {
        self.lo = UInt32(truncatingIfNeeded: lo)
        self.len = UInt32(truncatingIfNeeded: len)
    }
}

/// One step in the path to a value: `.key("services")`, `.index(2)`.
public enum PathComponent: Sendable, Hashable {
    case key(String)
    case index(Int)
}

extension Array where Element == PathComponent {
    /// `services[2].healthCheck.timeoutSeconds`
    public var pathDescription: String {
        var out = ""
        for c in self {
            switch c {
            case .key(let k):
                if !out.isEmpty { out += "." }
                out += k
            case .index(let i):
                out += "[\(i)]"
            }
        }
        return out
    }
}

/// A machine-readable classification. Match on this, never on `message`.
public enum IssueCode: Sendable, Hashable {
    case missing
    case typeMismatch
    case malformedDocument
    case numberOverflow
    case invalidUTF8
    case unknownKey
    case duplicateKey
    case depthExceeded
    case tooManyBytes
    case trailingContent
    case custom(String)
}

/// A parameter value carried alongside an `IssueCode`.
public enum IssueValue: Sendable, Hashable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
}

/// A hard failure.
public struct Issue: Sendable, Hashable {
    public var code: IssueCode
    public var path: [PathComponent]
    public var params: [String: IssueValue]
    /// What was actually there, rendered for humans. Nil when there was nothing.
    public var received: String?
    public var location: SourceSpan?

    public init(
        code: IssueCode,
        path: [PathComponent] = [],
        params: [String: IssueValue] = [:],
        received: String? = nil,
        location: SourceSpan? = nil
    ) {
        self.code = code
        self.path = path
        self.params = params
        self.received = received
        self.location = location
    }
}

/// A tolerated deviation: a fallback that fired, an alias that matched, an unknown key
/// that was ignored. Only ever surfaced through `diagnose`.
public struct Warning: Sendable, Hashable {
    public var code: IssueCode
    public var path: [PathComponent]
    public var params: [String: IssueValue]
    public var location: SourceSpan?

    public init(
        code: IssueCode,
        path: [PathComponent] = [],
        params: [String: IssueValue] = [:],
        location: SourceSpan? = nil
    ) {
        self.code = code
        self.path = path
        self.params = params
        self.location = location
    }
}

/// The collection buffer, passed `inout` through the whole decode.
///
/// A struct, not a class: exclusivity on an `inout` parameter is statically enforced and
/// free, whereas class stored properties get a `swift_beginAccess`/`swift_endAccess` pair
/// per access. An empty `[Issue]` is a store of the immortal empty-array singleton
/// pointer, so a clean decode allocates nothing here.
///
/// **The generated code must never capture this in an escaping closure.** Doing so boxes
/// it and reintroduces dynamic exclusivity per field.
public struct IssueSink: Sendable {

    // MARK: Container size hints — per-parse scratch, not a diagnostic
    //
    // NOT diagnostics, and a deliberate lodging rather than a natural one. A hint has to
    // outlive one `_assay` call and die with the parse, and the sink is the only per-parse
    // value already threaded `inout` through every decode. The reader would be the obvious
    // home and cannot be: `AssayReader` is the frame of four recursive descent parsers, and
    // sixteen bytes added to it overflowed the 512 KB stack Swift Testing gives its workers,
    // turning `AmplificationTests.yamlDeepNesting` into a SIGBUS. The same sixteen bytes here
    // measured no depth cost at all (probed both ways, 2026-09-20). The alternative — a fourth
    // parameter on every generated `_assay` — would change every signature on every path.
    //
    // TWO slots, matched by site id, which is the common record shape: one array, or an array
    // and a dictionary. A third site evicts, which only mis-sizes a reservation, and no
    // decoded value depends on it. `docs/EFFICIENCY.md` row 2.
    @usableFromInline var hintSiteA: Int32 = -1
    @usableFromInline var hintSizeA: Int32 = 0
    @usableFromInline var hintSiteB: Int32 = -1
    @usableFromInline var hintSizeB: Int32 = 0

    /// What the last container at this site held, or 0 for a site not seen yet.
    @_documentation(visibility: internal)
    @inlinable
    public func _shapeHint(_ site: Int) -> Int {
        let id = Int32(truncatingIfNeeded: site)
        if hintSiteA == id { return Int(hintSizeA) }
        if hintSiteB == id { return Int(hintSizeB) }
        return 0
    }

    /// Record what this container held, for the next one at this site.
    @_documentation(visibility: internal)
    @inlinable
    public mutating func _noteShape(_ n: Int, _ site: Int) {
        let id = Int32(truncatingIfNeeded: site)
        let size = Int32(clamping: n)
        if hintSiteA == id || hintSiteA < 0 {
            hintSiteA = id
            hintSizeA = size
        } else {
            hintSiteB = id
            hintSizeB = size
        }
    }
    public var issues: [Issue] = []
    public var warnings: [Warning] = []
    /// Set when `Limits.maxIssues` was reached, so a caller can tell a hundred-of-a-hundred
    /// from a hundred-of-ten-thousand.
    public var truncatedIssues: Bool = false

    @usableFromInline
    var limits: Limits


    @inlinable
    public init(limits: Limits = .default) {
        self.limits = limits
    }

    @inlinable
    public var isValid: Bool { issues.isEmpty }

    /// Whether `add` would now discard rather than record.
    ///
    /// For callers that do expensive work only to hand it to `add` — the did-you-mean
    /// search is the one that matters, being a Damerau distance against every declared
    /// key. Cheap to ask, and it turns a report nobody sees into a branch.
    @inlinable
    public var isFull: Bool { issues.count >= limits.maxIssues }

    /// Cold: never inlined into the field loop, where it would bloat the hot function
    /// past the escape-analysis complexity budget (`1_000_000 / estimatedFunctionSize`,
    /// divided by a further 10 for ARC queries — and exhaustion is indistinguishable
    /// from "it escapes").
    @inline(never)
    public mutating func add(_ issue: Issue) {
        if issues.count >= limits.maxIssues {
            truncatedIssues = true
            return
        }
        issues.append(issue)
    }

    @inline(never)
    public mutating func add(warning: Warning) {
        if warnings.count >= limits.maxIssues {
            truncatedIssues = true
            return
        }
        warnings.append(warning)
    }
}

// MARK: - Checkpoints, for @Fallback

extension IssueSink {
    /// Number of issues currently collected. `@Fallback` codegen brackets a field's
    /// decode+validation with checkpoint/rollback: on any issue at this field, the
    /// issues are removed, the fallback value is assigned, and a warning records what
    /// happened — "a fallback silently swallowing bad data is the point; the warning is
    /// how you find out" (EXPERIENCE.md §6).
    @inlinable
    public func checkpoint() -> Int { issues.count }

    /// Insert `key` at `position` in the path of every issue added since `checkpoint`.
    ///
    /// A dictionary value's primitive names the FIELD (`"m must be an integer"`) and, for
    /// an array value, the element index (`d[1]`); the entry key is only known to the
    /// loop around it. Until 2026-09-10 the report said `m` when it meant `m.j` and
    /// `d[1]` when it meant `d.a[1]`. `position` is the depth just past the field's own
    /// component, so the key lands between the field and whatever the primitive added.
    /// Cold: called on the failure path only, on the issues that failure added, so the
    /// hot path pays one `checkpoint()` read per entry.
    @inlinable
    @_documentation(visibility: internal)
    public mutating func _insertKey(since checkpoint: Int, _ key: String, at position: Int) {
        _insert(since: checkpoint, .key(key), at: position)
    }

    /// `_insertKey` for any component. An array element whose issues name the FIELD — a
    /// nested array, a dictionary or a date inside an array — gets its `.index(i)` put in
    /// after the fact, on the path that already failed, so a clean decode pays nothing.
    @inline(never)
    @_documentation(visibility: internal)
    public mutating func _insert(since checkpoint: Int, _ c: PathComponent, at position: Int) {
        var i = checkpoint
        while i < issues.count {
            let p = position < issues[i].path.count ? position : issues[i].path.count
            issues[i].path.insert(c, at: p)
            i &+= 1
        }
    }

    @inlinable
    public mutating func rollback(to checkpoint: Int) {
        if issues.count > checkpoint {
            issues.removeLast(issues.count - checkpoint)
        }
    }
}

/// The `alias_matched` warning: `field` was read from `alias`. Cold; every path that
/// honours `@Key(_:or:)` reports through here so the warning is the same on all of them.
@inline(never)
public func _assayAliasMatched(
    _ sink: inout IssueSink, _ path: [PathComponent], _ field: StaticString, _ alias: StaticString
) {
    sink.add(warning: Warning(code: .aliasMatched,
                              path: path + [.key(String(describing: field))],
                              params: ["alias": .string(String(describing: alias))]))
}
