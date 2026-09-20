// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The reader: a cursor over a contiguous UTF-8 buffer.
//
// Design constraints this file exists to satisfy (docs/PERFORMANCE.md §3.3, §8.4):
//   * Holds only transitively trivial things — a pointer, two Ints. A struct containing
//     a String/Array/closure/class is NOT ARC-free, and "structs are ARC-free" is
//     folklore.
//   * Passed `inout`, never stored, never captured escapingly.
//   * Indexes without bounds checks on the hot path. `Span`'s checked subscript uses
//     `_precondition`, which survives `-O`, and elimination requires a linear induction
//     variable — a data-dependent parser cursor is definitionally not one.
//
// PHASE-1 DEVIATION, deliberate and documented:
// docs/PERFORMANCE.md §3.3 specifies a `RawSpan`-backed `~Escapable` reader. This uses a
// raw pointer behind a safe façade instead, following the recommendation in
// docs/research/perf-swift-codegen.md §4.6 / §10 item 20. The reason recorded there was
// that `@_lifetime` is experimental and a `~Escapable` type "would put a feature gate on
// the whole library".
//
// **That half is measurably wrong, as of Swift 6.3.3 (checked 2026-08-19).** A client
// package consumes a `~Escapable` public type and calls its methods with no
// `enableExperimentalFeature` at all, and the escape check still fires. The gate binds only
// a client writing its own `@lifetime` annotation.
//
// The deviation stands on the other, stronger reason: `Escapable` is what `Array`,
// `Optional`, `Equatable` and every ordinary stored property require. A `~Escapable` reader
// would have to stay inside one scope and could never be held — which is fine for a reader
// passed `inout` and never stored, and is exactly why this type is `~Copyable` only. The
// public API takes bytes and never exposes a pointer, so the seam can still move to
// `RawSpan` without a source break.
//
// TWO SURFACES, ONE TYPE, and the underscore is the line between them (2026-09-10).
//
// The UNPREFIXED members are for a decoder written by hand — an `_assay` body for a type
// the macro cannot express, an `AssayerBacked` conformance, a format module: `beginValue`,
// `scanString`/`scanInt64`/`scanDouble`/`scanBool`/`scanNull`, `tryConsume`/`expect`,
// `enterContainer`/`leaveContainer`, `scanKey`/`keyMatches`, `skipValue`, `skipWhitespace`,
// `reportTypeMismatch`/`reportMalformed`/`report`, `lastValueSpan`, `byteOffset`,
// `currentByte`/`byte(at:)`, `mark`/`restore`, `matches`/`consume`, `string(from:to:)`,
// `find`. That is the vocabulary a JSON decoder needs, and it is documented.
//
// The `_`-PREFIXED members exist so that GENERATED code can be one line per field —
// `_decodeIntOrNull` is `beginValue` + `scanInt64` + the null case + the failure report,
// which the emitter would otherwise spell out per field and pay for in compile time
// (docs/COMPILE-TIME.md §3). They are public because the expansion compiles in the user's
// module; they are prefixed and `@_documentation(visibility: internal)` because nobody
// should reach for them. `@_exported import AssayCore` puts every public name in every
// user's namespace, and until 2026-09-10 the seventy-seven of these sat in autocomplete
// beside `parse(json:)`.
//===----------------------------------------------------------------------===//

/// A borrowed view of the input. Valid only for the duration of the enclosing
/// `withUnsafeBytes`-style scope; the public API never hands one to a caller.
@safe
public struct AssayReader: ~Copyable {
    @usableFromInline let base: UnsafePointer<UInt8>
    @usableFromInline let count: Int
    @usableFromInline var cursor: Int
    @usableFromInline var depth: Int
    /// Branch attempts made by untagged unions so far. Global across one decode — see
    /// `Limits.maxUnionAttempts` for why a per-union counter cannot bound what this bounds.
    ///
    /// **Not restored by `restore(_:)`, deliberately.** A `Mark` puts back where the reader
    /// *is*; the budget records work already done, and rewinding must not refund it or the
    /// bound is not a bound.
    @usableFromInline var unionAttempts: Int = 0
    /// Start of the most recent value consumed by a decode entry point. Combined with the
    /// cursor after the decode returns, this is the value's span — captured by generated
    /// code only for fields that carry @Validate, so `replicas: 0` renders with a caret
    /// under the 0. Two integer stores; nothing else on the hot path.
    @usableFromInline var valueStart: Int = 0
    /// Where a string escape went wrong, or -1. `scanStringSlow` sets it and scans on to
    /// the closing quote so the cursor is past the value; `failed` reads it and reports
    /// `invalid_escape` at that byte instead of a type mismatch. One Int, so the reader
    /// stays transitively trivial.
    @usableFromInline var escapeErrorAt: Int = -1

