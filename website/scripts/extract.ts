/**
 * Pulls real output out of the library so the site never has to invent any.
 *
 *     bun run scripts/extract.ts
 *
 * Every error render on this site is the library's actual output for the document shown
 * beside it: a tiny Swift program is built against the real package, run, and its JSON is
 * written to src/data/samples.json for the pages to import. Nothing is typed by hand, so
 * nothing drifts when a message changes. The numbers come from the files that hold them
 * — RESULTS.md, CHANGELOG.md, the test target — for the same reason.
 *
 * Without a Swift toolchain the script says so and leaves the committed output in place,
 * so `astro dev` and the CI build work on a fresh clone.
 */

import { $ } from 'bun'
import { existsSync, mkdirSync, writeFileSync, readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = join(HERE, '..', '..')
const OUT = join(HERE, '..', 'src', 'data')

// ---------------------------------------------------------------------------
// The Swift program. One struct, several documents, every render captured.
// ---------------------------------------------------------------------------

const SWIFT = String.raw`
import Assay
import AssayYAML
import AssayXML
import AssayTOML

// The hero: a deployment config with one thing wrong in it.
@Schema(keys: .snakeCase, formats: .all)
struct Deployment {
    @Validate(.min(1), .max(63)) var name: String
    var image: String
    @Validate(.min(1)) var replicas: Int
    var region: String = "eu-west-1"
    @Validate(.url) var healthCheck: String?
}

// Every kind of failure at once, so the "all of them, not the first" claim is visible.
@Schema(keys: .snakeCase, unknownKeys: .warn)
struct Signup {
    @Validate(.min(3), .max(24)) var username: String
    @Validate(.email) var email: String
    @Validate(.min(13)) var age: Int
    var newsletter: Bool = false
    @Check
    static func adults(_ s: Signup, _ issues: inout Issues<Signup>) {
        if s.age < 18, s.newsletter { issues.add("needs a guardian's consent", at: \.newsletter) }
    }
}

@Schema(keys: .snakeCase)
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var tags: [String] = []
}

func esc(_ s: String) -> String {
    var out = ""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        default:
            if c.value < 0x20 {
                let hex = String(c.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else { out.unicodeScalars.append(c) }
        }
    }
    return out
}
func pair(_ source: String, _ render: String) -> String {
    "{\"source\":\"\(esc(source))\",\"render\":\"\(esc(render))\"}"
}

var parts: [String] = []

// 1. Hero.
let deploy = """
{
  "name": "api",
  "image": "registry.internal/api:2.4.1",
  "replicas": 0,
  "health_check": "https://api.internal/healthz"
}
"""
let d1 = Deployment.diagnose(json: deploy, sourceName: "deploy.json")
parts.append("\"hero\":" + pair(deploy, d1.render(.plain)))

// 2. The same struct, four formats, the same mistake. Same message, four carets.
let deployYAML = """
name: api
image: registry.internal/api:2.4.1
replicas: 0
health_check: https://api.internal/healthz
"""
let deployTOML = """
name = "api"
image = "registry.internal/api:2.4.1"
replicas = 0
health_check = "https://api.internal/healthz"
"""
let deployXML = """
<deployment>
  <name>api</name>
  <image>registry.internal/api:2.4.1</image>
  <replicas>0</replicas>
  <health_check>https://api.internal/healthz</health_check>
</deployment>
"""
@Schema(keys: .snakeCase, coerceScalars: true, formats: [.xml])
struct XMLDeployment {
    @Validate(.min(1), .max(63)) var name: String
    var image: String
    @Validate(.min(1)) var replicas: Int
    var region: String = "eu-west-1"
    @Validate(.url) var healthCheck: String?
}
let f = [
    "json": pair(deploy, d1.render(.plain)),
    "yaml": pair(deployYAML, Deployment.diagnose(yaml: deployYAML, sourceName: "deploy.yaml").render(.plain)),
    "toml": pair(deployTOML, Deployment.diagnose(toml: deployTOML, sourceName: "deploy.toml").render(.plain)),
    "xml": pair(deployXML, XMLDeployment.diagnose(xml: Array(deployXML.utf8), sourceName: "deploy.xml").render(.plain)),
]
parts.append("\"formats\":{" + f.map { "\"\($0.key)\":\($0.value)" }.sorted().joined(separator: ",") + "}")

// 3. Everything wrong at once.
let signup = """
{
  "username": "jo",
  "email": "jo@localhost",
  "age": "fourteen",
  "newsleter": true
}
"""
let d3 = Signup.diagnose(json: signup, sourceName: "signup.json")
parts.append("\"collect\":" + pair(signup, d3.render(.plain)))
parts.append("\"collectJSON\":\"" + esc(d3.render(.json)) + "\"")

// 4. The happy path, so the page shows what success looks like too.
let article = """
{"title": "On carets", "link": "https://example.com/carets", "reading_minutes": 4, "tags": ["errors"]}
"""
let a = try! Article.parse(json: article)
parts.append("\"happy\":" + pair(article, String(describing: a)))

// 5. A did-you-mean, on its own.
@Schema(keys: .snakeCase, unknownKeys: .reject)
struct Strict { var apiKey: String; var timeoutSeconds: Int }
let strict = """
{"api_key": "sk-live-4f2a", "timeout_secs": 30}
"""
parts.append("\"didYouMean\":" + pair(strict, Strict.diagnose(json: strict, sourceName: "config.json").render(.plain)))

print("{" + parts.joined(separator: ",") + "}")
`

// ---------------------------------------------------------------------------
// Numbers, read from the files that hold them
// ---------------------------------------------------------------------------

function version(): string {
  const m = /^## (\d+\.\d+\.\d+)/m.exec(readFileSync(join(REPO, 'CHANGELOG.md'), 'utf8'))
  return m?.[1] ?? '0.0.0'
}

function testCounts(): { tests: number; suites: number } {
  const dir = join(REPO, 'Tests', 'AssayTests')
  let tests = 0, suites = 0
  for (const f of readdirSync(dir)) {
    if (!f.endsWith('.swift')) continue
    const src = readFileSync(join(dir, f), 'utf8')
    tests += (src.match(/@Test\b/g) ?? []).length
    suites += (src.match(/@Suite\b/g) ?? []).length
  }
  return { tests, suites }
}

function issueCodes(): number {
  const src = readFileSync(join(REPO, 'Sources', 'AssayCore', 'IssueCode+Names.swift'), 'utf8')
  return (src.match(/public static let /g) ?? []).length
}

/** The "Current numbers" table at the top of RESULTS.md: arm, number, baseline. */
function numbers(): { arm: string; number: string; against: string }[] {
  const md = readFileSync(join(REPO, 'Benchmarks', 'RESULTS.md'), 'utf8')
  const rows: { arm: string; number: string; against: string }[] = []
  // The Current numbers table is the first table in the file and contiguous; it ends at
  // the first line that is not a table row once rows have started.
  for (const line of md.split('\n')) {
    if (!line.startsWith('|')) { if (rows.length) break; else continue }
    if (line.startsWith('| arm') || line.startsWith('|---')) continue
    const cells = line.split('|').map((c) => c.trim())
    if (cells.length < 5) continue
    const strip = (s: string) => s.replace(/\*\*/g, '').replace(/`/g, '')
    rows.push({ arm: strip(cells[1]), number: strip(cells[2]), against: strip(cells[3]) })
  }
  return rows
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

mkdirSync(OUT, { recursive: true })
const dest = join(OUT, 'samples.json')
const previous = existsSync(dest) ? JSON.parse(readFileSync(dest, 'utf8')) : {}

const stats = {
  version: version(),
  ...testCounts(),
  codes: issueCodes(),
  formats: ['JSON', 'YAML', 'XML', 'TOML', 'plist'],
}

let hasSwift = true
try {
  await $`swift --version`.quiet()
} catch {
  hasSwift = false
}

let renders = previous.renders ?? null
if (hasSwift) {
  const tmp = join(REPO, '.website-extract')
  mkdirSync(join(tmp, 'Sources', 'extract'), { recursive: true })
  writeFileSync(join(tmp, 'Sources', 'extract', 'main.swift'), SWIFT)
  writeFileSync(
    join(tmp, 'Package.swift'),
    `// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "extract",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "${REPO}")],
    targets: [.executableTarget(name: "extract", dependencies: [
        .product(name: "Assay", package: "assay"),
        .product(name: "AssayYAML", package: "assay"),
        .product(name: "AssayXML", package: "assay"),
        .product(name: "AssayTOML", package: "assay"),
    ])]
)
`
  )
  console.log('  extract: building the examples against the real library…')
  const json = await $`swift run -c release --package-path ${tmp} extract`.quiet().text()
  renders = JSON.parse(json)
} else if (renders) {
  console.log('  extract: no Swift toolchain — keeping the committed renders')
} else {
  console.error('  extract: no Swift toolchain and no committed renders; run this once with Swift')
  process.exit(1)
}

// ---------------------------------------------------------------------------
// Generated reference: the issue codes
// ---------------------------------------------------------------------------
//
// One row per code, read out of IssueCode+Names.swift. Hand-maintaining this table would
// mean it is wrong the first time somebody adds a code; generating it means the page and
// the library cannot disagree.

function codeTable(): string {
  const src = readFileSync(join(REPO, 'Sources', 'AssayCore', 'IssueCode+Names.swift'), 'utf8')
  const lines = src.split('\n')
  let section = 'Core'
  const groups = new Map<string, { code: string; doc: string }[]>()
  for (let i = 0; i < lines.length; i++) {
    const mark = /^\s*\/\/ MARK: (.+)$/.exec(lines[i])
    if (mark) { section = mark[1].trim(); continue }
    const decl = /public static let (\w+) = IssueCode\.(?:custom\("([^"]+)"\)|(\w+))/.exec(lines[i])
    if (!decl) continue
    // The doc comment is the run of /// lines immediately above.
    const doc: string[] = []
    for (let j = i - 1; j >= 0; j--) {
      const d = /^\s*\/\/\/ ?(.*)$/.exec(lines[j])
      if (!d) break
      doc.unshift(d[1])
    }
    const wire = decl[2] ?? decl[3]
    // The doc's first line is "`wire_code` — the sentence". Keep the sentence.
    // The doc's first line is usually "`wire_code` — the sentence" (or just "`wire_code`.").
    // Strip the code and the dash; keep the sentence and any "Params:" note after it.
    let text = doc.join(' ').trim()
    text = text.replace(new RegExp('^`' + wire.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&') + '`\\s*(—|-|\\.)?\\s*'), '')
    text = text.trim().replace(/^\.\s*/, '')
    // Unwrap the quoted message so the table reads as prose. Allows \" inside it, which
    // several of these have.
    text = text.replace(/^"((?:[^"\\]|\\.)*)"\.?\s*/, (_m, q) => {
      const msg = q.replace(/\\"/g, '"')
      return msg.charAt(0).toUpperCase() + msg.slice(1) + '. '
    })
    // A literal pipe would end the table cell.
    text = text.trim().replace(/\|/g, '\\|')
    if (!groups.has(section)) groups.set(section, [])
    groups.get(section)!.push({ code: wire, doc: text })
  }
  let out = ''
  for (const [name, rows] of groups) {
    out += `\n### ${name}\n\n| Code | Meaning |\n|---|---|\n`
    for (const r of rows) out += `| \`${r.code}\` | ${r.doc || '—'} |\n`
  }
  return out
}

