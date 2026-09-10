// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `LocalizedError` for `AssayError`, so `error.localizedDescription` — what an alert, a
// `Result` log line and every Apple-platform error surface reads — shows the rendered
// issues rather than "The operation couldn’t be completed. (Assay.AssayError error 1.)".
//
// Here and not in `Assay` because `LocalizedError` is Foundation, and the core is not.
// `CustomStringConvertible` (Foundation-free) lives beside the type; this is the bridge.
//===----------------------------------------------------------------------===//

import Foundation
public import Assay

extension AssayError: LocalizedError {
    public var errorDescription: String? { render(.plain) }
}
