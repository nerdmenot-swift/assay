# The documents

The website at [assay.nerdmenot.in](https://assay.nerdmenot.in) is the place to *learn*
Assay: guides, recipes, a page per format, every example generated from the real library.

This directory is the other thing — the reasoning. Why the API has the shape it has, what was
measured, what was tried and thrown away, and which claims are allowed to be made out loud.
If you are reading here rather than there, you probably want an argument rather than a
tutorial.

## Start with one of these

| | what it is for |
|---|---|
| [`EXPERIENCE.md`](EXPERIENCE.md) | The API, and the case for every part of it. Written before the implementation; the table in `../CLAUDE.md` says which parts exist. |
| [`PERFORMANCE.md`](PERFORMANCE.md) | The strategy: what makes a Swift decoder slow, which of it a macro can delete, and the two phases retired without building. |
| [`EFFICIENCY.md`](EFFICIENCY.md) | The ledger. One row per idea, each decided by a counter rather than an opinion, including the ones that lost. |
| [`COMPILE-TIME.md`](COMPILE-TIME.md) | Why build time is a gate here and not a footnote. |

## One feature, in depth

| | |
|---|---|
| [`VALIDATE.md`](VALIDATE.md) | Rules, and `T.validate(_:)` — the seam for a reader that decoded the bytes itself. |
| [`ENCODING.md`](ENCODING.md) | Writing. Round-trip stated as a law, with a closed list of exceptions. |
| [`UNIONS.md`](UNIONS.md) | Tagged and untagged unions, and the four hard questions each one answers. |
| [`ASSAYER.md`](ASSAYER.md) | `Assayer<T>`: a schema with no declaration, for shapes known at run time. |
| [`TOML.md`](TOML.md) | TOML 1.0.0, where all the difficulty is in the redefinition rules. |
| [`PLIST.md`](PLIST.md) | Both plist flavours, and the two amplification attacks no depth limit catches. |
| [`VALUE-MODELS.md`](VALUE-MODELS.md) | Five value models, and why unifying them would lose information. |
| [`CONFORMANCE.md`](CONFORMANCE.md) | What each parser accepts and refuses, and the harness that holds it there. |
| [`STREAMING.md`](STREAMING.md) | Why streaming is out of scope. Written out in full so it stays a decision. |

## Elsewhere in the repository

- [`../Benchmarks/RESULTS.md`](../Benchmarks/RESULTS.md) — every measurement this project has
  taken, in a journal, including the mistakes made taking them. The current numbers are the
  table at the top.
- [`../ROADMAP.md`](../ROADMAP.md) — what is deferred and why, plus the full record of two
  features that were built, measured and then removed.
- [`../CLAUDE.md`](../CLAUDE.md) — the working context: what is built, what is only designed,
  the hard constraints on generated code, and a list of premises that turned out to be false.
- [`../Experiments/`](../Experiments/) — four standalone experiments with their own results.
  The jump-table one settled a fear that turned out to be misplaced.

## `research/`

Seven pre-implementation research passes, ~6,500 lines, each ending in an explicit
"do not assert these" list.

Read them as **archaeology, not documentation.** They were written before anything compiled,
several of their premises have since been measured false, and `CLAUDE.md` keeps the corrected
list. They are here because throwing away the reasoning that produced a design makes the
design look like luck.

## A note on the numbers in here

Every ratio in these documents belongs to one machine, one toolchain, one corpus, and says
so. Where a number inverts across platforms — XML is 2.47× Foundation on macOS and 0.96× on
Linux, where `FoundationXML` is libxml2 — both halves are printed. The honesty rules in
`CLAUDE.md` list the claims this project will not make, and "fastest JSON decoder" is the
first of them.
