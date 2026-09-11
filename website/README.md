# The Assay website

[assay.nerdmenot.in](https://assay.nerdmenot.in) — Astro + Starlight, deployed to
Cloudflare Pages.

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
src/pages/index.astro        the landing page
src/styles/theme.css         tokens + Starlight overrides (docs and landing page share them)
src/styles/home.css          the landing page only
src/components/              Header and PageTitle overrides, theme and ToC toggles
src/content/docs/            start/, guides/, formats/, reference/
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
| `reference/performance.md` | `scripts/performance.md.tmpl`, table from `RESULTS.md` |
| `formats/*.md` | `scripts/pages/formats--*.md.tmpl` |
| `recipes/*.md` | `scripts/pages/recipes--*.md.tmpl`, examples from `scripts/cookbook.swift.txt` and `scripts/recipes.swift.txt` |

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
3. `bun run build` (or `bun run astro build` without Swift) and check the link gate passes.
   It checks anchors as well as pages: a reworded heading breaks `#fragment` links silently
   otherwise, and has.

## Deploying

CI does it on push to `main`. By hand:

```sh
bun run deploy      # needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID
```

## The logo is a placeholder

`public/icon.svg` and `src/components/lockup.svg` are a caret drawn in two minutes.
Replacing them touches nothing else — the header inlines the lockup with `?raw`, and the
favicon and Starlight logo both point at `icon.svg`.
