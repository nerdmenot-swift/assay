// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Rendering. docs/EXPERIENCE.md §3: "Errors are the product. Everything else in this
// document is in service of this section."
//
// The target output, from a String, on every platform, with no debugger:
//
//     deploy.yaml:4:13: error: replicas must be at least 1
//       2 │ deployment:
//       3 │   name: api
//       4 │   replicas: 0
//         │             ^
//       5 │   image: api:1.4
//
// The format is the one Swift developers already read every day, because it is the
// compiler's.
//
// Line/column is derived HERE, lazily, from the byte offsets the issues carry — never
// during the parse. `LineIndex` is built once per render, binary-searched per issue.
// Issues are ordered by position at render time ("all the errors, ordered by position",
// §18); collection order is preserved everywhere else.
//===----------------------------------------------------------------------===//

// Plain imports: the only libc symbol used here is `isatty`, a function. `@preconcurrency`
// exists for mutable C globals and bought nothing, while strict memory safety flags it as an
// unsafe import, which failed CI's zero-warnings gate.
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// How to render a diagnosis or error.
public enum RenderStyle: Sendable, Equatable {
    /// Carets and colour. Colour is automatically disabled when stdout is not a TTY —
    /// including on WebAssembly, where there is no TTY at all and colour resolves to off
    /// rather than to garbage.
    case terminal
    /// The same output with no ANSI codes, unconditionally.
    case plain
    /// Machine-readable, stable shape. Codes and params alongside messages, so a client
    /// can localise or branch without string-matching English.
    case json
    /// RFC 9457 `application/problem+json`.
    case problemDetails
}

/// The render engine. Operates on the pieces a `Diagnosis` or `AssayError` carries, so
/// both can delegate here without the core knowing either type.
public enum Renderer {

    public static func render(
        issues: [Issue],
        warnings: [Warning],
        source: SourceBytes,
        sourceName: String,
        style: RenderStyle
    ) -> String {
        switch style {
        case .terminal:
            return caretRender(issues, warnings, source, sourceName, color: stdoutIsTTY())
        case .plain:
            return caretRender(issues, warnings, source, sourceName, color: false)
        case .json:
            return jsonRender(issues, warnings, source, sourceName)
        case .problemDetails:
            return problemDetailsRender(issues)
        }
    }

    /// The deepest byte offset any issue or warning will report, which is as far as a
    /// line index needs to reach.
    static func renderHorizon(_ issues: [Issue], _ warnings: [Warning]) -> Int {
        var h = 0
        for i in issues { if let l = i.location { h = max(h, Int(l.lo) + Int(l.len)) } }
        for w in warnings { if let l = w.location { h = max(h, Int(l.lo) + Int(l.len)) } }
        return h
    }

    // MARK: - Terminal / plain

    static func caretRender(
        _ issues: [Issue], _ warnings: [Warning],
        _ source: SourceBytes, _ sourceName: String,
        color: Bool
    ) -> String {
        let bold = color ? "\u{1B}[1m" : ""
        let red = color ? "\u{1B}[31m" : ""
        let yellow = color ? "\u{1B}[33m" : ""
        let reset = color ? "\u{1B}[0m" : ""

        // One line-index build per render, shared by every issue — and bounded to the
        // deepest offset any of them reports, so rendering a caret from a mapped file
        // does not index the whole file. See LineIndex.init(_:_:indexingThrough:).
        let horizon = renderHorizon(issues, warnings)
        let index = source.count > 0 ? unsafe source.withUnsafeBytes { buf in
            unsafe LineIndex(buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                             buf.count, indexingThrough: horizon)
        } : nil

        // Ordered by position; location-less issues keep collection order at the end.
        let orderedIssues = issues.enumerated().sorted {
            (Int($0.element.location?.lo ?? .max), $0.offset)
                < (Int($1.element.location?.lo ?? .max), $1.offset)
        }.map(\.element)
        let orderedWarnings = warnings.enumerated().sorted {
            (Int($0.element.location?.lo ?? .max), $0.offset)
                < (Int($1.element.location?.lo ?? .max), $1.offset)
        }.map(\.element)

        var out = ""
        for issue in orderedIssues {
            renderOne(
                severity: "error", severityColor: red,
                path: issue.path, message: issue.message, location: issue.location,
                index: index, source: source, sourceName: sourceName,
                bold: bold, reset: reset, into: &out)
        }
        for warning in orderedWarnings {
            renderOne(
                severity: "warning", severityColor: yellow,
                path: warning.path, message: warning.message, location: warning.location,
                index: index, source: source, sourceName: sourceName,
                bold: bold, reset: reset, into: &out)
        }

        // Footer: "4 errors, 1 warning"
        if issues.count + warnings.count > 0 {
            var parts: [String] = []
            if issues.count > 0 {
                parts.append("\(issues.count) error\(issues.count == 1 ? "" : "s")")
            }
            if warnings.count > 0 {
                parts.append("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")")
            }
            out += parts.joined(separator: ", ") + "\n"
        }
        return out
    }

