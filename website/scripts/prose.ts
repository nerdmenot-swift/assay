/**
 * Measures how the docs READ, so "it reads better now" can be a number.
 *
 *     bun run prose
 *
 * Four quantities per page: words of prose, mean sentence length, second-person density,
 * and how many performance numbers the page carries. The last one is not a style metric —
 * it is adoption. A reader decides whether to swap at the moment they open a recipe, and a
 * recipe with no number gives them nothing to weigh.
 *
 * THIS REPORTS AND NEVER FAILS. Exit code is always 0, on purpose, and the precedent is
 * CLAUDE.md's on total malloc traffic: "reported and never gated — total traffic has no
 * a-priori right answer and would fail CI on a change to String's growth policy". A warmth
 * floor is worse than that, because it is gameable in the one direction that defeats it:
 * sprinkle "you" and the metric rises while the writing gets worse. The number is an
 * instrument for a human to read, not a gate to satisfy.
 *
 * TARGETS ARE PER SEGMENT, which matters more than it sounds. A single target makes
 * reference/attributes — 84 words wrapped around a generated table — look broken when it is
 * doing exactly its job. A lookup page is not a teaching page and should not be scored like
 * one, so reference/ is measured for sentence length only and carries no warmth target.
 */

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const DOCS = join(HERE, '..', 'src', 'content', 'docs')
const RESULTS = join(HERE, '..', '..', 'Benchmarks', 'RESULTS.md')
const PAGES = join(HERE, 'pages')

// ---------------------------------------------------------------------------
// Segments
// ---------------------------------------------------------------------------

interface Segment {
  readonly name: string
  readonly warmth: readonly [number, number] | null
  readonly sentenceCeiling: number
}

// `warmth: null` means the segment is not scored for second person at all, rather than
// scored and forgiven. The distinction shows up in the summary: an unscored page can never
// be "off-voice", so it never appears in the count a human is trying to drive down.
const SEGMENTS: readonly Segment[] = [
  { name: 'start', warmth: [2.4, 3.0], sentenceCeiling: 20 },
  { name: 'guides', warmth: [2.4, 3.0], sentenceCeiling: 20 },
  { name: 'recipes', warmth: [2.4, 3.0], sentenceCeiling: 20 },
  // Format pages carry more spec detail than a guide, so the same warmth target would
  // force padding. A little lower, still clearly addressed to a reader.
  { name: 'formats', warmth: [2.0, 2.8], sentenceCeiling: 20 },
  { name: 'reference', warmth: null, sentenceCeiling: 22 },
]
const FALLBACK: Segment = { name: '(other)', warmth: null, sentenceCeiling: 22 }

function segmentOf(slug: string): Segment {
  const top = slug.split('/')[0]
  return SEGMENTS.find((s) => s.name === top) ?? FALLBACK
}

// ---------------------------------------------------------------------------
// Prose only
// ---------------------------------------------------------------------------

/**
 * Strips everything that is not running prose, in an order that matters: fences before
 * tables (a fenced block can contain a pipe), tables before inline code, link text kept
 * while the target is dropped.
 *
 * Without this the metrics measure the code samples, and a page that happens to carry a
 * long JSON document scores as cold no matter how it is written.
 */
