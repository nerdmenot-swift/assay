/**
 * Builds the Open Graph card — the image every shared link to this site renders.
 *
 *     bun run og
 *
 * It existed as a committed PNG with no generator at all, which meant it could not be
 * rebuilt and quietly went stale: the one in the repository predated three versions of the
 * mark. Now it is derived from the same two sources everything else here is derived from.
 *
 *   * The mark comes out of public/icon.svg, so a redrawn logo reaches the card.
 *   * The error render comes out of src/data/samples.json, which extract.ts fills by
 *     building the examples against the real library. The old card had the render typed in
 *     by hand — on a site whose stated promise is that every render on it is real output.
 *
 * RASTERISING USES sharp, which arrives with Astro and carries librsvg, so this works on
 * macOS and in Linux CI with nothing extra to install. rsvg-convert, resvg and magick are
 * tried after it for anyone running the script outside this package. If none is present the
 * script says so and leaves the committed PNG alone, the same way extract.ts leaves its
 * output in place without a Swift toolchain — so a fresh clone still builds.
 *
 * qlmanage was the first thing tried here and is not in that list. It renders an SVG onto a
 * SQUARE canvas at the size you ask for, ignoring the aspect ratio, so a 1200x630 card came
 * out 1200x1200 with the right-hand third of every line cut off and white padding below.
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const PUBLIC = join(HERE, '..', 'public')
const SVG_OUT = join(HERE, 'og.svg')
const PNG_OUT = join(PUBLIC, 'og.png')

const INK = '#15141a'
const PAPER = '#ece8e0'
const MUTED = '#8f897f'
const ACCENT = '#f07b62'
const AMBER = '#ffc61a'

// ---------------------------------------------------------------------------
// The mark, lifted from the published icon rather than copied
// ---------------------------------------------------------------------------

/**
 * Pulls the three path shapes out of public/icon.svg. Deliberately reads the file instead
 * of holding its own copy: the mark has been redrawn four times, and a second copy of a
 * 900-character path is a second thing to forget.
 */
function markPaths(): { braces: string[]; bead: string; beadTransform: string } {
  const svg = readFileSync(join(PUBLIC, 'icon.svg'), 'utf8')
  const paths = [...svg.matchAll(/<path\b[^>]*\bd="([^"]+)"/g)].map((m) => m[1])
  if (paths.length < 3) throw new Error('public/icon.svg: expected three paths, found ' + paths.length)
  const beadTag = svg.match(/<path\b[^>]*transform="([^"]+)"[^>]*\bd="/)
  return {
    braces: [paths[0], paths[1]],
    bead: paths[2],
    beadTransform: beadTag?.[1] ?? '',
  }
}

// ---------------------------------------------------------------------------
// The card
// ---------------------------------------------------------------------------

const esc = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

/** One `<tspan>` per line, with the caret line and the `error:` label coloured. */
function renderLines(render: string, x: number, y: number, lh: number): string {
  return render
    .split('\n')
    .map((line, i) => {
      const dy = y + i * lh
      // A caret row is the renderer's own output and the only red in the block besides the
      // label; colouring it is the single thing that makes this card legible as a thumbnail.
      const isCaret = /^\s*[│|]?\s*\^+\s*$/.test(line) || /\^/.test(line)
      const fill = isCaret ? ACCENT : PAPER
      const parts = line.split(/(error:)/)
      const spans = parts
        .map((p) => (p === 'error:' ? `<tspan fill="${ACCENT}">${esc(p)}</tspan>` : esc(p)))
        .join('')
      return `<text x="${x}" y="${dy}" fill="${fill}" xml:space="preserve">${spans}</text>`
    })
    .join('\n    ')
}

