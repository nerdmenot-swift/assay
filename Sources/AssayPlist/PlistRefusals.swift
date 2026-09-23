// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// WHAT A MISSING `formats:` LOOKS LIKE, for property lists. See `YAMLRefusals.swift` for
// the mechanism and why it is shaped this way.
//
// Plist is the one door whose message cannot name a `SchemaFormats` case, because there is
// no `.plist`: a plist decodes through the `RawValue` projection, which any non-JSON format
// turns on. Saying "add `formats: .plist`" would be a fix that does not compile, so the
// message says what is actually true.
//===----------------------------------------------------------------------===//

import AssayCore
import Assay

extension Assayable {

    @available(
        *, unavailable,
        message:
            "this schema does not decode property lists. A plist decodes through the RawValue projection, so add a non-JSON format to its @Schema — `formats: .all` is the usual answer, and any of .yaml/.xml/.toml also enables it."
    )
    public static func parse(
        plist bytes: [UInt8], limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        fatalError("unavailable")
    }

    @available(
        *, unavailable,
        message:
            "this schema does not decode property lists. A plist decodes through the RawValue projection, so add a non-JSON format to its @Schema — `formats: .all` is the usual answer, and any of .yaml/.xml/.toml also enables it."
    )
    public static func diagnose(
        plist bytes: [UInt8], limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        fatalError("unavailable")
    }

    @available(
        *, unavailable,
        message:
            "this schema does not decode property lists. A plist decodes through the RawValue projection, so add a non-JSON format to its @Schema — `formats: .all` is the usual answer, and any of .yaml/.xml/.toml also enables it."
    )
    public static func parse(
        binaryPlist bytes: [UInt8], limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        fatalError("unavailable")
    }

    @available(
        *, unavailable,
        message:
            "this schema does not decode property lists. A plist decodes through the RawValue projection, so add a non-JSON format to its @Schema — `formats: .all` is the usual answer, and any of .yaml/.xml/.toml also enables it."
    )
    public static func diagnose(
        binaryPlist bytes: [UInt8], limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        fatalError("unavailable")
    }

    @available(
        *, unavailable,
        message:
            "this schema does not decode property lists. A plist decodes through the RawValue projection, so add a non-JSON format to its @Schema — `formats: .all` is the usual answer, and any of .yaml/.xml/.toml also enables it."
    )
    public static func parse(
        xmlPlist bytes: [UInt8], limits: Limits = .default,
        sourceName: String = "<input>"
    ) throws -> Self {
        fatalError("unavailable")
    }

    @available(
        *, unavailable,
        message:
            "this schema does not decode property lists. A plist decodes through the RawValue projection, so add a non-JSON format to its @Schema — `formats: .all` is the usual answer, and any of .yaml/.xml/.toml also enables it."
    )
    public static func diagnose(
        xmlPlist bytes: [UInt8], limits: Limits = .default,
        sourceName: String = "<input>"
    ) -> Diagnosis<Self> {
        fatalError("unavailable")
    }
}