function prose(raw: string): string {
  let t = raw
  t = t.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '') // frontmatter
  t = t.replace(/^(?:[ \t]*)(?:```|~~~)[\s\S]*?^(?:[ \t]*)(?:```|~~~)[ \t]*$/gm, '') // fences
  t = t.replace(/^[ \t]*\|.*$/gm, '') // table rows
  t = t.replace(/^[ \t]*(?:import|export)\s.*$/gm, '') // MDX imports
  t = t.replace(/<[^>]+>/g, ' ') // MDX / HTML tags
  t = t.replace(/`[^`]*`/g, ' ') // inline code
  t = t.replace(/!\[[^\]]*\]\([^)]*\)/g, ' ') // images
  t = t.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1') // links: keep the text
  t = t.replace(/^[ \t]*[#>]+[ \t]*/gm, '') // heading / quote markers
  t = t.replace(/[*_~]{1,3}/g, '') // emphasis
  return t
}

const WORD = /[A-Za-z][A-Za-z'’-]*/g
const SECOND_PERSON = new Set([
  'you', 'your', 'yours', 'yourself', "you're", 'youre',
  "you'll", 'youll', "you've", 'youve', "you'd", 'youd',
])

/**
 * A performance number, which is the thing a reader weighs. Multiples, percentages and
 * timings count; a version number or a section index does not, which is why a bare integer
 * is never a match.
 */
const PERF = /\b\d+(?:[.,]\d+)?\s*(?:×|x\b|%|ns\b|µs\b|us\b|ms\b|s\b|MB\/s\b|GB\/s\b)/g

interface Page {
  readonly slug: string
  readonly segment: Segment
  readonly words: number
  readonly sentence: number
  readonly warmth: number
  readonly numbers: number
  readonly generated: string | null
}

function measure(file: string, slug: string): Page {
  const raw = readFileSync(file, 'utf8')
  const text = prose(raw)
  const words = text.match(WORD) ?? []
  // Three words is the floor for a sentence: it drops list fragments and stray "See below."
  // without dropping real short sentences, which this voice uses deliberately.
  const sentences = text
    .split(/(?<=[.!?])["')\]]?\s+/)
    .map((s) => (s.match(WORD) ?? []).length)
    .filter((n) => n > 3)
  const second = words.filter((w) => SECOND_PERSON.has(w.toLowerCase())).length
  return {
    slug,
    segment: segmentOf(slug),
    words: words.length,
    sentence: sentences.length ? sentences.reduce((a, b) => a + b, 0) / sentences.length : 0,
    warmth: words.length ? (second * 100) / words.length : 0,
    numbers: (prose(raw).match(PERF) ?? []).length,
    generated: generatorFor(slug),
  }
}

// ---------------------------------------------------------------------------
// Where a page is actually edited
// ---------------------------------------------------------------------------

/**
 * The single most useful column here, and it exists because of a real mistake: 26 of these
 * pages are generated by extract.ts from scripts/pages/*.md.tmpl, and docs.yml's freshness
 * job re-runs extract and fails on `git diff --exit-code -- website/src`. Editing the
 * generated page is reverted and then fails CI. Printing the template path next to the page
 * means nobody has to remember which is which.
 */
function generatorFor(slug: string): string | null {
  if (slug === 'reference/performance') return 'performance.md.tmpl'
  if (slug === 'reference/changelog') return 'CHANGELOG.md (repo root)'
  const tmpl = `${slug.replace(/\//g, '--')}.md.tmpl`
  try {
    if (readdirSync(PAGES).includes(tmpl)) return `pages/${tmpl}`
  } catch {
    /* no pages dir: every page is hand-written */
  }
  return null
}

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (/\.mdx?$/.test(p)) out.push(p)
  }
  return out
}

// ---------------------------------------------------------------------------
// The ratio check
// ---------------------------------------------------------------------------

/**
 * Every multiple published to a reader should be traceable to Benchmarks/RESULTS.md, which
 * CLAUDE.md names as the one place the current numbers live. This is the check that would
 * have caught a published 4.2× that matched no measurement: it was arithmetically impossible
 * from the figures in the same sentence, and nothing in CI looked.
 *
 * Reported, not gated — same as everything else here. Rounding a live 3.61× to 3.6× is good
 * writing, and a sentence that says a number "was" something is history, not a claim, so an
 * exact-match gate would cry wolf constantly. The allowlist carries those; everything else
 * is worth a human glance.
 */
const HISTORICAL = new Set([
  '2.9', // encoding, before the writers owned their buffers — "it was 2.9× until…"
  '11.04', // YAML struct decode, before the direct RawValue door
  '1.15', // @Key(path:) ship-or-refuse gate, written before the measurement
  '1.14', // @Key(path:) mixed-shape arm, from COMPILE-TIME.md not RESULTS.md
  '3.7', // @Schema vs Codable, default JSON-only arm: 81 ms / 22 ms
])

