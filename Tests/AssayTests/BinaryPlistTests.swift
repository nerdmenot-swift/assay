// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The BINARY property-list flavour: a random-access object graph with two amplification
// attacks no existing limit covered (`docs/PLIST.md`), the differential against
// Foundation, and the count-overflow cases. Split out of PlistTests.swift on 2026-09-10;
// the hand-built bplist helpers live there and are shared.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore
import AssayPlist
import Foundation

@Suite("plists — the binary flavour")
struct BinaryPlistTests {

    /// `{"name": "server", "retry_count": 3, "enabled": true, "ratio": 0.5}` by hand.
    static func settingsDocument() -> [UInt8] {
        var b = BPlistBuilder()
        let kName = b.add(BPlistBuilder.asciiString("name"))
        let vName = b.add(BPlistBuilder.asciiString("server"))
        let kRetry = b.add(BPlistBuilder.asciiString("retry_count"))
        let vRetry = b.add(BPlistBuilder.int(3))
        let kEnabled = b.add(BPlistBuilder.asciiString("enabled"))
        let vEnabled = b.add([0x09])                              // true
        let kRatio = b.add(BPlistBuilder.asciiString("ratio"))
        let vRatio = b.add([0x23] + BPlistBuilder.beBytes(
            Int(bitPattern: UInt(Double(0.5).bitPattern)), 8))    // 8-byte real
        var dict: [UInt8] = [0xD4]
        for r in [kName, kRetry, kEnabled, kRatio] { dict.append(UInt8(r)) }
        for r in [vName, vRetry, vEnabled, vRatio] { dict.append(UInt8(r)) }
        let top = b.add(dict)
        return b.finish(top: top)
    }

    @Test("a binary plist decodes into a schema")
    func decodes() throws {
        let s = try PSettings.parse(plist: Self.settingsDocument())
        #expect(s == PSettings(name: "server", retryCount: 3, enabled: true, ratio: 0.5))
    }

    /// Not sniffing: `bplist00` is eight magic bytes at offset zero, and the caller already
    /// said the format is "property list". See `PlistEntry.swift`'s header.
    @Test("the encoding is discriminated by magic, exactly")
    func encodingDetection() {
        #expect(Plist.encoding(of: Self.settingsDocument()) == .binary)
        #expect(Plist.encoding(of: Array("<plist><dict/></plist>".utf8)) == .xml)
        #expect(Plist.encoding(of: []) == .xml)
    }

    @Test("parse(binaryPlist:) refuses an XML document")
    func binaryOnlyRefusesXML() {
        #expect(throws: (any Error).self) {
            try PSettings.parse(binaryPlist: Array("<plist><dict/></plist>".utf8))
        }
    }

    @Test("a truncated document is refused, not read past the end")
    func truncated() {
        let full = Self.settingsDocument()
        for cut in [8, 20, full.count - 33, full.count - 1] where cut > 0 && cut < full.count {
            var sink = IssueSink(limits: .default)
            _ = Plist.decode(Array(full[0..<cut]), into: &sink)
            #expect(!sink.isValid, "truncating to \(cut) bytes decoded successfully")
        }
    }

    @Test("a reference to an object that does not exist is refused")
    func badReference() {
        var b = BPlistBuilder()
        _ = b.add(BPlistBuilder.asciiString("x"))
        let top = b.add(BPlistBuilder.array([99]))
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b.finish(top: top), into: &sink) == nil)
        #expect(sink.issues.contains { $0.code == .plistBadReference })
    }

    @Test("a UTF-16 string decodes, and an unpaired surrogate does not")
    func utf16() {
        var b = BPlistBuilder()
        // "é€" as UTF-16BE.
        let top = b.add([0x62, 0x00, 0xE9, 0x20, 0xAC])
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b.finish(top: top), into: &sink) == .string("é€"))

        var c = BPlistBuilder()
        let bad = c.add([0x61, 0xD8, 0x00])          // a lone high surrogate
        var sink2 = IssueSink(limits: .default)
        #expect(Plist.decode(c.finish(top: bad), into: &sink2) == nil)
        #expect(sink2.issues.contains { $0.code == .plistBadString })
    }

    @Test("<data> becomes base64 in the binary flavour too, so the flavours agree")
    func dataAgrees() {
        var b = BPlistBuilder()
        let top = b.add([0x45] + Array("Hello".utf8))   // 5-byte data
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b.finish(top: top), into: &sink) == .string("SGVsbG8="))
    }

    /// The format stores seconds since 2001-01-01. It is handed over unconverted, because
    /// converting would mean choosing an epoch inside a Foundation-free core.
    @Test("a date is the stored double, unconverted")
    func date() {
        var b = BPlistBuilder()
        let top = b.add([0x33] + BPlistBuilder.beBytes(
            Int(bitPattern: UInt(Double(1.0).bitPattern)), 8))
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b.finish(top: top), into: &sink) == .double(1.0))
    }

    @Test("a non-string dictionary key is refused, as on the YAML path")
    func nonStringKey() {
        var b = BPlistBuilder()
        let k = b.add(BPlistBuilder.int(1))
        let v = b.add(BPlistBuilder.asciiString("x"))
        let top = b.add([0xD1, UInt8(k), UInt8(v)])
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b.finish(top: top), into: &sink) == nil)
        #expect(sink.issues.contains { $0.code == .plistUnrepresentableKey })
    }
}

