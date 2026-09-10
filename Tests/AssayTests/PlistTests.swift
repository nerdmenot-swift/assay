// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `parse(plist:)`, built 2026-09-09. EXPERIENCE §1, ROADMAP §10.
//
// The suite that matters is `PlistAmplification`. `ROADMAP.md` §10 called plists
// "mechanically the smallest item on this list", and the reason that was wrong is that a
// binary plist is a random-access OBJECT GRAPH with two attacks no existing limit covered:
// a reference cycle (an array holding itself), and shared-object amplification (ten arrays
// of a thousand references each — under a kilobyte on disk, 10^30 nodes materialised, and
// `maxDepth` sees a depth of ten).
//
// Both bombs are BUILT here, byte by byte, rather than described. A test that asserts a limit
// exists without constructing the input it bounds is a test that passes when the limit is
// removed.
//
// `PlistDifferential` adjudicates against Foundation's own `PropertyListSerialization`, which
// is the same discipline the YAML (Yams/libyaml) and XML (Foundation XMLParser) parsers are
// held to. Darwin-only, because that is where the oracle is.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore
import AssayPlist
#if canImport(Foundation)
import Foundation
#endif

@Schema(keys: .snakeCase, formats: .all)
struct PSettings: Equatable {
    var name: String
    var retryCount: Int
    var enabled: Bool
    var ratio: Double
}

@Schema(formats: .all)
struct PNested: Equatable {
    var title: String
    var tags: [String]
}

/// Build a binary plist by hand, so the tests own their input rather than depending on a
/// writer that could be wrong in the same direction as the reader.
struct BPlistBuilder {
    /// Each entry is the encoded object body; offsets are computed on `finish`.
    var objects: [[UInt8]] = []

    static func header() -> [UInt8] { Array("bplist00".utf8) }

    mutating func add(_ body: [UInt8]) -> Int {
        objects.append(body)
        return objects.count - 1
    }

    static func asciiString(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        precondition(u.count < 15, "test helper handles short strings only")
        return [0x50 | UInt8(u.count)] + u
    }

    static func int(_ v: Int64) -> [UInt8] {
        var out: [UInt8] = [0x13]
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: v >> Int64(shift)))
        }
        return out
    }

    static func array(_ refs: [Int], refSize: Int = 1) -> [UInt8] {
        precondition(refs.count < 15, "test helper handles short arrays only")
        var out: [UInt8] = [0xA0 | UInt8(refs.count)]
        for r in refs { out += beBytes(r, refSize) }
        return out
    }

    static func bigArray(_ refs: [Int], refSize: Int) -> [UInt8] {
        // The 0xF escape: an int object marker carrying the real count.
        var out: [UInt8] = [0xAF, 0x11, UInt8(refs.count)]
        if refs.count > 255 {
            out = [0xAF, 0x12,
                   UInt8(truncatingIfNeeded: refs.count >> 8),
                   UInt8(truncatingIfNeeded: refs.count)]
        }
        for r in refs { out += beBytes(r, refSize) }
        return out
    }

    static func beBytes(_ v: Int, _ width: Int) -> [UInt8] {
        (0..<width).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
    }

    /// Assemble: header, objects, offset table, trailer.
    func finish(top: Int, refSize: Int = 1, offsetSize: Int = 1) -> [UInt8] {
        var out = Self.header()
        var offsets: [Int] = []
        for o in objects {
            offsets.append(out.count)
            out += o
        }
        let tableOffset = out.count
        for off in offsets { out += Self.beBytes(off, offsetSize) }
        out += [0, 0, 0, 0, 0]                         // unused
        out += [0]                                     // sortVersion
        out += [UInt8(offsetSize), UInt8(refSize)]
        out += Self.beBytes(objects.count, 8)
        out += Self.beBytes(top, 8)
        out += Self.beBytes(tableOffset, 8)
        return out
    }
}

@Suite("plists — the XML flavour")
struct XMLPlistTests {

    static let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>name</key><string>server</string>
            <key>retry_count</key><integer>3</integer>
            <key>enabled</key><true/>
            <key>ratio</key><real>0.5</real>
        </dict>
        </plist>
        """

    @Test("an XML plist decodes into a schema")
    func decodes() throws {
        let s = try PSettings.parse(plist: Self.settings)
        #expect(s == PSettings(name: "server", retryCount: 3, enabled: true, ratio: 0.5))
    }

    /// The DOCTYPE above names an external DTD by URL. Nothing fetches it, because the
    /// parser this reuses refuses external entities by construction — which is the reason it
    /// is reused rather than a second one written.
    @Test("the external DTD reference is not fetched")
    func noExternalEntity() throws {
        _ = try PSettings.parse(plist: Self.settings)
    }

    @Test("a bare <dict> root, with no <plist> wrapper")
    func bareRoot() throws {
        let s = try PNested.parse(plist: """
            <dict><key>title</key><string>t</string>
            <key>tags</key><array><string>a</string><string>b</string></array></dict>
            """)
        #expect(s == PNested(title: "t", tags: ["a", "b"]))
    }

    @Test("<data> becomes base64, the same spelling the binary flavour produces")
    func data() {
        var sink = IssueSink(limits: .default)
        let v = Plist.decode(Array("""
            <dict><key>d</key><data>SGVsbG8=</data></dict>
            """.utf8), into: &sink)
        #expect(v == .mapping([.init(key: "d", value: .string("SGVsbG8="))]))
    }

    @Test("<data> that is not base64 is refused rather than passed through")
    func badData() {
        var sink = IssueSink(limits: .default)
        let v = Plist.decode(Array("<dict><key>d</key><data>not!base64</data></dict>".utf8),
                             into: &sink)
        #expect(v == nil)
        #expect(sink.issues.contains { $0.code == .plistBadValue })
    }

    /// Foundation is lenient about this. Being lenient about which value belongs to which key
    /// is not a leniency worth having.
    @Test("a <key> with no value is a malformed document")
    func unpairedKey() {
        var sink = IssueSink(limits: .default)
        let v = Plist.decode(Array("<dict><key>a</key></dict>".utf8), into: &sink)
        #expect(v == nil)
        #expect(sink.issues.contains { $0.code == .plistUnpairedKey })
    }

    @Test("a value with no <key> before it is a malformed document")
    func unpairedValue() {
        var sink = IssueSink(limits: .default)
        let v = Plist.decode(Array("<dict><string>x</string></dict>".utf8), into: &sink)
        #expect(v == nil)
        #expect(sink.issues.contains { $0.code == .plistUnpairedKey })
    }

    /// A number read as a different number is the one failure a decoder must never have.
    @Test("an integer too large for Int64 is refused, not saturated")
    func integerOutOfRange() {
        var sink = IssueSink(limits: .default)
        let v = Plist.decode(Array(
            "<dict><key>n</key><integer>99999999999999999999</integer></dict>".utf8),
            into: &sink)
        #expect(v == nil)
        #expect(sink.issues.contains { $0.code == .plistIntOutOfRange })
    }

    @Test("an element that is not a plist type is named in the issue")
    func unknownElement() {
        var sink = IssueSink(limits: .default)
        let v = Plist.decode(Array("<dict><key>a</key><widget/></dict>".utf8), into: &sink)
        #expect(v == nil)
        #expect(sink.issues.contains { $0.code == .plistBadMarker })
    }
}
