// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Encoding, measured. Added 2026-09-08 to close a stated prohibition rather than to make a
// claim: `docs/ENCODING.md` §288 says
//
//     "Encoding is unbenchmarked. No number should be quoted for it until the harness has
//      an arm, and the honesty rules apply to the encode direction exactly as to the decode
//      one."
//
// Encoding shipped 2026-08-09 with differential oracles for correctness -- 75 documents that
// Foundation, libyaml and Foundation's XMLParser all read back -- and no performance arm at
// all. `grep encode Benchmarks/Sources/AssayBench` returned nothing until this file.
//
// WHAT THIS IS NOT. It is not a thesis. The decode thesis is that deleting the
// `KeyedDecodingContainer` boundary is worth a large multiple, and it is measured at 9x. The
// encode direction has no equivalent claim: `JSONEncoder` is a different amount of machinery
// and Assay's writer is a different amount of machinery, and whichever wins, the number is a
// number rather than an argument. It is measured so that it is known, and so that a
// regression in it is visible.
//
// The comparison is the honest one a migrating project would make: `Encodable` +
// `JSONEncoder` against `@Schema(encodes: true)` + `encodedJSON()`, over the same corpus
// shapes the decode arms use, at the same sizes.
//
// WHICH `JSONEncoder`, because it changes what the ratio means. Foundation's JSON encoder
// was rewritten in pure Swift for swift-foundation; the legacy Darwin one boxed values
// through `NSNumber` and was materially slower, so a ratio against it would be a ratio
// against something nobody runs any more.
//
// Verified rather than assumed, on 2026-09-08 / macOS 26 / Xcode toolchain. The linked
// symbol is `Foundation.JSONEncoder.encode<A>(A) throws -> Data` from the system
// `Foundation.framework`, which is in the dyld shared cache and so cannot be read with
// `nm`. The discriminator is behavioural: the legacy implementation widened `Float` to
// `Double` through `NSNumber`, so `Float(0.1)` encoded as `0.10000000149011612`. Here it
// encodes as `0.1`. That is the rewrite.
//
// So this ratio is against a current baseline. If it is ever re-run somewhere the old
// implementation is live -- an older OS, a Linux corelibs build -- the number will flatter
// Assay and should be labelled with the platform rather than quoted bare.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayYAML
import AssayXML

@Schema(keys: .snakeCase, formats: .all, encodes: true)
struct EncItem: Equatable {
    var id: String
    var sequence: Int
    var name: String
    var description: String
    var createdAt: String
    var updatedAt: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    var ownerId: String
}

@Schema(keys: .snakeCase, formats: .all, encodes: true)
struct EncPayloadBench: Equatable {
    var requestId: String
    var generatedAt: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [EncItem]
}

/// The same shape through `Encodable`, which is what a migrating project is leaving.
struct CodableEncItem: Encodable {
    var id: String
    var sequence: Int
    var name: String
    var description: String
    var createdAt: String
    var updatedAt: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    var ownerId: String
    enum CodingKeys: String, CodingKey {
        case id, sequence, name, description
        case createdAt = "created_at", updatedAt = "updated_at"
        case amount, active
        case retryCount = "retry_count", ownerId = "owner_id"
    }
}

struct CodableEncPayload: Encodable {
    var requestId: String
    var generatedAt: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [CodableEncItem]
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id", generatedAt = "generated_at"
        case page
        case totalCount = "total_count", hasMore = "has_more"
        case items
    }
}

