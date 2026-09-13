// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// WHAT A MISSING CAPABILITY LOOKS LIKE — the doors that live in this module.
//
// Every one of these used to report a conformance failure naming a protocol the reader
// never wrote and has no reason to know:
//
//     referencing instance method 'encodedJSON(pretty:)' on 'JSONEncodableSchema'
//     requires that 'Article' conform to 'JSONEncodableSchema'
//
// `@XML(root:)`'s refusal has said "Add `formats: .xml` (or `.all`)" since it shipped, and
// that is the standard these should meet: name the attribute argument to add.
//
// The mechanism is the one in `AssayYAML/YAMLRefusals.swift`: the real member lives on the
// capability protocol, this one lives on `Assayable` — which every schema conforms to,
// `ContextualAssayable` included — and is `unavailable`. A type that HAS the capability
// resolves to the real member because the more constrained extension wins; a type that does
// not gets this sentence. Both directions are compiled in the test suite.
//===----------------------------------------------------------------------===//

import AssayCore

extension Assayable {


    @available(*, unavailable, message: "this schema does not encode. Add `encodes: true` to its @Schema, e.g. @Schema(encodes: true).")
    public func encodedJSON(pretty: Bool = false) throws -> [UInt8] {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "this schema does not describe itself. Add `describes: true` to its @Schema, e.g. @Schema(describes: true).")
    public static func jsonSchema(for face: SchemaFace = .input) -> JSONSchemaValue {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "this schema does not describe itself. Add `describes: true` to its @Schema, e.g. @Schema(describes: true).")
    public static func jsonSchemaText(for face: SchemaFace = .input) -> String {
        fatalError("unavailable")
    }

    // `parse(body:)` is the one refusal here that is NOT about a missing attribute argument,
    // and the message has to say so. Negotiation picks a parser at RUNTIME from `accepting:`,
    // so the door requires the `RawValue` projection whatever list you pass — a JSON-only
    // schema cannot use it even with `accepting: [.json]`. That is a real constraint rather
    // than an oversight (the compiler cannot see that a runtime array holds only `.json`),
    // and it was undocumented until 2026-09-13.
    @available(*, unavailable, message: "content negotiation chooses a parser at run time, so this door needs the RawValue projection even for `accepting: [.json]`. Add a non-JSON format to its @Schema — `formats: .all` is the usual answer.")
    public static func parse(body bytes: [UInt8], contentType: String?,
                             accepting: [WireFormat], limits: Limits = .default,
                             sourceName: String = "<body>") throws -> Self {
        fatalError("unavailable")
    }

    @available(*, unavailable, message: "content negotiation chooses a parser at run time, so this door needs the RawValue projection even for `accepting: [.json]`. Add a non-JSON format to its @Schema — `formats: .all` is the usual answer.")
    public static func diagnose(body bytes: [UInt8], contentType: String?,
                                accepting: [WireFormat], limits: Limits = .default,
                                sourceName: String = "<body>") -> Diagnosis<Self> {
        fatalError("unavailable")
    }
}
