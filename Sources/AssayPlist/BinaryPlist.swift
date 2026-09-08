// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The binary property list format, `bplist00`, projected onto `RawValue`.
//
// `ROADMAP.md` §10 called plists "mechanically the smallest item on this list". That was
// wrong twice over, and correcting it is what this file is.
//
// FIRST: BINARY PLIST IS NOT A PROJECTION, IT IS A PARSER. A YAML or XML document is a tree
// read front to back. A binary plist is a **random-access object graph**: a trailer at the end
// of the file gives an offset table, every object is reached by index through that table, and
// containers hold *references* rather than children. Nothing about the YAML or XML path
// applies. It is closer to reading an object file than to reading a document.
//
// SECOND, AND THE REASON THIS FILE IS MOSTLY BOUNDS CHECKS: **a binary plist can be a
// decompression bomb, and the roadmap did not name it.** Two distinct attacks, both cheap to
// write and neither prevented by any limit the library already had:
//
//   * **Reference cycles.** An array whose element ref points at the array itself. A naive
//     recursive reader never returns. There is no syntax to prevent it — the format is a
//     graph, and a cycle is a well-formed graph.
//   * **Shared-object amplification.** Ten arrays, each holding a thousand references to the
//     one below it, is under a kilobyte on disk and 10^30 nodes materialised. No cycle
//     involved; every reference is to a distinct, real, forward object. This is the plist
//     spelling of the billion-laughs attack, and `Limits.maxDepth` does not touch it because
//     the DEPTH is ten.
//
// Both are closed here, and closed by construction rather than by a heuristic:
//
//   * A **visiting set** on the reference path refuses a cycle at the reference that closes
//     it. Not a global "seen" set — an object legitimately referenced twice from different
//     branches is shared, not cyclic — the set is pushed and popped along the current path.
//   * A **node budget** charged per materialised node, against `Limits.maxBytes`-derived
//     ceiling, refuses amplification at the point the count is exceeded. The same device the
//     YAML parser already uses for alias bombs, for the same reason.
//
// WHAT `<data>` BECOMES: a base64 `.string`. Adding `RawValue.data` would break every
// exhaustive switch over `RawValue` in this package and in user code, for one format's one
// type — and base64 is what the XML plist flavour writes for the same bytes anyway, so the
// two flavours agree. Stated in `docs/PLIST.md` rather than discovered.
//
// WHAT A DATE BECOMES: a `.double`, seconds since 2001-01-01 UTC — the value the format
// stores, unconverted. The core is Foundation-free and stays that way; `@DateFormat(.unix)`
// is not it either, since the epoch differs by 978307200 seconds. `docs/PLIST.md` names the
// constant and the reason the conversion is the caller's.
//
// WHAT A UID BECOMES: an `.int`. UIDs appear in `NSKeyedArchiver` output, which this does not
// pretend to decode — a keyed archive is a different format that happens to be written in a
// plist, and reading one as data is a separate feature nobody has asked for.
//===----------------------------------------------------------------------===//

public import Assay
public import AssayCore

enum BinaryPlist {

    static let magic: [UInt8] = Array("bplist00".utf8)

    /// A `bplist00` document, or nil having reported.
    ///
    /// `limits` bounds three separate things, and they are separate on purpose: `maxDepth`
    /// bounds nesting, the node budget bounds *total* materialised nodes (which nesting alone
    /// cannot), and the visiting set bounds cycles (which neither of the others can).
    static func decode(
        _ bytes: [UInt8], into sink: inout IssueSink, limits: Limits
    ) -> RawValue? {
        var r = Reader(bytes: bytes, limits: limits)
        return r.run(&sink)
    }

    struct Reader {
        let bytes: [UInt8]
        let limits: Limits

