// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Rewind — the invariant unions are built on, pinned before they are built.
//
// `ROADMAP.md` §5 says unions "force the one thing the decode body was designed never to do:
// **rewind**", and that both primitives already exist — `AssayReader.seek(to:)` and
// `IssueSink.rollback(to:)`. They do. What that sentence does not say is whether a *failed*
// decode leaves the reader in a state the next attempt can use, and an untagged union is
// exactly a sequence of failed decodes followed by one that works.
//
// Two pieces of state, and `seek` restores only one of them:
//
//   cursor   restored by `seek(to:)`
//   depth    NOT restored — `enterContainer` increments it and `leaveContainer` decrements it,
//            so a branch that bails out between the two leaves it inflated
//
// If generated bodies leak depth on their failure paths, then N failed branches cost N levels
// of the depth budget and a union near the limit would refuse a document it should accept —
// or, read the other way, an attacker could exhaust the budget with branches that fail
// cheaply. These tests establish which world we are in **before** any union code depends on
// it, rather than discovering it from a bug report about `maxDepth`.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore

@Schema struct RewindInner: Equatable { var a: Int; var b: Int }
@Schema struct RewindPair: Equatable { var x: RewindInner }

/// A second shape over the same bytes, which is what a union branch is.
@Schema struct RewindAlt: Equatable { var a: Int; var b: String }
@Schema struct RewindArray: Equatable { var xs: [Int] }

@Suite("rewind — the invariant unions need")
struct RewindTests {

    /// Run `body` against `text` with a fresh reader, the way a union's driver would.
    static func withReader<T>(
        _ text: String, limits: Limits = .default,
        _ body: (inout AssayReader, inout IssueSink) -> T
    ) -> T {
        let bytes = Array(text.utf8)
        var sink = IssueSink(limits: limits)
        return bytes.withUnsafeBufferPointer { buf in
            var reader = unsafe AssayReader(base: buf.baseAddress!, count: buf.count,
                                            limits: limits)
            return body(&reader, &sink)
        }
    }

