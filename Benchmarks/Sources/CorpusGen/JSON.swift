// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A tiny JSON writer with ORDERED object keys, and a seeded PRNG.
//
// Both exist for one reason: determinism. Regenerating the corpus must be byte-identical
// or the allocation-count CI gate becomes noise rather than a signal.
//
// Swift's Dictionary is unordered and its iteration order is seed-randomised per process,
// so an object cannot be modelled as [String: JSON]. Keys are an ordered array of pairs.
//
// The PRNG is SplitMix64 rather than SystemRandomNumberGenerator or Int.random(in:),
// because the stdlib makes no guarantee that its generator's output sequence is stable
// across toolchain versions. A corpus that changes when you upgrade Swift is not a corpus.
//===----------------------------------------------------------------------===//

/// SplitMix64. Fixed, published, trivially reimplementable in any language — which
/// matters if anyone ever wants to regenerate this corpus outside Swift.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<n`, without modulo bias.
    mutating func int(_ n: Int) -> Int {
        precondition(n > 0)
        let bound = UInt64(n)
        let limit = UInt64.max - (UInt64.max % bound)
        var r = next()
        while r >= limit { r = next() }
        return Int(r % bound)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + int(range.count)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    mutating func bool() -> Bool { next() & 1 == 0 }

    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

/// Ordered JSON. `object` keeps insertion order so output is stable.
///
/// `Member` IS A NAMED STRUCT AND MUST NOT BECOME A TUPLE AGAIN. `case object([(key:
/// String, value: JSON)])` is the obvious spelling, it is what this file used to say, and
/// it does not compile in debug. The error names no file, no line and no declaration:
///
///     <unknown>:0: error: circular reference
///
/// `-Xfrontend -debug-cycles` prints what it will not:
///
///     TypeCheckFunctionBodyRequest(unknownKeys @ Shapes.swift)
///      -> LookupConformance(Sendable for [(key: String, value: JSON)])
///       -> LookupConformance(Sendable for (key: String, value: JSON))
///        -> LookupConformance(Sendable for Pack{String, JSON})
///         -> LookupConformance(Sendable for JSON)
///          -> ImplicitKnownProtocolConformanceRequest(JSON, Sendable)
///           -> LookupConformance(Sendable for Array<(key: String, value: JSON)>)
///            -> (cyclic dependency)
///
/// The loop closes because the tuple is in the enum's STORED PAYLOAD: inferring Sendable
/// for `JSON` requires it of the payload, which requires it of the tuple, which requires
/// it of `JSON`. Recursion through `JSON` is not itself the problem — `case array([JSON])`
/// is just as recursive and has never been an issue.
///
/// That the payload is what matters is verified rather than assumed. With `Member` in
/// place, a function declaring a `[(key: String, value: JSON)]` LOCAL — the same tuple, the
/// same recursion, one position over — compiles fine. Removing it from the payload is the
/// whole fix.
///
/// HONEST LIMIT ON THIS EXPLANATION: a synthetic minimal case does not reproduce it. A
/// fresh `indirect enum { case leaf; case node([(String, Self)]) }` plus a function forcing
/// the same lookup compiles clean, with or without an `[Self]` case and with or without
/// labels. So some further ingredient of the real type is involved and has not been
/// isolated. What is established is the trace above, and that the struct removes it.
///
/// An explicit `: Sendable` on the enum also silences it, and that was the first fix here.
/// It is narrower — it stops the inference request from being issued rather than removing
/// the loop — so this file no longer relies on it, and does not declare it.
///
/// It only bit in DEBUG. Release builds whole-module and never issues the per-file
/// `TypeCheckPrimaryFileRequest` that starts the chain, and every CI step exercising this
/// package ran `-c release` — which is how it sat broken for an unknown length of time.
/// CI now builds this package in debug as well.
indirect enum JSON {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSON])
    case object([Member])

    /// One key-value pair. Named rather than a tuple; see above.
    struct Member {
        var key: String
        var value: JSON
        init(_ key: String, _ value: JSON) {
            self.key = key
            self.value = value
        }
    }
}

extension JSON {
    /// Minified, matching what an API actually sends. A pretty-printed corpus would be
    /// measuring whitespace skipping — `citm_catalog.json` is 71% whitespace, which is
    /// why every published "citm at N GB/s" figure is really a whitespace benchmark.
    var encoded: [UInt8] {
        var out: [UInt8] = []
        write(into: &out)
        return out
    }

    private func write(into out: inout [UInt8]) {
        switch self {
        case .string(let s):
            JSON.writeString(s, into: &out)
        case .int(let i):
            out.append(contentsOf: Array(String(i).utf8))
        case .double(let d):
            // Two decimal places, formatted by hand. `String(d)` would emit
            // platform- and version-dependent shortest-round-trip output.
            let scaled = (d * 100).rounded()
            let whole = Int(scaled) / 100
            let frac = abs(Int(scaled) % 100)
            out.append(contentsOf: Array("\(whole).\(frac < 10 ? "0" : "")\(frac)".utf8))
        case .bool(let b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .array(let items):
            out.append(0x5B)
            for (i, v) in items.enumerated() {
                if i > 0 { out.append(0x2C) }
                v.write(into: &out)
            }
            out.append(0x5D)
        case .object(let pairs):
            out.append(0x7B)
            for (i, p) in pairs.enumerated() {
                if i > 0 { out.append(0x2C) }
                JSON.writeString(p.key, into: &out)
                out.append(0x3A)
                p.value.write(into: &out)
            }
            out.append(0x7D)
        }
    }

    /// RFC 8259 string escaping. Deliberately escapes only what must be escaped, so the
    /// `escaped` corpus shape exercises the unescape path and the others do not.
    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":  out.append(contentsOf: Array("\\\"".utf8))
            case "\\":  out.append(contentsOf: Array("\\\\".utf8))
            case "\n":  out.append(contentsOf: Array("\\n".utf8))
            case "\r":  out.append(contentsOf: Array("\\r".utf8))
            case "\t":  out.append(contentsOf: Array("\\t".utf8))
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out.append(contentsOf: Array("\\u\(String(repeating: "0", count: 4 - hex.count))\(hex)".utf8))
                } else {
                    out.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        out.append(0x22)
    }

    var byteCount: Int { encoded.count }

    /// Every string value and every key, for the length histogram.
    func collectStringLengths(into acc: inout [Int]) {
        switch self {
        case .string(let s):
            acc.append(s.utf8.count)
        case .array(let items):
            for v in items { v.collectStringLengths(into: &acc) }
        case .object(let pairs):
            for p in pairs {
                acc.append(p.key.utf8.count)
                p.value.collectStringLengths(into: &acc)
            }
        default:
            break
        }
    }
}