        var offsets: [Int] = []
        var objectRefSize = 0
        var topObject = 0
        /// Remaining nodes this document may materialise. See the header: nesting depth
        /// cannot bound this, because amplification is wide rather than deep.
        var budget = 0
        /// Object indices on the CURRENT reference path. Pushed on descent, popped on
        /// return — an object reached twice from different branches is shared and legal;
        /// an object reached from inside itself is a cycle and is not.
        var visiting: Set<Int> = []

        init(bytes: [UInt8], limits: Limits) {
            self.bytes = bytes
            self.limits = limits
            // One node per 8 bytes of input, floored generously. A real document cannot
            // materialise more nodes than it has bytes to describe them with; a bomb can,
            // which is the whole distinction being drawn.
            self.budget = max(4_096, min(limits.maxBytes, bytes.count) * 4)
        }

        mutating func fail(_ sink: inout IssueSink, _ reason: String, _ code: String) -> RawValue? {
            sink.add(Issue(code: .custom(code), params: ["reason": .string(reason)]))
            return nil
        }

        mutating func run(_ sink: inout IssueSink) -> RawValue? {
            // Header + 32-byte trailer. A file too short for both cannot be a plist, and
            // saying so is better than a bounds failure three functions down.
            guard bytes.count >= magic.count + 32 else {
                return fail(&sink, "shorter than a header plus trailer", "plist_truncated")
            }
            for (i, b) in magic.enumerated() where bytes[i] != b {
                return fail(&sink, "not a bplist00 document", "plist_bad_magic")
            }

            let t = bytes.count - 32
            let offsetIntSize = Int(bytes[t + 6])
            objectRefSize = Int(bytes[t + 7])
            // Read as UInt64 and RANGE-CHECK before narrowing. `Int(someUInt64)` traps on
            // anything above `Int.max`, and all three of these come straight out of the
            // file — so the obvious spelling turns a malformed document into a crash rather
            // than an issue. Found by the truncation test, which feeds the trailer bytes
            // that happen to lie at the cut.
            let numObjects64 = readBE(t + 8, 8)
            let topObject64 = readBE(t + 16, 8)
            let offsetTableOffset64 = readBE(t + 24, 8)
            let ceiling = UInt64(bytes.count)
            guard numObjects64 <= ceiling, topObject64 <= ceiling,
                  offsetTableOffset64 <= ceiling else {
                return fail(&sink,
                            "the trailer describes more objects than the file has bytes",
                            "plist_bad_trailer")
            }
            let numObjects = Int(numObjects64)
            topObject = Int(topObject64)
            let offsetTableOffset = Int(offsetTableOffset64)

            guard offsetIntSize >= 1, offsetIntSize <= 8,
                  objectRefSize >= 1, objectRefSize <= 8 else {
                return fail(&sink, "offset or reference width outside 1...8",
                            "plist_bad_trailer")
            }
            guard numObjects > 0, topObject < numObjects else {
                return fail(&sink, "top object is outside the object table",
                            "plist_bad_trailer")
            }
            // The multiplication is checked: numObjects comes from the file and an
            // attacker-chosen 2^63 would otherwise overflow into a small, passing product.
            let (tableBytes, overflow) = numObjects.multipliedReportingOverflow(by: offsetIntSize)
            guard !overflow, offsetTableOffset >= magic.count,
                  offsetTableOffset <= t, tableBytes <= t - offsetTableOffset else {
                return fail(&sink, "offset table does not fit in the file",
                            "plist_bad_trailer")
            }

            offsets.reserveCapacity(numObjects)
            for i in 0..<numObjects {
                let at = offsetTableOffset + i * offsetIntSize
                let off64 = readBE(at, offsetIntSize)
                guard off64 <= ceiling else {
                    return fail(&sink, "an object offset points outside the file",
                                "plist_bad_offset")
                }
                let off = Int(off64)
                guard off >= magic.count, off < t else {
                    return fail(&sink, "an object offset points outside the file",
                                "plist_bad_offset")
                }
                offsets.append(off)
            }

            return object(topObject, depth: 0, &sink)
        }

