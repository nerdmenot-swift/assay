# The documents

The website is the place to *learn* Assay: guides, recipes, a page per format, every
example generated from the real library. Its source is in [`../website/`](../website/); it
is not yet published.

This directory is the other thing — the reasoning. Why the API has the shape it has, what was
measured, what was tried and thrown away, and which claims are allowed to be made out loud.
If you are reading here rather than there, you probably want an argument rather than a
tutorial.

## Start with one of these

| | what it is for |
|---|---|
| [`EXPERIENCE.md`](EXPERIENCE.md) | The API, and the case for every part of it. Written before the implementation; the table in `../CLAUDE.md` says which parts exist. |
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

## Elsewhere in the repository

- [`../Benchmarks/RESULTS.md`](../Benchmarks/RESULTS.md) — the current numbers, and how to
  read them: what each comparison is unfair about, and in whose favour.
- [`../ROADMAP.md`](../ROADMAP.md) — what is not built, what is half built, and what was
  decided against.
- [`../CLAUDE.md`](../CLAUDE.md) — the working context: what is built, what is only designed,
  the hard constraints on generated code, and a list of premises that turned out to be false.
- [`../Experiments/`](../Experiments/) — three standalone experiments with their own results:
  the jump-table lowering, the compile-time budget, and the static ARC audit. The last two
  are CI gates.

## A note on the numbers in here

Every ratio in these documents belongs to one machine, one toolchain, one corpus, and says
so. Where a number inverts across platforms — XML is 2.53× Foundation on macOS and 0.96× on
Linux, where `FoundationXML` is libxml2 — both halves are printed. The honesty rules in
`CLAUDE.md` list the claims this project will not make, and "fastest JSON decoder" is the
first of them.
