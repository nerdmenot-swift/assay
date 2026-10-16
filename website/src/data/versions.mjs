// Archived documentation versions, newest first, each `{ slug, label }`.
//
// The CURRENT version is not listed here: it is read from CHANGELOG.md's first release
// heading by `scripts/extract.ts`, so no version string is written down twice.
//
// Empty until 1.1 ships. One entry per MINOR series, not per tag (`{ slug: '1-0', label:
// 'v1.0.x' }`): under semver a patch cannot change the API, so a patch's docs are its
// minor's, and the Swift Package Index already keeps every tag's symbol reference. Each
// entry needs its snapshot under `src/content/docs/<slug>/` — the procedure, including the
// `starlight-versions` wiring an archive needs, is "Versions" in website/README.md.
export const archived = []