        /// Big-endian unsigned integer of `width` bytes. Callers have already bounds-checked
        /// `at ..< at + width`; `width` is at most 8, so the accumulator cannot overflow.
        func readBE(_ at: Int, _ width: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<width { v = (v << 8) | UInt64(bytes[at + i]) }
            return v
        }

        /// An object reference, narrowed so an out-of-range one becomes a bad reference
        /// (which `object` reports) rather than a trap.
        func reference(at p: Int) -> Int {
            let v = readBE(p, objectRefSize)
            return v <= UInt64(Int.max) ? Int(v) : -1
        }

        /// The size nibble, and the "0xF means an integer object follows" escape.
        /// Returns the count and the offset just past it.
        mutating func count(at p: Int, low: Int, _ sink: inout IssueSink) -> (Int, Int)? {
            guard low != 0xF else {
                guard p + 1 <= bytes.count - 32 else { return nil }
                let marker = bytes[p + 1]
                guard marker >> 4 == 0x1 else { return nil }
                let width = 1 << Int(marker & 0x0F)
                guard width <= 8, p + 2 + width <= bytes.count - 32 else { return nil }
                let n = readBE(p + 2, width)
                guard n <= UInt64(Int.max) else { return nil }
                return (Int(n), p + 2 + width)
            }
            return (low, p + 1)
        }

