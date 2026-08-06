# Security policy

Assay parses untrusted input by design. Its security posture is structural rather than
configurational, and it is testable:

- **XXE is refused by construction.** The XML parser has no code path that can fetch an
  external entity or DTD — `SYSTEM`/`PUBLIC` identifiers are recognised so they can be
  refused, and the refusal is a warning you can observe (`xml_external_entity_ignored`).
  This is also why `parse(_:contentType:accepting:)` makes `accepting:` a required
  parameter: a server must opt in to parsing XML at all.
- **Entity-expansion and alias-expansion bombs are capped by budget**, not by depth alone
  — billion-laughs is flat. YAML alias expansion has a total-node budget, and an alias is
  charged the size of the subtree it expands to rather than one unit: `Node` is a value
  type, so an unbudgeted alias graph is a cheap DAG at parse time that explodes into a
  tree in whatever walks it. (A pre-release audit found exactly that hole — 331 bytes
  reaching 11.4 million nodes with no issue reported — and it is pinned by
  `Tests/AssayTests/AuditRegressionTests.swift`.)
- **Resource limits are first-class**: `Limits(maxIssues:maxDepth:maxBytes:)` bounds
  every parse; depth is checked on entry to every container.
- **Every parser is differentially tested** against an independent implementation
  (JSONSerialization, Yams/libyaml, Foundation XMLParser) and **fuzzed deterministically
  in CI** — mutations and truncations, with any finding reproducible from a fixed seed.
  The class of bug where a parser silently *mis-reads* valid input is treated as a
  security bug here, because it is how validation gets bypassed.

## Known limitations, stated rather than discovered

- **`@Validate(.regex(...))` inherits Swift's regex engine, which backtracks.** The
  pattern is yours, but the *input* is the attacker's, so a pattern with catastrophic
  backtracking is a denial-of-service vector in your schema. Assay does not analyse
  patterns. Prefer the hand-written validators (`.email`, `.url`, `.uuid`, `.hostname`),
  which are linear over bytes by construction, and bound string length with `.max` before
  a regex rule runs.
- **XML internal entity values are not re-expanded.** `<!ENTITY a "&b;">` yields the
  literal text `&b;` rather than resolving `b`. That is a deliberate stopping point
  (it is also what makes the expansion budget trivially sufficient), but it means Assay
  reads a nested-entity document differently from a fully conforming parser. It is
  recorded in `ROADMAP.md`.
- **Decoded values still cost memory proportional to what they retain.** `Limits.maxBytes`
  bounds the input; nothing bounds the output. A schema that declares `[String: RawValue]`
  over a large document keeps the document.

## Reporting a vulnerability

Please **do not open a public issue** for anything you believe is exploitable —
parser crashes and hangs on crafted input, expansion-limit bypasses, any way to make
Assay fetch a URL, or any input the differential oracles would call a mis-read.

Use GitHub's private vulnerability reporting ("Report a vulnerability" under the
Security tab), or email the maintainer address in the commit log. You can expect an
acknowledgement within a week. Please include the input (or a generator for it), the
platform, and the toolchain version; if the fuzzer found it, the seed and iteration
are the perfect reproduction.

Crashes found by fuzzing that are *not* reachable from the public entry points, and
resource exhaustion that stays within the configured `Limits`, are ordinary bugs —
public issues are welcome for those.

## Supported versions

Pre-1.0, only the latest tagged release is supported with fixes.
