// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The model the falsification check decodes, declared twice: once for @Schema, once for
// Codable. Kept beside each other so a field added to one is visibly missing from the
// other — the correctness gate in FalsificationBench compares the two decodes field by
// field before timing anything.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

@Schema(keys: .snakeCase)
struct Item {
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

@Schema(keys: .snakeCase)
struct Payload {
    var requestId: String
    var generatedAt: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [Item]
}

struct CodableItem: Codable {
    var id: String
    var sequence: Int
    var name: String
    var description: String
    var created_at: String
    var updated_at: String
    var amount: Double
    var active: Bool
    var retry_count: Int
    var owner_id: String
}

// Float-dense, canada.json-shaped. The case a scalar decoder with no Eisel-Lemire is
// expected to lose — measured so the loss can be published rather than assumed.
@Schema
struct Polygon {
    var type: String
    var coordinates: [[Double]]
}

struct CodablePolygon: Codable {
    var type: String
    var coordinates: [[Double]]
}

struct CodablePayload: Codable {
    var request_id: String
    var generated_at: String
    var page: Int
    var total_count: Int
    var has_more: Bool
    var items: [CodableItem]
}
