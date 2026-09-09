// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Discriminated unions — the tag pre-scan. `docs/UNIONS.md`, `EXPERIENCE.md` §9.
//
// `{"a": 1, "type": "click"}` is a legal document, so the branch cannot be chosen by reading
// forward: the tag may arrive last. This is the one place in the library that looks ahead and
// then rewinds, and `docs/UNIONS.md` §1 is why that is acceptable here and nowhere else.
//
// WHAT IT COSTS, stated because "it rewinds" sounds worse than it is. The pre-scan reads KEYS
// and skips VALUES — `skipValue` is the same structural skip an unknown key already uses, and
// it does not build anything. So a union pays one extra pass over the object's *keys*, not
// over its contents, and it stops at the tag rather than at the closing brace. On the common
// shape, where the tag is written first, it stops immediately.
//
// The alternative — decode to `RawValue`, look at the tag, then decode the branch from the
// tree — costs a whole materialised tree per union value and loses the byte offsets the
// carets need. That is the design this one is chosen over.
//===----------------------------------------------------------------------===//

extension AssayReader {

    /// Find `key`'s string value in the object at the cursor, leaving the reader wherever the
    /// scan finished — the caller restores.
    ///
    /// Returns nil having reported, for the three failures that are the union's rather than a
    /// branch's: the value is not an object, the tag is absent, the tag is not a string.
    ///
    /// **Depth is charged and released here**, so a document that nests unions to exhaustion
    /// is refused by `maxDepth` during the scan rather than during the branch decode, where
    /// the error would name the branch and mislead.
    @inlinable
    public mutating func scanDiscriminator(
        _ sink: inout IssueSink, _ key: StaticString, _ path: [PathComponent]
    ) -> String? {
        guard tryConsume(0x7B) else {
            reportTypeMismatch(&sink, path, expected: "object")
            return nil
        }
        guard enterContainer(&sink) else { return nil }
        defer { leaveContainer() }

        if tryConsume(0x7D) {
            missingRequired(&sink, path, key)
            return nil
        }
        while true {
            guard let k = scanKey(), expect(0x3A) else {
                reportMalformed(&sink, path)
                return nil
            }
            if keyMatches(k, key) {
                guard let tag = scanString() else {
                    // The tag exists and is not a string. Its own failure, not a branch's:
                    // no branch could have been chosen, so none should be blamed.
                    sink.add(Issue(
                        code: .typeMismatch,
                        path: path + [.key(String(describing: key))],
                        params: ["expected": .string("string")],
                        location: SourceSpan(lo: byteOffset, len: 1)))
                    return nil
                }
                return tag
            }
            guard skipValue(&sink) else { return nil }
            if tryConsume(0x2C) { continue }
            break
        }
        // Ran off the end of the object without finding it.
        missingRequired(&sink, path, key)
        return nil
    }

    /// The variant name was read but matches nothing the enum declares.
    ///
    /// Carries did-you-mean, from the same Damerau machinery unknown keys use — a tag that is
    /// `"pageview"` where the schema says `"page_view"` is the overwhelmingly common way this
    /// fails, and answering it with a bare list is a worse error than answering it with a
    /// suggestion.
    @inline(never)
    public mutating func unknownVariant(
        _ sink: inout IssueSink, _ path: [PathComponent],
        _ key: StaticString, _ received: String, _ known: [String]
    ) {
        var params: [String: IssueValue] = [
            "discriminator": .string(String(describing: key)),
            "known": .string(known.joined(separator: ", ")),
        ]
        // The same Damerau helper unknown keys use, and the same `didYouMean` param name, so
        // the renderers and any consumer matching on params need no new case.
        if let suggestion = Self.didYouMean(received, in: known) {
            params["didYouMean"] = .string(suggestion)
        }
        sink.add(Issue(
            code: .custom("union_unknown_variant"),
            path: path + [.key(String(describing: key))],
            params: params,
            received: received))
    }
}
