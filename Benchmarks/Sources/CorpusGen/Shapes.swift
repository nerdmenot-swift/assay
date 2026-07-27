// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Assay benchmark corpus generator — docs/PERFORMANCE.md §12.2.
//
// Why this exists: the standard JSON corpus (twitter/canada/citm) is megabyte-scale,
// contains no dates, no unknown keys, no absent optionals, and no invalid inputs at all.
// simdjson's paper states its scope outright — "We deliberately did not consider small
// documents (smaller than 50 kB)" — which excludes Assay's entire 1–50 kB band.
//
// So Assay builds its own, and publishes the generator alongside the files so the numbers
// are reproducible and the shapes are auditable. That commitment is the reason this is
// Swift and not a scripting language: a Swift library whose corpus generator is not
// Swift is a worse artifact, and one more toolchain a contributor has to have.
//
// Determinism is load-bearing. Fixed seed, SplitMix64 rather than the stdlib generator,
// ordered JSON objects, hand-formatted doubles. Regenerating must be byte-identical or
// the allocation-count CI gate degrades into noise.
//
//   swift run -c release CorpusGen [--out DIR]
//===----------------------------------------------------------------------===//

import Foundation

let SEED: UInt64 = 20260726
let SIZES = [512, 2_048, 8_192, 32_768, 65_536]
let SIZE_NAMES = [512: "512b", 2_048: "2k", 8_192: "8k", 32_768: "32k", 65_536: "64k"]

// Field-name pool drawn from real public API response schemas (Stripe, GitHub, Twilio,
// Kubernetes). Deliberately includes the acronym cases that break .convertFromSnakeCase.
let KEY_POOL = [
    "id", "object", "amount", "currency", "customer", "description", "livemode",
    "metadata", "status", "created", "updated_at", "account_id", "invoice_id",
    "payment_method", "receipt_url", "avatar_url", "html_url", "node_id", "login",
    "full_name", "private", "owner", "default_branch", "open_issues_count", "watchers",
    "date_created", "date_updated", "sid", "account_sid", "api_version", "direction",
    "from_number", "to_number", "price_unit", "namespace", "resource_version", "uid",
    "generation", "cluster_name", "replicas", "ready_replicas", "image_pull_policy",
    "restart_count", "container_id", "node_name", "host_ip", "pod_ip", "phase",
    "qos_class", "service_account", "termination_message_path", "dns_policy",
]

let LOWER = Array("abcdefghijklmnopqrstuvwxyz")
let LETTERS = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ ")
let HEX = Array("0123456789abcdef")

// MARK: - Value generators

/// 1–6 digits: IDs, counts, status codes. §6.1 says this is the band that matters and
/// that the SWAR eight-digit trick is a loss here.
func vInt(_ r: inout SplitMix64) -> JSON { .int(r.int(in: 0...999_999)) }

/// 13 digits — epoch millis, the one common width where SWAR would win.
func vBigInt(_ r: inout SplitMix64) -> JSON { .int(r.int(in: 1_700_000_000_000...1_800_000_000_000)) }

func vDouble(_ r: inout SplitMix64) -> JSON { .double(r.double(in: 0...10_000)) }
func vBool(_ r: inout SplitMix64) -> JSON { .bool(r.bool()) }

/// ≤15 bytes: enum-like values and codes. Free on 64-bit, allocates on wasm32 (SSO = 8).
func vShortString(_ r: inout SplitMix64) -> JSON {
    .string(r.pick(["active", "pending", "failed", "usd", "eur", "GET", "POST",
                    "succeeded", "canceled", "Running", "Ready", "true", "v1"]))
}

/// 30–120 bytes: one malloc per field on every platform.
func vLongString(_ r: inout SplitMix64) -> JSON {
    let n = r.int(in: 30...120)
    return .string(String((0..<n).map { _ in r.pick(LETTERS) }))
}

