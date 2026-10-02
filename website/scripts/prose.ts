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
 * PAGES WITH ALMOST NO PROSE ARE NOT SCORED FOR WARMTH. Below about 120 words the ratio is
 * noise — one pronoun moves it by more than a point — and the only way to "fix" such a page
 * is to add prose nobody asked for. start/cheatsheet is 75 words wrapped around code blocks
 * and its own description reads "skim it, bookmark it, stop reading prose". Scoring it like a
 * guide asks it to stop being a cheatsheet. Sentence length is still measured, since that one
 * works at any size.
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
// The upper bound is 3.4 and not the 3.0 first written here, because 3.0 was a guess and
// the exemplars outvoted it: guides/presence measures 3.38 and guides/dates 3.30, and those
// are the two pages this voice was set FROM. A ceiling that excludes your own best pages is
// measuring the wrong thing. 3.4 is where they sit; past it the prose starts addressing the
// reader instead of telling them something.
const SEGMENTS: readonly Segment[] = [
  { name: 'start', warmth: [2.4, 3.4], sentenceCeiling: 20 },
  { name: 'guides', warmth: [2.4, 3.4], sentenceCeiling: 20 },
  { name: 'recipes', warmth: [2.4, 3.4], sentenceCeiling: 20 },
  // Format pages carry more spec detail than a guide, so the same floor would force
  // padding. A little lower, still clearly addressed to a reader.
  { name: 'formats', warmth: [2.0, 3.0], sentenceCeiling: 20 },
  { name: 'reference', warmth: null, sentenceCeiling: 22 },
]
const FALLBACK: Segment = { name: '(other)', warmth: null, sentenceCeiling: 22 }

// Below this many words of prose, warmth is noise rather than signal.
const MIN_PROSE_FOR_WARMTH = 120

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
  const seg = segmentOf(slug)
  return {
    slug,
    // A page too short to score keeps its sentence ceiling and loses its warmth target.
    segment:
      words.length < MIN_PROSE_FOR_WARMTH && seg.warmth
        ? { ...seg, warmth: null }
        : seg,
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
 *
 * TWO THINGS THIS GOT WRONG AT FIRST, both found by a stale number it failed to catch.
 *
 * It only looked at decimals, so `about 6×` sailed past — and that was the superseded Date
 * figure, replaced by 5.40× at the 2026-09-20 re-measure. Whole numbers are checked now, with
 * a wider tolerance, because "about 6×" is a legitimate rounding of anything from 5.5 to 6.5
 * and the question is only whether SOMETHING live is nearby.
 *
 * And it treated all of RESULTS.md as live. That file is a journal: it carries the original
 * measurement next to the current one, so the stale 6.06× was "in RESULTS.md" and passed. Only
 * the headline table counts now, which is what CLAUDE.md actually says is the source.
 */
const HISTORICAL = new Set([
  '2.9', // encoding, before the writers owned their buffers — "it was 2.9× until…"
  '11.04', // YAML struct decode, before the direct RawValue door
  // Live, but measured somewhere other than the headline table.
  '1.15', // @Key(path:) ship-or-refuse gate, written before the measurement
  '1.14', // @Key(path:) mixed-shape arm — COMPILE-TIME.md
  '0.97', // @Key(path:) against the nesting it saves — COMPILE-TIME.md
  '1.01', // the other end of that range
  '6.95', // the [String: T] dictionary worst case — CLAUDE.md
  // Not Assay's numbers at all, and not ours to update.
  '1.38', // ZippyJSON over Foundation, as ZippyJSON itself published it
  // Not a measurement: a configured ceiling.
  '32', // XML entity expansion bounded at 32× the input, with a 64 KB floor
])

// A changelog's job is to say what was true at the time, so every superseded figure in it is
// correct BECAUSE it is superseded. Checking it against today's numbers asks it to lie.
const RATIO_EXEMPT = (slug: string) => slug === 'reference/changelog'

function ratioCheck(pages: readonly { slug: string; file: string }[]): string[] {
  let live: number[]
  try {
    const all = readFileSync(RESULTS, 'utf8')
    // The headline table ONLY — from its header row to the blank line that ends it. The rest
    // of the file is a journal and carries superseded figures beside the current ones.
    const start = all.indexOf('| arm | number | against | journal |')
    const table = start < 0 ? all : all.slice(start, all.indexOf('\n\n', start))
    live = [...table.matchAll(/(\d+(?:\.\d+)?)(?=×)/g)].map((m) => Number(m[1]))
  } catch {
    return ['RESULTS.md not readable — ratio check skipped']
  }
  if (!live.length) return ['no headline table found in RESULTS.md — ratio check skipped']

  const flagged: string[] = []
  for (const { slug, file } of pages) {
    if (RATIO_EXEMPT(slug)) continue
    const text = prose(readFileSync(file, 'utf8'))
    for (const m of text.matchAll(/(?<![\d.])(\d+(?:\.\d+)?)(?=×)/g)) {
      const v = m[1]
      if (HISTORICAL.has(v)) continue
      // Tolerance scales with how precisely the page quoted the figure. "3.6×" claims one
      // decimal, so 0.05 is right; "about 6×" claims none, so anything from 5.5 to 6.5 is an
      // honest rounding and the only question is whether something live sits in that band.
      // 0.051, not 0.05: 3.35 - 3.3 is 0.050000000000000266 in binary floating point,
      // which flagged two correctly-rounded figures on the first run.
      const tol = v.includes('.') ? 0.051 : 0.5
      if (live.some((x) => Math.abs(x - Number(v)) <= tol)) continue
      flagged.push(`${slug}: ${v}× has no figure within ${tol} in the RESULTS.md headline table`)
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
const overWarm: Page[] = []
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
  // The range has two ends, and leaving the upper one unmeasured is how a rewrite sails
  // past it: four recipes went 0.54 -> 4.2 in one pass and nothing here said so. Over the
  // ceiling is not a worse failure than under it, but it is the same kind — prose bent
  // toward a number instead of toward a reader.
  if (p.segment.warmth && p.warmth > p.segment.warmth[1]) {
    flags.push('OVER')
    overWarm.push(p)
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
console.log(`  over the warmth ceiling:            ${overWarm.length}`)
console.log(`  over the sentence ceiling:          ${tooLong.length}`)
console.log(`  carrying no performance number:     ${noNumber.length}`)

if (offVoice.length) {
  console.log('\ncoldest first — these are where a rewrite buys the most:')
  for (const p of [...offVoice].sort((a, b) => a.warmth - b.warmth).slice(0, 12)) {
    console.log(`  ${num(p.warmth, 5, 2)}  ${pad(p.slug, W_PAGE)}→ edit ${p.generated ?? '(hand-written page)'}`)
  }
}

if (overWarm.length) {
  console.log('\nover the ceiling — trim, do not add:')
  for (const p of [...overWarm].sort((a, b) => b.warmth - a.warmth)) {
    console.log(`  ${num(p.warmth, 5, 2)}  ${pad(p.slug, W_PAGE)}→ edit ${p.generated ?? '(hand-written page)'}`)
  }
}

const flagged = ratioCheck(pages)
console.log(`\nratios not traceable to Benchmarks/RESULTS.md: ${flagged.length}`)
for (const f of flagged) console.log(`  ${f}`)

console.log('\nreported, not gated — this script never fails a build.')
