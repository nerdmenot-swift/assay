// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `Data` input, without the copy it used to cost.
//
// WHY HERE AND NOT IN THE CORE. `Data` is Foundation, and `Assay` takes bytes precisely so
// that no hot path routes through Foundation — `docs/EXPERIENCE.md` §16 makes the argument in
// full, and it is not the obvious one: `Data`'s byte access is *faster* off Apple platforms,
// because Apple retains a legacy ABI the others were free to drop, so a `Data`-typed hot path
// is the one place where performance would genuinely differ by platform. This file is
// therefore a bridge in `AssayFoundation`, exactly where that document says it lives, and it
// has been promised there since before there was an implementation.
//
// WHAT IT BUYS. Until now a `Data` caller wrote `Array(data)`, which copies the whole
// document before the parse begins — one full copy of a request body, on every request. These
// overloads decode inside `withUnsafeBytes`, so nothing is copied at all.
//
// THE ONE PLACE THIS DIFFERS FROM THE `[UInt8]` DOOR, stated because it is a real difference
// and not an implementation detail. `Diagnosis.source` holds the input so `render(.terminal)`
// can draw a caret afterwards, and a `Data`'s bytes are only valid inside `withUnsafeBytes` —
// `Data` is a struct with an inline representation, so there is no object whose lifetime
// `SourceBytes.init(unsafeBorrowed:count:owner:)` could hold on to (that initialiser exists
// for `MappedFile`, which really does own its pages). So the bytes are retained **only when
// there is something to render**: a clean decode copies nothing and `source` is empty; a
// decode with any issue or warning copies once, inside the same scope, so carets and
// `render(.json)` are byte-identical to the array door's. The asymmetry is defensible because
// the caller passed the `Data` in and still holds it — unlike the array door, whose whole
// point is that `Diagnosis` keeps the bytes so the caller need not.
//
// Every overload here delegates to the same `_decode` seam the array and mapped doors use, so
// none of them can drift: same whole-buffer UTF-8 validation, same scanner, same
// trailing-content check, same `maxBytes` issue.
//===----------------------------------------------------------------------===//

public import Foundation
public import Assay
public import AssayCore

// MARK: - The shared bridge

/// Decode `data` through `body`, and keep the bytes only if the sink has something to say.
///
/// `body` runs inside `Data.withUnsafeBytes`, so it must not let the pointer escape — none of
/// the callers below do; each one hands it straight to a `_decode`.
@inline(__always)
private func _assayWithData<T>(
    _ data: Data,
    limits: Limits,
    sourceName: String,
    _ body: (UnsafePointer<UInt8>, Int, inout IssueSink) -> T?
) -> Diagnosis<T> where T: Sendable {
    var sink = IssueSink(limits: limits)

    // Checked before the buffer is touched, and named in the issue, exactly as the array
    // door does it.
    if data.count > limits.maxBytes {
        sink.add(Issue(code: .tooManyBytes, params: ["maxBytes": .int(limits.maxBytes)]))
        return Diagnosis(sink: sink, value: nil, source: .empty, sourceName: sourceName)
    }

    return unsafe data.withUnsafeBytes { raw -> Diagnosis<T> in
        guard let base = unsafe raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            // An empty `Data` has no base address, while an empty `Array` has the shared
            // empty-buffer singleton and therefore a real one. Routing through a zero-byte
            // buffer keeps the two doors' reports identical on empty input, which a test
            // pins — the alternative was an issue code that only the `Data` door could
            // produce.
            return unsafe withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1) { tmp in
                let value = unsafe body(tmp.baseAddress!, 0, &sink)
                return Diagnosis(sink: sink, value: value,
                                 source: unsafe _assaySource(sink, tmp.baseAddress!, 0),
                                 sourceName: sourceName)
            }
        }
        let value = unsafe body(base, raw.count, &sink)
        return Diagnosis(sink: sink, value: value,
                         source: unsafe _assaySource(sink, base, raw.count),
                         sourceName: sourceName)
    }
}

/// The bytes, but only when a renderer will want them. See the header.
@inline(__always)
private func _assaySource(
    _ sink: IssueSink, _ base: UnsafePointer<UInt8>, _ count: Int
) -> SourceBytes {
    guard !sink.issues.isEmpty || !sink.warnings.isEmpty else { return .empty }
    return unsafe SourceBytes(Array(UnsafeBufferPointer(start: base, count: count)))
}

// MARK: - The two verbs

extension JSONAssayable {