func runEncodeBenchmarks() {
    print("")
    print("Encoding — @Schema(encodes: true) vs Encodable + JSONEncoder")
    print("Unmeasured until 2026-09-08; docs/ENCODING.md forbade quoting a number until")
    print("this arm existed. It is a measurement, not a thesis: the decode direction's")
    print("claim is about deleting the Codable boundary, and encoding makes no such claim.")
    print("")
    print(pad("items", 8, right: true) + pad("bytes", 10) + pad("JSONEncoder ns", 16)
          + pad("Assay ns", 12) + pad("ratio", 10))
    print(String(repeating: "-", count: 58))

    for count in [1, 10, 50, 200] {
        let items = (0..<count).map { i in
            EncItem(id: "id-\(i)", sequence: i, name: "name-\(i)",
                    description: "a description of moderate length for item \(i)",
                    createdAt: "2026-08-09T12:00:00Z", updatedAt: "2026-08-09T12:30:00Z",
                    amount: Double(i) * 1.5, active: i % 2 == 0,
                    retryCount: i % 4, ownerId: "owner-\(i)")
        }
        let payload = EncPayloadBench(
            requestId: "req-1", generatedAt: "2026-08-09T12:00:00Z",
            page: 1, totalCount: count, hasMore: false, items: items)

        let cItems = items.map {
            CodableEncItem(id: $0.id, sequence: $0.sequence, name: $0.name,
                           description: $0.description, createdAt: $0.createdAt,
                           updatedAt: $0.updatedAt, amount: $0.amount, active: $0.active,
                           retryCount: $0.retryCount, ownerId: $0.ownerId)
        }
        let cPayload = CodableEncPayload(
            requestId: payload.requestId, generatedAt: payload.generatedAt,
            page: payload.page, totalCount: payload.totalCount,
            hasMore: payload.hasMore, items: cItems)

        guard let bytes = try? payload.encodedJSON() else { continue }
        let reps = max(50, 200_000 / max(1, bytes.count))

        let encoder = JSONEncoder()
        let foundation = measure(iterations: reps) {
            _ = try? encoder.encode(cPayload)
        }
        let assay = measure(iterations: reps) {
            _ = try? payload.encodedJSON()
        }
        print(pad("\(count)", 8, right: true)
              + pad("\(bytes.count)", 10)
              + pad(String(format: "%.0f", foundation), 16)
              + pad(String(format: "%.0f", assay), 12)
              + pad(String(format: "%.2fx", foundation / assay), 10))
    }

    // YAML and XML have no Foundation counterpart to compare against, so they are reported
    // as absolute cost per document rather than as a ratio. A ratio against nothing is how
    // a benchmark starts lying.
    print("")
    print("YAML and XML encode — absolute, no comparable Foundation encoder exists")
    print(pad("format", 12) + pad("bytes", 10) + pad("ns/document", 14))
    print(String(repeating: "-", count: 36))

    let items = (0..<50).map { i in
        EncItem(id: "id-\(i)", sequence: i, name: "name-\(i)",
                description: "a description of moderate length for item \(i)",
                createdAt: "2026-08-09T12:00:00Z", updatedAt: "2026-08-09T12:30:00Z",
                amount: Double(i) * 1.5, active: i % 2 == 0,
                retryCount: i % 4, ownerId: "owner-\(i)")
    }
    let payload = EncPayloadBench(
        requestId: "req-1", generatedAt: "2026-08-09T12:00:00Z",
        page: 1, totalCount: 50, hasMore: false, items: items)

    if let j = try? payload.encodedJSON() {
        let ns = measure(iterations: 2_000) { _ = try? payload.encodedJSON() }
        print(pad("json", 12) + pad("\(j.count)", 10) + pad(String(format: "%.0f", ns), 14))
    }
    if let y = try? payload.encodedYAML() {
        let ns = measure(iterations: 2_000) { _ = try? payload.encodedYAML() }
        print(pad("yaml", 12) + pad("\(y.count)", 10) + pad(String(format: "%.0f", ns), 14))
    }
    if let x = try? payload.encodedXML() {
        let ns = measure(iterations: 2_000) { _ = try? payload.encodedXML() }
        print(pad("xml", 12) + pad("\(x.count)", 10) + pad(String(format: "%.0f", ns), 14))
    }
}
