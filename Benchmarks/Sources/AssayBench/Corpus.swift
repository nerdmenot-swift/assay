//===----------------------------------------------------------------------===//
// The full corpus sweep — all 81 files of docs/PERFORMANCE.md §12.2, not the two shapes
// the falsification check needed.
//
// Three passes, because one number cannot answer three questions:
//
//   STRUCT DECODE — @Schema vs Codable on shapes a fixed struct consumes entirely
//   (apimodel, arrays-of-*, nested-3-deep, floats-dense). This is the headline claim.
//
//   PREFIX + SKIP — the flat shapes scale by ADDING KEYS (bigints-64k has 2232 of them),
//   so a fixed struct necessarily consumes a prefix and skips the rest. That is not a
//   defect in the measurement, it is the single most common real shape: a client struct
//   against a verbose server response. Both decoders do the same work, and the skip path
//   is what §13.2's structural skip exists for.
//
//   GENERIC VALUE — JSON.Value vs JSONSerialization over every positive file. No struct,
//   no macro, no key dispatch: the value model on its own, where Assay has none of its
//   structural advantage and the comparison is nearly like-for-like.
//
// Plus the negative files, where the question is not throughput but whether collecting
// every error costs more than Foundation's throw-on-first.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore

// MARK: - Prefix schemas for the flat shapes
//
// Six fields each, matching the corpus generator's stable prefix, with unknown keys
// ignored. The Codable twins use snake_case member names so no key strategy is in play
// on either side — CodingKeys or .convertFromSnakeCase would put different work on
// Foundation's side of the comparison and make the ratio meaningless.

@Schema(unknownKeys: .ignore)
struct IntPrefix {
    var id: Int, object: Int, amount: Int, currency: Int, customer: Int, description: Int
}
struct CodableIntPrefix: Codable {
    var id: Int, object: Int, amount: Int, currency: Int, customer: Int, description: Int
}

@Schema(unknownKeys: .ignore)
struct StringPrefix {
    var id: String, object: String, amount: String
    var currency: String, customer: String, description: String
}
struct CodableStringPrefix: Codable {
    var id: String, object: String, amount: String
    var currency: String, customer: String, description: String
}

@Schema(unknownKeys: .ignore)
struct MixedPrefix {
    var id: Int, object: String, amount: Bool
    var currency: String, customer: String, description: Double
}
struct CodableMixedPrefix: Codable {
    var id: Int, object: String, amount: Bool
    var currency: String, customer: String, description: Double
}

@Schema(unknownKeys: .ignore)
struct FloatPrefix {
    var id: Double, object: Int, amount: Double
    var currency: Double, customer: Int, description: Double
}
struct CodableFloatPrefix: Codable {
    var id: Double, object: Int, amount: Double
    var currency: Double, customer: Int, description: Double
}

/// optionals-absent omits half its keys; the point is that absence costs nothing.
@Schema(unknownKeys: .ignore)
struct OptionalPrefix {
    var id: Int
    var object: String?
    var amount: Bool
    var currency: String?
    var customer: String
    var description: Double?
}
struct CodableOptionalPrefix: Codable {
    var id: Int
    var object: String?
    var amount: Bool
    var currency: String?
    var customer: String
    var description: Double?
}

// MARK: - Structurally faithful schemas

@Schema(keys: .snakeCase)
struct ScalarArray {
    var items: [Int]
}
struct CodableScalarArray: Codable { var items: [Int] }

@Schema(keys: .snakeCase)
struct StructItem {
    var id: Int
    var name: String
    var createdAt: String
    var active: Bool
    var score: Double
}
@Schema(keys: .snakeCase)
struct StructArray {
    var items: [StructItem]
}
struct CodableStructItem: Codable {
    var id: Int, name: String, created_at: String, active: Bool, score: Double
}
struct CodableStructArray: Codable { var items: [CodableStructItem] }

@Schema(keys: .snakeCase, unknownKeys: .ignore)
struct NestedMeta {
    var requestId: String
    var timestamp: String
    var version: String
}
@Schema(keys: .snakeCase, unknownKeys: .ignore)
struct NestedOwner {
    var id: Int
    var type: String
}
@Schema(keys: .snakeCase, unknownKeys: .ignore)
struct NestedRelationships {
    var owner: NestedOwner
}
@Schema(keys: .snakeCase, unknownKeys: .ignore)
struct NestedData {
    var relationships: NestedRelationships
}
@Schema(keys: .snakeCase, unknownKeys: .ignore)
struct NestedDoc {
    var meta: NestedMeta
    var data: NestedData
    var included: [StructItem]
}
struct CodableNestedMeta: Codable { var request_id: String, timestamp: String, version: String }
struct CodableNestedOwner: Codable { var id: Int, type: String }
struct CodableNestedRelationships: Codable { var owner: CodableNestedOwner }
struct CodableNestedData: Codable { var relationships: CodableNestedRelationships }
struct CodableNestedDoc: Codable {
    var meta: CodableNestedMeta
    var data: CodableNestedData
    var included: [CodableStructItem]
}

// MARK: - Shape registry
//
// Each entry knows how to decode its shape both ways. Closures returning Bool ("did it
// produce a value") keep the driver uniform without existentials in the timed region.

struct ShapeRunner: Sendable {
    let name: String
    let assay: @Sendable ([UInt8]) -> Bool
    let foundation: @Sendable (Data) -> Bool
}

let structShapes: [ShapeRunner] = [
    ShapeRunner(name: "apimodel",
                assay: { Payload.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodablePayload.self, from: $0)) != nil }),
    ShapeRunner(name: "arrays-of-scalars",
                assay: { ScalarArray.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableScalarArray.self, from: $0)) != nil }),
    ShapeRunner(name: "arrays-of-structs",
                assay: { StructArray.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableStructArray.self, from: $0)) != nil }),
    ShapeRunner(name: "nested-3-deep",
                assay: { NestedDoc.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableNestedDoc.self, from: $0)) != nil }),
    ShapeRunner(name: "floats-dense",
                assay: { Polygon.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodablePolygon.self, from: $0)) != nil }),
]

let prefixShapes: [ShapeRunner] = [
    ShapeRunner(name: "bigints",
                assay: { IntPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableIntPrefix.self, from: $0)) != nil }),
    ShapeRunner(name: "escaped",
                assay: { StringPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableStringPrefix.self, from: $0)) != nil }),
    ShapeRunner(name: "long-strings",
                assay: { StringPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableStringPrefix.self, from: $0)) != nil }),
    ShapeRunner(name: "short-strings",
                assay: { StringPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableStringPrefix.self, from: $0)) != nil }),
    ShapeRunner(name: "uuids-and-dates",
                assay: { StringPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableStringPrefix.self, from: $0)) != nil }),
    ShapeRunner(name: "mixed",
                assay: { MixedPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableMixedPrefix.self, from: $0)) != nil }),
    ShapeRunner(name: "optionals-present",
                assay: { OptionalPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableOptionalPrefix.self, from: $0)) != nil }),
    ShapeRunner(name: "scalars",
                assay: { FloatPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableFloatPrefix.self, from: $0)) != nil }),
    ShapeRunner(name: "unknown-keys",
                assay: { MixedPrefix.diagnose(json: $0).value != nil },
                foundation: { (try? JSONDecoder().decode(CodableMixedPrefix.self, from: $0)) != nil }),
]