const CODES_PAGE = `---
title: Issue codes
description: Every code the library can report, generated from the source so it cannot drift.
---

Match on the code, never on the message: the wording is not part of the API, the code is.
Every code is also a static on \`IssueCode\` in camelCase — \`too_small\` is
\`IssueCode.tooSmall\`.

Parameters named in a meaning are in \`issue.params\`, ready to interpolate into your own
wording.

<!-- Generated by website/scripts/extract.ts from Sources/AssayCore/IssueCode+Names.swift.
     Do not edit by hand. -->
${codeTable()}
`
writeFileSync(join(HERE, '..', 'src', 'content', 'docs', 'reference', 'issue-codes.md'), CODES_PAGE)

// The performance page: prose in scripts/performance.md.tmpl, numbers from RESULTS.md.
// A template file rather than a string literal here, because the prose is full of
// backticks and a template literal full of escaped backticks is unreadable and unsafe
// to edit.
const perfTmpl = readFileSync(join(HERE, 'performance.md.tmpl'), 'utf8')
writeFileSync(
  join(HERE, '..', 'src', 'content', 'docs', 'reference', 'performance.md'),
  perfTmpl.replace(
    '{{TABLE}}',
    numbers().map((r) => `| ${r.arm} | **${r.number}** | ${r.against} |`).join('\n')
  )
)

writeFileSync(dest, JSON.stringify({ stats, numbers: numbers(), renders }, null, 2) + '\n')
console.log(`  extract: v${stats.version}, ${stats.tests} tests, ${stats.codes} codes, ${Object.keys(renders).length} renders`)
