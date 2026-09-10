// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Documents for the YAML and XML oracles.
//
// Two sources, deliberately:
//
//   HAND-WRITTEN cases, one per feature, named after what they exercise. These are chosen
//   adversarially — the things a subset parser gets wrong — and a failure names its own
//   cause. Generated volume finds a disagreement; a named case tells you which feature.
//
//   GENERATED volume, by re-rendering the existing JSON corpus into block-style YAML and
//   into XML. The renderer only has to emit VALID documents, not semantically intended
//   ones: the oracles compare Assay against libyaml and libxml2 on whatever the text
//   actually says, so a renderer bug produces a document both sides read the same way and
//   the comparison stays honest. That is what makes generating input this cheaply sound.
//===----------------------------------------------------------------------===//

import Foundation
import AssayCore
import CorpusRender

// MARK: - YAML, hand-written

let handWrittenYAML: [(name: String, text: String)] = [
    ("block-mapping", "a: 1\nb: two\nc: true\n"),
    ("block-sequence", "- 1\n- 2\n- three\n"),
    ("nested-block", "root:\n  child:\n    leaf: value\n  list:\n    - a\n    - b\n"),
    ("flow-in-block", "a: [1, 2, 3]\nb: {x: 1, y: 2}\n"),
    ("empty-values", "a:\nb: ~\nc: null\nd: \"\"\n"),

    // Multi-line plain scalars — YAML 1.2 §7.3.3. A line break inside one folds to a
    // single space and a blank line becomes a newline, which is fiddly enough that the
    // parser refused them outright until 2026-08-14. The last two are NOT valid YAML: a
    // plain scalar cannot be followed by a more-indented sequence entry or mapping key,
    // and libyaml is the arbiter of that rather than this parser's opinion.
    ("plain-multiline", "a: one\n  two\nb: 3\n"),
    ("plain-multiline-3", "description: this is a long\n  description that\n  wraps\n"),
    ("plain-multiline-blank", "a: one\n\n  two\n"),
    ("plain-multiline-nested", "root:\n  note: one\n    two\n  other: 3\n"),
    ("plain-multiline-seq", "- one\n  two\n- three\n"),
    ("plain-multiline-top", "one\n  two\n"),
    ("plain-multiline-comment", "a: one\n  # not content\nb: 3\n"),
    ("plain-then-dash", "a: one\n  - x\n"),
    ("plain-then-colon", "a: one\n  two: 3\n"),

    // The Norway problem and its neighbours. Assay keeps scalars unresolved precisely so
    // this is the schema's decision — but the RESOLVED comparison must still match libyaml.
    ("norway", "country: NO\nanswer: YES\nother: on\nnope: off\n"),
    ("booleans", "a: true\nb: True\nc: TRUE\nd: false\ne: False\n"),
    ("numbers", "i: 42\nn: -7\nf: 3.14\ne: 1e3\nz: 0\nneg: -0.5\n"),
    ("number-lookalikes", "version: 1.2.3\nphone: 555-1234\nzip: 01234\nhex: 0x1F\n"),
    ("special-floats", "inf: .inf\nninf: -.inf\nnan: .nan\n"),

    // Quoting. The rule that makes JSON a subset: quoted is always a string.
    ("quoted-numbers", "a: \"123\"\nb: '456'\nc: 789\n"),
    ("escapes", "a: \"line\\nbreak\"\nb: \"tab\\there\"\nc: \"quote\\\"inside\"\n"),
    ("single-quote-escape", "a: 'it''s here'\n"),
    ("unicode", "a: \"caf\u{00E9}\"\nb: \"\u{1F600}\"\nc: plain-caf\u{00E9}\n"),

    // Block scalars.
    ("literal-block", "a: |\n  line one\n  line two\n"),
    ("folded-block", "a: >\n  folded one\n  folded two\n"),
    ("literal-strip", "a: |-\n  no trailing newline\n"),
    ("literal-keep", "a: |+\n  keep\n\n"),

    // Anchors and aliases.
    ("anchor-alias", "base: &b\n  x: 1\nuse: *b\n"),
    ("anchor-scalar", "a: &v hello\nb: *v\n"),
    ("merge-key", "base: &b\n  x: 1\n  y: 2\nderived:\n  <<: *b\n  y: 3\n"),
    // Anchors defined INSIDE flow, unrecognised until 2026-09-08. Adjudicated by
    // Yams/libyaml rather than by our reading of the spec, which is the whole point of
    // having an oracle for a format this subtle.
    ("anchor-flow-seq", "a: [&x 1, *x]\n"),
    ("anchor-flow-map", "a: {&k key: &v val, other: *v}\n"),
    ("anchor-flow-collection", "a: [&c [1, 2], *c]\n"),
    ("anchor-flow-on-alias", "a: [&p 1, &q *p, *q]\n"),
    ("anchor-flow-then-block", "first: [&s 42]\nsecond: *s\n"),

    // Documents and comments.
    ("multi-document", "---\na: 1\n---\nb: 2\n"),
    ("explicit-end", "---\na: 1\n...\n"),
    ("comments", "# leading\na: 1  # trailing\n# between\nb: 2\n"),
    ("comment-only", "# nothing but a comment\n"),

    // Structural corners a subset parser is likely to get wrong.
    ("sequence-of-mappings", "- a: 1\n  b: 2\n- a: 3\n  b: 4\n"),
    ("mapping-of-sequences", "a:\n  - 1\n  - 2\nb:\n  - 3\n"),
    ("nested-sequences", "- - 1\n  - 2\n- - 3\n"),
    ("deep-indent", "a:\n    b:\n        c:\n            d: deep\n"),
    ("key-with-colon", "\"a: b\": value\n"),
    ("value-with-colon", "url: http://example.com/path\n"),
    ("trailing-spaces", "a: value   \nb: 2\n"),
    ("crlf", "a: 1\r\nb: 2\r\n"),
    ("crlf-literal", "a: |\r\n  x\r\n  y\r\n"),
    ("dash-value-next-line", "- \n  a: 1\n  b: 2\n-\n  - 1\n  - 2\n"),
    ("empty-flow", "a: []\nb: {}\n"),
    ("long-plain", "a: this is a fairly long plain scalar with spaces in it\n"),
]