        mutating func object(
            _ index: Int, depth: Int, _ sink: inout IssueSink
        ) -> RawValue? {
            guard depth <= limits.maxDepth else {
                return fail(&sink, "nesting deeper than \(limits.maxDepth)", "plist_too_deep")
            }
            guard budget > 0 else {
                return fail(&sink,
                            "materialises more nodes than the document has bytes to describe "
                            + "— shared references can expand without nesting deeply",
                            "plist_amplification")
            }
            budget -= 1
            guard index >= 0, index < offsets.count else {
                return fail(&sink, "reference to object \(index), which does not exist",
                            "plist_bad_reference")
            }
            let p = offsets[index]
            let limit = bytes.count - 32
            guard p < limit else {
                return fail(&sink, "object starts past the offset table", "plist_bad_offset")
            }

            let marker = bytes[p]
            let high = Int(marker >> 4)
            let low = Int(marker & 0x0F)

            switch high {
            case 0x0:
                switch low {
                case 0x0: return .null
                case 0x8: return .bool(false)
                case 0x9: return .bool(true)
                // 0xF is a padding "fill" byte, which is not a value. It appears only in
                // malformed or hand-built files; treating it as null would invent data.
                default:
                    return fail(&sink, "unsupported singleton marker 0x0\(String(low, radix: 16))",
                                "plist_bad_marker")
                }

            case 0x1:
                let width = 1 << low
                guard width <= 16, p + 1 + width <= limit else {
                    return fail(&sink, "integer runs past the end", "plist_truncated")
                }
                // 16-byte integers exist in the wild for values above Int64. RawValue has no
                // wider case, so this refuses rather than silently truncating — a number
                // read as a different number is the one failure a decoder must never have.
                guard width <= 8 else {
                    return fail(&sink, "128-bit integer has no RawValue representation",
                                "plist_int_too_wide")
                }
                let raw = readBE(p + 1, width)
                // 1, 2 and 4-byte integers are unsigned; 8-byte ones are signed. That is the
                // format, not a choice.
                return .int(width == 8 ? Int64(bitPattern: raw) : Int64(raw))

            case 0x2:
                let width = 1 << low
                guard width == 4 || width == 8, p + 1 + width <= limit else {
                    return fail(&sink, "real is not 4 or 8 bytes", "plist_bad_real")
                }
                let raw = readBE(p + 1, width)
                return .double(width == 4
                    ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
                    : Double(bitPattern: raw))

            case 0x3:
                guard low == 0x3, p + 9 <= limit else {
                    return fail(&sink, "date is not 8 bytes", "plist_bad_date")
                }
                // Seconds since 2001-01-01 UTC, unconverted. See the header.
                return .double(Double(bitPattern: readBE(p + 1, 8)))

            case 0x4:
                guard let (n, start) = count(at: p, low: low, &sink),
                      n >= 0, start + n <= limit else {
                    return fail(&sink, "data runs past the end", "plist_truncated")
                }
                return .string(Base64.encode(bytes, start, n))

            case 0x5:
                guard let (n, start) = count(at: p, low: low, &sink),
                      n >= 0, start + n <= limit else {
                    return fail(&sink, "ASCII string runs past the end", "plist_truncated")
                }
                var s = ""
                s.reserveCapacity(n)
                for i in 0..<n {
                    let b = bytes[start + i]
                    guard b < 0x80 else {
                        return fail(&sink, "byte 0x\(String(b, radix: 16)) in an ASCII string",
                                    "plist_bad_string")
                    }
                    s.unicodeScalars.append(Unicode.Scalar(b))
                }
                return .string(s)

            case 0x6:
                guard let (n, start) = count(at: p, low: low, &sink),
                      n >= 0, start + n * 2 <= limit else {
                    return fail(&sink, "UTF-16 string runs past the end", "plist_truncated")
                }
                var units: [UInt16] = []
                units.reserveCapacity(n)
                for i in 0..<n {
                    units.append(UInt16(readBE(start + i * 2, 2)))
                }
                guard let s = decodeUTF16(units) else {
                    return fail(&sink, "unpaired surrogate in a UTF-16 string",
                                "plist_bad_string")
                }
                return .string(s)

            case 0x8:
                // A UID. See the header: an integer, not an archive reference.
                let width = low + 1
                guard width <= 8, p + 1 + width <= limit else {
                    return fail(&sink, "UID runs past the end", "plist_truncated")
                }
                return .int(Int64(readBE(p + 1, width)))

            case 0xA, 0xC:
                guard let (n, start) = count(at: p, low: low, &sink),
                      n >= 0, start + n * objectRefSize <= limit else {
                    return fail(&sink, "array runs past the end", "plist_truncated")
                }
                guard visiting.insert(index).inserted else {
                    return fail(&sink, "object \(index) contains itself", "plist_cycle")
                }
                defer { visiting.remove(index) }
                var out: [RawValue] = []
                out.reserveCapacity(min(n, 1024))
                for i in 0..<n {
                    // Narrowed the safe way, as in the trailer: an 8-byte reference above
                    // `Int.max` is a bad reference, not a crash.
                    let ref = reference(at: start + i * objectRefSize)
                    guard let v = object(ref, depth: depth + 1, &sink) else { return nil }
                    out.append(v)
                }
                return .sequence(out)

            case 0xD:
                guard let (n, start) = count(at: p, low: low, &sink),
                      n >= 0, start + n * objectRefSize * 2 <= limit else {
                    return fail(&sink, "dictionary runs past the end", "plist_truncated")
                }
                guard visiting.insert(index).inserted else {
                    return fail(&sink, "object \(index) contains itself", "plist_cycle")
                }
                defer { visiting.remove(index) }
                var members: [RawValue.Member] = []
                members.reserveCapacity(min(n, 1024))
                for i in 0..<n {
                    let kRef = reference(at: start + i * objectRefSize)
                    let vRef = reference(at: start + (n + i) * objectRefSize)
                    guard let k = object(kRef, depth: depth + 1, &sink) else { return nil }
                    // A plist key must be a string. `RawValue.Member.key` is a `String`, so
                    // a non-string key has nowhere to go — the same refusal the YAML entry
                    // point already makes, with the same reasoning and its own code.
                    guard case .string(let key) = k else {
                        return fail(&sink,
                                    "a dictionary key is not a string; plists allow it, "
                                    + "RawValue does not",
                                    "plist_unrepresentable_key")
                    }
                    guard let v = object(vRef, depth: depth + 1, &sink) else { return nil }
                    members.append(.init(key: key, value: v))
                }
                return .mapping(members)

            default:
                return fail(&sink, "unknown object marker 0x\(String(marker, radix: 16))",
                            "plist_bad_marker")
            }
        }

