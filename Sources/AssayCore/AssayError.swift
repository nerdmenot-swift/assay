// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The one thrown type, for every format and every entry point.
//
// In AssayCore rather than Assay since 2026-09-10, because the value-model parsers —
// `JSON.Value.parse`, `YAML.parse`, `XML.parse` — each threw a private twin of it
// (`JSONValueError`, `YAMLParseError`, `XMLParseError`: `public var issues: [Issue]` and
// nothing else). None carried the source, so none could render a caret; none printed as
// anything but a reflection dump. docs/ENCODING.md Q4's rule is one error vocabulary across
// every format; this is the type that rule names.
//===----------------------------------------------------------------------===//

/// The thrown type.
///
/// A struct wrapping a single class reference, so it stays **pointer-sized**. serde_json's
/// maintainers state plainly that "a larger Error type was substantially slower due to all
/// the functions that pass around Result<T, Error>", and moved to a boxed representation
/// for exactly that reason. A `throws` function returns its error in the callee-saved
/// `swifterror` register, which is why the happy path pays nothing — but only if the value
/// fits.
public struct AssayError: Error, Sendable {
    @usableFromInline final class Storage: @unchecked Sendable {
        let issues: [Issue]
        let source: SourceBytes
        let sourceName: String
        init(issues: [Issue], source: SourceBytes, sourceName: String) {
            self.issues = issues
            self.source = source
            self.sourceName = sourceName
        }
    }

    @usableFromInline let storage: Storage

    /// Public so out-of-module encoders (AssayYAML) can throw the same error type.
    /// docs/ENCODING.md question 4: one error vocabulary across every format.
    public init(issues: [Issue], source: SourceBytes, sourceName: String) {
        self.storage = Storage(issues: issues, source: source, sourceName: sourceName)
    }

    public var issues: [Issue] { storage.issues }
}

extension AssayError {

    /// Render every issue. The error retains the source, so carets work here too —
    /// `catch let e as AssayError { print(e.render(.plain)) }` needs nothing else.
    public func render(_ style: RenderStyle) -> String {
        Renderer.render(
            issues: storage.issues, warnings: [],
            source: storage.source, sourceName: storage.sourceName,
            style: style)
    }

    /// The document this error was raised against, for a caller that wants to render it
    /// differently or attach it to a report.
    public var sourceName: String { storage.sourceName }
}

// MARK: - Printing
//
// `print(error)`, `"\(error)"`, a failed `#expect(throws:)`, a `do/catch` that logs — every
// place a developer sees an error without asking for it. Until 2026-09-10 all of them showed
// `AssayError(storage: Assay.AssayError.Storage)`, which is the one output this library must
// never produce. `description` is the plain caret render; there is nothing to add to it.
//
// `LocalizedError` — what `error.localizedDescription` and every Apple-platform error
// surface reads — needs Foundation, so it lives in `AssayFoundation`.

extension AssayError: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { render(.plain) }
    public var debugDescription: String {
        "AssayError (\(issues.count) issue\(issues.count == 1 ? "" : "s") in "
            + "\(storage.sourceName))\n" + render(.plain)
    }
}
