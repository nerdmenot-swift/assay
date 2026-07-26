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
// docs/research/perf-swift-codegen.md §4.6 / §10 item 20: `@_lifetime` is still
// `SUPPRESSIBLE_EXPERIMENTAL_FEATURE(Lifetimes)` with no accepted proposal, and a
// `~Escapable` reader would put an experimental-feature gate on the whole library.
// The public API takes bytes and never exposes a pointer, so the seam can move to
// `RawSpan` without a source break once `Lifetimes` ships un-gated.
//===----------------------------------------------------------------------===//

/// A borrowed view of the input. Valid only for the duration of the enclosing
/// `withUnsafeBytes`-style scope; the public API never hands one to a caller.
@safe
public struct AssayReader: ~Copyable {
    @usableFromInline let base: UnsafePointer<UInt8>
    @usableFromInline let count: Int
    @usableFromInline var cursor: Int
    @usableFromInline var depth: Int
    @usableFromInline let limits: Limits

    @inlinable
    public init(base: UnsafePointer<UInt8>, count: Int, limits: Limits = .default) {
        self.base = base
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

    @inlinable @inline(__always)
    func peek(_ offset: Int) -> UInt8 {
        let i = cursor &+ offset
        return i < count ? unsafe base[i] : 0
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
    public struct KeyRange {
        public var lo: Int
        public var len: Int
        /// True when the key contained no backslash, so it can be compared byte-for-byte
        /// against a compile-time literal with no unescaping.
        public var simple: Bool

        @inlinable
        public init(lo: Int, len: Int, simple: Bool) {
            self.lo = lo
            self.len = len
            self.simple = simple
        }
    }

    /// Scan a `"..."` key and leave the cursor just past the closing quote.
    @inlinable
    public mutating func scanKey() -> KeyRange? {
        skipWhitespace()
        guard cursor < count, unsafe base[cursor] == 0x22 else { return nil }
        cursor &+= 1
        let start = cursor
        var simple = true
        while cursor < count {
            let c = unsafe base[cursor]
            if c == 0x22 {
                let r = KeyRange(lo: start, len: cursor &- start, simple: simple)
                cursor &+= 1
                return r
            }
            if c == 0x5C {
                simple = false
                cursor &+= 2
                continue
            }
            cursor &+= 1
        }
        return nil
    }

    /// Read the byte at `offset` bytes past the start of `key`, using `"` as the virtual
    /// byte at `idx == len`. This is what makes `{"jo","joe"}` separable with no length
    /// test, and it is why the confirming compare needs no separate length compare.
    @inlinable @inline(__always)
    public func keyByte(_ key: KeyRange, _ offset: Int) -> UInt8 {
        offset < key.len ? unsafe base[key.lo &+ offset] : 0x22
    }

    /// The two-byte unaligned load the window dispatcher indexes with.
    @inlinable @inline(__always)
    public func keyWindow(_ key: KeyRange, byteOffset: Int, shift: UInt8) -> UInt8 {
        let b0 = UInt16(keyByte(key, byteOffset))
        let b1 = UInt16(keyByte(key, byteOffset &+ 1))
        let pair = b0 | (b1 << 8)
        return UInt8(truncatingIfNeeded: pair >> UInt16(shift))
    }

    /// Confirm a candidate. `literal` is a compile-time constant in generated code, so
    /// the length is constant-folded and this becomes a fixed-size compare.
    @inlinable @inline(__always)
    public func keyMatches(_ key: KeyRange, _ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard key.len == n else { return false }
        let p = literal.utf8Start
        var i = 0
        while i < n {
            if unsafe (base[key.lo &+ i] != p[i]) { return false }
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

    @inline(never)
    public mutating func reportMalformed(_ sink: inout IssueSink, _ path: [PathComponent]) {
        sink.add(Issue(
            code: .malformedJSON,
            path: path,
            location: SourceSpan(lo: cursor, len: 1)))
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

    @inline(never)
    public mutating func reportMissing(_ sink: inout IssueSink, _ path: [PathComponent]) {
        sink.add(Issue(code: .missing, path: path))
    }

    /// Best-effort rendering of whatever is under the cursor, for `issue.received`.
    /// Cold path only — never called when the data is valid.
    @inline(never)
    func describeCurrentValue() -> String? {
        guard cursor < count else { return nil }
        var end = cursor
        var n = 0
        while end < count, n < 32 {
            let c = unsafe base[end]
            if c == 0x2C || c == 0x7D || c == 0x5D { break }
            end &+= 1
            n &+= 1
        }
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

    /// Does the input match `literal` at the cursor?
    @inlinable
    public func matches(_ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard cursor &+ n <= count else { return false }
        let p = literal.utf8Start
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
    @inlinable
    public func string(from lo: Int, to hi: Int) -> String {
        let n = hi &- lo
        guard n > 0 else { return "" }
        return unsafe String(unsafeUninitializedCapacity: n) { buffer in
            unsafe buffer.baseAddress!.update(from: base + lo, count: n)
            return n
        }
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