        /// UTF-16BE code units to a `String`, refusing unpaired surrogates rather than
        /// substituting U+FFFD — a decoder that silently repairs its input is a decoder whose
        /// output nobody can reason about.
        func decodeUTF16(_ units: [UInt16]) -> String? {
            var s = ""
            var i = 0
            while i < units.count {
                let u = units[i]
                if u >= 0xD800 && u <= 0xDBFF {
                    guard i + 1 < units.count else { return nil }
                    let lo = units[i + 1]
                    guard lo >= 0xDC00 && lo <= 0xDFFF else { return nil }
                    let v = 0x10000 + (UInt32(u - 0xD800) << 10) + UInt32(lo - 0xDC00)
                    guard let scalar = Unicode.Scalar(v) else { return nil }
                    s.unicodeScalars.append(scalar)
                    i += 2
                } else if u >= 0xDC00 && u <= 0xDFFF {
                    return nil
                } else {
                    guard let scalar = Unicode.Scalar(UInt32(u)) else { return nil }
                    s.unicodeScalars.append(scalar)
                    i += 1
                }
            }
            return s
        }
    }
}

/// Base64, because the core is Foundation-free and `Data.base64EncodedString` is not
/// available to it. Standard alphabet, padded — RFC 4648 §4, which is what the XML plist
/// flavour writes, so the two agree byte for byte.
enum Base64 {
    static let alphabet: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func encode(_ bytes: [UInt8], _ start: Int, _ count: Int) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((count + 2) / 3 * 4)
        var i = 0
        while i + 3 <= count {
            let n = (UInt32(bytes[start + i]) << 16)
                | (UInt32(bytes[start + i + 1]) << 8)
                | UInt32(bytes[start + i + 2])
            out.append(alphabet[Int((n >> 18) & 63)])
            out.append(alphabet[Int((n >> 12) & 63)])
            out.append(alphabet[Int((n >> 6) & 63)])
            out.append(alphabet[Int(n & 63)])
            i += 3
        }
        let rest = count - i
        if rest == 1 {
            let n = UInt32(bytes[start + i]) << 16
            out.append(alphabet[Int((n >> 18) & 63)])
            out.append(alphabet[Int((n >> 12) & 63)])
            out.append(UInt8(ascii: "="))
            out.append(UInt8(ascii: "="))
        } else if rest == 2 {
            let n = (UInt32(bytes[start + i]) << 16) | (UInt32(bytes[start + i + 1]) << 8)
            out.append(alphabet[Int((n >> 18) & 63)])
            out.append(alphabet[Int((n >> 12) & 63)])
            out.append(alphabet[Int((n >> 6) & 63)])
            out.append(UInt8(ascii: "="))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decoding, for the XML flavour's `<data>` element, which arrives as text.
    /// Whitespace is skipped — Apple's writer wraps at 68 columns.
    static func decode(_ text: String) -> [UInt8]? {
        var rev = [Int8](repeating: -1, count: 256)
        for (i, c) in alphabet.enumerated() { rev[Int(c)] = Int8(i) }
        var acc: UInt32 = 0
        var nbits = 0
        var out: [UInt8] = []
        for b in text.utf8 {
            if b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { continue }
            if b == UInt8(ascii: "=") { break }
            let v = rev[Int(b)]
            guard v >= 0 else { return nil }
            acc = (acc << 6) | UInt32(v)
            nbits += 6
            if nbits >= 8 {
                nbits -= 8
                out.append(UInt8(truncatingIfNeeded: acc >> UInt32(nbits)))
            }
        }
        return out
    }
}
