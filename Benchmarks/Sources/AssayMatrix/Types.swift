// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The types the fixtures decode into.
//
// Assay is schema-driven, which is the one way this matrix differs from haul's: there, a
// fixture is read by a schema-less reader and the shape is entirely in the file. Here a
// shape and a type are a PAIR, and a property like "field count" moves both. So the types
// are written out rather than generated, one per axis position, and the mapping from shape
// to type lives in `Tasks.swift` where it can be read in one screen.
//
// Every type is `Equatable` so a task can consume its result without the optimiser being
// able to prove the decode dead, and `encodes: true` where an encode task needs it.
//===----------------------------------------------------------------------===//

import Assay
import AssayCore

// MARK: - Field count, the jump-table axis

@Schema(encodes: true) struct M2: Equatable { var f0: String; var f1: String }
@Schema(encodes: true) struct Doc2: Equatable { var items: [M2] }

@Schema(formats: .all, encodes: true) struct M5: Equatable {
    var f0: String; var f1: String; var f2: String; var f3: String; var f4: String
}
@Schema(formats: .all, encodes: true) struct Doc5: Equatable { var items: [M5] }

/// Twenty fields: past experiment #1's N ≥ 10, so this is the first benchmark in the
/// repository that has ever exercised a real arm64 jump table.
@Schema(encodes: true) struct M20: Equatable {
    var f0: String; var f1: String; var f2: String; var f3: String; var f4: String
    var f5: String; var f6: String; var f7: String; var f8: String; var f9: String
    var f10: String; var f11: String; var f12: String; var f13: String; var f14: String
    var f15: String; var f16: String; var f17: String; var f18: String; var f19: String
}
@Schema(encodes: true) struct Doc20: Equatable { var items: [M20] }

// MARK: - Key length, across the small-string boundary

@Schema struct MLongKeys: Equatable {
    var a_rather_long_field_name_number_0: String
    var a_rather_long_field_name_number_1: String
    var a_rather_long_field_name_number_2: String
    var a_rather_long_field_name_number_3: String
    var a_rather_long_field_name_number_4: String
}
@Schema struct DocLongKeys: Equatable { var items: [MLongKeys] }

// MARK: - Value type

@Schema struct MInt: Equatable {
    var f0: Int64; var f1: Int64; var f2: Int64; var f3: Int64; var f4: Int64
}
@Schema struct DocInt: Equatable { var items: [MInt] }

@Schema struct MDouble: Equatable {
    var f0: Double; var f1: Double; var f2: Double; var f3: Double; var f4: Double
}
@Schema struct DocDouble: Equatable { var items: [MDouble] }

@Schema struct MBool: Equatable {
    var f0: Bool; var f1: Bool; var f2: Bool; var f3: Bool; var f4: Bool
}
@Schema struct DocBool: Equatable { var items: [MBool] }

// MARK: - Shape

// `encodes: true` since 2026-09-19, so `nested-3/encode` measures what a NESTED field costs on
// the write side; every other encode cell is flat.
@Schema(formats: .all, encodes: true) struct MInner2: Equatable { var h0: String }
@Schema(formats: .all, encodes: true) struct MInner1: Equatable { var g0: String; var inner: MInner2 }
@Schema(formats: .all, encodes: true) struct MNested: Equatable {
    var f0: String; var f1: String; var f2: String; var f3: String
    var inner: MInner1
}
@Schema(formats: .all, encodes: true) struct DocNested: Equatable { var items: [MNested] }

@Schema struct MArray: Equatable {
    var f0: String; var f1: String; var f2: String; var f3: String
    var tags: [String]
}
@Schema struct DocArray: Equatable { var items: [MArray] }

// MARK: - Absence

@Schema struct MOptional: Equatable {
    var f0: String?; var f1: String?; var f2: String?; var f3: String?; var f4: String?
}
@Schema struct DocOptional: Equatable { var items: [MOptional] }

// MARK: - The prefix type, for the unknown-key skip path

/// Two fields declared out of ten present: the structural skip is most of the work, which
/// is the arm `prefix decode + unknown-key skip` exists for — here with a gradient.
@Schema struct MPrefix: Equatable { var f0: String; var f1: String }
@Schema struct DocPrefix: Equatable { var items: [MPrefix] }

// MARK: - A validated variant
//
// A rule-free `@Schema` does not conform to `Validatable` — there is nothing to run — so
// the `validate` task needs a type that carries rules. Same five short string fields as the
// base, with the cheapest rule that still has to look at every byte.

@Schema struct MValidated: Equatable {
    @Validate(.min(1)) var f0: String
    @Validate(.min(1)) var f1: String
    @Validate(.min(1)) var f2: String
    @Validate(.min(1)) var f3: String
    @Validate(.min(1)) var f4: String
}
@Schema struct DocValidated: Equatable { var items: [MValidated] }