    private static func renderOne(
        severity: String, severityColor: String,
        path: [PathComponent], message: String, location: SourceSpan?,
        index: LineIndex?, source: SourceBytes, sourceName: String,
        bold: String, reset: String, into out: inout String
    ) {
        let pathText = path.pathDescription
        let sentence = pathText.isEmpty ? message : "\(pathText) \(message)"

        if let span = location, let index, Int(span.lo) < source.count {
            let (line, column) = index.lineAndColumn(of: span.lo)
            out += "\(bold)\(sourceName):\(line):\(column):\(reset) "
                + "\(severityColor)\(bold)\(severity):\(reset) \(bold)\(sentence)\(reset)\n"
            out += snippet(around: line, caretColumn: column,
                           caretLength: Int(span.len), index: index, source: source)
        } else {
            out += "\(bold)\(sourceName):\(reset) "
                + "\(severityColor)\(bold)\(severity):\(reset) \(bold)\(sentence)\(reset)\n"
        }
        out += "\n"
    }

    /// Two lines of context before, the offending line, the caret, one line after —
    /// the shape of the worked examples in EXPERIENCE.md §3 and §16.
    static func snippet(
        around line: Int, caretColumn: Int, caretLength: Int,
        index: LineIndex, source: SourceBytes
    ) -> String {
        let first = max(1, line - 2)
        let last = min(index.lineCount, line + 1)
        let gutterWidth = String(last).count

        var out = ""
        for n in first...last {
            guard let range = index.byteRange(ofLine: n) else { continue }
            let text = unsafe source.withUnsafeBytes { buf -> String in
                // Strip a trailing CR so CRLF documents do not render a stray ^M.
                var r = range
                if r.count > 0, unsafe buf[r.upperBound - 1] == 0x0D {
                    r = r.lowerBound..<(r.upperBound - 1)
                }
                let slice = unsafe UnsafeRawBufferPointer(rebasing: buf[r])
                // The buffer was UTF-8-validated at parse entry, so this cannot repair.
                return unsafe String(decoding: slice, as: UTF8.self)
            }
            let number = String(n)
            let pad = String(repeating: " ", count: gutterWidth - number.count)
            out += "  \(pad)\(number) │ \(text)\n"

            if n == line {
                // The caret column is 1-based and COUNTS BYTES, not display columns. For
                // the ASCII-dominant config/API case those are the same number. They are
                // not the same for a line containing multi-byte UTF-8 before the caret --
                // the caret lands too far right, by one column per continuation byte --
                // and not for a terminal applying east-asian wide or combining-mark rules,
                // which no byte or scalar count can predict. Getting it exactly right needs
                // a width table this library will not carry.
                //
                // This comment used to end "noted in the docs". It was not, anywhere. Said
                // here instead, where the approximation is.
                let lineLength = range.count
                let spaces = String(repeating: " ", count: max(0, caretColumn - 1))
                let run = max(1, min(caretLength, max(1, lineLength - caretColumn + 1)))
                let carets = String(repeating: "^", count: run)
                out += "  \(String(repeating: " ", count: gutterWidth)) │ \(spaces)\(carets)\n"
            }
        }
        return out
    }

    // MARK: - JSON