    /// Where a number was syntactically fine and OUT OF RANGE for a `Double`, and how long
    /// it was. Same out-of-band shape as `escapeErrorAt`, for the same reason: `scanDouble`
    /// returns `Double?`, so "this is not a number" and "this number cannot be represented"
    /// arrive at the caller identically unless one of them is recorded on the side.
    @usableFromInline var numberRangeErrorAt: Int = -1
    @usableFromInline var numberRangeErrorLength: Int = 0
    /// Where an ESCAPED key's unescaped bytes live (`KeyRange.simple == false`), so it can be
    /// matched against a declared key like any other. Allocated on the first escaped key and
    /// reused; a document with none never allocates it. See `scanEscapedKey`.
    @usableFromInline var keyScratch: UnsafeMutablePointer<UInt8>? = nil
    @usableFromInline var keyScratchCapacity: Int = 0

    @usableFromInline let limits: Limits

    /// The limits this reader was created with. Public because generated code consults
    /// `verboseUnions` — a union's failure path branches on it — and a generated body cannot
    /// reach an internal member.
    @inlinable
    public var activeLimits: Limits { limits }

    @inlinable
    deinit { unsafe keyScratch?.deallocate() }


    public init(base: UnsafePointer<UInt8>, count: Int, limits: Limits = .default) {
        unsafe self.base = base
        self.count = count
        self.cursor = 0
        self.depth = 0
        self.limits = limits
    }

    // MARK: - Primitive access

    /// Unchecked by design; see the file header. The parser's own invariants and the
    /// `atEnd` guards carry the safety argument, not the compiler.
    @inlinable @inline(__always)
    var current: UInt8 {
        unsafe base[cursor]
    }

    @inlinable @inline(__always)
    public var atEnd: Bool { cursor >= count }

    /// Current byte offset, for constructing a `SourceSpan` on the error path.
    @inlinable @inline(__always)
    public var byteOffset: Int { cursor }

    /// Mark the start of a value about to be decoded. Called by decode entry points.
    @inlinable @inline(__always)
    public mutating func beginValue() {
        skipWhitespace()
        valueStart = cursor
    }

    /// Span of the value most recently decoded, read by generated code immediately after
    /// the decode call while the cursor still sits just past it.
    @inlinable @inline(__always)
    public var lastValueSpan: SourceSpan {
        SourceSpan(lo: valueStart, len: cursor - valueStart)
    }

    @inlinable @inline(__always)
    mutating func advance(_ n: Int = 1) {
        cursor &+= n
    }

    // MARK: - Whitespace

    /// yyjson orders its structural dispatch so the whitespace test comes *last*, which
    /// makes whitespace cost zero on minified input — the common case for an API body.
    /// Here the loop is simply tight and branch-predictable.
    @inlinable @inline(__always)
    public mutating func skipWhitespace() {
        while cursor < count {
            let c = unsafe base[cursor]
            if c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D {
                cursor &+= 1
            } else {
                return
            }
        }
    }

    // MARK: - Structural

    @inlinable
    public mutating func expect(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard cursor < count, unsafe base[cursor] == byte else { return false }
        cursor &+= 1
        return true
    }

    @inlinable
    public mutating func tryConsume(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard cursor < count, unsafe base[cursor] == byte else { return false }
        cursor &+= 1
        return true
    }

