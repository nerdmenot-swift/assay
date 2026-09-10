// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore

// EXPERIENCE.md §3: "Errors are the product. Everything else in this document is in
// service of this section." These tests hold the renderer to the worked examples.

@Schema
struct RenderTarget {
    var a: Int
    var port: Int
    var b: Int
}

@Schema(unknownKeys: .warn)
struct RenderWarnTarget {
    var timeout: Int
}

@Suite("Rendering")
struct RenderTests {

    // MARK: Golden output

    @Test("plain render matches the compiler-style format exactly")
    func golden() {
        let json = """
        {
        "a": 1,
        "port": "x",
        "b": 2
        }
        """
        let d = RenderTarget.diagnose(json: json, sourceName: "test.json")
        #expect(d.isValid == false)

        let expected = """
        test.json:3:9: error: port must be an integer, found "x"
          1 │ {
          2 │ "a": 1,
          3 │ "port": "x",
            │         ^
          4 │ "b": 2

        1 error

        """
        #expect(d.render(.plain) == expected)
    }

    @Test("multiple issues render ordered by position with a combined footer")
    func multiple() {
        let json = """
        {
        "b": "y",
        "a": "x",
        "port": 1
        }
        """
        let d = RenderTarget.diagnose(json: json, sourceName: "m.json")
        #expect(d.issues.count == 2)

        let out = d.render(.plain)
        // Position order, not collection order: line 2 ("b") before line 3 ("a").
        let bPos = out.range(of: "m.json:2:6")
        let aPos = out.range(of: "m.json:3:6")
        #expect(bPos != nil && aPos != nil)
        #expect(bPos!.lowerBound < aPos!.lowerBound)
        #expect(out.hasSuffix("2 errors\n\n") || out.contains("2 errors\n"))
    }

    @Test("issues without a location render without a snippet, not at all badly")
    func noLocation() {
        // The YAML path produces location-less issues today (node spans are a roadmap
        // item); the renderer must degrade to `name: error: ...` rather than crash or
        // print garbage.
        let d = RenderTarget.diagnose(json: "{}", sourceName: "empty.json")
        #expect(d.issues.count == 3)                     // three missing required fields
        let out = d.render(.plain)
        #expect(out.contains("empty.json: error: a is required"))
        #expect(out.contains("empty.json: error: port is required"))
        #expect(out.contains("3 errors"))
        #expect(!out.contains("│"))                       // no snippet without a span
    }

    @Test("warnings render as warnings, after errors, with did-you-mean inline")
    func warnings() {
        let d = RenderWarnTarget.diagnose(json: #"{"timeout":5,"tiemout":9}"#,
                                          sourceName: "w.json")
        #expect(d.isValid)
        let out = d.render(.plain)
        #expect(out.contains("warning:"))
        #expect(out.contains(#"unknown key "tiemout"; did you mean "timeout"?"#))
        #expect(out.contains("1 warning"))
        #expect(!out.contains("error:"))
    }

    @Test("terminal render without a TTY equals plain")
    func terminalNoTTY() {
        // The test runner's stdout is not a TTY, so .terminal must contain no ANSI.
        let d = RenderTarget.diagnose(json: "{}", sourceName: "t.json")
        #expect(d.render(.terminal) == d.render(.plain))
        #expect(!d.render(.terminal).contains("\u{1B}["))
    }