    /// **The core union move.** Try a branch, fail, rewind, try another, succeed.
    @Test("a failed branch can be rewound and a second branch decodes")
    func rewindAfterFailure() {
        let ok = Self.withReader(#"{"a":1,"b":"text"}"#) { reader, sink in
            let start = reader.byteOffset
            let mark = sink.checkpoint()

            // Branch 1: wrong shape — `b` is a String, not an Int.
            let first = RewindInner._assay(from: &reader, into: &sink, at: [])
            #expect(first == nil, "branch 1 must fail on this document")
            #expect(sink.checkpoint() > mark, "and must have reported something")

            // Rewind both.
            reader.seek(to: start)
            sink.rollback(to: mark)
            #expect(sink.checkpoint() == mark, "the failed branch's issues are gone")

            // Branch 2: right shape.
            let second = RewindAlt._assay(from: &reader, into: &sink, at: [])
            return second
        }
        #expect(ok == RewindAlt(a: 1, b: "text"),
                "the second branch must decode as if the first had never run")
    }

    /// **The one `seek` does not cover.** Repeated failures must not consume the depth budget.
    ///
    /// Two documents in one buffer, because the point is ONE reader: attempts run against the
    /// invalid document at offset 0, then a well-formed decode runs against the valid one that
    /// follows. An earlier version of this test re-decoded the *same invalid* document at the
    /// end and reported a leak that was not there — the document was simply still invalid.
    @Test("repeated failed branches do not exhaust the depth budget")
    func failedBranchesDoNotLeakDepth() {
        var limits = Limits.default
        limits.maxDepth = 4

        let bad = #"{"x":{"a":1,"b":"text"}}"#
        let good = #"{"x":{"a":1,"b":2}}"#
        let ok = Self.withReader(bad + good, limits: limits) { reader, sink in
            let m = reader.mark
            let issueMark = sink.checkpoint()

            // Twenty failed attempts, each entering two containers before giving up. With a
            // depth budget of four, a leak of even one level per attempt exhausts it long
            // before the twentieth.
            for _ in 0..<20 {
                _ = RewindPair._assay(from: &reader, into: &sink, at: [])
                reader.restore(m)
                sink.rollback(to: issueMark)
            }

            // The valid document that follows, on the same reader.
            reader.seek(to: bad.utf8.count)
            return RewindPair._assay(from: &reader, into: &sink, at: [])
        }
        #expect(ok == RewindPair(x: RewindInner(a: 1, b: 2)), """
                twenty failed branches left the reader unusable. If `restore(_:)` is what \
                fixes this, `seek(to:)` alone is not enough for a union driver.
                """)
    }

    /// **The path that is NOT balanced.** A well-formed failure returns after `leaveContainer`
    /// and leaks nothing — which is why the test above passes with `seek(to:)` alone. A
    /// MALFORMED ARRAY does not: the generated arm reports and returns from inside the
    /// enclosing object, without unwinding it.
    ///
    /// This is the case that decides whether `restore(_:)` is real API or ceremony.
    @Test("a malformed array inside an object does not leak depth across attempts")
    func malformedArrayDoesNotLeakDepth() {
        var limits = Limits.default
        limits.maxDepth = 4

        let bad = #"{"xs":[1,2"#                      // never closed
        let good = #"{"xs":[1,2]}"#
        let ok = Self.withReader(bad + good, limits: limits) { reader, sink in
            let m = reader.mark
            let issueMark = sink.checkpoint()
            for _ in 0..<20 {
                _ = RewindArray._assay(from: &reader, into: &sink, at: [])
                reader.restore(m)
                sink.rollback(to: issueMark)
            }
            reader.seek(to: bad.utf8.count)
            return RewindArray._assay(from: &reader, into: &sink, at: [])
        }
        #expect(ok == RewindArray(xs: [1, 2]), """
                a malformed array left the enclosing object's container entered, and twenty \
                attempts exhausted the depth budget.
                """)
    }

    /// **The invariant at source, asserted with `seek` on purpose.** The test above uses
    /// `restore`, so it would pass whether or not the generated code balanced its own error
    /// paths. This one uses `seek(to:)` alone, so it fails the moment a generated failure path
    /// returns without unwinding a container it entered.
    ///
    /// That path existed: the arm for an unterminated array reported and returned from inside
    /// the enclosing object. It was fixed at source on 2026-09-09 — one `leaveContainer()` per
    /// array, dictionary and path-group error arm — rather than left for `restore` to paper
    /// over, because "nothing observes it today" is the reasoning that produced several of the
    /// other bugs found this week.
    @Test("generated failure paths balance their own containers")
    func generatedPathsAreBalanced() {
        var limits = Limits.default
        limits.maxDepth = 4

        let bad = #"{"xs":[1,2"#
        let good = #"{"xs":[1,2]}"#
        let ok = Self.withReader(bad + good, limits: limits) { reader, sink in
            let start = reader.byteOffset
            let issueMark = sink.checkpoint()
            for _ in 0..<20 {
                _ = RewindArray._assay(from: &reader, into: &sink, at: [])
                reader.seek(to: start)          // cursor only — no depth restore
                sink.rollback(to: issueMark)
            }
            reader.seek(to: bad.utf8.count)
            return RewindArray._assay(from: &reader, into: &sink, at: [])
        }
        #expect(ok == RewindArray(xs: [1, 2]), """
                a generated failure path entered a container and did not leave it. `restore` \
                hides this from unions; nothing hides it from anything else.
                """)
    }

    /// Rewinding must not resurrect issues from a branch that was abandoned. A union that
    /// reported every branch's failures alongside the winning branch's success would be the
    /// "did not match any of 3 variants" wall of noise a discriminator exists to prevent.
    @Test("rollback discards the abandoned branch's issues entirely")
    func rollbackIsComplete() {
        let count = Self.withReader(#"{"a":1,"b":"text"}"#) { reader, sink in
            let start = reader.byteOffset
            let mark = sink.checkpoint()
            for _ in 0..<5 {
                _ = RewindInner._assay(from: &reader, into: &sink, at: [])
                reader.seek(to: start)
                sink.rollback(to: mark)
            }
            _ = RewindAlt._assay(from: &reader, into: &sink, at: [])
            return sink.checkpoint()
        }
        #expect(count == 0, "five failed branches left \(count) issues behind")
    }

    /// The discriminated case needs a different move: scan ahead for the tag, then rewind to
    /// the start and decode the chosen branch in one pass. This is that move, without a macro.
    @Test("a tag can be found ahead of the cursor and the document then decoded from the start")
    func scanAheadThenRewind() {
        // The tag arrives LAST, which is the case that forces the scan.
        let text = #"{"a":1,"b":"text","type":"alt"}"#
        let found = Self.withReader(text) { reader, sink in
            let start = reader.byteOffset
            // A crude stand-in for the generated tag scan: skip the value, then look at the
            // bytes. What matters here is only that seeking back afterwards works.
            _ = reader.skipValue(&sink)
            let afterSkip = reader.byteOffset
            reader.seek(to: start)
            let v = RewindAlt._assay(from: &reader, into: &sink, at: [])
            return (afterSkip > start, v)
        }
        #expect(found.0, "the pre-scan must actually advance")
        #expect(found.1 == RewindAlt(a: 1, b: "text"),
                "and the decode must then see the whole document from the start")
    }
}
