//===----------------------------------------------------------------------===//
// Enums are free. docs/EXPERIENCE.md §8:
//
//     enum Priority: String, JSONAssayable { case low, medium, high }
//
// Conformance is the entire implementation — any RawRepresentable enum with a String or
// Int raw value gets its schema for nothing. Invalid values produce a real suggestion
// rather than "cannot initialize":
//
//     error: priority must be one of "low", "medium", "high", found "urgent"
//
// The richer message needs the case list, so it lives in the CaseIterable-constrained
// extensions; at a concrete conformance the more-constrained extension wins. Both decode
// paths (bytes and RawValue) are covered, so an enum works from JSON, YAML and XML alike.
//===----------------------------------------------------------------------===//

public import AssayCore

// MARK: - String raw values

extension JSONAssayable where Self: RawRepresentable, RawValue == String {
    public static func _assay(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self? {
        reader.beginValue()
        guard let s = reader.scanString() else {
            reader.reportTypeMismatch(&sink, path, expected: "string")
            return nil
        }
        guard let v = Self(rawValue: s) else {
            unknownVariant(&sink, path, received: s, options: nil,
                           span: reader.lastValueSpan)
            return nil
        }
        return v
    }
}

extension JSONAssayable where Self: RawRepresentable & CaseIterable, RawValue == String {
    public static func _assay(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self? {
        reader.beginValue()
        guard let s = reader.scanString() else {
            reader.reportTypeMismatch(&sink, path, expected: "string")
            return nil
        }
        guard let v = Self(rawValue: s) else {
            unknownVariant(&sink, path, received: s,
                           options: allCases.map(\.rawValue),
                           span: reader.lastValueSpan)
            return nil
        }
        return v
    }
}

extension RawDecodable where Self: RawRepresentable, RawValue == String {
    public static func _assay(
        from raw: AssayCore.RawValue,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self? {
        guard case .string(let s) = raw else {
            AssayCore.RawValue.mismatchAt(&sink, path, "string", raw)
            return nil
        }
        guard let v = Self(rawValue: s) else {
            unknownVariant(&sink, path, received: s, options: nil, span: nil)
            return nil
        }
        return v
    }
}

extension RawDecodable where Self: RawRepresentable & CaseIterable, RawValue == String {
    public static func _assay(
        from raw: AssayCore.RawValue,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self? {
        guard case .string(let s) = raw else {
            AssayCore.RawValue.mismatchAt(&sink, path, "string", raw)
            return nil
        }
        guard let v = Self(rawValue: s) else {
            unknownVariant(&sink, path, received: s,
                           options: allCases.map(\.rawValue), span: nil)
            return nil
        }
        return v
    }
}

// MARK: - Int raw values

extension JSONAssayable where Self: RawRepresentable, RawValue == Int {
    public static func _assay(
        from reader: inout AssayReader,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self? {
        reader.beginValue()
        guard let i = reader.scanInt64(), let n = Int(exactly: i) else {
            reader.reportTypeMismatch(&sink, path, expected: "integer")
            return nil
        }
        guard let v = Self(rawValue: n) else {
            unknownVariant(&sink, path, received: String(n), options: nil,
                           span: reader.lastValueSpan)
            return nil
        }
        return v
    }
}

extension RawDecodable where Self: RawRepresentable, RawValue == Int {
    public static func _assay(
        from raw: AssayCore.RawValue,
        into sink: inout IssueSink,
        at path: [PathComponent]
    ) -> Self? {
        guard case .int(let i) = raw, let n = Int(exactly: i) else {
            AssayCore.RawValue.mismatchAt(&sink, path, "integer", raw)
            return nil
        }
        guard let v = Self(rawValue: n) else {
            unknownVariant(&sink, path, received: String(n), options: nil, span: nil)
            return nil
        }
        return v
    }
}

/// Cold. The `unknown_variant` issue, with the case list and a did-you-mean when one is
/// close — the same bounded edit distance the unknown-key path uses.
@inline(never)
private func unknownVariant(
    _ sink: inout IssueSink,
    _ path: [PathComponent],
    received: String,
    options: [String]?,
    span: SourceSpan?
) {
    var params: [String: IssueValue] = [:]
    if let options {
        params["options"] = .string(options.map { "\"\($0)\"" }.joined(separator: ", "))
        if let hint = AssayReader.didYouMean(received, in: options) {
            params["didYouMean"] = .string(hint)
        }
    }
    sink.add(Issue(
        code: .custom("unknown_variant"),
        path: path,
        params: params,
        received: received,
        location: span))
}