    @inlinable
    public mutating func enterContainer(_ sink: inout IssueSink) -> Bool {
        depth &+= 1
        if depth > limits.maxDepth {
            reportDepth(&sink)
            return false
        }
        return true
    }

    @inlinable
    public mutating func leaveContainer() {
        depth &-= 1
    }

    @inline(never)
    @usableFromInline
    mutating func reportDepth(_ sink: inout IssueSink) {
        sink.add(Issue(
            code: .depthExceeded,
            params: ["maxDepth": .int(limits.maxDepth)],
            location: SourceSpan(lo: cursor, len: 1)))
    }

    // MARK: - Keys

    /// A key's byte range, *excluding* the quotes. The window dispatcher reads from
    /// `lo` and relies on the closing quote at `lo + len` being the virtual byte —
    /// which is exactly what simdjson's `key_selector` tier 1 depends on.
    @frozen
    @safe public struct KeyRange {
        /// Where the key starts IN THE SOURCE, for spans and carets.
        public var lo: Int
        /// How many bytes to match: the key's length, unescaped when it had escapes.
        public var len: Int
        /// True when the key contained no backslash, so its bytes ARE the source bytes.
        public var simple: Bool
        /// The bytes to match: the source (`base + lo`) for a simple key, the reader's
        /// scratch for an escaped one. Chosen once, in `scanKey`, so the readers of a key's
        /// bytes do not branch on `simple`; a version that did cost 1.5–4.8% instructions
        /// across the decode cells (count.py, 2026-09-19).
        @usableFromInline var bytes: UnsafePointer<UInt8>

        @inlinable
        public init(lo: Int, len: Int, simple: Bool, bytes: UnsafePointer<UInt8>) {
            self.lo = lo
            self.len = len
            self.simple = simple
            unsafe self.bytes = bytes
        }
    }

    /// Scan a `"..."` key and leave the cursor just past the closing quote.
    @inlinable
    public mutating func scanKey() -> KeyRange? {
        skipWhitespace()
        guard cursor < count, unsafe base[cursor] == 0x22 else { return nil }
        cursor &+= 1
        let start = cursor
        while cursor < count {
            let c = unsafe base[cursor]
            if c == 0x22 {
                let r = unsafe KeyRange(lo: start, len: cursor &- start, simple: true,
                                        bytes: base + start)
                cursor &+= 1
                return r
            }
            if c == 0x5C {
                return scanEscapedKey(from: start)
            }
            cursor &+= 1
        }
        return nil
    }

