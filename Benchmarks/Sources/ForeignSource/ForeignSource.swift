// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A driver, in a DIFFERENT MODULE from the schema it decodes.
//
// This is the only arrangement worth measuring, and it is not the one that is easy to
// measure. A benchmark that decodes a schema declared beside its call site is measuring
// specialisation that a real driver never gets: `reader.rows(as: User.self)` is generic
// over a type in someone else's module, `@inlinable` is forbidden on generated bodies
// (SE-0193), and the witness-table call therefore stands.
//
// The retired row-at-a-time path paid that call PER ROW and measured 1.6-4.7x for it. The
// batch entry point exists precisely so the call lands once per batch, and this module is
// how that claim gets checked rather than asserted.
//===----------------------------------------------------------------------===//

public import Assay

public func driverDecodeBatch<T: SourceDecodable, C: ColumnarSource & ~Copyable>(
    _ type: T.Type,
    from source: borrowing C
) -> [T] {
    var sink = IssueSink()
    return T._assayBatch(from: source, into: &sink, at: [])
}