function card(): string {
  const data = JSON.parse(readFileSync(join(HERE, '..', 'src', 'data', 'samples.json'), 'utf8'))
  const render: string = data.renders.hero.render
  // stats.formats is an array of short names; the card wants the long reading, and
  // HTTP bodies are an entry point rather than a format so they are not in that array.
  const names: string[] = Array.isArray(data.stats?.formats) ? data.stats.formats : []
  const formats = (names.length ? names : ['JSON', 'YAML', 'XML', 'TOML', 'plist'])
    .map((n: string) => (n === 'plist' ? 'property lists' : n))
    .join(' · ') + ' · HTTP bodies'
  const { braces, bead, beadTransform } = markPaths()

  // The mark is drawn in a 1024 box; 0.085 puts it at ~87px, which matches the wordmark's
  // cap height closely enough to sit on the same baseline.
  const k = 0.085
  const markX = 78
  const markY = 60

  return `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="${INK}"/>
  <rect width="10" height="630" fill="${ACCENT}"/>

  <g transform="translate(${markX} ${markY}) scale(${k})">
    <path fill="${ACCENT}" d="${braces[0]}"/>
    <path fill="${ACCENT}" d="${braces[1]}"/>
    <path fill="${AMBER}" transform="${beadTransform}" d="${bead}"/>
  </g>

  <text x="190" y="142" fill="${PAPER}" font-family="Bricolage Grotesque, Helvetica Neue, Arial, sans-serif"
        font-size="92" font-weight="700" letter-spacing="-2">Assay</text>
  <text x="78" y="196" fill="${MUTED}" font-family="Public Sans, Helvetica Neue, Arial, sans-serif"
        font-size="30">A decoder for Swift that tells you what went wrong.</text>

  <rect x="78" y="240" width="1044" height="300" rx="6" fill="#1d1c23" stroke="#33313a"/>
  <g font-family="JetBrains Mono, Menlo, ui-monospace, monospace" font-size="23">
    ${renderLines(render, 110, 288, 34)}
  </g>

  <text x="78" y="578" fill="${MUTED}" font-family="Public Sans, Helvetica Neue, Arial, sans-serif"
        font-size="25">${esc(formats)}</text>
  <text x="78" y="612" fill="#5f5a52" font-family="Public Sans, Helvetica Neue, Arial, sans-serif"
        font-size="23">assay.nerdmenot.in</text>
</svg>
`
}

// ---------------------------------------------------------------------------
// Rasterise with whatever is here
// ---------------------------------------------------------------------------

function has(cmd: string): boolean {
  return spawnSync('command', ['-v', cmd], { shell: true, stdio: 'ignore' }).status === 0
}

async function rasterise(svgPath: string): Promise<string | null> {
  // sharp first: it is already installed, it honours the SVG's own width and height, and it
  // is the only one of these that is guaranteed present wherever the site builds.
  try {
    const sharp = (await import('sharp')).default
    await sharp(svgPath, { density: 144 }).resize(1200, 630).png().toFile(PNG_OUT)
    return 'sharp'
  } catch {
    /* fall through to a command-line renderer */
  }
  if (has('rsvg-convert')) {
    const r = spawnSync('rsvg-convert', ['-w', '1200', '-h', '630', '-o', PNG_OUT, svgPath],
      { stdio: 'inherit' })
    if (r.status === 0) return 'rsvg-convert'
  }
  if (has('resvg')) {
    const r = spawnSync('resvg', ['-w', '1200', svgPath, PNG_OUT], { stdio: 'inherit' })
    if (r.status === 0) return 'resvg'
  }
  if (has('magick')) {
    const r = spawnSync('magick', ['-background', 'none', '-density', '144', svgPath,
      '-resize', '1200x630!', PNG_OUT], { stdio: 'inherit' })
    if (r.status === 0) return 'magick'
  }
  return null
}

const svg = card()
writeFileSync(SVG_OUT, svg)
console.log(`  og: wrote ${SVG_OUT.replace(process.cwd() + '/', '')}`)

const used = await rasterise(SVG_OUT)
if (used) {
  console.log(`  og: wrote public/og.png (1200x630) via ${used}`)
} else {
  console.log('  og: no rasteriser found (sharp, rsvg-convert, resvg or magick).')
  console.log('      The SVG is current; public/og.png is left as committed.')
}
