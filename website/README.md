# The Assay website

Astro + Starlight, built for Cloudflare Pages at `assay.nerdmenot.in`. **It is not
published yet**: the deploy job needs the `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` repository secrets, which are not set, and the domain does not
resolve until the first deploy.

```sh
bun install
bun run dev        # extract (needs Swift) + astro dev
bun run astro dev  # skip the extract, use the committed data
bun run build
```

## How it is put together

**Starlight owns `src/content/docs/**` and nothing else.** The landing page is a plain
Astro route with its own layout, because a docs framework's default shell is the fastest
way to look like every other project. Starlight is here for what it genuinely does better
than a bespoke build: sidebar, search, keyboard navigation, heading anchors and
accessibility.

```
scripts/extract.ts           builds a Swift program against the real package, runs it,
                             writes src/data/samples.json and every generated page
scripts/samples.swift.txt    the example program — most renders on the site come from it
scripts/recipes.swift.txt    five whole programs, one per "Putting it together" page
scripts/cookbook.swift.txt   the feature catalogue — one tiny program per Recipes entry
scripts/pages/*.md.tmpl      docs pages whose examples are real output (see below)
scripts/performance.md.tmpl  prose for the performance page; {{TABLE}} is substituted
scripts/prose.ts             readability report for the docs (reported in CI, never gated)
scripts/og.ts, og.svg        renders public/og.png, the social card
src/pages/index.astro        the landing page
src/styles/theme.css         tokens + Starlight overrides (docs and landing page share them)
src/styles/home.css          the landing page only
src/components/              Header and PageTitle overrides, theme and ToC toggles,
                             the shared GitHub mark
src/content/docs/            start/, recipes/, guides/, formats/, reference/
```

## Nothing on this site is typed by hand

Every error render is the library's real output for the document shown beside it.
`bun run extract` writes a small Swift program, builds it against the package, runs it, and
saves the output — so a message that changes in the library changes here on the next build
rather than drifting silently. The numbers come from the files that hold them:
`Benchmarks/RESULTS.md`, `CHANGELOG.md`, the test target, `IssueCode+Names.swift`.

These pages are generated in full and **should not be edited** — edit the template instead:

| page | from |
|---|---|
| `reference/issue-codes.md` | `Sources/AssayCore/IssueCode+Names.swift` |
| `reference/performance.md` | `scripts/performance.md.tmpl`, table from `../Benchmarks/RESULTS.md` |
| `reference/changelog.md` | `CHANGELOG.md`, with repo-relative links rewritten to GitHub |
| `formats/*.md` | `scripts/pages/formats--*.md.tmpl` |
| `recipes/*.md` | `scripts/pages/recipes--*.md.tmpl`, examples from `scripts/cookbook.swift.txt` and `scripts/recipes.swift.txt` |
| `start/first-schema.md`, `guides/errors.md`, `guides/rules.md` | `scripts/pages/*.md.tmpl` — moved there 2026-09-23, see below |

**Why those last three moved.** They were hand-written, and they showed terminal renders
typed by hand beside the code that was supposed to produce them. One had drifted into
something the code could not produce at all: `start/first-schema` declared `@Schema` (so
camelCase keys) and then showed a document with `reading_minutes` and an error naming
`reading_minutes`, where that pairing really produces `readingMinutes is required`. Two
others were close but not exact — a trimmed context line, a different surrounding document.
A page that teaches "the error points at the byte" cannot itself be approximate, so the
renders now come from the extract like everything else.

`scripts/pages/<name>.md.tmpl` becomes `src/content/docs/<name>.md`, with `--` in the
filename meaning a directory separator. Four placeholders pull real output in by render key:

```
{{in:key:lang}}       the input document, fenced as `lang`
{{out:key}}           what the library printed, fenced as `text`
{{value:key}}         the decoded value, fenced as `swift`
{{example:key:lang}}  both: input, then output
```

A placeholder naming a key that does not exist fails the build rather than printing
`{{out:typo}}` on the page. The keys are whatever `scripts/samples.swift.txt` emits — add a
render there first, then reference it.

The generated output is committed, so CI and a fresh clone work without a Swift toolchain.
Without Swift, `extract` says so and keeps what is committed.

## The two headers

The docs header and the landing page header are deliberately the same shape, and
deliberately short. The docs one carries **no text links at all**: everything they used to
point at is in the sidebar two inches below, and they cost the width that search and the
toggles need on a phone. The landing page keeps three words, and drops those below 34rem —
its own body is the navigation there, through the hero buttons, the format rail and the
closing doors.

