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
scripts/extract.ts         builds a Swift program against the real package, runs it,
                           writes src/data/samples.json and two generated pages
scripts/performance.md.tmpl  prose for the performance page; {{TABLE}} is substituted
src/pages/index.astro      the landing page
src/styles/theme.css       tokens + Starlight overrides (docs and landing page share them)
src/styles/home.css        the landing page only
src/components/            Header and PageTitle overrides, theme and ToC toggles
src/content/docs/          start/, guides/, reference/
```

## Nothing on this site is typed by hand

Every error render is the library's real output for the document shown beside it.
`bun run extract` writes a small Swift program, builds it against the package, runs it, and
saves the output — so a message that changes in the library changes here on the next build
rather than drifting silently. The numbers come from the files that hold them:
`Benchmarks/RESULTS.md`, `CHANGELOG.md`, the test target, `IssueCode+Names.swift`.

Two pages are generated in full and should not be edited:

- `src/content/docs/reference/issue-codes.md` — from `Sources/AssayCore/IssueCode+Names.swift`
- `src/content/docs/reference/performance.md` — prose from the template, table from `RESULTS.md`

The generated output is committed, so CI and a fresh clone work without a Swift toolchain.
Without Swift, `extract` says so and keeps what is committed.

## Voice

Second person, present tense, British spelling, short declaratives. Explain the *reason*,
not just the mechanism — and where a thing was measured, say the number. No exclamation
marks, no marketing adjectives, and no claim the repository cannot support: if a number is
platform-specific, the page says which platform.

## Adding a page

1. Write it in `src/content/docs/<section>/<slug>.md` with `title` and `description`.
2. Add its slug to the `sidebar` in `astro.config.mjs` — order is editorial, not
   alphabetical.
3. `bun run astro build` and check the link gate passes.

## Deploying

CI does it on push to `main`. By hand:

```sh
bun run deploy      # needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID
```

## The logo is a placeholder

`public/icon.svg` and `src/components/lockup.svg` are a caret drawn in two minutes.
Replacing them touches nothing else — the header inlines the lockup with `?raw`, and the
favicon and Starlight logo both point at `icon.svg`.