    /// A key containing a backslash: unescape it into `keyScratch` and return a range whose
    /// bytes are read from there (`KeyRange.simple == false`), with its UNESCAPED length.
    ///
    /// Until 2026-09-19 an escaped key was matched on its raw bytes. `simple` was computed
    /// and read by nothing, so `{"a\/b": 1}` did not match `@Key("a/b")`. RFC 8259 says those
    /// are one key, and Python's `json.dumps` escapes every non-ASCII character by default,
    /// so a field named `café` arrived as `"caf\u00e9"` and was reported MISSING. Cold: a
    /// document without escaped keys never reaches this, and the only cost on the hot path is
    /// the byte-source branch in `_keyBytes`, which such a document always predicts.
    @inline(never)
    @usableFromInline
    mutating func scanEscapedKey(from start: Int) -> KeyRange? {
        var end = cursor
        while end < count {
            let c = unsafe base[end]
            if c == 0x22 { break }
            end &+= c == 0x5C ? 2 : 1
        }
        let bound = Swift.max(Swift.min(end, count) &- start, 1)
        if bound > keyScratchCapacity {
            unsafe keyScratch?.deallocate()
            unsafe keyScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: bound)
            keyScratchCapacity = bound
        }
        guard let n = unsafe unescape(from: start, into: keyScratch!) else {
            escapeErrorAt = -1
            return nil
        }
        return unsafe KeyRange(lo: start, len: n, simple: false,
                               bytes: UnsafePointer(keyScratch!))
    }

    /// Where a key's matchable bytes are: the input itself, or the unescaped copy of an
    /// escaped key. Every reader of a `KeyRange`'s bytes goes through here.
    @inlinable @inline(__always)
    func _keyBytes(_ key: KeyRange) -> UnsafePointer<UInt8> { unsafe key.bytes }

    /// Read the byte at `offset` bytes past the start of `key`, using `"` as the virtual
    /// byte at `idx == len`. This is what makes `{"jo","joe"}` separable with no length
    /// test, and it is why the confirming compare needs no separate length compare.
    @_documentation(visibility: internal)
    @inlinable @inline(__always)
    public func _keyByte(_ key: KeyRange, _ offset: Int) -> UInt8 {
        offset < key.len ? unsafe _keyBytes(key)[offset] : 0x22
    }

    /// The two-byte unaligned load the window dispatcher indexes with.
    @_documentation(visibility: internal)
    @inlinable @inline(__always)
    public func _keyWindow(_ key: KeyRange, byteOffset: Int, shift: UInt8) -> UInt8 {
        let b0 = UInt16(_keyByte(key, byteOffset))
        let b1 = UInt16(_keyByte(key, byteOffset &+ 1))
        let pair = b0 | (b1 << 8)
        return UInt8(truncatingIfNeeded: pair >> UInt16(shift))
    }

    /// Confirm a candidate. `literal` is a compile-time constant in generated code, so
    /// the length is constant-folded and this becomes a fixed-size compare.
    @inlinable @inline(__always)
    public func keyMatches(_ key: KeyRange, _ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard key.len == n else { return false }
        let p = unsafe literal.utf8Start
        let k = unsafe _keyBytes(key)
        var i = 0
        while i < n {
            if unsafe (k[i] != p[i]) { return false }
            i &+= 1
        }
        return true
    }

    // MARK: - Value skipping

    /// Skip a value without decoding it — the `.ignore` unknown-key path.
    ///
    /// Unknown keys are extremely common in real API payloads and are completely
    /// unmeasured in every published JSON benchmark, which is why the corpus has an
    /// `unknown-keys` shape.
    /// Skip one value without decoding it.
    ///
    /// **WHAT THIS VALIDATES, PRECISELY: the value's EXTENT, never its contents.** The
    /// skip finds where the value ends — matching brackets, honouring string state so a
    /// `}` inside a string does not close an object, refusing an unterminated string or
    /// container, and charging nesting against `Limits.maxDepth`. It does not check that
    /// what it skipped over was JSON.
    ///
    /// So `{"known": 1, "unknown": NaN}` decodes, and so does `'x'` or `01` in that
    /// position, while `JSON.Value.parse` refuses all three. That is a real difference in
    /// meaning and it is deliberate: skipping is what makes the prefix path 6.3x, and
    /// validating a value in order to throw it away spends exactly what skipping saves.
    /// simdjson's On-Demand API documents the same property for the same reason.
    ///
    /// The consequence, stated plainly because it is easy to assume otherwise:
    /// **`T.parse(json:)` is not a JSON validator.** It validates the document's structure
    /// and every value the schema declares. A caller who needs the whole document checked
    /// wants `JSON.Value.parse`, which validates all of it.
    @inlinable
    public mutating func skipValue(_ sink: inout IssueSink) -> Bool {
        skipWhitespace()
        guard cursor < count else { return false }
        switch unsafe base[cursor] {
        case 0x22:
            return skipString()
        case 0x7B, 0x5B:
            return skipContainer(&sink)
        default:
            // number, true, false, null — scan to the next structural byte
            while cursor < count {
                let c = unsafe base[cursor]
                if c == 0x2C || c == 0x7D || c == 0x5D
                    || c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D {
                    break
                }
                cursor &+= 1
            }
            return true
        }
    }

    @inlinable
    mutating func skipString() -> Bool {
        cursor &+= 1
        while cursor < count {
            let c = unsafe base[cursor]
            if c == 0x22 { cursor &+= 1; return true }
            if c == 0x5C { cursor &+= 2; continue }
            cursor &+= 1
        }
        return false
    }

    /// Depth-counted structural skip: count `{`/`[` against `}`/`]` while respecting
    /// string state, and never touch the contents.
    @inlinable
    mutating func skipContainer(_ sink: inout IssueSink) -> Bool {
        var localDepth = 0
        while cursor < count {
            let c = unsafe base[cursor]
            switch c {
            case 0x7B, 0x5B:
                localDepth &+= 1
                if localDepth > limits.maxDepth {
                    reportDepth(&sink)
                    return false
                }
                cursor &+= 1
            case 0x7D, 0x5D:
                localDepth &-= 1
                cursor &+= 1
                if localDepth == 0 { return true }
            case 0x22:
                if !skipString() { return false }
            default:
                cursor &+= 1
            }
        }
        return false
    }

    // MARK: - Diagnostics

    /// A syntax error, saying WHAT WAS EXPECTED where it can.
    ///
    /// This reported the bare predicate `is not a well-formed document` for every JSON
    /// syntax error there is — no subject, no expectation — and truncated input got a caret
    /// one byte past the end, which renders as nothing. For a library whose headline is
    /// that it tells you what went wrong, that was the worst sentence it produced, in the
    /// case the headline is about.
    ///
    /// `expected` is a `StaticString` so a call site cannot allocate to describe itself;
    /// every caller has a literal. It stays optional because `Discriminator` reports a
    /// malformed document from a position where no single token was expected.
    @inline(never)
    public mutating func reportMalformed(
        _ sink: inout IssueSink, _ path: [PathComponent], expected: StaticString? = nil
    ) {
        var params: [String: IssueValue] = [:]
        if let e = expected { params["expected"] = .string("\(e)") }
        // AT THE END IS A DIFFERENT MISTAKE from a wrong byte, and it reads differently:
        // "the input ended" rather than "found `x`". The caret goes on the LAST byte —
        // one past the end is outside the source and the renderer draws nothing there,
        // which is how truncated input came to have no position at all.
        let ended = cursor >= count
        if ended { params["atEnd"] = .bool(true) }
        sink.add(Issue(
            code: .malformedDocument,
            path: path,
            params: params,
            location: SourceSpan(lo: ended ? Swift.max(0, count - 1) : cursor, len: 1)))
    }

    /// A value of the wrong type: rewind to where it began, report it there, and CONSUME it,
    /// so the caller carries on at the next member. Reporting without consuming was the bug
    /// every container and scalar-special decoder had until 2026-09-19. The caller then read
    /// the leftover value where it expected ',' or '}', and one false `malformed_document`
    /// replaced every later issue in the document.
    @inline(never)
    public mutating func _mismatch(
        _ sink: inout IssueSink, _ path: [PathComponent], from start: Int, expected: String
    ) {
        cursor = start
        reportTypeMismatch(&sink, path, expected: expected)
        _ = skipValue(&sink)
    }

    @inline(never)
    public mutating func reportTypeMismatch(
        _ sink: inout IssueSink,
        _ path: [PathComponent],
        expected: String
    ) {
        sink.add(Issue(
            code: .typeMismatch,
            path: path,
            params: ["expected": .string(expected)],
            received: describeCurrentValue(),
            location: SourceSpan(lo: cursor, len: 1)))
    }

    /// Best-effort rendering of whatever is under the cursor, for `issue.received`.
    /// Cold path only — never called when the data is valid.
    @inline(never)
    func describeCurrentValue() -> String? {
        guard cursor < count else { return nil }
        // A container is summarised, not quoted: `found [[[[[[[[[[[[[[[[` told nobody
        // anything, and `found {` told them less.
        switch unsafe base[cursor] {
        case 0x5B: return "an array"
        case 0x7B: return "an object"
        default: break
        }
        var end = cursor
        var n = 0
        while end < count, n < 32 {
            let c = unsafe base[end]
            if c == 0x2C || c == 0x7D || c == 0x5D { break }
            end &+= 1
            n &+= 1
        }
        // Never cut inside a multi-byte scalar: back up over continuation bytes so the
        // snippet ends on a boundary rather than on a replacement character.
        while end > cursor, end < count, unsafe (base[end] & 0xC0) == 0x80 { end &-= 1 }
        guard end > cursor else { return nil }
        return unsafe String(decoding: UnsafeBufferPointer(start: base + cursor, count: end - cursor),
                             as: UTF8.self)
    }
}

