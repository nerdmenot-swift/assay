//===----------------------------------------------------------------------===//
// @Preprocess ops. EXPERIENCE.md §11: preprocess runs on the raw value BEFORE rules, and
// its job is normalising input; @Transform runs AFTER validation and changes the type.
// The distinction is which side of validation they sit on, and the order is fixed:
// preprocess → coerce → decode → field rules → cross-field checks → transform.
//
// Everything here is locale-free byte manipulation, for the standard reason: a struct
// must mean the same thing on Linux and on a Mac.
//===----------------------------------------------------------------------===//

/// A normalisation applied to a string field before its rules run.
public enum PreprocessOp: Sendable {
    /// Strip leading and trailing ASCII whitespace.
    case trim
    /// ASCII lowercase. Deliberately not Unicode case folding — that is locale-adjacent
    /// territory, and an email or slug field wants exactly this.
    case lowercase
    /// ASCII uppercase.
    case uppercase
    /// Collapse internal runs of whitespace to single spaces (implies nothing else).
    case collapseWhitespace
}

@inlinable
public func _assayPreprocess(_ value: String, _ ops: [PreprocessOp]) -> String {
    var v = value
    for op in ops {
        switch op {
        case .trim:
            var bytes = Array(v.utf8)
            while let f = bytes.first, f == 0x20 || f == 0x09 || f == 0x0A || f == 0x0D {
                bytes.removeFirst()
            }
            while let l = bytes.last, l == 0x20 || l == 0x09 || l == 0x0A || l == 0x0D {
                bytes.removeLast()
            }
            v = String(decoding: bytes, as: UTF8.self)
        case .lowercase:
            v = String(decoding: v.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 },
                       as: UTF8.self)
        case .uppercase:
            v = String(decoding: v.utf8.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 32 : $0 },
                       as: UTF8.self)
        case .collapseWhitespace:
            var out: [UInt8] = []
            out.reserveCapacity(v.utf8.count)
            var inRun = false
            for b in v.utf8 {
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    if !inRun { out.append(0x20) }
                    inRun = true
                } else {
                    out.append(b)
                    inRun = false
                }
            }
            v = String(decoding: out, as: UTF8.self)
        }
    }
    return v
}