function ratioCheck(pages: readonly { slug: string; file: string }[]): string[] {
  let live: Set<string>
  try {
    live = new Set(readFileSync(RESULTS, 'utf8').match(/\d+\.\d+(?=×)/g) ?? [])
  } catch {
    return ['RESULTS.md not readable — ratio check skipped']
  }
  const flagged: string[] = []
  for (const { slug, file } of pages) {
    const text = prose(readFileSync(file, 'utf8'))
    for (const m of text.match(/\d+\.\d+(?=×)/g) ?? []) {
      // A rounding of a live figure is fine: 3.6 for 3.61, 2.5 for 2.47.
      const rounds = [...live].some((v) => Math.abs(Number(v) - Number(m)) < 0.05)
      if (live.has(m) || rounds || HISTORICAL.has(m)) continue
      flagged.push(`${slug}: ${m}× is not in RESULTS.md, not a rounding, not allowlisted`)
    }
  }
  return flagged
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

const files = walk(DOCS).sort()
// The `/index` suffix is KEPT rather than stripped to the directory name. Stripping it read
// better in a list and was wrong twice over: `formats/index.md` is generated from
// `formats--index.md.tmpl`, so a bare `formats` slug failed the template lookup and the page
// was reported as hand-written — the one column here that exists to stop that mistake.
const pages = files.map((f) => {
  const slug = relative(DOCS, f).replace(/\.mdx?$/, '')
  return { file: f, slug }
})
const measured = pages.map(({ file, slug }) => measure(file, slug))

const pad = (s: string, n: number) => s.padEnd(n)
const num = (v: number, n: number, d = 1) => v.toFixed(d).padStart(n)

console.log('')
const W_PAGE = 30
const W_EDIT = 40
const WIDTH = W_PAGE + W_EDIT + 27
console.log(
  pad('page', W_PAGE) + pad('edit', W_EDIT) +
    'words'.padStart(6) + 'sent'.padStart(6) + 'you/100'.padStart(9) + 'nums'.padStart(6)
)
console.log('-'.repeat(WIDTH))

let currentSegment = ''
const offVoice: Page[] = []
const tooLong: Page[] = []
const noNumber: Page[] = []

for (const p of measured) {
  if (p.segment.name !== currentSegment) {
    currentSegment = p.segment.name
    const t = p.segment.warmth
    console.log(
      `\n  ${currentSegment}/  — ` +
        (t ? `warmth ${t[0]}–${t[1]}` : 'warmth not scored') +
        `, sentence ≤ ${p.segment.sentenceCeiling}`
    )
  }
  const flags: string[] = []
  if (p.segment.warmth && p.warmth < p.segment.warmth[0]) {
    flags.push('COLD')
    offVoice.push(p)
  }
  if (p.sentence > p.segment.sentenceCeiling) {
    flags.push('LONG')
    tooLong.push(p)
  }
  if (p.numbers === 0 && p.segment.warmth) {
    flags.push('NO-NUM')
    noNumber.push(p)
  }
  console.log(
    pad(p.slug, W_PAGE) +
      pad(p.generated ?? '(hand-written)', W_EDIT) +
      num(p.words, 6, 0) +
      num(p.sentence, 6) +
      num(p.warmth, 9, 2) +
      num(p.numbers, 6, 0) +
      (flags.length ? '  ' + flags.join(' ') : '')
  )
}

console.log('\n' + '-'.repeat(WIDTH))
for (const seg of [...SEGMENTS, FALLBACK]) {
  const inSeg = measured.filter((p) => p.segment === seg)
  if (!inSeg.length) continue
  const mean = (f: (p: Page) => number) => inSeg.reduce((a, p) => a + f(p), 0) / inSeg.length
  console.log(
    pad(`  ${seg.name}/ mean (${inSeg.length} pages)`, W_PAGE + W_EDIT) +
      num(mean((p) => p.sentence), 6) +
      num(seg.warmth ? mean((p) => p.warmth) : 0, 9, 2) +
      num(inSeg.reduce((a, p) => a + p.numbers, 0), 6, 0)
  )
}

const scored = measured.filter((p) => p.segment.warmth)
console.log('')
console.log(`teaching pages scored for voice: ${scored.length}`)
console.log(`  off-voice (below the warmth floor): ${offVoice.length}`)
console.log(`  over the sentence ceiling:          ${tooLong.length}`)
console.log(`  carrying no performance number:     ${noNumber.length}`)

if (offVoice.length) {
  console.log('\ncoldest first — these are where a rewrite buys the most:')
  for (const p of [...offVoice].sort((a, b) => a.warmth - b.warmth).slice(0, 12)) {
    console.log(`  ${num(p.warmth, 5, 2)}  ${pad(p.slug, W_PAGE)}→ edit ${p.generated ?? '(hand-written page)'}`)
  }
}

const flagged = ratioCheck(pages)
console.log(`\nratios not traceable to Benchmarks/RESULTS.md: ${flagged.length}`)
for (const f of flagged) console.log(`  ${f}`)

console.log('\nreported, not gated — this script never fails a build.')