Anything added to either header has to earn its width at 360px. The rule of thumb is that
a header item must be something the page itself cannot offer: the way home, search, the
source, and the version the page describes. Below 24rem the docs header's theme toggle
gives way to the version chip; Starlight's menu carries its own theme picker there.

## Voice

Second person, present tense, British spelling, short declaratives. Explain the *reason*,
not just the mechanism — and where a thing was measured, say the number. No exclamation
marks, no marketing adjectives, and no claim the repository cannot support: if a number is
platform-specific, the page says which platform.

## Adding a page

1. Write it in `src/content/docs/<section>/<slug>.md` with `title` and `description`. If it
   shows library output, write `scripts/pages/<section>--<slug>.md.tmpl` instead and add the
   renders it needs to `scripts/samples.swift.txt`.
2. Add its slug to the `sidebar` in `astro.config.mjs` — order is editorial, not
   alphabetical.
3. `bun run build` (or `bun run astro build` without Swift). The link gate — pages and
   `#fragment` anchors — runs in CI (`.github/workflows/docs.yml`), not locally: a reworded
   heading breaks anchor links silently otherwise, and has.

## Deploying

CI deploys to Cloudflare Pages (project `assay-docs`) on every push to `main`, after the
freshness check and the build pass (`.github/workflows/docs.yml`). `CLOUDFLARE_API_TOKEN`
and `CLOUDFLARE_ACCOUNT_ID` are organisation secrets. By hand:

```sh
bun run deploy      # needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID
```

## Versions

The header carries a version chip (`src/components/VersionSwitcher.astro`) naming the
release the page describes. The current label comes from `CHANGELOG.md`'s first release
heading through the extract, so a release needs no edit here: tag it, the push to `main`
redeploys, and the chip reads the new version. **A patch or a new tag archives nothing.**

Older versions appear in the chip only once one is archived, and archiving is by hand —
the same scheme as catena's site:

- **One archive per minor series, not per tag**, made when the *next* minor ships, from the
  last tag of the outgoing series and labelled for the series (`v1.0.x`). Under semver a
  patch cannot change the API, and the Swift Package Index keeps every tag's DocC.
- **A published URL is permanent.** Once `/1-0/` is linked somewhere, removing it breaks
  the link, so archive coarsely. Past about six entries, drop the oldest from the chip and
  keep serving its pages.
- Never skip a series because it changed little. A gap in the list reads as a fault.

To archive 1.0.x when 1.1.0 ships:

1. **Snapshot from the tag, not from the working tree** — the tree is already the new
   release. The generated pages are committed, so the tag holds them, and
   `scripts/extract.ts` writes files without deleting any, so it leaves the archive alone:

   ```sh
   dest=src/content/docs/1-0 && mkdir -p "$dest"
   git archive v1.0.N website/src/content/docs | tar -x --strip-components=4 -C "$dest"
   ```

2. Add `{ slug: '1-0', label: 'v1.0.x' }` to `src/data/versions.mjs`.
3. **Wire `starlight-versions`**, which was not installed while there was nothing to archive
   (it refuses to build with an empty list): `bun add starlight-versions`, then in
   `astro.config.mjs` add `starlightVersions({ current: { label: 'v' + version }, versions:
   archived })` to Starlight's `plugins`. Record that tag's sidebar in
   `src/content/versions/1-0.json` as `{"sidebar": [...], "excluded": []}`; the plugin
   refuses to build without it.
4. **Render the plugin's components yourself.** `Header` and `PageTitle` are config-level
   overrides, which beat a plugin's, so its pieces disappear silently unless imported:
   swap Starlight's `Search` in `Header.astro` for `starlight-versions/components/VersionSearch.astro`
   (results scoped to the version being read), and put
   `starlight-versions/components/VersionNotice.astro` at the top of `PageTitle.astro` (the
   "you are reading an old version" banner).
5. Build, and check an archived page shows the notice, the chip lists both versions, and
   the archived reference does not mention anything added since.

## The logo

The mark exists in several cuts that must change together: `public/icon.svg` (the SVG
favicon), `src/assets/icon.svg` (Starlight's logo), `public/icon-small.svg` and the PNGs
made from it (`favicon-16.png`, `favicon-32.png`, `apple-touch-icon.png`, `icon-512.png`),
and `src/components/lockup.svg`, which both headers inline with `?raw`.