func vUUID(_ r: inout SplitMix64) -> JSON {
    func p(_ n: Int) -> String { String((0..<n).map { _ in r.pick(HEX) }) }
    return .string("\(p(8))-\(p(4))-\(p(4))-\(p(4))-\(p(12))")
}

/// ISO-8601. Nothing in the entire standard corpus contains a date; every real API
/// payload is full of them. §6.3 calls this the highest win-to-effort ratio available.
func vDate(_ r: inout SplitMix64) -> JSON {
    func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
    return .string("\(r.int(in: 2020...2026))-\(two(r.int(in: 1...12)))-\(two(r.int(in: 1...28)))"
                   + "T\(two(r.int(in: 0...23))):\(two(r.int(in: 0...59))):\(two(r.int(in: 0...59)))Z")
}

/// Forces the unescape path — the largest fork in any decoder.
func vEscaped(_ r: inout SplitMix64) -> JSON {
    let parts = ["say \"hi\"", "line\nbreak", "tab\there", "back\\slash",
                 "unicode éè", "emoji \u{1F600}", "quote\"inside"]
    let tail = String((0..<8).map { _ in r.pick(LOWER) })
    return .string(r.pick(parts) + " " + tail)
}

// MARK: - Builders

func objectOf(_ r: inout SplitMix64, target: Int,
              _ gen: (inout SplitMix64) -> JSON) -> JSON {
    var pairs: [(key: String, value: JSON)] = []
    var i = 0
    while true {
        var k = KEY_POOL[i % KEY_POOL.count]
        if i >= KEY_POOL.count { k = "\(k)_\(i / KEY_POOL.count)" }
        pairs.append((k, gen(&r)))
        i += 1
        if JSON.object(pairs).byteCount >= target { return .object(pairs) }
    }
}

func arrayOf(_ r: inout SplitMix64, target: Int,
             _ gen: (inout SplitMix64) -> JSON) -> JSON {
    var items: [JSON] = []
    while true {
        items.append(gen(&r))
        let doc = JSON.object([("items", .array(items))])
        if doc.byteCount >= target { return doc }
    }
}

func structsOf(_ r: inout SplitMix64, _ target: Int) -> JSON {
    var items: [JSON] = []
    while true {
        items.append(.object([
            ("id", vInt(&r)), ("name", vShortString(&r)),
            ("created_at", vDate(&r)), ("active", vBool(&r)), ("score", vDouble(&r)),
        ]))
        let doc = JSON.object([("items", .array(items))])
        if doc.byteCount >= target { return doc }
    }
}

func nested3(_ r: inout SplitMix64, _ target: Int) -> JSON {
    let innerTarget = max(64, target / 3)
    let attributes = objectOf(&r, target: innerTarget, vShortString)
    var included: [JSON] = []
    if case .object(let pairs) = structsOf(&r, innerTarget),
       case .array(let items)? = pairs.first(where: { $0.key == "items" })?.value {
        included = items
    }
    return .object([
        ("meta", .object([("request_id", vUUID(&r)), ("timestamp", vDate(&r)),
                          ("version", .string("v1"))])),
        ("data", .object([
            ("attributes", attributes),
            ("relationships", .object([
                ("owner", .object([("id", vInt(&r)), ("type", .string("user"))]))])),
        ])),
        ("included", .array(included)),
    ])
}

/// A bit of everything, in the proportions real payloads have.
func mixed(_ r: inout SplitMix64, _ target: Int) -> JSON {
    let gens: [(inout SplitMix64) -> JSON] =
        [vInt, vShortString, vBool, vDate, vUUID, vDouble, vLongString]
    var pairs: [(key: String, value: JSON)] = []
    var i = 0
    while true {
        var k = KEY_POOL[i % KEY_POOL.count]
        if i >= KEY_POOL.count { k = "\(k)_\(i / KEY_POOL.count)" }
        pairs.append((k, gens[i % gens.count](&r)))
        i += 1
        if JSON.object(pairs).byteCount >= target { return .object(pairs) }
    }
}