//===----------------------------------------------------------------------===//
// Primitives for out-of-module format scanners (AssayYAML, AssayXML).
//
// The JSON scanner keeps its own internals private, but YAML and XML need the same byte
// cursor, the same one-copy String construction, and the same byte-offset spans — so
// those are exposed here rather than duplicated per format. Duplicating them would mean
// three String fast paths to keep correct and three places for the SE-0263
// declared-capacity trap to be reintroduced.
//===----------------------------------------------------------------------===//

extension AssayReader {

    /// Byte at the cursor, or nil at end of input.
    @inlinable
    public var currentByte: UInt8? {
        cursor < count ? unsafe base[cursor] : nil
    }

    /// Byte `offset` past the cursor, or nil.
    @inlinable
    public func byte(at offset: Int) -> UInt8? {
        let i = cursor &+ offset
        return i >= 0 && i < count ? unsafe base[i] : nil
    }

    /// Bytes between the cursor and the previous newline (or the start): the cursor's
    /// column, for indentation-sensitive formats. Unchecked: `i` stays in `1...cursor`. The
    /// YAML parser asked this through `byte(absolute:)`, a bounds check and an Optional per
    /// byte, and it was 7% of `base/yaml` (callgrind, 2026-09-20).
    @inlinable
    public func _columnSinceNewline() -> Int {
        var i = cursor
        while i > 0, unsafe base[i &- 1] != 0x0A { i &-= 1 }
        return cursor &- i
    }