    /// Decode from `Data`, reporting everything.
    ///
    /// Nothing is copied on a clean decode; see this file's header for what `source` holds.
    public static func diagnose(
        json data: Data,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        unsafe _assayWithData(data, limits: limits, sourceName: sourceName) { base, count, sink in
            unsafe Self._decode(base: base, count: count, into: &sink, limits: limits)
        }
    }

    /// Decode from `Data`, or throw with every issue found.
    public static func parse(
        json data: Data,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(json: data, limits: limits, sourceName: sourceName).get()
    }
}

// MARK: - Async checks

extension JSONAssayable where Self: AsyncCheckAssayable {

    /// The async pair. The decode itself stays synchronous — only the checks await — so the
    /// zero-copy scope closes before the first suspension, which is also why this cannot
    /// simply forward to the sync overload's `Diagnosis` and then await inside it.
    public static func diagnose(
        json data: Data,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async -> Diagnosis<Self> {
        // Pinned to the SYNC overload by its function type: an async context otherwise
        // prefers this very function and recurses. `AsyncEntry.swift` has the same line for
        // the same reason.
        let syncDiagnose: (Data, Limits, String) -> Diagnosis<Self> =
            Self.diagnose(json:limits:sourceName:)
        let d = syncDiagnose(data, limits, sourceName)
        guard let value = d.value, d.isValid else { return d }

        let asyncIssues = await Self._assayAsyncChecks(value, at: [])
        guard !asyncIssues.isEmpty else { return d }
        // An async check failed, so there IS something to render now — and the sync pass,
        // having been clean, kept no bytes. Copy them here, where the cost is paid by a
        // failure rather than by every request.
        return Diagnosis(value: nil, issues: d.issues + asyncIssues, warnings: d.warnings,
                         truncatedIssues: d.truncatedIssues,
                         source: SourceBytes(Array(data)), sourceName: sourceName)
    }

    public static func parse(
        json data: Data,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) async throws -> Self {
        try await diagnose(json: data, limits: limits, sourceName: sourceName).get()
    }
}

// MARK: - The contextual door

extension ContextualJSONAssayable {

    public static func diagnose(
        json data: Data,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        unsafe _assayWithData(data, limits: limits, sourceName: sourceName) { base, count, sink in
            unsafe Self._decode(base: base, count: count, into: &sink,
                                limits: limits, context: context)
        }
    }

    public static func parse(
        json data: Data,
        context: AssayContext,
        limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        try diagnose(json: data, context: context,
                     limits: limits, sourceName: sourceName).get()
    }
}

// MARK: - The runtime schema value

extension Assayer {

    /// `Assayer<T>` decodes through `JSON.Value`, so this door saves the input copy and not
    /// the tree — the tree is what a runtime schema is for.
    public func diagnose(
        json data: Data, limits: Limits = .default, sourceName: String = "<input>"
    ) -> Diagnosis<T> {
        let d: Diagnosis<JSON.Value> = unsafe _assayWithData(
            data, limits: limits, sourceName: sourceName
        ) { base, count, sink in
            unsafe JSON.Value._decode(base: base, count: count, into: &sink, limits: limits)
        }
        guard let tree = d.value, d.isValid else {
            return Diagnosis(value: nil, issues: d.issues, warnings: d.warnings,
                             truncatedIssues: d.truncatedIssues,
                             source: d.source, sourceName: sourceName)
        }
        let inner = diagnose(RawValue(tree), limits: limits, sourceName: sourceName)
        return Diagnosis(value: inner.value, issues: d.issues + inner.issues,
                         warnings: d.warnings + inner.warnings,
                         truncatedIssues: inner.truncatedIssues,
                         // The plan's own issues carry spans into this document, so they
                         // need the bytes even though the scan itself was clean.
                         source: inner.isValid && inner.warnings.isEmpty
                             ? d.source : SourceBytes(Array(data)),
                         sourceName: sourceName)
    }

    public func parse(
        json data: Data, limits: Limits = .default, sourceName: String = "<input>"
    ) throws -> T {
        try diagnose(json: data, limits: limits, sourceName: sourceName).get()
    }
}

// MARK: - The generic value model

extension JSON.Value {

    /// Parse a whole `Data` document into a `JSON.Value`, with no copy of the input.
    public static func parse(
        _ data: Data,
        limits: Limits = .default
    ) throws(AssayError) -> JSON.Value {
        let d: Diagnosis<JSON.Value> = unsafe _assayWithData(
            data, limits: limits, sourceName: "<input>"
        ) { base, count, sink in
            unsafe JSON.Value._decode(base: base, count: count, into: &sink, limits: limits)
        }
        guard let value = d.value, d.isValid else {
            throw AssayError(issues: d.issues, source: d.source, sourceName: d.sourceName)
        }
        return value
    }
}

// MARK: - An HTTP body

extension RawDecodable {