    static func jsonRender(
        _ issues: [Issue], _ warnings: [Warning],
        _ source: SourceBytes, _ sourceName: String
    ) -> String {
        let horizon = renderHorizon(issues, warnings)
        let index = source.count > 0 ? unsafe source.withUnsafeBytes { buf in
            unsafe LineIndex(buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                             buf.count, indexingThrough: horizon)
        } : nil

        var out = "{"
        out += "\"source\":\(jsonString(sourceName)),"
        out += "\"valid\":\(issues.isEmpty ? "true" : "false"),"
        out += "\"issues\":["
        out += issues.map { entry($0.code, $0.path, $0.message, $0.params,
                                  $0.received, $0.location, index) }
            .joined(separator: ",")
        out += "],\"warnings\":["
        out += warnings.map { entry($0.code, $0.path, $0.message, $0.params,
                                    nil, $0.location, index) }
            .joined(separator: ",")
        out += "]}"
        return out
    }

    private static func entry(
        _ code: IssueCode, _ path: [PathComponent], _ message: String,
        _ params: [String: IssueValue], _ received: String?,
        _ location: SourceSpan?, _ index: LineIndex?
    ) -> String {
        var out = "{"
        out += "\"path\":\(jsonString(path.pathDescription)),"
        out += "\"code\":\(jsonString(code.codeString)),"
        out += "\"message\":\(jsonString(message))"
        if !params.isEmpty {
            // Sorted keys, so the output is deterministic and diffable.
            let body = params.sorted { $0.key < $1.key }.map { k, v -> String in
                "\(jsonString(k)):\(jsonValue(v))"
            }.joined(separator: ",")
            out += ",\"params\":{\(body)}"
        }
        if let r = received { out += ",\"received\":\(jsonString(r))" }
        if let span = location {
            out += ",\"offset\":\(span.lo),\"length\":\(span.len)"
            if let index, Int(span.lo) <= index.totalBytes {
                let (line, column) = index.lineAndColumn(of: span.lo)
                out += ",\"line\":\(line),\"column\":\(column)"
            }
        }
        out += "}"
        return out
    }

    // MARK: - RFC 9457

    /// RFC 9457 §3.1: `status` SHOULD be the same code the origin server actually sent,
    /// and it exists so a client reading a stored or forwarded problem document can
    /// recover it. A renderer cannot know the status in general — but for some issues it
    /// is determined, and hard-coding 422 through those was wrong.
    ///
    /// The load-bearing case is the one that made this visible. `unsupported_media_type`
    /// is its own code *precisely* so a server can answer 415 rather than 400 or 422; a
    /// body claiming 422 next to a 415 header contradicts the header the client has
    /// already acted on. A recipe that wrote the handler end to end caught it; three
    /// documents describing the renderer had not.
    ///
    /// Ordered by when the failure happened, earliest first: negotiation before the body
    /// was read, then its size, then whether it parsed, then what it said.
    static func problemStatus(_ issues: [Issue]) -> (code: Int, title: String) {
        if issues.contains(where: { $0.code == .unsupportedMediaType }) {
            return (415, "Unsupported media type")
        }
        if issues.contains(where: { $0.code == .tooManyBytes }) {
            return (413, "Content too large")
        }
        // 400 rather than 422: 422 is for a body that parsed and then failed its rules.
        // A body that is not well-formed never got that far.
        if issues.contains(where: {
            $0.code == .malformedDocument || $0.code == .invalidUTF8
                || $0.code == .trailingContent || $0.code == .depthExceeded
        }) {
            return (400, "Malformed request body")
        }
        return (422, "Validation failed")
    }

    static func problemDetailsRender(_ issues: [Issue]) -> String {
        let status = problemStatus(issues)
        var out = "{"
        out += "\"type\":\"about:blank\","
        out += "\"title\":\(jsonString(status.title)),"
        out += "\"status\":\(status.code),"
        out += "\"errors\":["
        out += issues.map { issue -> String in
            var e = "{"
            e += "\"path\":\(jsonString(issue.path.pathDescription)),"
            e += "\"code\":\(jsonString(issue.code.codeString)),"
            e += "\"message\":\(jsonString(issue.message))"
            if !issue.params.isEmpty {
                let body = issue.params.sorted { $0.key < $1.key }.map { k, v -> String in
                    "\(jsonString(k)):\(jsonValue(v))"
                }.joined(separator: ",")
                e += ",\"params\":{\(body)}"
            }
            e += "}"
            return e
        }.joined(separator: ",")
        out += "]}"
        return out
    }