    /// Absolute byte, or nil.
    @inlinable
    public func byte(absolute i: Int) -> UInt8? {
        i >= 0 && i < count ? unsafe base[i] : nil
    }

    @inlinable
    public var byteCount: Int { count }

    @inlinable
    public mutating func advanceBy(_ n: Int) { cursor &+= n }

    @inlinable
    public mutating func seek(to offset: Int) { cursor = offset }

    /// Everything a rewind has to put back. `ROADMAP.md` §5 says unions need `seek(to:)` and
    /// `IssueSink.rollback(to:)`; **that list is one short**, and the reason is narrower than
    /// it first looks — `Tests/AssayTests/RewindTests.swift` establishes both halves.
    ///
    /// **The generated code balances its own error paths, and this does not depend on that.**
    /// Both halves are measured, in `RewindTests.swift`.
    ///
    /// An *ordinary* decode failure was always balanced: a body that finds a type mismatch
    /// scans on to the closing brace, calls `leaveContainer`, and only then returns nil at the
    /// unwrap. A **malformed container** was not — the arm for an unterminated array reported
    /// and returned from inside the enclosing object — so twenty attempts against a depth
    /// budget of four failed the twenty-first decode.
    ///
    /// That was **fixed at source** on 2026-09-09, one `leaveContainer()` per array,
    /// dictionary and path-group error arm. The first instinct was to leave it and let this
    /// type paper over it at the union boundary, on the grounds that nothing else could
    /// observe the leak; "nothing observes it today" is the reasoning that produced several
    /// other bugs found the same week, and the fix costs one line per collection field.
    /// `generatedPathsAreBalanced` asserts it with `seek(to:)` alone, so it fails if a future
    /// emitter regresses.
    ///
    /// **This type stays anyway**, now as the complete rewind rather than a workaround: a
    /// union driver should not depend on every generated error path in every future feature
    /// staying balanced, and the cost of not depending on it is two integers.
    public struct Mark: Sendable, Equatable {
        @usableFromInline let cursor: Int
        @usableFromInline let depth: Int
        @inlinable init(cursor: Int, depth: Int) {
            self.cursor = cursor
            self.depth = depth
        }
    }

    /// Where the reader is now, for a later `restore(_:)`.
    @inlinable
    public var mark: Mark { Mark(cursor: cursor, depth: depth) }