    @Test("AssayError renders with carets too — the thrown path keeps the source")
    func errorRender() {
        do {
            _ = try RenderTarget.parse(json: "{\n\"a\": true,\n\"port\": 1,\n\"b\": 2\n}",
                                       sourceName: "e.json")
            Issue.record("should have thrown")
        } catch let e as AssayError {
            let out = e.render(.plain)
            #expect(out.contains("e.json:2:6: error: a must be an integer, found true"))
            #expect(out.contains("│ \"a\": true,"))
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("CRLF documents do not render a stray carriage return")
    func crlf() {
        let json = "{\r\n\"a\": 1,\r\n\"port\": \"x\",\r\n\"b\": 2\r\n}"
        let d = RenderTarget.diagnose(json: json, sourceName: "crlf.json")
        let out = d.render(.plain)
        #expect(!out.contains("\r"))
        #expect(out.contains("│ \"port\": \"x\","))
    }

    // MARK: Machine formats

    @Test("json render is valid JSON with codes, params, and line/column — dogfooded")
    func jsonFormat() throws {
        let d = RenderTarget.diagnose(json: "{\n\"a\": 1,\n\"port\": \"x\",\n\"b\": 2\n}",
                                      sourceName: "j.json")
        // Parse it back with Assay's own document parser: the renderer's output must
        // survive the library's own strictness.
        let v = try JSON.Value.parse(d.render(.json))
        #expect(v["source"]?.string == "j.json")
        #expect(v["valid"]?.bool == false)
        let issue = v["issues"]?[0]
        #expect(issue?["code"]?.string == "type_mismatch")
        #expect(issue?["path"]?.string == "port")
        #expect(issue?["message"]?.string == "must be an integer, found \"x\"")
        #expect(issue?["params"]?["expected"]?.string == "integer")
        #expect(issue?["line"]?.int == 3)
        #expect(issue?["column"]?.int == 9)
        #expect(issue?["received"]?.string == "\"x\"")
    }

    @Test("problemDetails is RFC 9457 shaped")
    func problemDetails() throws {
        let d = RenderTarget.diagnose(json: "{}")
        let v = try JSON.Value.parse(d.render(.problemDetails))
        #expect(v["type"]?.string == "about:blank")
        #expect(v["title"]?.string == "Validation failed")
        #expect(v["status"]?.int == 422)
        #expect(v["errors"]?.array?.count == 3)
        #expect(v["errors"]?[0]?["code"]?.string == "missing")
        #expect(v["errors"]?[0]?["message"]?.string == "is required")
    }

    @Test("json render escapes what needs escaping")
    func jsonEscaping() throws {
        // A malformed document whose *content* would break naive JSON emission.
        let d = RenderTarget.diagnose(json: #"{"a": "quote\"and\nnewline"#,
                                      sourceName: "esc\"name.json")
        let v = try JSON.Value.parse(d.render(.json))
        #expect(v["source"]?.string == "esc\"name.json")
    }

    // MARK: Messages

    @Test("messages are derived from code+params, predicate-shaped")
    func messages() {
        #expect(Issue(code: .missing).message == "is required")
        #expect(Issue(code: .typeMismatch,
                      params: ["expected": .string("integer")],
                      received: "\"many\"").message
                == "must be an integer, found \"many\"")
        #expect(Issue(code: .typeMismatch,
                      params: ["expected": .string("string")],
                      received: "42").message
                == "must be a string, found 42")
        #expect(Issue(code: .depthExceeded, params: ["maxDepth": .int(64)]).message
                == "nesting exceeds the maximum depth of 64")
        #expect(Issue(code: .unknownKey,
                      params: ["didYouMean": .string("timeout")],
                      received: "tiemout").message
                == "unknown key \"tiemout\"; did you mean \"timeout\"?")
        // The one-off custom check: the string IS the message. EXPERIENCE.md §3.
        #expect(Issue(code: .custom("must be a company address")).message
                == "must be a company address")
        // Internal codes render as sentences, not identifiers.
        #expect(Issue(code: .yamlUndefinedAlias).message
                == "alias refers to an undefined anchor")
        // An explicit message param wins over everything.
        #expect(Issue(code: .tooSmall,
                      params: ["message": .string("way too short"),
                               "minimum": .int(12)]).message
                == "way too short")
    }

    @Test("code strings are stable — clients branch on these")
    func codeStrings() {
        #expect(IssueCode.missing.codeString == "missing")
        #expect(IssueCode.typeMismatch.codeString == "type_mismatch")
        #expect(IssueCode.invalidUTF8.codeString == "invalid_utf8")
        #expect(IssueCode.custom("company_domain").codeString == "company_domain")
    }
}

@Suite("Message coverage")
struct MessageCoverageTests {

    /// Every code the library can raise, read from the one file that names them all
    /// (`Sources/AssayCore/IssueCode+Names.swift`) rather than from a list kept by hand.
    /// The hand-kept list this replaced covered 55 of 85 codes and its "completeness" test
    /// checked only that the list agreed with itself.
    ///
    /// A code with no derived message renders as its own identifier —
    /// `yaml_unexpected_in_flow` instead of a sentence — which is a rendering bug that
    /// ships silently and reads as contempt for whoever hit it.
    static let allCustomCodes: [String] = {
        let names = #filePath.split(separator: "/").dropLast(3).joined(separator: "/")
            + "/Sources/AssayCore/IssueCode+Names.swift"
        guard let text = try? String(contentsOfFile: "/" + names, encoding: .utf8) else {
            return ["<could not read IssueCode+Names.swift>"]
        }
        var out: [String] = []
        for line in text.split(separator: "\n") {
            guard let open = line.range(of: "IssueCode.custom(\""),
                  let close = line[open.upperBound...].firstIndex(of: "\"") else { continue }
            out.append(String(line[open.upperBound..<close]))
        }
        return out
    }()

