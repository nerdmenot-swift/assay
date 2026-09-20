// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// WHAT A MISSING `formats:` LOOKS LIKE.
//
// `Article.parse(yaml:)` on a schema that does not declare YAML used to say
//
//     referencing static method 'parse(yaml:limits:sourceName:)' on 'RawDecodable'
//     requires that 'Article' conform to 'RawDecodable'
//
// which names an underscore-adjacent internal protocol the reader has never heard of, and
// nowhere says the fix. `@XML(root:)`'s refusal has said "Add `formats: .xml` (or `.all`)"
// since it shipped, and that is the standard the rest of the doors should meet.
//
// The mechanism: the real entry points live on `RawDecodable`; these live on `Assayable`,
// which every schema conforms to, and are `unavailable`. A type that DOES decode YAML
// resolves to the real one — the more constrained extension wins — and a type that does not
// gets this sentence instead of a conformance error. Verified both ways by compiling them.
//===----------------------------------------------------------------------===//

import AssayCore
import Assay

extension Assayable {

    @available(*, unavailable, message: "this schema does not decode YAML. Add `formats: .yaml` (or `.all`) to its @Schema, e.g. @Schema(formats: .yaml).")
    public static func parse(yaml bytes: [UInt8], limits: Limits = .default,
                             sourceName: String = "<input>") throws -> Self {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "this schema does not decode YAML. Add `formats: .yaml` (or `.all`) to its @Schema, e.g. @Schema(formats: .yaml).")
    public static func parse(yaml text: String, limits: Limits = .default,
                             sourceName: String = "<input>") throws -> Self {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "this schema does not decode YAML. Add `formats: .yaml` (or `.all`) to its @Schema, e.g. @Schema(formats: .yaml).")
    public static func diagnose(yaml bytes: [UInt8], limits: Limits = .default,
                                sourceName: String = "<input>") -> Diagnosis<Self> {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "this schema does not decode YAML. Add `formats: .yaml` (or `.all`) to its @Schema, e.g. @Schema(formats: .yaml).")
    public static func diagnose(yaml text: String, limits: Limits = .default,
                                sourceName: String = "<input>") -> Diagnosis<Self> {
        fatalError("unavailable")
    }

    // The encode side needs BOTH `encodes: true` and the format, so the message names both
    // rather than sending the reader back for a second compile to discover the other half.
    @available(*, unavailable, message: "this schema does not encode YAML. It needs both `encodes: true` and the format — e.g. @Schema(formats: .yaml, encodes: true).")
    public func encodedYAML() throws -> EncodedBytes {
        fatalError("unavailable")
    }
}