/// A UID whose value does not fit `Int64`.
///
/// `Int64(readBE(…))` **trapped** until 2026-09-12 — a 50-byte file killed the process, in
/// release as well as debug. The fuzz arm could not reach it: it mutates documents
/// Foundation wrote, and Foundation only emits UIDs from `NSKeyedArchiver`, never with the
/// top bit set. Found by reading the arm beside the integer one, which handles the same
/// width correctly.
@Suite("plists — the UID arm")
struct PlistUIDTests {

    /// `87` is a UID marker with a low nibble of 7, so the width is 8 and every bit is set.
    static let hugeUID: [UInt8] = {
        var b: [UInt8] = Array("bplist00".utf8)
        let objOffset = b.count
        b.append(0x87)
        b.append(contentsOf: [UInt8](repeating: 0xFF, count: 8))
        let table = b.count
        b.append(UInt8(objOffset))
        b.append(contentsOf: [UInt8](repeating: 0, count: 6))
        b.append(1)                                   // offsetIntSize
        b.append(1)                                   // objectRefSize
        for v in [UInt64(1), UInt64(0), UInt64(table)] {
            withUnsafeBytes(of: v.bigEndian) { b.append(contentsOf: $0) }
        }
        return b
    }()

    @Test("a UID above Int64.max is refused, not a trap")
    func hugeUIDIsRefused() {
        #expect(Self.hugeUID.count == 50)
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(Self.hugeUID, into: &sink) == nil)
        #expect(sink.issues.contains { $0.code == .plistIntOutOfRange },
                "got \(sink.issues.map(\.code))")
    }

    @Test("a UID that does fit decodes as the integer it is")
    func smallUIDDecodes() {
        var b: [UInt8] = Array("bplist00".utf8)
        let objOffset = b.count
        b.append(0x81)                                // width 2
        b.append(contentsOf: [0x01, 0x2C])            // 300
        let table = b.count
        b.append(UInt8(objOffset))
        b.append(contentsOf: [UInt8](repeating: 0, count: 6))
        b.append(1); b.append(1)
        for v in [UInt64(1), UInt64(0), UInt64(table)] {
            withUnsafeBytes(of: v.bigEndian) { b.append(contentsOf: $0) }
        }
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b, into: &sink)?.int == 300)
        #expect(sink.isValid)
    }
}

@Suite("plists — amplification")
struct PlistAmplification {