    // MARK: - Escaping

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func jsonValue(_ v: IssueValue) -> String {
        switch v {
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return jsonString(s)
        }
    }

    // MARK: - TTY

    /// Whether stdout is a terminal. No TTY exists on WASI, so colour is always off there
    /// rather than emitting escape codes into a pipe.
    static func stdoutIsTTY() -> Bool {
        #if os(WASI)
        return false
        #elseif os(Windows)
        return _isatty(1) != 0
        #else
        return isatty(1) != 0
        #endif
    }
}

// MARK: - LineIndex extensions the renderer needs

extension LineIndex {
    /// Number of lines in the buffer (a trailing newline does not start a new line).
    public var lineCount: Int {
        newlines.count + 1
    }

    @usableFromInline
    var totalBytes: Int { byteCount }

    /// Byte range of a 1-based line, excluding its terminating newline (and a trailing
    /// carriage return, so CRLF documents do not render a stray ^M). Nil when out of range.
    public func byteRange(ofLine line: Int) -> Range<Int>? {
        guard line >= 1, line <= lineCount else { return nil }
        let start = line == 1 ? 0 : Int(newlines[line - 2]) + 1
        var end = line - 1 < newlines.count ? Int(newlines[line - 1]) : byteCount
        end = min(end, byteCount)
        guard end >= start else { return nil }
        return start..<end
    }
}

// MARK: - Line index
//
// Internal since 2026-09-10 — it was public, in UTF8Validation.swift, and this file is its
// only user.

/// Lazily-built newline index, for turning a byte offset into line:column at render time.
///
/// Nothing is computed until the first diagnostic is rendered — LLVM's `SourceMgr` shape:
/// "Vector of offsets into Buffer at which there are line-endings (lazily populated)."
struct LineIndex {
    @usableFromInline var newlines: [UInt32]
    /// Total buffer length, so the final (newline-less) line has a real end offset.
    @usableFromInline var byteCount: Int

    init(_ base: UnsafePointer<UInt8>, _ count: Int) {
        unsafe self.init(base, count, indexingThrough: count)
    }

    /// Index only as far as the render will reach.
    ///
    /// A full index over the whole buffer is what the mmap path must not pay: a 10 GB
    /// mapped file has ~250M newlines, so indexing all of them faults every page back in
    /// and allocates a gigabyte of `UInt32` — to print one caret, on the error path,
    /// undoing the entire reason `SourceBytes` can borrow a mapping. The renderer knows
    /// every offset it will report before it builds this, so it indexes to the deepest
    /// one plus the two lines of trailing context a snippet shows, and stops.
    ///
    /// Line numbers stay exact, because every newline *before* the deepest reported
    /// offset is still counted. What is lost is knowledge of the buffer beyond it —
    /// `byteCount` is clamped to where the scan stopped so the final line cannot render
    /// as the remaining gigabytes.
    init(_ base: UnsafePointer<UInt8>, _ count: Int, indexingThrough limit: Int) {
        var acc: [UInt32] = []
        let horizon = min(count, max(0, limit))
        // Estimate lines only over the region actually indexed; ~40 bytes per line is the
        // usual shape for config and API payloads.
        acc.reserveCapacity(horizon / 40 + 8)
        var i = 0
        var trailingLines = 0
        while i < count {
            if unsafe base[i] == 0x0A {
                acc.append(UInt32(i))
                // Two newlines past the horizon covers the one line of trailing context a
                // snippet renders, plus its terminator.
                if i >= horizon {
                    trailingLines &+= 1
                    if trailingLines >= 2 { i &+= 1; break }
                }
            }
            i &+= 1
        }
        self.newlines = acc
        self.byteCount = i
    }

    /// 1-based line, 1-based column.
    func lineAndColumn(of offset: UInt32) -> (line: Int, column: Int) {
        var lo = 0
        var hi = newlines.count
        while lo < hi {
            let mid = (lo &+ hi) / 2
            if newlines[mid] < offset { lo = mid &+ 1 } else { hi = mid }
        }
        let line = lo &+ 1
        let lineStart = lo == 0 ? 0 : newlines[lo &- 1] &+ 1
        return (line, Int(offset &- lineStart) &+ 1)
    }
}