    @Test("the names file was found and is not tiny")
    func namesFileRead() {
        #expect(MessageCoverageTests.allCustomCodes.count >= 80,
                "got \(MessageCoverageTests.allCustomCodes.count)")
    }

    @Test("every named code derives a human sentence, not its own identifier",
          arguments: MessageCoverageTests.allCustomCodes)
    func codeHasMessage(_ code: String) {
        let issue = Issue(code: .custom(code), path: [])
        #expect(issue.message != code, "'\(code)' renders as its own identifier")
        #expect(issue.message.isEmpty == false)
    }

    /// The reverse direction: a `.custom("…")` raised anywhere in `Sources/` that has no
    /// name. Raise sites use the statics, so a literal outside the names file and the
    /// message table is a code nobody can match on by name.
    @Test("no raise site uses a string literal the names file does not know")
    func noAnonymousCodes() throws {
        let root = "/" + #filePath.split(separator: "/").dropLast(3).joined(separator: "/")
        let fm = FileManager.default
        var offenders: [String] = []
        let e = try #require(fm.enumerator(atPath: root + "/Sources"))
        for case let rel as String in e where rel.hasSuffix(".swift") {
            // The macro target emits SOURCE TEXT; its one `.custom("Instant")` is a
            // `ColumnMetadata` unit, not an issue code.
            if rel.hasSuffix("IssueCode+Names.swift") || rel.hasSuffix("Messages.swift")
                || rel.hasPrefix("AssayMacros/") { continue }
            let text = try String(contentsOfFile: root + "/Sources/" + rel, encoding: .utf8)
            var search = text[...]
            while let r = search.range(of: ".custom(\"") {
                let rest = search[r.upperBound...]
                if let q = rest.firstIndex(of: "\"") {
                    offenders.append("\(rel): \(rest[..<q])")
                }
                search = rest
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

// MARK: - Printing
//
// Added 2026-09-10. The audit's first finding: `print(error)` on the library whose headline
// is error reporting printed `AssayError(storage: Assay.AssayError.Storage)`, and
// `localizedDescription` printed "The operation couldn't be completed." These pin what a
// developer sees WITHOUT asking — interpolation, a failed `#expect`, a log line.

@Schema(encodes: true)
struct PrintTarget {
    var a: Int
    @Validate(.min(1)) var name: String
}

@Suite("Printing — what you see without asking")
struct PrintingTests {

    @Test("an AssayError interpolates as its plain render")
    func errorDescription() {
        do {
            _ = try PrintTarget.parse(json: #"{"a":"x","name":""}"#, sourceName: "t.json")
            Issue.record("expected a throw")
        } catch let e as AssayError {
            #expect("\(e)" == e.render(.plain))
            #expect("\(e)".contains("t.json:1:6: error: a must be an integer"))
            #expect(!"\(e)".contains("storage"))
            #expect(String(reflecting: e).hasPrefix("AssayError (2 issues in t.json)\n"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("an Issue prints as path and message, never its reflection")
    func issueDescription() {
        let d = PrintTarget.diagnose(json: #"{"a":"x","name":""}"#)
        #expect("\(d.issues[0])" == "a must be an integer, found \"x\"")
        #expect("\(d.issues[1])" == "name must be at least 1 character")
        let top = Issue(code: .malformedDocument)
        #expect("\(top)" == top.message)
    }

    @Test("a Warning prints the same way")
    func warningDescription() {
        let d = RenderWarnTarget.diagnose(json: #"{"timeout":1,"timeuot":2}"#)
        #expect(d.warnings.count == 1)
        #expect("\(d.warnings[0])" == d.warnings[0].message)
        #expect("\(d.warnings[0])".contains("did you mean \"timeout\""))
        #expect(!"\(d.warnings[0])".contains("IssueCode"))
    }

    @Test("a Diagnosis prints its render when invalid, one line when valid")
    func diagnosisDescription() {
        let bad = PrintTarget.diagnose(json: #"{"a":"x","name":""}"#)
        #expect("\(bad)" == bad.render(.plain))
        #expect(!"\(bad)".contains("SourceBytes"))
        let good = PrintTarget.diagnose(json: #"{"a":1,"name":"n"}"#)
        #expect("\(good)" == "valid PrintTarget")
        let warned = RenderWarnTarget.diagnose(json: #"{"timeout":1,"timeuot":2}"#)
        #expect("\(warned)" == "valid RenderWarnTarget (1 warning)")
    }

    @Test("an EncodeDiagnosis prints its render when invalid, one line when valid")
    func encodeDiagnosisDescription() {
        let good = PrintTarget(a: 1, name: "n").diagnoseEncodeJSON()
        #expect("\(good)" == "valid (\(good.bytes.count) bytes)")
    }
}