    /// **A cycle is a well-formed graph.** There is no syntax that prevents it, so nothing but
    /// an explicit check does. Without one this test does not fail — it never returns.
    @Test(.timeLimit(.minutes(1)))
    func selfReferencingArray() {
        var b = BPlistBuilder()
        let top = b.add(BPlistBuilder.array([0]))    // object 0 is itself
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b.finish(top: top), into: &sink) == nil)
        #expect(sink.issues.contains { $0.code == .plistCycle })
    }

    @Test(.timeLimit(.minutes(1)))
    func mutuallyReferencingArrays() {
        var b = BPlistBuilder()
        _ = b.add(BPlistBuilder.array([1]))          // 0 -> 1
        _ = b.add(BPlistBuilder.array([0]))          // 1 -> 0
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b.finish(top: 0), into: &sink) == nil)
        #expect(sink.issues.contains { $0.code == .plistCycle })
    }

    /// **The billion-laughs shape, in plist.** Ten arrays, each holding many references to the
    /// one below. No cycle: every reference is to a distinct, real, forward object, and the
    /// DEPTH is ten — so `maxDepth` is not what stops this. Only the node budget is.
    @Test(.timeLimit(.minutes(1)))
    func sharedObjectAmplification() {
        var b = BPlistBuilder()
        _ = b.add(BPlistBuilder.asciiString("leaf"))          // object 0
        var previous = 0
        for _ in 0..<10 {
            let refs = Array(repeating: previous, count: 12)
            previous = b.add(BPlistBuilder.array(Array(refs.prefix(12))))
        }
        let doc = b.finish(top: previous)
        // 12^10 leaves from a document this size. If this returns a value, the budget is not
        // doing its job — and the assertion below is on the SIZE of the input for a reason.
        #expect(doc.count < 400, "the bomb must stay small, or it proves nothing")

        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(doc, into: &sink) == nil)
        #expect(sink.issues.contains { $0.code == .plistAmplification },
                "got \(sink.issues.map(\.code))")
    }

    /// An object referenced twice from two different branches is SHARED, not cyclic. A global
    /// "seen" set would reject this, which is why the check is a path set that pops.
    @Test
    func sharingIsNotACycle() {
        var b = BPlistBuilder()
        let leaf = b.add(BPlistBuilder.asciiString("x"))
        let a = b.add(BPlistBuilder.array([leaf]))
        let c = b.add(BPlistBuilder.array([leaf]))
        let top = b.add(BPlistBuilder.array([a, c]))
        var sink = IssueSink(limits: .default)
        let v = Plist.decode(b.finish(top: top), into: &sink)
        #expect(v == .sequence([.sequence([.string("x")]), .sequence([.string("x")])]),
                "a shared leaf must decode twice, not be refused")
    }

    @Test
    func deepNestingHitsMaxDepth() {
        var b = BPlistBuilder()
        _ = b.add(BPlistBuilder.asciiString("x"))
        var previous = 0
        for _ in 0..<200 { previous = b.add(BPlistBuilder.array([previous])) }
        var sink = IssueSink(limits: .default)
        // offsetSize 2: 200 objects run past byte 255, and a 1-byte offset table would
        // truncate them into a document that is malformed for the wrong reason.
        #expect(Plist.decode(b.finish(top: previous, offsetSize: 2), into: &sink) == nil)
        #expect(sink.issues.contains {
            $0.code == .plistTooDeep || $0.code == .plistAmplification
        })
    }

    @Test
    func trailerFieldsAreValidated() {
        var b = BPlistBuilder()
        let top = b.add(BPlistBuilder.asciiString("x"))
        var doc = b.finish(top: top)
        // An offsetIntSize of zero would make the offset table zero-length and every offset
        // read the same byte.
        doc[doc.count - 32 + 6] = 0
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(doc, into: &sink) == nil)
        #expect(sink.issues.contains { $0.code == .plistBadTrailer })
    }

    @Test
    func hugeObjectCountDoesNotOverflow() {
        var b = BPlistBuilder()
        let top = b.add(BPlistBuilder.asciiString("x"))
        var doc = b.finish(top: top)
        // numObjects = 2^62, which multiplied by offsetIntSize would wrap into a small,
        // passing product without the checked multiplication.
        let n = doc.count - 32 + 8
        for (i, byte) in BPlistBuilder.beBytes(1 << 62, 8).enumerated() { doc[n + i] = byte }
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(doc, into: &sink) == nil)
    }
}

#if canImport(Darwin)
@Suite("plists — differential against Foundation")
struct PlistDifferential {

    /// The same discipline the YAML and XML parsers are held to: an independent implementation
    /// adjudicates, rather than the tests agreeing with the code that produced them.
    static let documents: [String] = [
        "<plist version=\"1.0\"><dict><key>a</key><string>x</string></dict></plist>",
        "<plist version=\"1.0\"><dict><key>n</key><integer>-42</integer></dict></plist>",
        "<plist version=\"1.0\"><dict><key>r</key><real>1.5</real></dict></plist>",
        "<plist version=\"1.0\"><dict><key>t</key><true/><key>f</key><false/></dict></plist>",
        "<plist version=\"1.0\"><array><integer>1</integer><integer>2</integer></array></plist>",
        "<plist version=\"1.0\"><dict><key>e</key><dict/></dict></plist>",
        "<plist version=\"1.0\"><dict><key>a</key><array/></dict></plist>",
        "<plist version=\"1.0\"><dict><key>u</key><string>héllo €</string></dict></plist>",
    ]

    @Test("XML plists agree with PropertyListSerialization")
    func xmlAgrees() throws {
        var checked = 0
        for text in Self.documents {
            let bytes = Array(text.utf8)
            var sink = IssueSink(limits: .default)
            guard let ours = Plist.decode(bytes, into: &sink) else {
                Issue.record("we rejected a document Foundation accepts: \(text)")
                continue
            }
            let theirs = try PropertyListSerialization.propertyList(
                from: Data(bytes), format: nil)
            #expect(Self.matches(ours, theirs), "disagreed on \(text)")
            checked += 1
        }
        #expect(checked == Self.documents.count)
    }

