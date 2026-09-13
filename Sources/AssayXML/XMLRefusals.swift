// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// WHAT A MISSING `formats:` LOOKS LIKE.
//
// `Article.parse(xml:)` on a schema that does not declare XML used to say
//
//     referencing static method 'parse(xml:limits:sourceName:)' on 'RawDecodable'
//     requires that 'Article' conform to 'RawDecodable'
//
// which names an underscore-adjacent internal protocol the reader has never heard of, and
// nowhere says the fix. `@XML(root:)`'s refusal has said "Add `formats: .xml` (or `.all`)"
// since it shipped, and that is the standard the rest of the doors should meet.
//
// The mechanism: the real entry points live on `RawDecodable`; these live on `Assayable`,
// which every schema conforms to, and are `unavailable`. A type that DOES decode XML
// resolves to the real one — the more constrained extension wins — and a type that does not
// gets this sentence instead of a conformance error. Verified both ways by compiling them.
//===----------------------------------------------------------------------===//

import AssayCore
import Assay

extension Assayable {

    @available(*, unavailable, message: "this schema does not decode XML. Add `formats: .xml` (or `.all`) to its @Schema, e.g. @Schema(formats: .xml).")
    public static func parse(xml bytes: [UInt8], limits: Limits = .default,
                             sourceName: String = "<input>") throws -> Self {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "this schema does not decode XML. Add `formats: .xml` (or `.all`) to its @Schema, e.g. @Schema(formats: .xml).")
    public static func parse(xml text: String, limits: Limits = .default,
                             sourceName: String = "<input>") throws -> Self {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "this schema does not decode XML. Add `formats: .xml` (or `.all`) to its @Schema, e.g. @Schema(formats: .xml).")
    public static func diagnose(xml bytes: [UInt8], limits: Limits = .default,
                                sourceName: String = "<input>") -> Diagnosis<Self> {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "this schema does not decode XML. Add `formats: .xml` (or `.all`) to its @Schema, e.g. @Schema(formats: .xml).")
    public static func diagnose(xml text: String, limits: Limits = .default,
                                sourceName: String = "<input>") -> Diagnosis<Self> {
        fatalError("unavailable")
    }

    // XML's encoder takes a root element name, so the signature has to match the real one
    // for the refusal to be the overload that is chosen.
    @available(*, unavailable, message: "this schema does not encode XML. It needs both `encodes: true` and the format — e.g. @Schema(formats: .xml, encodes: true).")
    public func encodedXML(root: String? = nil, pretty: Bool = false,
                           declaration: Bool = true) throws -> [UInt8] {
        fatalError("unavailable")
    }
}
