# Security policy

Assay parses untrusted input by design. Its security posture is structural rather than
configurational, and it is testable:

- **XXE is refused by construction.** The XML parser has no code path that can fetch an
  external entity or DTD — `SYSTEM`/`PUBLIC` identifiers are recognised so they can be
  refused, and the refusal is a warning you can observe (`xml_external_entity_ignored`).
  This is also why `parse(_:contentType:accepting:)` makes `accepting:` a required
  parameter: a server must opt in to parsing XML at all.
- **Entity-expansion and alias-expansion bombs are capped by budget**, not by depth alone
  — billion-laughs is flat. YAML alias expansion has a total-node budget for the same
  reason.
- **Resource limits are first-class**: `Limits(maxIssues:maxDepth:maxBytes:)` bounds
  every parse; depth is checked on entry to every container.
- **Every parser is differentially tested** against an independent implementation
  (JSONSerialization, Yams/libyaml, Foundation XMLParser) and **fuzzed deterministically
  in CI** — mutations and truncations, with any finding reproducible from a fixed seed.
  The class of bug where a parser silently *mis-reads* valid input is treated as a
  security bug here, because it is how validation gets bypassed.

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