    /// The binary flavour, through Foundation's own WRITER — which is the strongest form of
    /// this test available: the bytes are produced by the implementation being compared
    /// against, so nothing about our reader shaped the input.
    @Test("binary plists Foundation wrote decode to the same tree")
    func binaryAgrees() throws {
        let values: [Any] = [
            ["a": "x", "n": 42, "b": true] as [String: Any],
            ["list": [1, 2, 3]] as [String: Any],
            ["nested": ["inner": ["deep": "v"]]] as [String: Any],
            ["unicode": "héllo €", "empty": ""] as [String: Any],
            ["big": 9_223_372_036_854_775_807] as [String: Any],
            ["neg": -1, "zero": 0] as [String: Any],
            ["real": 0.5, "negreal": -1.25] as [String: Any],
        ]
        for v in values {
            let data = try PropertyListSerialization.data(
                fromPropertyList: v, format: .binary, options: 0)
            var sink = IssueSink(limits: .default)
            guard let ours = Plist.decode(Array(data), into: &sink) else {
                Issue.record("rejected a document Foundation wrote: \(v), \(sink.issues)")
                continue
            }
            #expect(Self.matches(ours, v), "disagreed on \(v)")
        }
    }

    /// Structural comparison. Deliberately does not compare NUMERIC TYPE across the boundary:
    /// Foundation hands back `NSNumber`, which does not distinguish an integer from a double
    /// the way `RawValue` does, so comparing the tags would test the bridge rather than the
    /// parser. Values are compared; representation is not.
    static func matches(_ ours: RawValue, _ theirs: Any) -> Bool {
        switch ours {
        case .null:
            return theirs is NSNull
        case .bool(let b):
            guard let n = theirs as? NSNumber else { return false }
            return n.boolValue == b
        case .int(let i):
            guard let n = theirs as? NSNumber else { return false }
            return n.int64Value == i
        case .double(let d):
            guard let n = theirs as? NSNumber else { return false }
            return n.doubleValue == d
        case .string(let s):
            if let t = theirs as? String { return t == s }
            // `<data>` comes back as `Data`; we render base64.
            if let d = theirs as? Data { return d.base64EncodedString() == s }
            return false
        case .sequence(let items):
            guard let a = theirs as? [Any], a.count == items.count else { return false }
            for (x, y) in zip(items, a) where !matches(x, y) { return false }
            return true
        case .mapping(let members):
            guard let d = theirs as? [String: Any], d.count == members.count else {
                return false
            }
            for m in members {
                guard let v = d[m.key], matches(m.value, v) else { return false }
            }
            return true
        }
    }
}
#endif

// MARK: - Integer overflow on attacker-controlled counts
//
// Found by reading the code rather than by the fuzzer, which is worth saying: the counts below
// need the 0xF "size follows in an integer object" escape carrying a value near `Int.max`, and
// random mutation reaches that combination essentially never. Every other bound in this reader
// was checked; these three multiplications were not, and in Swift an overflowing `*` traps.

@Suite("plists — count overflow")
struct PlistCountOverflow {

    /// Build an object whose 0xF-escaped element count is `count`, then a valid trailer.
    static func hugeCount(marker: UInt8, count: Int) -> [UInt8] {
        var obj: [UInt8] = [marker | 0x0F, 0x13]        // 0xF escape, then an 8-byte integer
        obj += BPlistBuilder.beBytes(count, 8)
        var b = BPlistBuilder()
        _ = b.add(obj)
        return b.finish(top: 0)
    }

    @Test("a UTF-16 string claiming Int.max code units does not trap")
    func utf16Count() {
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(Self.hugeCount(marker: 0x60, count: Int.max), into: &sink) == nil)
    }

    @Test("an array claiming Int.max elements does not trap")
    func arrayCount() {
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(Self.hugeCount(marker: 0xA0, count: Int.max), into: &sink) == nil)
    }

    @Test("a dictionary claiming Int.max pairs does not trap")
    func dictCount() {
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(Self.hugeCount(marker: 0xD0, count: Int.max), into: &sink) == nil)
    }

    /// Half of `Int.max` overflows only after the `* 2` for a dictionary's key+value refs,
    /// which is the arithmetic the array case does not have.
    @Test("a dictionary at half Int.max does not trap on the key/value doubling")
    func dictHalfCount() {
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(Self.hugeCount(marker: 0xD0, count: Int.max / 2),
                             into: &sink) == nil)
    }

    @Test("data claiming Int.max bytes does not trap")
    func dataCount() {
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(Self.hugeCount(marker: 0x40, count: Int.max), into: &sink) == nil)
    }
}
