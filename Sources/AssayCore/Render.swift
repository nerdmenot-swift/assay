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

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Android)
@preconcurrency import Android
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
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

        // One line-index build per render, shared by every issue.
        let index = source.count > 0 ? source.withUnsafeBytes { buf in
            unsafe LineIndex(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), buf.count)
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
            let text = source.withUnsafeBytes { buf -> String in
                // Strip a trailing CR so CRLF documents do not render a stray ^M.
                var r = range
                if r.count > 0, buf[r.upperBound - 1] == 0x0D {
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
                // The caret column is 1-based and counts bytes; for the ASCII-dominant
                // config/API case that equals display columns. Multi-byte alignment is a
                // known approximation, noted in the docs.
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
        let index = source.count > 0 ? source.withUnsafeBytes { buf in
            unsafe LineIndex(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), buf.count)
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

    static func problemDetailsRender(_ issues: [Issue]) -> String {
        var out = "{"
        out += "\"type\":\"about:blank\","
        out += "\"title\":\"Validation failed\","
        out += "\"status\":422,"
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
