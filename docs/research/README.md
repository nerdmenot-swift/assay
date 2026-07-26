# Research

Seven passes, each written against primary sources — repositories cloned and read at named
paths and line numbers, papers, maintainers' own benchmark output. Each file ends with a
**"do not assert these"** section listing what it could *not* verify. That section is the most
important part of each file.

| file | scope |
|---|---|
| `cross-platform-audit.md` | what actually works on Linux/Windows/Android/Wasm, and the 15 API consequences |
| `perf-state-of-the-art.md` | simdjson, yyjson, serde_json, sonic-rs, simd-json — the measured numbers |
| `perf-swift-libraries.md` | Foundation, ZippyJSON, IkigaJSON, Yams, XMLCoder, Ananda |
| `perf-swift-codegen.md` | ARC, specialization, bounds checks, Span, what `-O` will and won't do |
| `perf-simd-and-c.md` | Builtin intrinsics, per-function targeting, vendoring C, the safety boundary |
| `perf-dispatch-and-hot-path.md` | field dispatch, numbers, strings, UTF-8, the error model |
| `perf-allocation-and-benchmarking.md` | allocation strategy, and what a credible speed claim requires |

Two standing cautions. Every figure belongs to someone else's C, C++, Rust or Go — cited as
evidence about *architecture*, not as a prediction about Assay's Swift. And several premises
that were widely believed turned out to be stale; the corrected list is in `CLAUDE.md`.