/// Half the declared fields simply are not present. Missing-key handling is a real cost
/// and nobody benchmarks it.
func optionalsAbsent(_ r: inout SplitMix64, _ target: Int) -> JSON {
    guard case .object(let pairs) = mixed(&r, target * 2) else { return .object([]) }
    return .object(pairs.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element })
}

/// Half the payload keys are NOT in the schema. Extremely common in real APIs and
/// completely unmeasured in every published JSON benchmark (§4.4).
func unknownKeys(_ r: inout SplitMix64, _ target: Int) -> JSON {
    guard case .object(let pairs) = mixed(&r, target) else { return .object([]) }
    var merged: [(key: String, value: JSON)] = []
    for (i, p) in pairs.enumerated() {
        merged.append(p)
        if i < pairs.count / 2 {
            merged.append(("x_unknown_\(i)", vShortString(&r)))
        }
    }
    return .object(merged)
}

/// Float-dense, modelled on `canada.json` — the most float-dense file in the standard
/// corpus and the one case where a scalar decoder with no Eisel-Lemire is expected to
/// lose. Coordinate pairs at 6-7 significant digits, which is exactly the shape the
/// Clinger fast path is bounded to handle.
///
/// This exists so the loss can be *measured and published* rather than assumed.
/// yyjson's benchmark repository is credible specifically because it publishes cases
/// where yyjson loses.
func floatsDense(_ r: inout SplitMix64, _ target: Int) -> JSON {
    var coords: [JSON] = []
    while true {
        coords.append(.array([
            .double(r.double(in: -180...180)),
            .double(r.double(in: -90...90)),
        ]))
        let doc = JSON.object([("type", .string("Polygon")),
                               ("coordinates", .array(coords))])
        if doc.byteCount >= target { return doc }
    }
}

/// The typed-decode shape.
///
/// Everything else varies its key set with size, which is right for exercising the
/// scanner but useless for a *typed* head-to-head: Foundation's Codable and Assay's
/// @Schema both need one fixed declared type. This holds the field set constant and
/// scales by array length instead.
func apimodel(_ r: inout SplitMix64, _ target: Int) -> JSON {
    var items: [JSON] = []
    while true {
        items.append(.object([
            ("id", vUUID(&r)),
            ("sequence", vInt(&r)),
            ("name", vShortString(&r)),
            ("description", vLongString(&r)),
            ("created_at", vDate(&r)),
            ("updated_at", vDate(&r)),
            ("amount", vDouble(&r)),
            ("active", vBool(&r)),
            ("retry_count", vInt(&r)),
            ("owner_id", vUUID(&r)),
        ]))
        let doc = JSON.object([
            ("request_id", vUUID(&r)),
            ("generated_at", vDate(&r)),
            ("page", .int(items.count)),
            ("total_count", .int(items.count * 3)),
            ("has_more", .bool(true)),
            ("items", .array(items)),
        ])
        if doc.byteCount >= target { return doc }
    }
}

struct Shape: @unchecked Sendable {
    let name: String
    let doc: String
    let build: (inout SplitMix64, Int) -> JSON
}