    /// Content negotiation over a `Data` body.
    ///
    /// **This one copies, and the reason is structural rather than incidental.** Negotiation
    /// may land on YAML, XML, TOML or a plist, whose parsers live in modules
    /// `AssayFoundation` cannot see — depending on them here would pull every format into
    /// every `Data` user's binary — so the bytes go through `WireFormat.decode`, which takes
    /// an array. The copy is still worth having as a call the user does not have to write,
    /// and the negotiation itself happens BEFORE it: a body whose media type is not in
    /// `accepting` is refused without the copy, let alone a parser.
    public static func diagnose(
        body data: Data,
        contentType: String?,
        accepting: [WireFormat],
        limits: Limits = .default,
        sourceName: String = "<body>"
    ) -> Diagnosis<Self> {
        if case .failure(let why) = _assayNegotiate(contentType: contentType,
                                                    accepting: accepting) {
            var sink = IssueSink(limits: limits)
            sink.add(why.issue)
            return Diagnosis(sink: sink, value: nil, source: .empty, sourceName: sourceName)
        }
        return diagnose(body: Array(data), contentType: contentType, accepting: accepting,
                        limits: limits, sourceName: sourceName)
    }

    public static func parse(
        body data: Data,
        contentType: String?,
        accepting: [WireFormat],
        limits: Limits = .default,
        sourceName: String = "<body>"
    ) throws -> Self {
        try diagnose(body: data, contentType: contentType, accepting: accepting,
                     limits: limits, sourceName: sourceName).get()
    }
}

extension RawDecodable where Self: JSONAssayable {

    /// The same door for a type that also decodes JSON from bytes directly — and here a
    /// `.json` body IS zero-copy, because it routes to the JSON door above rather than
    /// through `RawValue`. That asymmetry already exists on the array door
    /// (`Negotiate.swift`) for the same reason: a JSON body arriving through negotiation
    /// must cost what one arriving through the front door costs.
    public static func diagnose(
        body data: Data,
        contentType: String?,
        accepting: [WireFormat],
        limits: Limits = .default,
        sourceName: String = "<body>"
    ) -> Diagnosis<Self> {
        switch _assayNegotiate(contentType: contentType, accepting: accepting) {
        case .failure(let why):
            var sink = IssueSink(limits: limits)
            sink.add(why.issue)
            return Diagnosis(sink: sink, value: nil, source: .empty, sourceName: sourceName)
        // `format.name == "json"` is how the array door spells this too: a `WireFormat` is
        // a VALUE of closures, not an enum case, so there is nothing to pattern-match.
        case .success(let format) where format.name == "json":
            return diagnose(json: data, limits: limits, sourceName: sourceName)
        case .success:
            return diagnose(body: Array(data), contentType: contentType,
                            accepting: accepting, limits: limits, sourceName: sourceName)
        }
    }

    public static func parse(
        body data: Data,
        contentType: String?,
        accepting: [WireFormat],
        limits: Limits = .default,
        sourceName: String = "<body>"
    ) throws -> Self {
        try diagnose(body: data, contentType: contentType, accepting: accepting,
                     limits: limits, sourceName: sourceName).get()
    }
}

// MARK: - What a missing capability looks like, for a `Data` body

// The same mechanism as `Assay/CapabilityRefusals.swift`, extended to this file's doors:
// without these, a JSON-only schema calling `parse(body: data)` resolves against the
// `[UInt8]` refusal above and reports "cannot convert value of type 'Data' to expected
// argument type '[UInt8]'" — a type error about the argument, when the real answer is that
// the schema needs the `RawValue` projection. The real members live on `RawDecodable`, so a
// type that HAS the projection resolves to them; these catch everything else.
extension Assayable {

    @available(*, unavailable, message: "content negotiation chooses a parser at run time, so this door needs the RawValue projection even for `accepting: [.json]`. Add a non-JSON format to its @Schema — `formats: .all` is the usual answer.")
    public static func parse(body data: Data, contentType: String?,
                             accepting: [WireFormat], limits: Limits = .default,
                             sourceName: String = "<body>") throws -> Self {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "content negotiation chooses a parser at run time, so this door needs the RawValue projection even for `accepting: [.json]`. Add a non-JSON format to its @Schema — `formats: .all` is the usual answer.")
    public static func diagnose(body data: Data, contentType: String?,
                                accepting: [WireFormat], limits: Limits = .default,
                                sourceName: String = "<body>") -> Diagnosis<Self> {
        fatalError("unavailable")
    }
}