// MARK: - XML, hand-written

let handWrittenXML: [(name: String, text: String)] = [
    ("simple", "<r><a>1</a><b>2</b></r>"),
    ("attributes", "<r id=\"1\" name=\"x\"><a k=\"v\"/></r>"),
    ("single-quoted-attrs", "<r id='1' name='x'/>"),
    ("empty-element", "<r><a/><b></b></r>"),
    ("nested", "<r><a><b><c>deep</c></b></a></r>"),
    ("mixed-content", "<r>text <b>bold</b> more</r>"),
    ("prolog", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><r><a>1</a></r>"),
    ("comment", "<r><!-- a comment --><a>1</a></r>"),
    ("processing-instruction", "<?xml version=\"1.0\"?><?target data?><r/>"),
    ("cdata", "<r><![CDATA[raw <not> markup & stuff]]></r>"),
    ("cdata-adjacent-text", "<r>before<![CDATA[middle]]>after</r>"),

    // Entities. The predefined five, numeric and hex character references.
    ("predefined-entities", "<r>&lt;&gt;&amp;&quot;&apos;</r>"),
    ("numeric-entities", "<r>&#65;&#66;&#x43;</r>"),
    ("entity-in-attribute", "<r a=\"&lt;&amp;&gt;\"/>"),
    // NOT here: <!DOCTYPE r [<!ENTITY e "expanded">]><r>&e;</r>. Assay expands internal
    // entities; Foundation's SAX mode silently DROPS the reference (observed: no text
    // event at all), so the oracle cannot adjudicate it. Assay's own tests cover expansion.

    // Namespaces — the part most likely to differ, and the reason the oracle compares
    // resolved URIs rather than prefixes.
    ("default-namespace", "<r xmlns=\"http://example.com/ns\"><a>1</a></r>"),
    ("prefixed-namespace", "<n:r xmlns:n=\"http://example.com/n\"><n:a>1</n:a></n:r>"),
    ("two-namespaces",
     "<r xmlns=\"http://d\" xmlns:n=\"http://n\"><a/><n:b/></r>"),
    ("nested-redefinition",
     "<r xmlns=\"http://a\"><c xmlns=\"http://b\"><d/></c></r>"),
    ("namespaced-attribute",
     "<r xmlns:n=\"http://n\"><a n:k=\"v\" k=\"w\"/></r>"),

    // Whitespace and text handling.
    ("whitespace-between", "<r>\n  <a>1</a>\n  <b>2</b>\n</r>"),
    ("significant-whitespace", "<r><a> spaced </a></r>"),
    ("unicode-content", "<r><a>caf\u{00E9}</a><b>\u{1F600}</b></r>"),
    ("unicode-names", "<r><caf\u{00E9}>x</caf\u{00E9}></r>"),
    ("crlf-content", "<r>\r\n<a>1</a>\r\n</r>"),
    // XML 1.0 §2.11: a parser MUST normalise \r\n and bare \r to \n in character data.
    // Unlike crlf-content, the text here is not whitespace-only, so the normalisation
    // difference cannot be hidden by the blank-text drop.
    ("crlf-text", "<r>a\r\nb\rc</r>"),
    // XML 1.0 §3.3.3: literal whitespace in an attribute value becomes a space, and
    // \r\n is ONE space because line-ending normalisation runs first.
    ("newline-in-attribute", "<r a=\"x\ny\" b=\"p\r\nq\" c=\"t\tu\"/>"),
    ("long-text", "<r>" + String(repeating: "abcdefghij", count: 200) + "</r>"),
    ("many-attributes",
     "<r " + (0..<30).map { "a\($0)=\"v\($0)\"" }.joined(separator: " ") + "/>"),
    ("many-children",
     "<r>" + (0..<200).map { "<c>\($0)</c>" }.joined() + "</r>"),
]

/// TOML feature cases, one per specification section plus the corners a hand-written
/// parser gets wrong. Includes documents both sides should REJECT — those count as
/// agreement too, and an "Assay only rejected" row is a parser bug until proven a
/// toml++ leniency.
let handWrittenTOML: [(name: String, text: String)] = [
    ("empty", ""),
    ("comment-only", "# just a comment\n"),
    ("scalars", "a = 1\nb = -2\nc = +3\nd = 1.5\ne = true\nf = \"s\"\n"),
    ("ints-bases", "h = 0xDEAD_BEEF\no = 0o755\nb = 0b1010\nu = 1_000_000\nz = 0\nn = -0\n"),
    ("ints-range", "max = 9223372036854775807\nmin = -9223372036854775808\n"),
    ("floats", "a = 1e5\nb = 6.626e-34\nc = -0.0\nd = 1_0.5_5\ne = 5E+22\nf = 0.1\n"),
    ("floats-special", "a = inf\nb = -inf\nc = +inf\nd = nan\ne = -nan\n"),
    ("strings-basic", #"a = "tab\t nl\n q\" bs\\ u\u00E9 U\U0001F600 ctl\u0001""# + "\n"),
    ("strings-literal", #"a = 'C:\path\to' # no escapes"# + "\n"),
    ("strings-ml-basic", "a = \"\"\"\nline one\nline \\\n    two\"\"\"\nb = \"\"\"x\"\"\"\n"),
    ("strings-ml-quotes", "a = \"\"\"\"\"five\"\"\"\"\"\nb = '''''five'''''\n"),
    ("strings-ml-literal", "a = '''\nraw \\ text\n  kept\n'''\n"),
    ("strings-ml-crlf", "a = \"\"\"\r\nx\r\ny\"\"\"\r\nb = '''\r\nx\r\ny'''\r\n"),
    ("strings-unicode", "a = \"ünïcödé 日本語 😀\"\n\"ключ\" = 1\n"),
    ("keys", "bare = 1\n\"quoted key\" = 2\n'lit' = 3\n\"\" = 4\n1234 = 5\na.b.c = 6\na . d = 7\n\"x.y\".z = 8\n"),
    ("keys-dotted-then-header", "[fruit]\napple.color = \"red\"\n[fruit.apple.texture]\nsmooth = true\n"),
    ("dates", "a = 1979-05-27T07:32:00Z\nb = 1979-05-27T00:32:00-07:00\nc = 1979-05-27T00:32:00.999999-07:00\nd = 1979-05-27 07:32:00Z\n"),
    ("dates-local", "a = 1979-05-27T07:32:00\nb = 1979-05-27\nc = 07:32:00\nd = 00:32:00.999999\ne = 1979-05-27t07:32:00.5z\n"),
    ("dates-frac-long", "a = 07:32:00.123456789123\nb = 1979-05-27T07:32:00.1Z\n"),
    // No `23:59:60` here: the TOML ABNF allows a leap second (`time-second … 00-60`) and
    // Assay accepts one, toml++ refuses it, toml-test has no case either way. The
    // library's own tests pin the acceptance.
    ("dates-leap-year", "a = 2024-02-29\nb = 2000-02-29\n"),
    ("arrays", "a = [1, 2, 3]\nb = [\"x\", 'y']\nc = [[1, 2], [3]]\nd = []\ne = [ 1 , 2 , ]\n"),
    ("arrays-multiline", "a = [\n  1, # one\n  2,\n  # comment\n  3\n]\n"),
    ("arrays-mixed", "a = [1, \"two\", 3.0, true, 1979-05-27, [1], {x = 1}]\n"),
    ("inline-tables", "a = {}\nb = { x = 1, y = \"z\" }\nc = { d.e = 1, d.f = 2 }\nn = { a = { b = { c = 1 } } }\n"),
    ("tables", "[a]\nx = 1\n[a.b]\ny = 2\n[c . d]\nz = 3\n[\"q k\"]\nw = 4\n[e]\n"),
    ("tables-implicit", "[a.b.c]\nx = 1\n[a]\ny = 2\n"),
    ("tables-array", "[[p]]\nn = 1\n[[p]]\nn = 2\n[p.sub]\nq = 1\n[[p.items]]\ni = 1\n[[p.items]]\ni = 2\n[[p]]\n"),
    ("tables-array-nested", "[[fruits]]\nname = \"apple\"\n[fruits.physical]\ncolor = \"red\"\n[[fruits.varieties]]\nname = \"red delicious\"\n[[fruits.varieties]]\nname = \"granny smith\"\n[[fruits]]\nname = \"banana\"\n[[fruits.varieties]]\nname = \"plantain\"\n"),
    ("whitespace", "  a   =   1   \n\t b\t=\t2\t\n\n\n[ t ]\n c = 3 # c\n"),
    ("crlf", "a = 1\r\nb = 2\r\n[t]\r\nc = 3\r\n"),
    ("bom", "\u{FEFF}a = 1\n"),
    ("no-trailing-newline", "a = 1"),
    ("deep", "a = " + String(repeating: "[", count: 40) + "1" + String(repeating: "]", count: 40) + "\n"),
    ("wide", (0..<300).map { "k\($0) = \($0)" }.joined(separator: "\n") + "\n"),
    // Both should reject.
    ("bad-dup-key", "a = 1\na = 2\n"),
    ("bad-dup-table", "[a]\n[a]\n"),
    ("bad-dotted-after-header", "[a.b]\n[a]\nb.c = 1\n"),
    ("bad-header-after-dotted", "[a]\nb.c = 1\n[a.b]\n"),
    ("bad-inline-extend", "a = { b = 1 }\na.c = 2\n"),
    ("bad-inline-header", "a = { b = 1 }\n[a.c]\n"),
    ("bad-static-array", "a = []\n[[a]]\n"),
    ("bad-array-header", "[[a]]\n[a]\n"),
    ("bad-leading-zero", "a = 01\n"),
    ("bad-underscore", "a = 1__2\n"),
    ("bad-float-dot", "a = 1.\n"),
    ("bad-float-lead-dot", "a = .5\n"),
    ("bad-overflow", "a = 9223372036854775808\n"),
    ("bad-hex-overflow", "a = 0x1_0000_0000_0000_0000\n"),
    ("bad-date-month", "a = 1979-13-01\n"),
    ("bad-date-day", "a = 2023-02-29\n"),
    ("bad-time-no-seconds", "a = 07:32\n"),
    ("bad-escape", "a = \"\\x41\"\n"),
    ("bad-surrogate", "a = \"\\uD800\"\n"),
    ("bad-control", "a = \"\u{01}\"\n"),
    ("bad-control-comment", "# \u{01}\n"),
    ("bad-bare-cr", "a = 1\rb = 2\n"),
    ("bad-inline-newline", "a = { b = 1,\n c = 2 }\n"),
    ("bad-inline-trailing-comma", "a = { b = 1, }\n"),
    ("bad-two-values", "a = 1 b = 2\n"),
    ("bad-no-value", "a =\n"),
    ("bad-no-key", "= 1\n"),
    ("bad-unterminated-array", "a = [1, 2\n"),
    ("bad-unterminated-string", "a = \"x\n"),
    ("bad-ml-in-key", "\"\"\"k\"\"\" = 1\n"),
    ("bad-six-quotes", "a = \"\"\"x\"\"\"\"\"\"\n"),
    ("bad-empty-header", "[]\n"),
    ("bad-header-space", "[a] b\n"),
    ("bad-utf8", "a = \"" + String(decoding: [0xC3], as: UTF8.self) + "\"\n"),
]

// The generated-volume renderers (renderYAML / renderXML) live in CorpusRender, shared
// with AssayBench so the differential corpus and the benchmark corpus are the same bytes.
