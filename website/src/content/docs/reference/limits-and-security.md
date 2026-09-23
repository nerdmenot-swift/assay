---
title: Limits and security
description: What bounds a parse, what is refused by construction, and the limitations stated rather than discovered.
---

Assay parses untrusted input by design. The posture is structural rather than
configurational — most of it you get without asking.

## Limits

```swift
Limits(maxIssues: 100, maxDepth: 64, maxBytes: 64 << 20)     // the defaults

try Config.parse(json: bytes, limits: Limits(maxDepth: 16, maxBytes: 1 << 20))
```

| Limit | Default | What it bounds |
|---|---|---|
| `maxIssues` | 100 | Issues collected. When it fires, `issuesWereTruncated` is `true` |
| `maxDepth` | 64 | Container nesting. Checked on entry to every container |
| `maxBytes` | 64 MB | Input size. Checked before the first byte is read |
| `maxUnionAttempts` | 10,000 | Untagged-union branch attempts, across the document |
| `verboseUnions` | `false` | Keep every branch's issues rather than the closest one's |

`maxIssues` is a memory bound, not a security one — but `issuesWereTruncated` matters for a
different reason: it lets you tell a hundred-of-a-hundred from a hundred-of-ten-thousand
instead of guessing.

## Refused by construction

**XXE.** The XML parser has no code path that can fetch an external entity or DTD.
`SYSTEM` and `PUBLIC` identifiers are recognised *so that they can be refused*, and the
refusal is an observable warning (`xml_external_entity_ignored`) rather than silence.

This is also why `parse(body:contentType:accepting:)` has no default for `accepting:` — a
server must opt in to parsing XML at all. A billion-laughs body offered to a JSON-only
endpoint produces one negotiation issue and never enters a parser.

**No content sniffing, ever.** The format comes from the caller or the `Content-Type`
header, never from the bytes. The one exception is a property list, where `bplist00` picks
between the two encodings of a format you already named.

## Expansion bombs

Billion-laughs is flat — depth alone does not stop it — so the bound is on **total
expansion**, not nesting.

**YAML aliases** are charged the size of the subtree they expand to, not one unit each.
That distinction is load-bearing: `Node` is a value type, so an unbudgeted alias graph is a
cheap DAG at parse time that explodes into a tree in whatever walks it. A pre-release audit
found exactly that hole — 331 bytes reaching 11.4 million nodes with nothing reported —
and it is now pinned by a regression test.

**XML entities** are bounded by *ratio*: 32× the input with a 64 KB floor. The absolute
figure was the bug there once. A flat 8 MB cap sounds generous and the classic bomb walks
straight through it: 290 bytes to 1,000,000 is comfortably under eight megabytes. The
amplification is the attack; the absolute number is beside the point.

**Binary property lists** carry two attacks that none of the three limits above covers, and
both needed their own answer:

- **Reference cycles.** An array whose element points at the array. The visiting set is
  kept on the reference *path*, not globally — sharing is legal in a plist, and a global
  seen-set would reject valid documents.
- **Shared-object amplification.** Ten arrays of a thousand references each: under a
  kilobyte, 10³⁰ nodes, depth 10 — so `maxDepth` never fires. A node budget does.

**TOML** has no references at all, so there is no expansion attack: the output is at most
the size of the input.

## Gated, not asserted

`AmplificationTests` bounds how much output a small input may buy — nested and repeated
YAML aliases, XML entity expansion, deep nesting in every format, and the quadratic-work
class where output stays small but *cost* explodes. The bounds are on deterministic
quantities, so they hold identically on every machine rather than being timing-sensitive.

Every parser is also differentially tested against an independent implementation —
`JSONSerialization`, Yams/libyaml, Foundation's `XMLParser`, toml++, and TOML against the
official `toml-test` suite (710/710) — and fuzzed deterministically in CI, with any finding
reproducible from a fixed seed.

A parser that silently **mis-reads** valid input is treated as a security bug here, not a
correctness one, because it is how validation gets bypassed.

## Known limitations

Stated rather than discovered.

**`.regex` inherits Swift's backtracking engine.** The pattern is yours; the *input* is the
attacker's. A pattern with catastrophic backtracking is a denial-of-service vector in your
schema, and Assay does not analyse patterns. Prefer the hand-written validators — `.email`,
`.url`, `.uuid`, `.hostname` are linear over bytes by construction — and bound the length
with `.max` before a regex rule runs.

**XML internal entity values are not re-expanded.** `<!ENTITY a "&b;">` yields the literal
text `&b;`. A deliberate stopping point rather than an oversight.

**Duplicate keys are last-wins**, matching `JSONSerialization` and most of the ecosystem. If
you need duplicates rejected, that is a policy question with its own tradeoffs and it is not
currently exposed.

## Reporting

Security issues go to the address in [`SECURITY.md`](https://github.com/nerdmenot-swift/assay/blob/main/SECURITY.md)
in the repository, not to the public issue tracker.