    /// Put the reader back exactly as `mark` found it. Pairs with `IssueSink.rollback(to:)`:
    /// one restores the input position, the other the reported issues, and a branch attempt
    /// needs both.
    @inlinable
    public mutating func restore(_ m: Mark) {
        cursor = m.cursor
        depth = m.depth
    }

    /// Does the input match `literal` at the cursor?
    @inlinable
    public func matches(_ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard cursor &+ n <= count else { return false }
        let p = unsafe literal.utf8Start
        var i = 0
        while i < n {
            if unsafe (base[cursor &+ i] != p[i]) { return false }
            i &+= 1
        }
        return true
    }

    /// Consume `literal` if present.
    @inlinable
    public mutating func consume(_ literal: StaticString) -> Bool {
        guard matches(literal) else { return false }
        cursor &+= literal.utf8CodeUnitCount
        return true
    }

    /// Build a `String` from an absolute byte range, with the one-copy path.
    ///
    /// Capacity is the exact byte count, so values at or below the small-string threshold
    /// stay inline: no allocation, no retain/release, no validation. Declaring a loose
    /// upper bound here would heap-allocate unconditionally (SE-0263).
    /// The pointer is hoisted into a local before the closure, so the closure captures two
    /// trivial values rather than reaching through `self` — which is `~Copyable`, and whose
    /// capture is not a trivial copy. Structurally right, and worth **0.5%**: a profile
    /// attributes samples to `partial apply for closure #1` here, but those are the memcpy
    /// itself rather than thunk overhead. Noted so the next reader does not chase it twice.
    @inlinable
    public func string(from lo: Int, to hi: Int) -> String {
        let n = hi &- lo
        guard n > 0 else { return "" }
        let src = unsafe base + lo
        return unsafe String(unsafeUninitializedCapacity: n) { buffer in
            unsafe buffer.baseAddress!.update(from: src, count: n)
            return n
        }
    }

    /// Append the bytes in `lo..<hi` to `out` in ONE copy.
    ///
    /// The companion to `string(from:to:)`, for a parser that is building a `[UInt8]`
    /// rather than a `String` — TOML's string scanner, which appended one byte at a time
    /// through a `while` loop where the no-escape run is almost always the whole literal.
    /// Same pointer-hoisting reason as above: the closure captures two trivial values and
    /// not `self`, which is `~Copyable`.
    @inlinable
    public func appendBytes(from lo: Int, to hi: Int, into out: inout [UInt8]) {
        let n = hi &- lo
        guard n > 0 else { return }
        let src = unsafe base + lo
        unsafe out.append(contentsOf: UnsafeBufferPointer(start: src, count: n))
    }

    /// `keyMatches` for a `@Key(_:or:)` alias: on a match, records the warning that says
    /// which alias the field was read from. The generated dispatch arm is
    /// `keyMatches(primary) || _aliasMatched(alias, …)`, so the warning costs nothing on
    /// the primary key and the decode body is not duplicated per alias.
    @inlinable
    public func _aliasMatched(
        _ key: KeyRange, _ alias: StaticString, _ sink: inout IssueSink,
        _ path: [PathComponent], _ field: StaticString
    ) -> Bool {
        guard keyMatches(key, alias) else { return false }
        _assayAliasMatched(&sink, path, field, alias)
        return true
    }

    /// Scan forward to the next occurrence of `byte`, returning its absolute offset.
    @inlinable
    public func find(_ needle: UInt8, from start: Int) -> Int? {
        var i = start
        while i < count {
            if unsafe base[i] == needle { return i }
            i &+= 1
        }
        return nil
    }

    /// Report an arbitrary issue at the cursor. Cold.
    @inline(never)
    public mutating func report(
        _ sink: inout IssueSink,
        _ code: IssueCode,
        _ path: [PathComponent] = [],
        params: [String: IssueValue] = [:],
        span: SourceSpan? = nil
    ) {
        sink.add(Issue(code: code, path: path, params: params,
                       location: span ?? SourceSpan(lo: cursor, len: 1)))
    }
}
