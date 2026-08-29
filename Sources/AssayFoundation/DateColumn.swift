// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `Date` out of a column store. docs/COLUMN-DECODABLE.md.
//
// WHY THIS IS HERE AND NOT IN AssayCore. The core is Foundation-free by design, and the
// `Date` architecture already turns on that: the parsers in `Dates.swift` return epoch
// seconds and the macro emits `Date(timeIntervalSince1970:)` into the USER's module, so
// `Date` never appears in a core signature. A conformance in the core would drag Foundation
// into it for one type.
//
// WHY `Date` IS NOT A NATIVE COLUMNAR TYPE, WHICH IS THE ERGONOMIC PULL TO RESIST. Adding
// `case "Date": return "int64Column"` to the macro would be shorter than this file and
// wrong: it would have to pick a unit at compile time, and a column's unit is DATA -- two
// parquet files with the same logical schema may declare micros and nanos. Going through
// `ColumnDecodable` is what lets `ColumnMetadata.unit` decide per column, at the source.
//
// The tree path is a DIFFERENT problem and keeps its own answer. There the wire form is
// text, which is why `@DateFormat`, the hand-written ISO-8601 parser and the candidate
// chains exist. Here the source hands over a number whose unit only the source knows. The
// asymmetry is real; it is not an inconsistency.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

// No `@retroactive`, and the compiler is explicit about why: "'retroactive' attribute does
// not apply; 'ColumnDecodable' is declared in the same package". SE-0364's check is
// same-PACKAGE, not same-module -- so conforming a Foundation type to an Assay protocol
// from another Assay target is a first-party conformance and warns about nothing.
extension Date: ColumnDecodable {

    /// `Int64` and not `Double`, because that is what column stores actually hold: Arrow's
    /// TIMESTAMP is int64, Parquet's is INT64 with a logical unit, Postgres and DuckDB are
    /// int64 microseconds. It is also the only carrier that survives nanoseconds -- a
    /// `Double` holds 2^53 of them, about 104 days.
    public typealias Column = ColumnBuffer<Int64>

    /// `metadata.unit` is a power-of-ten exponent: 0 seconds, -3 milli, -6 micro, -9 nano.
    /// A source that declares anything else gets `nil` for the row rather than a guess.
    public init?(assayColumn c: borrowing ColumnBuffer<Int64>,
                 row: Int, metadata m: ColumnMetadata) {
        let divisor: Int64
        switch m.unit {
        case 0:  divisor = 1
        case -3: divisor = 1_000
        case -6: divisor = 1_000_000
        case -9: divisor = 1_000_000_000
        default: return nil
        }
        // Split before converting, and NOT for tidiness. `Double(1_700_000_000_000_000_000)`
        // -- a plausible nanosecond instant -- needs 61 bits of significand and Double has
        // 53, so scaling after the conversion throws away hundreds of nanoseconds before
        // the multiply even happens. Dividing first keeps the seconds exact (1.7e9 is well
        // inside 2^53) and spends the rounding only on the fraction, which is where Date's
        // own representation runs out anyway.
        let (seconds, fraction) = c[row].quotientAndRemainder(dividingBy: divisor)
        self = Date(timeIntervalSince1970:
                        Double(seconds) + Double(fraction) / Double(divisor))
    }
}

// NO conformance for a floating-seconds column, deliberately. `Column` is one type per
// conforming type, and a source cannot change it -- so `Date` has to pick, and int64 is
// what the formats in question store. A source whose timestamps really are `Double` seconds
// declares its own wrapper with `Column = ColumnBuffer<Double>`, which is a five-line type
// and exactly what the extension point is for.
//
// A TEXT date column is the same answer for a stronger reason: choosing among ISO-8601,
// RFC 9110, a pattern and a candidate chain is precisely what `@DateFormat` does, and a bare
// conformance has nowhere to put that choice.