nonisolated(unsafe) let SHAPES: [Shape] = [
    Shape(name: "scalars",
          doc: "All Int/Double/Bool. Isolates number parsing and struct fill.",
          build: { r, t in objectOf(&r, target: t) { r in r.bool() ? vInt(&r) : vDouble(&r) } }),
    Shape(name: "short-strings",
          doc: "All string values <=15 bytes. Isolates the SSO win and exposes the wasm32 cliff.",
          build: { r, t in objectOf(&r, target: t, vShortString) }),
    Shape(name: "long-strings",
          doc: "All string values 30-120 bytes. One malloc per field, worst case.",
          build: { r, t in objectOf(&r, target: t, vLongString) }),
    Shape(name: "uuids-and-dates",
          doc: "The realistic API case. Every string allocates on every platform.",
          build: { r, t in objectOf(&r, target: t) { r in r.bool() ? vUUID(&r) : vDate(&r) } }),
    Shape(name: "escaped",
          doc: "Strings requiring unescaping. Separates the memcpy path from the transform path.",
          build: { r, t in objectOf(&r, target: t, vEscaped) }),
    Shape(name: "arrays-of-scalars",
          doc: "Tests the exact-sizing hypothesis of allocation strategy 2.1.",
          build: { r, t in arrayOf(&r, target: t, vInt) }),
    Shape(name: "arrays-of-structs",
          doc: "The other side of exact-sizing: per-element work dominates.",
          build: structsOf),
    Shape(name: "nested-3-deep",
          doc: "Realistic envelope + payload + metadata.",
          build: nested3),
    Shape(name: "mixed",
          doc: "A bit of everything, in real-payload proportions.",
          build: mixed),
    Shape(name: "bigints",
          doc: "13-digit epoch-millis. The one integer width where SWAR would win.",
          build: { r, t in objectOf(&r, target: t, vBigInt) }),
    Shape(name: "optionals-absent",
          doc: "Half the declared fields are absent.",
          build: optionalsAbsent),
    Shape(name: "optionals-present",
          doc: "All declared fields present. Control for optionals-absent.",
          build: mixed),
    Shape(name: "unknown-keys",
          doc: "Half the payload keys are not in the schema. Skip-cost.",
          build: unknownKeys),
    Shape(name: "floats-dense",
          doc: "canada.json-shaped coordinate pairs. The case a scalar decoder is "
             + "expected to lose; generated so the loss can be published.",
          build: floatsDense),
    Shape(name: "apimodel",
          doc: "Fixed field set, scales by array length. The only shape a typed "
             + "head-to-head against Foundation's Codable can use.",
          build: apimodel),
]

// MARK: - Negative cases
//
// No JSON benchmark includes these, and they matter enormously for a validator.

struct Negative: @unchecked Sendable {
    let name: String
    let doc: String
    let build: (inout SplitMix64) -> [UInt8]
}

nonisolated(unsafe) let NEGATIVES: [Negative] = [
    Negative(name: "invalid-early", doc: "Malformed at byte 10. Measures fail-fast.",
             build: { r in
                 var b = mixed(&r, 8_192).encoded
                 b[10] = 0xFF; b[11] = 0xFE
                 return b
             }),
    Negative(name: "invalid-late", doc: "Malformed near byte 8000.",
             build: { r in
                 var b = mixed(&r, 8_192).encoded
                 let cut = min(b.count - 20, 8_000)
                 b[cut] = 0x40; b[cut + 1] = 0x40
                 return b
             }),
    Negative(name: "type-mismatch", doc: "Well-formed JSON, wrong types for the schema.",
             build: { r in
                 guard case .object(let pairs) = mixed(&r, 8_192) else { return [] }
                 return JSON.object(pairs.enumerated().map { i, p in
                     i % 3 == 0
                         ? (p.key, i % 2 == 0 ? .array([.string("wrong")])
                                              : .object([("wrong", .string("shape"))]))
                         : p
                 }).encoded
             }),
    Negative(name: "truncated", doc: "Unterminated document.",
             build: { r in
                 let b = mixed(&r, 8_192).encoded
                 return Array(b[0..<(b.count / 2)])
             }),
    Negative(name: "validation-fail-many",
             doc: "20 rule violations. Exercises issue collection from the unhappy side.",
             build: { r in
                 guard case .object(let pairs) = mixed(&r, 8_192) else { return [] }
                 return JSON.object(pairs.enumerated().map { i, p in
                     i < 20 ? (p.key, .string("")) : p
                 }).encoded
             }),
    Negative(name: "deep-nesting", doc: "200 levels deep. Exercises Limits.maxDepth.",
             build: { _ in
                 let depth = 200
                 var b: [UInt8] = []
                 for _ in 0..<depth { b.append(contentsOf: Array("{\"a\":".utf8)) }
                 b.append(0x31)
                 for _ in 0..<depth { b.append(0x7D) }
                 return b
             }),
]

