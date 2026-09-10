// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The public surface.
//
// "Assay is not a validation library that also decodes. It is the decoder that tells you
// what went wrong." Zero-rule @Schema is a first-class mode, not an on-ramp.
//===----------------------------------------------------------------------===//

@_exported import AssayCore

// The module's surface is split by kind:
//
//   Protocols.swift    — what `@Schema` conforms a type to
//   Macros.swift       — every attached macro and its documentation
//   Options.swift      — `SchemaFormats`, `UnknownKeys`, `Discriminator`, `KeyNamingStyle`, `XMLPlacement`
//   Entry.swift        — `parse` / `diagnose`, `Diagnosis`, `AssayError`, encoding entry points
//   AsyncEntry.swift   — the async pair for types with `@AsyncCheck`
//   ContextEntry.swift — the contextual pair
//   Validate.swift     — `T.validate(_:)` on a value something else produced (the rule
//                        engine itself is AssayCore/Rules.swift)
//   Enums.swift        — `RawRepresentable` enums for free
//   Negotiate.swift    — `parse(body:contentType:accepting:)`
//   Assayer*.swift     — the runtime schema value
