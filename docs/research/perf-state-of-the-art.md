# State of the Art: High-Performance Structured-Data Parsing (2026)

Research conducted for **Assay** (Swift, macro-driven, multi-format decoder + validator).

**Environment caveat:** no Swift/C/Rust toolchain was available. **Nothing here was compiled or
benchmarked by me.** Every claim is tagged:

- **VERIFIED** — I read the actual source at the cited `file:line`, or the number is a primary
  published measurement (vendor benchmark repo, paper, in-repo results file).
- **SELF-MEASURED** — I computed it in this environment from a corpus file present on disk
  (only applies to corpus statistics, not timings).
- **UNVERIFIED** — inference, blog post, or secondhand.

Repos cloned to `/home/claude/research/`: `simdjson`, `yyjson`, `json_benchmark_results`,
`sonic-rs`, `serde/json`, `simd-json`, `sonic-cpp`, `rapidyaml`, `libfyaml`, `libyaml`, `pugixml`,
`swift-foundation`, `Yams`, `Fuzi`, `XMLCoder`, `AEXML`, `SWXMLHash`, `ZippyJSON`, `ReerJSON`.

---

## 0. Executive summary of the numbers

The single most important primary dataset is **`simdjson/json_benchmark_results`** — Google
Benchmark output with hardware counters, run by the simdjson maintainers, benchmarking *real
use-the-data scenarios* rather than "parse and throw away". It is the only public dataset I found
that measures simdjson DOM, simdjson On-Demand, and yyjson **on the same machine, same compiler,
same workload, with instruction and branch-miss counts.**

**VERIFIED**, extracted from
`/home/claude/research/json_benchmark_results/v0.8.0/skylake-clang11.json`
(Skylake, 4.0 GHz, clang 11, simdjson v0.8.0, dated 2021-01-25; L1d 32 KB, L2 256 KB, L3 8 MB;
CPU scaling disabled). Corpus for the tweet benchmarks is `twitter.json`, 631,515 bytes.

| benchmark | parser | GB/s | ins/byte | cyc/byte | branch misses | derived IPC |
|---|---|---|---|---|---|---|
| partial_tweets | simdjson_dom | 2.29 | 4.72 | 1.612 | 3,558 | 2.93 |
| partial_tweets | **simdjson_ondemand** | **3.15** | 3.59 | 1.171 | 2,141 | 3.07 |
| partial_tweets | yyjson | 1.76 | **4.62** | 2.094 | 9,848 | 2.21 |
| partial_tweets | yyjson_insitu | 2.00 | 4.62 | 1.837 | 7,049 | 2.51 |
| partial_tweets | sajson | 1.06 | 9.31 | 3.471 | 10,098 | 2.68 |
| partial_tweets | rapidjson | 0.29 | 34.67 | 12.803 | 29,651 | 2.71 |
| partial_tweets | nlohmann_json | 0.08 | 127.16 | 48.271 | 150,200 | 2.63 |
| distinct_user_id | simdjson_dom / ondemand / yyjson | 2.39 / **4.13** / 1.88 | 4.62 / 2.98 / 4.56 | 1.542 / 0.893 / 1.966 | — | — |
| find_tweet | simdjson_dom / ondemand / yyjson | 2.52 / **5.87** / 1.85 | 4.49 / 2.18 / 4.46 | 1.468 / 0.629 / 1.993 | — | — |
| top_tweet | simdjson_dom / ondemand / yyjson | 2.45 / **4.23** / 1.82 | 4.54 / 3.02 / 4.50 | 1.506 / 0.873 / 2.032 | — | — |
| large_random (46 MB, all floats, **all fields used**) | simdjson_dom / ondemand / yyjson | 0.52 / **0.70** / 0.37 | 22.58 / 14.61 / 18.60 | 7.150 / 5.239 / 7.392 | — | — |
| kostya (137 MB, floats, skip 1 field) | simdjson_dom / ondemand / yyjson | 1.49 / **2.25** / 0.78 | 7.17 / 4.74 / 7.10 | 2.472 / 1.636 / 3.321 | — | — |

IPC column is my arithmetic on the VERIFIED ins/byte and cyc/byte columns.

**And the ARM run** (`v0.8.0/ampere-clang11.json`, Ampere Altra / Neoverse N1, 3.3 GHz, clang 11) —
this is the row that matters most for Assay, because Assay's target is Apple Silicon and ARM Linux
servers. **VERIFIED:**

| benchmark | simdjson_dom | simdjson_ondemand | yyjson | yyjson_insitu |
|---|---|---|---|---|
| partial_tweets | 0.40 | 0.60 | 0.60 | **0.62** |
| distinct_user_id | 0.41 | 0.61 | 0.60 | **0.64** |
| find_tweet | 0.42 | **0.70** | 0.63 | 0.66 |
| top_tweet | 0.41 | 0.61 | 0.62 | **0.65** |
| large_random | 0.15 | 0.23 | 0.23 | 0.23 |
| kostya | 0.36 | **0.54** | 0.48 | 0.51 |

**On ARM, scalar C yyjson meets or beats simdjson's SIMD On-Demand in 3 of 6 benchmarks and beats
simdjson's SIMD DOM in all 6.** This is the load-bearing fact of this whole document.

---

## 1. simdjson

Source: `github.com/simdjson/simdjson`, cloned at HEAD (2026-07).
Paper: Langdale & Lemire, *Parsing Gigabytes of JSON per Second*, arXiv:1902.08318, VLDB Journal.

### 1.1 Stage 1: structural indexing

**VERIFIED.** Stage 1 reads the document in 64-byte blocks (or 128 in two 64-byte halves,
`src/generic/stage1/json_structural_indexer.h:221-236`) and produces a flat `uint32_t[]` of byte
offsets of every *pseudo-structural character*. It does four things, all as 64-bit bitmasks:

1. **Escape resolution.** `json_escape_scanner` computes which bytes are escaped, handling
   `\\\\\"` runs correctly across block boundaries
   (`src/generic/stage1/json_string_scanner.h:64-65`).
2. **In-string mask via carry-less multiply.**
   `const uint64_t in_string = prefix_xor(quote) ^ prev_in_string;`
   (`src/generic/stage1/json_string_scanner.h:71`). `prefix_xor` is a `clmul` against all-ones on
   x86 — this is the famous trick: a 64-way parallel prefix-XOR that turns "quote positions" into
   "inside-string mask" in one instruction. Carry across blocks is a sign-extended shift
   (`:75`).
3. **Character classification** via `vpshufb` table lookup —
   `json_character_block::classify` at `src/haswell.cpp:43-46` uses a 16-entry nibble table
   (`repeat_16(' ', 100, 100, 100, 17, 100, 113, 2, 100, '\t', '\n', 112, 100, '\r', 100, 100)`)
   to produce `_whitespace` and `_op` masks. `scalar()` is defined by negation:
   `~(op() | whitespace())` (`src/generic/json_character_block.h:17`).
4. **Structural start** = `potential_structural_start() & ~_string.string_tail()`
   (`src/generic/stage1/json_scanner.h:44`). Scalar starts are found *by negation* — anything
   followed by a non-quote scalar is not a start; whatever remains is
   (`json_scanner.h:26-30`, `:135-140`).

**UTF-8 validation is fused into stage 1** as a separate SIMD pass over the same blocks
(`src/generic/stage1/utf8_lookup4_algorithm.h`). **VERIFIED** — this means simdjson validates
UTF-8 across the *entire* document even if you only read one field.

**Bit-to-index extraction is NOT SIMD.** `bit_indexer::write`
(`src/generic/stage1/json_structural_indexer.h:92-121`) is a scalar unrolled loop over
`trailing_zeroes` + `clear_lowest_bit` (x86) or `leading_zeroes` + `reverse_bits` (ARM,
`:44-48`), writing 4 indexes per step, unconditionally, up to 24, then a real loop. It
deliberately over-writes past the valid count and fixes up with `tail += cnt`. **This is
branchless scalar code, not vector code, and it is a significant fraction of stage 1's cost.**
The comment at `:97-99` explicitly notes the `if (bits == 0) return;` branch is sometimes a
misprediction cost and sometimes a huge win — i.e. this is the branchiest part of stage 1.

### 1.2 Why stage 1 is separable

**VERIFIED (design), from the paper §"Stage 1":** stage 1 needs no parser state whatsoever — no
depth stack, no type knowledge, no lookahead beyond one block. It is a pure streaming transform
`bytes → offsets`. That is exactly why it vectorizes: the answer for byte *i* depends only on a
64-byte window plus two carry bits. Stage 2 is inherently serial (it maintains a depth stack) and
is **entirely scalar** — `src/generic/stage2/tape_builder.h` and `json_iterator.h` contain no
intrinsics.

**This is the crux:** simdjson vectorizes the ~40% of the work that is a stateless byte transform,
and leaves the rest scalar. It does not "parse JSON with SIMD"; it *indexes* JSON with SIMD.

### 1.3 Stage 2 and the tape

**VERIFIED** from `doc/tape.md`. The tape is a `uint64_t[]` in document order. Tag in the top 8
bits (`'{'`, `'['`, `'"'`, `'l'`, `'u'`, `'d'`, `'t'`, `'f'`, `'n'`, `'r'`, `'Z'`), 56-bit payload.
Containers store the tape index *just past their scope*, so skipping a subtree is a single
indexed jump — no pointer chasing, no linked list. Numbers are stored inline (2 tape words) for
locality — `doc/tape.md`: *"We store numbers of the main tape because we believe that locality of
reference is helpful for performance."* Strings go on a separate string tape with a 4-byte
length prefix and a NUL terminator.

**Critical implementation detail: simdjson always copies strings.**
`parse_string` (`src/generic/stage2/stringparsing.h:151-192`) unconditionally calls
`b.copy_and_find(src, dst)` in a loop, copying `BYTES_PROCESSED` (32 on Haswell) bytes at a time
from the input into the parser's `string_buf`, *even when the string contains no escapes*.
**VERIFIED.** yyjson and Foundation both avoid this. This is a real algorithmic disadvantage for
simdjson that SIMD papers over.

### 1.4 On-Demand

**VERIFIED (`include/simdjson/generic/ondemand/parser-inl.h:54-68`): On-Demand still runs the
full stage 1 over the whole document.** `parser::iterate` calls
`implementation->stage1(..., stage1_mode::regular)` before returning anything. So On-Demand is
*not* lazy end-to-end: you always pay full structural indexing + full UTF-8 validation. What it
skips is stage 2 — no tape is built, no values are materialized, no strings are copied until you
ask.

The forward-only iterator design is documented in `doc/ondemand_design.md`:
- Streaming, forward-only, single index shared across nested loops.
- **Use-specific parsing**: `doc["x"].get_uint64()` runs a *dedicated* uint64 parser; there is no
  type-dispatch switch. The doc calls the alternative *"type blindness"*.
- **Validate what you use** — only the values you touch, plus the structure leading to them.

**Field lookup is a linear scan over raw source bytes with wraparound.** **VERIFIED:**
`value_iterator::find_field_unordered_raw`
(`include/simdjson/generic/ondemand/value_iterator-inl.h:229`, loop at `:325-340`) scans forward
from the current position to the end of the object, then wraps to the beginning, comparing with
`actual_key.unsafe_is_equal(key)` — a raw byte compare against the *un-unescaped* source key.
**No hashing. No dictionary. No perfect hash.** The world's fastest JSON reader does linear
`memcmp` on field names.

### 1.5 Measured On-Demand advantage over DOM

**VERIFIED** (derived from §0 table, skylake-clang11):

| workload | DOM GB/s | On-Demand GB/s | speedup | ins/byte reduction |
|---|---|---|---|---|
| large_random — **every field used** | 0.52 | 0.70 | **1.35×** | 22.58 → 14.61 (−35%) |
| kostya — skip 1 of 4 fields | 1.49 | 2.25 | 1.51× | 7.17 → 4.74 (−34%) |
| partial_tweets — skip most fields | 2.29 | 3.15 | 1.38× | 4.72 → 3.59 (−24%) |
| top_tweet — lazy | 2.45 | 4.23 | 1.73× | 4.54 → 3.02 (−34%) |
| distinct_user_id — deep nesting, skip most | 2.39 | 4.13 | 1.73× | 4.62 → 2.98 (−36%) |
| find_tweet — stop early | 2.52 | 5.87 | **2.33×** | 4.49 → 2.18 (−51%) |

**The most important row is `large_random`.** Every field is consumed; nothing is skipped. On-Demand
is still **1.35× faster and uses 35% fewer instructions**. That delta is *purely* the cost of
building and re-walking an intermediate representation. It is not a "you skipped work" win.

**Interpretation (UNVERIFIED, mine):** for a direct-to-struct decoder that reads every declared
field, the achievable win over DOM-then-walk is **~1.3–1.5×**, not 5×. The 2.3× `find_tweet`
number requires early exit, which a `Decodable`-shaped API cannot generally do.

### 1.6 Published headline figures and what they actually cover

- `README.md:16` **VERIFIED as published**: "Minify JSON at 6 GB/s, validate UTF-8 at 13 GB/s,
  NDJSON at 3.5 GB/s." Note these are *not* parse figures. Minify and UTF-8 validation are pure
  stage-1-class work. The 13 GB/s UTF-8 number is the strongest evidence that SIMD is
  overwhelmingly effective at stateless byte transforms and says nothing about parsing.
- `README.md:12-13`: "4x faster than RapidJSON and 25x faster than JSON for Modern C++" —
  **VERIFIED as published**, and **VERIFIED as corroborated** by the benchmark data
  (2.29/0.29 = 7.9× vs rapidjson on partial_tweets; 2.29/0.08 = 28× vs nlohmann).
- `README.md:136`: "three-quarters less instructions than RapidJSON" — **VERIFIED**
  (4.72 vs 34.67 ins/byte is actually 86% less).
- Rome/growing/gbps figures are PNG images; I could not extract numbers. Hardware stated in
  `README.md:140`: Intel Skylake 3.4 GHz, GCC 10 `-O3`.

### 1.7 SIMD vs structure — the decisive decomposition

Take `partial_tweets` on Skylake (**VERIFIED** counters):

| | ins/byte | cyc/byte | IPC |
|---|---|---|---|
| rapidjson (scalar, well-known, tree-building) | 34.67 | 12.803 | 2.71 |
| yyjson (scalar C, no SIMD) | **4.62** | 2.094 | 2.21 |
| simdjson DOM (AVX2) | **4.72** | 1.612 | 2.93 |
| simdjson On-Demand (AVX2) | 3.59 | 1.171 | 3.07 |

**yyjson executes fewer instructions per byte than simdjson's DOM parser, with zero SIMD.**
The 7.5× instruction-count gap that simdjson advertises is against RapidJSON, and RapidJSON is
simply a badly-structured parser by 2026 standards. Against a well-structured scalar parser, the
instruction-count advantage of SIMD is **zero**.

Where simdjson DOM wins on Skylake is **IPC: 2.93 vs 2.21**, a 33% gap, which tracks the
branch-miss gap (3,558 vs 9,848, a 2.8× difference). The SIMD structural index removes
data-dependent branches; it does not remove work.

Corroboration: on Ampere/NEON (128-bit vectors instead of 256-bit), simdjson DOM loses to yyjson
outright — 0.40 vs 0.60 GB/s on partial_tweets — and its ins/byte rises to 6.25 while yyjson's
rises only to 5.18. **VERIFIED** from `ampere-clang11.json`.

**Conclusion (mine, but tightly grounded): of simdjson's advantage over a naive parser, ~85% is
structural (single pass, flat tape, no allocation, no pointer chasing, no type dispatch,
branchless bit tricks) and ~15% is vector width. On 128-bit-vector ARM the vector-width term goes
to approximately zero.** A pure-Swift implementation with the right structure can capture nearly
all of it.

---

## 2. yyjson — the most important data point

Source: `github.com/ibireme/yyjson`. Single `src/yyjson.c` (11,388 lines) + `src/yyjson.h`
(8,455 lines). `README.md:14`: *"Portable: complies with ANSI C (C89), **no explicit SIMD**."*
**VERIFIED** (I grepped; the reader contains no intrinsics).

### 2.1 Published numbers

`README.md:36-60`, **VERIFIED as published** (parse GB/s on `twitter.json`, DOM API only):

| | AWS EC2 AMD EPYC 7R32, gcc 9.3 | Apple A14 (iPhone 12 Pro), clang 12 |
|---|---|---|
| yyjson (insitu) | **1.80** | **3.51** |
| yyjson | 1.72 | 2.39 |
| simdjson | 1.52 | 2.19 |
| sajson | 1.16 | 1.74 |
| rapidjson (insitu) | 0.77 | 0.75 |
| cjson | 0.32 | 0.48 |
| jansson | 0.05 | 0.09 |

**On Apple A14, scalar yyjson in-situ is 1.60× faster than simdjson.** Author's own caveat at
`README.md:30-31`, **VERIFIED**: *"The simdjson's new On Demand API is faster if most JSON fields
are known at compile-time. This benchmark project only checks the DOM API."* — an honest and
important disclaimer, and consistent with the independent simdjson-run data in §0.

`README.md:73-78` states what yyjson depends on: *"a modern processor with high instruction level
parallelism, excellent branch predictor, low penalty for misaligned memory access"* — i.e. yyjson
trades branchlessness for ILP and bets on the branch predictor. **Apple Silicon is precisely the
hardware where that bet pays best.**

### 2.2 Why scalar C wins — the actual techniques

All **VERIFIED** by reading `src/yyjson.c`.

**(a) Two whole-parser specializations chosen by a 2-byte heuristic.**
`yyjson.c:6314-6319`:
```c
if (char_is_space(cur[1]) && char_is_space(cur[2])) {
    doc = read_root_pretty(hdr, cur, eof, alc, flg, err);
} else {
    doc = read_root_minify(hdr, cur, eof, alc, flg, err);
}
```
`read_root_pretty` (`:5776`) and `read_root_minify` (`:5349`) are two ~400-line copies of the same
FSM, each with whitespace handling specialized in or out. Both are `static_inline`, so the
compiler specializes each fully. This is manual profile-guided specialization: **eliminating the
"is this whitespace?" branch from the minified path removes a mispredictable branch per token.**

**(b) Flags are runtime bits but every check is `unlikely()`-annotated.**
`yyjson.c:3119-3129`:
```c
#define has_flg(_flg) unlikely(has_rflag(flg, YYJSON_READ_##_flg, 0))
#define has_allow(_flg) unlikely(has_rflag(flg, YYJSON_READ_ALLOW_##_flg, 1))
```
Every optional-feature check (comments, trailing commas, NaN, single quotes, JSON5, bignum) is
marked cold, so the compiler lays them out off the hot path. Compile-time kill switches
(`YYJSON_DISABLE_NON_STANDARD`, `YYJSON_DISABLE_UTF8_VALIDATION`, `YYJSON_DISABLE_FAST_FP_CONV`)
constant-fold them away entirely. **This is the "read/write flag design" — it makes a
feature-rich parser cost the same as a minimal one on the hot path.**

**(c) 16× manually unrolled, goto-driven scan loops.** `yyjson.c:4799-4838`:
```c
#define expr_jump(i) \
    if (likely(char_is_ascii_skip(src[i]))) {} \
    else goto skip_ascii_stop##i;
    repeat16_incr(expr_jump)
    src += 16;
    goto skip_ascii;
    repeat16_incr(expr_stop)
```
With a source comment at `:4794-4798` explaining *"Some compiler may not generate instructions as
expected, so we rewrite it with explicit goto statements"* and a godbolt link. Character
classification is a 256-entry table (`char_table1/2/3`, bit flags at `:749-768`, accessors at
`:876-962`).

**This 16-wide unrolled table-lookup loop is the scalar analogue of a 16-byte SIMD compare.** It
gets most of the ILP without any intrinsics, and it is fully portable. **It is directly
translatable to Swift.**

**(d) Zero string allocation for escape-free strings, with in-place NUL termination.**
`yyjson.c:4840-4849`:
```c
if (likely(*src == quo)) {
    val->tag = ((u64)(src - hdr) << YYJSON_TAG_BIT) | YYJSON_TYPE_STR |
               (quo == '"' ? YYJSON_SUBTYPE_NOESC : 0);
    val->uni.str = (const char *)hdr;
    *src = '\0';
```
Length goes in the tag; the pointer points into the input buffer; the closing quote is overwritten
with NUL. **This is the pugixml technique applied to JSON.** Only escaped strings take the
`copy_escape` path (`:4795`, `:5165`). simdjson, by contrast, copies every string
(§1.3). **This is a genuine algorithmic advantage of yyjson over simdjson.**

**(e) UTF-8 validation fused into the string scan.** `yyjson.c:5145-5160, 5200-5225` — validation
is `byte_load_4` + `is_utf8_seq2/3/4` shape tests inside the same loop that copies. **No separate
pass.** Compare simdjson: a full separate SIMD pass over the whole document. For a decoder that
reads *some* fields, yyjson's approach validates less; for one that reads all, simdjson's
vectorized pass is probably cheaper. Trade-off, not a clear win either way. (**UNVERIFIED** which
is better in Assay's regime.)

**(f) Number parsing: 18-way unrolled digit ingestion with a computed-goto FSM.**
`yyjson.c:3991-4045`:
```c
#define expr_intg(i) \
    if (likely((num = (u64)(cur[i] - (u8)'0')) <= 9)) sig = num + sig * 10; \
    else { goto digi_sepr_##i; }
    repeat_in_1_18(expr_intg)
```
Eighteen fully unrolled digit steps, each with an exit label. `digi_sepr_i`, `digi_frac_i`,
`digi_stop_i` are parallel 18-way label families. Fast paths return an `i64` without ever touching
floating point. Doubles use yyjson's own Eisel-Lemire-class routine
(`pow10_table_get_sig`/`pow10_table_get_exp` at `:1911-1925`, guarded by
`YYJSON_DISABLE_FAST_FP_CONV` at `:3596`). **VERIFIED.**

**(g) Immutable/mutable doc split.** `doc/DataStructure.md`, **VERIFIED**:
- `yyjson_val` = `{ uint64_t tag; union {...} uni; }` — exactly **16 bytes**, trivially copyable.
- Type in low 8 bits of `tag`, size/length in high 56 bits.
- **All values in one contiguous array in document order**; all strings in one contiguous area.
- *"The `object` and `array` containers store their own memory usage, allowing easy traversal of
  the child values."* → subtree skip is pointer arithmetic on a flat array. **No pointer chasing.**
- The *mutable* doc (`yyjson_mut_val`, +`next` pointer, circular linked list) is a separate type
  used only for building. **The read path never pays for mutability.**

This is a tape by another name — 16-byte fixed cells instead of simdjson's 8-byte variable cells.
The allocator is a single `malloc` sized by a heuristic
(`alc_len = hdr_len + dat_len / YYJSON_READER_ESTIMATED_MINIFY_RATIO + 4`, `:5411`) with 1.5×
geometric `realloc` growth in the `val_incr()` macro (`:5367-5382`). **One allocation for the
whole document in the common case.**

### 2.3 The conclusion this forces

**If well-structured scalar C matches or beats SIMD C on the same workload — and it does, on
Skylake by instruction count and on ARM outright — then the SIMD question is a second-order
concern for Assay.** The techniques that actually produce yyjson's speed are:

1. one allocation, flat array, document order;
2. no string copies for the escape-free case;
3. 16× unrolled table-driven scanning;
4. specialization of the whole parser on the hot configuration;
5. cold-marking every optional feature;
6. an aggressive fully-unrolled integer fast path.

**All six are expressible in Swift with `UnsafeRawBufferPointer`, `@inline(__always)`,
`_fastPath`/`_slowPath`, static tables, and macro-generated specialization.** None require
intrinsics.

---

## 3. sonic-rs, simd-json, serde_json

Researched by a delegated agent reading the actual sources; findings reproduced with their
VERIFIED/UNVERIFIED tags intact.

### 3.1 serde_json — the closest analogue to Assay

**VERIFIED: no intermediate DOM on the derive path.** `serde_derive` emits a `Visitor` whose
`visit_map` loop calls `MapAccess::next_key::<__Field>()` then `MapAccess::next_value::<FieldTy>()`
straight into `Option<FieldTy>` locals
(`serde/serde_derive/src/de/struct_.rs:248, :299, :304`). Unknown keys go to `IgnoredAny`
(`:289`), skipped in place. There is a true in-place path via `InPlaceSeed` (`:552`).

**VERIFIED, and directly relevant: field dispatch is a plain Rust `match` on the key string.**
`serde_derive/src/de/identifier.rs:194-218` emits arms `"field_name" => Ok(__Field::__field0)`
into `visit_str` (`:448`), `visit_bytes` (`:461`), and `visit_borrowed_str` (`:410`). **No PHF, no
perfect hash, no explicit length switch.** It hands the compiler a string match and trusts codegen.
(**UNVERIFIED** what LLVM actually lowers this to.)

**VERIFIED: the one place serde_json buffers is `#[serde(flatten)]`.** With any flattened field,
codegen switches to collecting every unmatched key/value into `Vec<Option<(Content, Content)>>`
(`struct_.rs:225-235, :277-283`) — a real intermediate DOM. Internally-tagged and untagged enums
do the same. **This is the single biggest hidden cost in serde struct deserialization, and Assay
should treat any equivalent feature as a performance cliff and document it as one.**

**VERIFIED: strings borrow when unescaped.** `serde_json/src/read.rs:494-538` returns
`Reference::Borrowed(&slice[start..index])` when no escape was seen (`:513-519`), spilling to
`scratch` only on `\\` (`:520-524`). The delimiter scan is **SWAR, not SIMD** — a Mycroft-style
`u64` word trick (`read.rs:455-481`).

**VERIFIED and very relevant: UTF-8 validation timing costs 1.65×.** `SliceRead::parse_str` calls
`str::from_utf8` **per string** (`read.rs:588` → `:868-870`); `StrRead::parse_str` uses
`from_utf8_unchecked` because the input was already `&str` (`:709-716`). This is precisely why
`from_str` beats `from_slice` in every benchmark. On twitter.json the gap is
**2.2895 ms vs 1.3842 ms = 1.65×**.

**VERIFIED: serde_json does not use Eisel-Lemire by default.** Integers accumulate in `u64` with
overflow check (`de.rs:479-500`); floats go to `lexical::parse_concise_float`
(`de.rs:624-629`), a Bellerophon-style extended-80-bit path — but **only** under
`feature = "float_roundtrip"`. The default build uses naive `significand as f64` scaling
(`de.rs:639-645`): faster, not always correctly rounded.

### 3.2 sonic-rs

**VERIFIED, and it is the key structural finding: sonic-rs explicitly rejects simdjson's two-stage
design.** `README.md:60`: *"we do not use the two-stage SIMD algorithms from `simd-json`."* There
is no stage-1 index. SIMD is applied pointwise:
- string scanning via `StringBlock` over 32/64-byte vectors (`src/parser.rs:908-1042`);
- container skipping via JSONSki bracket-counting with popcount (`parser.rs:170-200`);
- whitespace skipping via cached non-space bitmaps (`src/util/arch/*`);
- **whole-input UTF-8 validation once up front** via `simdutf8` (`src/util/utf8.rs:6-9`, called
  from `src/reader.rs:175-183`), then `from_utf8_unchecked` everywhere (`parser.rs:783, :794`).

**VERIFIED: no runtime CPU dispatch** — `src/util/arch/mod.rs:1-11` requires `avx2`+`pclmulqdq` at
compile time. Without `-C target-cpu=native` you silently get the scalar fallback.

**VERIFIED: sonic-rs has no derive macro of its own.** It depends on `serde` and implements
`serde::Deserializer` (`src/serde/de.rs:3` header says the code is cloned from serde_json).
`deserialize_struct` → `visitor.visit_map(MapAccess::new(de))` (`:813-840`). **So the field-name
`match` is byte-identical to serde_json's — the entire gain is in the Deserializer internals.**

**VERIFIED: sonic-rs uses Eisel-Lemire.** `sonic-number/src/lemire.rs:1-29` (citing
arXiv:2101.11408), invoked at `sonic-number/src/lib.rs:864, :903` after two fast paths, with SWAR
8-digit ingestion (`swar.rs:31-40`).

**VERIFIED published numbers** (`sonic-rs/README.md:68-127`; Intel Xeon Platinum 8260 @ 2.40 GHz;
note serde_json was run with `float_roundtrip` ON, i.e. its *slow* float path):

*Deserialize into typed struct:*

| corpus | sonic_rs unchecked | sonic_rs from_slice | simd_json | serde_json from_slice | serde_json from_str |
|---|---|---|---|---|---|
| twitter (456 KB) | 707.83 µs | 827.74 µs | 1.0872 ms | 2.2895 ms | 1.3842 ms |
| citm (489 KB) | 1.2467 ms | 1.3671 ms | 2.0970 ms | 2.9870 ms | 2.6079 ms |
| canada (2.0 MB) | 3.8059 ms | 4.0212 ms | 8.0932 ms | 9.3560 ms | 9.2563 ms |

Derived: sonic-rs vs serde_json `from_slice` = 2.77× / 2.18× / 2.33×. Against the **fair**
`from_str` baseline: **1.67× / 1.91× / 2.30×**.

*Parse to DOM* (`README.md:140-178`): twitter 6.8×, citm 4.86×, canada 3.43× vs serde_json.
**Do not quote DOM ratios as struct ratios** — twitter is 6.8× DOM but 2.8× struct. The DOM gap
comes from the bumpalo arena + array-backed (not hashmap) objects (`README.md:132-135`,
`src/value/shared.rs:3-16`, `src/value/node.rs:1247-1248`).

*Lazy get* (`README.md:250-255`, one field from twitter.json): `get_unchecked` 76.766 µs;
validated `get` 434.62 µs (**5.7× cost of validation**); gjson 363.14 µs.

### 3.3 simd-json (Rust port of simdjson) — the cautionary tale

**VERIFIED, `serde-rs/json-benchmark` (i7-6600U, archived May 2024):**

```
serde_json  DOM parse:  canada 320  citm 420  twitter 300 MB/s
serde_json  STRUCT:     canada 580  citm 710  twitter 550 MB/s
simd-json   DOM parse:  canada 380  citm 720  twitter 810 MB/s
simd-json   STRUCT:     canada 580  citm 1220 twitter 1050 MB/s
```

**On canada.json, simd-json's typed-struct path is 580 MB/s — identical to serde_json. Zero
speedup from SIMD.** The reason is architectural and VERIFIED: simd-json builds a full structural
index (`Vec<u32>`, `src/lib.rs:93`, `find_structural_bits` at `:636`), materializes a `Tape`, and
*only then* feeds serde (`src/serde.rs:56-62`). It pays for a DOM it doesn't need.

Also note: `serde_json` STRUCT beats `serde_json` DOM by **1.8× / 1.7× / 1.8×** across the three
corpora. That is a second independent measurement of the direct-to-struct-vs-DOM advantage, and
it is *larger* than simdjson's 1.35× because serde_json's DOM is a `BTreeMap`/`IndexMap` tree
rather than a tape.

---

## 4. DOM vs On-Demand vs direct-to-struct — the decisive question

Three independent measurements of the same architectural question:

| source | comparison | speedup | notes |
|---|---|---|---|
| simdjson `json_benchmark_results` v0.8.0 skylake | tape DOM → On-Demand, **all fields used** | **1.35×** | VERIFIED; `large_random` |
| simdjson same | tape DOM → On-Demand, most fields skipped | 1.38–1.73× | VERIFIED |
| simdjson same | tape DOM → On-Demand, early exit | 2.33× | VERIFIED; `find_tweet` |
| serde json-benchmark | `serde_json` DOM → `serde_json` struct | **1.7–1.8×** | VERIFIED; DOM is a map tree |
| sonic-rs README | DOM ratio vs struct ratio, same library | 6.8× vs 2.8× | VERIFIED; shows how much DOM benchmarks mislead |

**Synthesis (mine, UNVERIFIED as a prediction but well-grounded):**

- Against a **flat-tape DOM** (simdjson tape, yyjson `yyjson_val[]`, Foundation `JSONMap`), going
  direct-to-struct is worth **~1.3–1.5×** when you read everything, rising toward **~1.7×** when
  you skip most fields.
- Against a **map/tree DOM** (`[String: Any]`, `BTreeMap`, `NSDictionary`) it is worth **2–7×**,
  because you also delete the hashing, the key `String` allocation, and the pointer chasing.
- **Foundation's `JSONDecoder` is the second kind wearing the first kind's clothes** — see §5.

The corollary for Assay: **the macro-generated direct-to-struct path is worth roughly 1.4× over a
well-built tape, and several × over anything that materializes a dictionary.** The design is
right; the magnitude of the win against a *good* baseline is modest, and against Foundation it is
large.

---

## 5. The Swift baseline: what `Foundation.JSONDecoder` actually does

This is Assay's real competition and its real opportunity. Source read:
`/home/claude/research/swift-foundation/Sources/FoundationEssentials/JSON/`
(`JSONScanner.swift` 1,391 lines, `JSONDecoder.swift` 1,944 lines).

**VERIFIED — the scanner is already tape-like and quite good.** `JSONScanner.swift:20`:
> *"The JSONMap representation of JSON arrays and objects is a sequence of integers that is
> delimited by their starting marker and a shared 'collection end' marker… the map encodes the
> offset in the map array to the next object after the end of the collection."*

`TypeDescriptor` (`:67-78`) has `string [marker, count, sourceByteOffset]`,
`object [marker, nextSiblingOffset, count, …]`, and crucially **`simpleString`** (`:78`) — a
separate tag for escape-free strings, exactly yyjson's `YYJSON_SUBTYPE_NOESC`. Numbers are
recorded as `Region`s into the source and parsed lazily (`:93-99`). So Foundation is:
**eager full-document structural scan → flat Int array with sibling-skip offsets → lazy value
materialization.** Architecturally that *is* simdjson On-Demand's split.

**And then it throws it away in the decoder. VERIFIED, `JSONDecoder.swift:1264-1308`:**
```swift
let dictionary: [String:JSONMap.Value]

static func stringify(objectRegion: ..., ...) throws -> [String:JSONMap.Value] {
    var result = [String:JSONMap.Value]()
    result.reserveCapacity(objectRegion.count / 2)
    var iter = impl.jsonMap.makeObjectIterator(from: objectRegion.startOffset)
    while let (keyValue, value) = iter.next() {
        let key = try impl.unwrapString(from: keyValue, ...)   // allocates a Swift String
        result[key]._setIfNil(to: value)                        // hashes + inserts
    }
    ...
}
init(impl:codingPathNode:region:) { ... self.dictionary = try Self.stringify(...) }
```
**Every `KeyedDecodingContainer` — i.e. every JSON object decoded into a struct — allocates a
Swift `Dictionary`, allocates a Swift `String` for every key in the object, hashes every key, and
inserts it.** Then `getValue(forKey:)` (`:1522`) does a hash lookup per field. For a struct with
*n* declared fields inside an object with *m* keys, that is *m* String allocations + *m* hashes +
*m* inserts + *n* lookups, where the theoretical minimum is *m* raw `memcmp`s against
compile-time-known literals.

**VERIFIED — floats go through `strtod`.** `JSONScanner.swift:1180-1193`:
```swift
extension Double : PrevalidatedJSONNumberBufferConvertible {
    init?(prevalidatedBuffer buffer: BufferView<UInt8>) {
        ... Platform.strtod_clocale(nptr, &endPtr) ...
```
Not Eisel-Lemire, not fast_float — the C library's `strtod`, plus a full-buffer end-pointer check.
Integers do use a hand-written `_parseInteger` (`JSONScanner.swift:1212`).

**Assay's headline opportunity, therefore, is not "beat simdjson". It is: keep Foundation's
already-decent scanner architecture, delete the per-object Dictionary, and replace `strtod`.**
Those two changes alone are, by the §4 evidence, worth multiples — not percentages.

**Existing Swift art (VERIFIED, from `yyjson/README.md:226-228` and clones):**
- **ZippyJSON** (`michaeleisel/ZippyJSON`) — simdjson-backed drop-in `JSONDecoder`.
- **ReerJSON** (`reers/ReerJSON`) — **yyjson**-backed drop-in `JSONDecoder`, actively maintained
  (README references 2026-04 benchmarks). Supports `JSONValue.parseInPlace(consuming: &data)`.
- **Ananda**, **swift-yyjson** — yyjson bindings.
- ReerJSON's benchmark charts are images; **I could not extract numbers.** ReerJSON's README note
  is itself informative and **VERIFIED as published**: *"On older/lower-end chips (e.g. A11),
  yyjson's 'build DOM tree then serialize' approach is bottlenecked by smaller caches and weaker
  branch prediction — exactly the hardware traits yyjson's README states it depends on."*

**Implication (UNVERIFIED, mine): the yyjson-backed Swift decoders still build a full
`yyjson_doc` and then walk it through the `Decodable` protocol. Assay's macro path can skip the
document entirely. That is the ~1.4× of §4, on top of whatever those libraries already gain.**

---

## 6. What actually dominates: the cost breakdown

Evidence for what a small-to-medium API payload's time is spent on.

### 6.1 Number parsing is the biggest single term for number-dense data — VERIFIED

From the §0 table (skylake, simdjson DOM), ins/byte by corpus:

| corpus | character | ins/byte | GB/s |
|---|---|---|---|
| twitter (partial_tweets) | strings, some ints | 4.72 | 2.29 |
| kostya | floats, 4 fields/object | 7.17 | 1.49 |
| large_random | **99% floats** | **22.58** | **0.52** |

**Float-dense JSON costs ~4.8× more instructions per byte than string-dense JSON, and runs ~4.4×
slower.** Corroborated by simdjson's own `doc/performance.md`:
> *"it is not possible, in general, to parse streams of numbers at gigabytes per second using a
> single core… you might be limited to a few hundred megabytes per second if your JSON documents
> are densely packed with floating-point values."* — **VERIFIED (in-repo doc).**

And by Lemire in simdjson issue #70, **VERIFIED as published**:
> *"Many files are mostly made of numbers: canada, mesh.pretty, mesh, random and numbers: in such
> instances, we see lower JSON parsing speeds due to the high cost of number parsing."*
> …*"A few hundred MB/s is all you can hope for in general"* for number-heavy JSON.

Also VERIFIED from that issue: **integers are much cheaper than floats.** `doc/performance.md`:
*"you should favor integer values written without a decimal point, as it simpler and faster to
parse."* yyjson reflects this — its 18-way unrolled integer path returns without touching FP
(`yyjson.c:3991-4010`).

### 6.2 UTF-8 validation is cheap if vectorized, and cheap if fused — VERIFIED

simdjson validates UTF-8 at **13 GB/s** standalone (`README.md:16`). At a parse speed of 2–3 GB/s
that is a 15–20% tax at most, and it is fused into stage 1 so it is nearly free. But: **serde_json's
per-string `str::from_utf8` costs 1.65× on twitter.json** (`from_slice` 2.2895 ms vs `from_str`
1.3842 ms, VERIFIED). The lesson is *not* "UTF-8 validation is expensive" — it is **"per-string
UTF-8 validation is expensive; one whole-buffer pass is cheap."** sonic-rs made exactly this
change (`src/reader.rs:175-183`).

### 6.3 String copying is avoidable and worth avoiding — VERIFIED

- simdjson: copies every string unconditionally (`stringparsing.h:151-192`).
- yyjson: zero-copy for escape-free strings, NUL written in place (`yyjson.c:4840-4849`).
- serde_json: `Reference::Borrowed` for escape-free (`read.rs:513-519`).
- Foundation: `simpleString` tag distinguishes them (`JSONScanner.swift:78`).

Three of four fastest implementations special-case the escape-free string. The measured value:
yyjson insitu vs yyjson non-insitu on skylake partial_tweets is **2.00 vs 1.76 GB/s = 1.14×**
(VERIFIED) — but that measures only the *input buffer copy*, not the per-string copy, which yyjson
avoids in both modes. **UNVERIFIED**: the per-string copy avoidance is probably a larger term than
1.14× for string-dense payloads, but I have no measurement isolating it.

### 6.4 Allocation

- yyjson: **one** `malloc` per document, geometric realloc (`yyjson.c:5367-5412`). VERIFIED.
- simdjson: reusable parser, buffers retained across parses; `doc/performance.md` devotes a whole
  section to "reusing the parser for maximum efficiency" and notes allocation of a 100 MB buffer
  can run *slower than parsing it* (~1.4 GB/s). VERIFIED.
- sonic-rs: bumpalo arena for the DOM only (`src/value/shared.rs:3-16`). VERIFIED.
- Foundation: `[String: JSONMap.Value]` **per object**, `String` per key. VERIFIED.

**For a 1–100 KB payload, allocation count is a first-order term** because the parse itself is
only microseconds. This is where the published GB/s literature is least helpful and where Assay
should focus.

### 6.5 Field dispatch

**VERIFIED, and the answer is boring:** the two fastest schema-aware readers in the world both use
linear byte comparison against compile-time-known keys —
simdjson On-Demand (`value_iterator-inl.h:325-340`, `unsafe_is_equal`) and serde_derive
(`identifier.rs:194-218`, a `match` on `&str`). **Neither uses a perfect hash.**

**UNVERIFIED (mine):** for typical API structs (5–30 fields) linear comparison on
`(length, first 8 bytes as u64)` is very likely optimal — a length switch plus one 64-bit compare
resolves most keys in one or two instructions, with perfect branch prediction on repeated
documents. A PHF adds a multiply, a table load, and a verify compare, and wins only for very wide
structs. I found **no published measurement** either way; do not assert a number.

---

## 7. YAML and XML

### 7.1 YAML

**rapidyaml (ryml), VERIFIED as published**, `rapidyaml/README.md:104`: *"ryml parses at ~200MB/s
and emits at ~600MB/s, and is generally 30x (parse) / 150x (emit) faster than yamlcpp, and never
less than 10x (parse) / 50x (emit)."* Compared against yaml-cpp, libyaml, libfyaml
(`README.md:91`).

**Important caveat: the concrete table in ryml's README (`README.md:118-133`) is a JSON corpus,
not YAML.** On `bm/cases/compile_commands.json`: rapidjson_inplace 1741.62 MB/s, **ryml_json
908.00**, **ryml_yaml 881.58**, sajson_inplace 599.41, **libfyaml_arena 149.15**,
**libyaml_arena 135.06**, yamlcpp_arena 22.53. VERIFIED as published; CPU not stated.

The one fully-disclosed in-repo run is `bm/results/parse.linux.i7_6800K.md` (i7-6800K @ 3.4 GHz,
clang 7 / gcc 8): on `travis.yml`, ryml_rw_reuse **131.6 MB/s** vs yamlcpp **8.08 MB/s** (~16×).
VERIFIED.

**Why ryml is fast — VERIFIED from source, and it is the pugixml recipe:**
1. **In-place, view-only tree.** `README.md:19-24`: *"the resulting tree holds only views to
   sub-ranges of the source buffer. No string copies or duplications are done, and no virtual
   functions are used… ryml parses data into a flat, index-based data tree."* API enforces it:
   `parse_in_place(substr)` vs `parse_in_arena(csubstr)` (`src/c4/yml/parse.hpp:59-124, :193`),
   with a static poison against passing a mutable buffer to the arena form (`:184-186`).
2. **Flat index tree, integer IDs not pointers.** `src/c4/yml/tree.hpp:287-299` — `NodeData` holds
   `id_type m_parent, m_first_child, m_last_child, m_next_sibling, m_prev_sibling`, in one
   contiguous `m_buf`; `id()` is literally `n - m_buf` (`:380-397`);
   `static_assert(std::is_trivially_copyable<NodeData>)` at `:300`.
3. **Bump arena** — `tree.hpp:1397 alloc_arena`, `:1432 _grow_arena`, `m_arena_pos`.
4. **In-place scalar filtering** — `filter_processor.hpp:150-166, :301` unescape/fold inside the
   source buffer, with a src→dst path (`:48`) only when the result would grow.
5. **Anchors/aliases are NOT resolved during parse** — `reference_resolver.hpp:19-50`, an explicit
   separate two-phase call, documented as *"potentially expensive… this potential cost is one of
   the reasons for requiring an explicit call."*
6. **Tags/implicit typing are NOT resolved** — `README.md:26-29`: *"the tree representation stores
   only string views and assumes nothing on user types… (de)serialization happens only at your
   direct request."*
7. **No SIMD** — VERIFIED by grep: zero intrinsics in `rapidyaml/src`.

**Points 5 and 6 are how ryml reaches JSON-class numbers, and they are exactly the parts a Swift
`Decodable` layer cannot skip**, because `decode(Bool.self)` forces implicit-type resolution (the
Norway problem) and `&a`/`*a` must be resolved before a struct can be populated. **(Causal
attribution: UNVERIFIED, mine.)**

**Is YAML inherently slower? Yes — reasoned, UNVERIFIED except where noted:**
- **A simdjson-style structural index is not constructible for YAML.** JSON's structural set
  `{}[]:,"` is closed and context-free, so a byte can be classified by looking at the byte alone;
  that is what makes the vectorized classify-then-mask step well-defined. In YAML the meaning of
  `:`, `-`, `#`, `,`, `[` depends on flow-vs-block context and on the *following* byte (`: ` is a
  mapping indicator, `:` inside a plain scalar is not). **The classification step has no valid
  byte-local definition.**
- **Plain scalars have no delimiter.** Termination is `: `, ` #`, newline, or a flow indicator in
  flow context only, subject to multi-line folding. **The single most valuable SIMD primitive in
  JSON — "find the next `\"`" — has no YAML analogue.**
- **Significant indentation** needs a per-line column count *and a stack of reference indents*
  (`parser_state.hpp:117 indref`, VERIFIED). Column is a vectorizable prefix-sum, but the decision
  it feeds is a serial dependency on the scope stack.
- **Five scalar styles** (plain, `'`, `"`, `|`, `>`) with distinct escape/fold/chomp rules → a
  branchy per-scalar dispatch; ryml needs a distinct filter per style
  (`parse_engine.hpp:467-471`, VERIFIED).
- **Anchors/aliases** need a name→node table, and resolving them risks exponential blowup
  (billion laughs, documented at `reference_resolver.hpp:44-48`, VERIFIED).
- **Implicit typing** requires regex-class matching of every plain scalar against the core schema.

**Is there any SIMD YAML parser? No — none found.** Four searches plus source greps over ryml,
libfyaml, libyaml. libfyaml's only SIMD is in its bundled blake3 hash
(`src/blake3/blake3_be_cpusimd.c`), **not the parser**. VERIFIED as a negative result to the limit
of search.

**Realistic YAML:JSON ratio:** the cleanest apples-to-apples figure is **the same library on both
inputs**: ryml ~200 MB/s YAML vs 908 MB/s JSON ≈ **1:4.5**. Best-YAML vs best-JSON ≈ 200 vs 1742
≈ **1:8.7**; vs simdjson ≈ 1:10–1:20. Mainstream vs mainstream (libyaml 135 vs rapidjson 1742)
≈ **1:13**. VERIFIED numerators/denominators, ratios arithmetic.

**libyaml — the baseline everyone wraps — is allocation-per-token.** VERIFIED:
`include/yaml.h:269-311` makes `yaml_token_s.data.scalar.value` a heap `yaml_char_t*`;
`src/api.c:591-609` frees each token's handle/suffix/value; every scalar/anchor/tag is a separate
malloc + memcpy (`src/scanner.c:2613`). Measured at 135 MB/s in ryml's harness.

**Yams → Swift ceiling. VERIFIED:** `Yams/Sources/CYaml/src/{scanner,parser,reader,emitter,api,
writer}.c` is a vendored copy of libyaml; `Yams/Sources/Yams/Parser.swift:177, :329` call
`yaml_parser_initialize`/`yaml_parser_parse`. **UNVERIFIED inference:** a Swift library on Yams
inherits libyaml's ~135 MB/s ceiling *before* Swift-side cost, and then materializes `Node` enums
and Swift `String`s per scalar — a second copy plus a UTF-8 validation pass each. Real end-to-end
throughput is well under 135 MB/s.

### 7.2 XML

**pugixml — VERIFIED from source** (`/home/claude/research/pugixml/src/pugixml.cpp`):

1. **In-place, mutating parse with a NUL-terminated buffer trick.** `:3608-3628`: `parse()` takes a
   mutable `char_t*`, saves the last character, and writes a NUL over it — comment: *"save last
   character and make buffer zero-terminated (speeds up parsing)"*. Every scan loop then runs
   unbounded to NUL; the displaced byte is threaded through as `endch` and checked via
   `PUGI_IMPL_ENDSWITH(c,e)` (`:2672`). **This removes the length check from every inner loop.**
2. **In-situ NUL termination of names/values.**
   `#define PUGI_IMPL_ENDSEG() do { ch = *s; *s = 0; ++s; } while(0)` (`:2680`).
3. **Entity/EOL decoding in place via the `gap` trick** (`:2489-2528`, `strconv_escape` at `:2531`):
   because every XML text transformation only *shrinks*, decoding `memmove`s runs backwards and
   never needs new storage.
4. **Page-based bump allocator** — `xml_allocator` at `:556`; `allocate_memory` at `:590` is
   `buf = root + sizeof(page) + busy_size; busy_size += size;`. 32 KB pages (`:542`,
   `docs/manual.adoc:536`).
5. **Compact nodes** — `xml_node_struct` = header + 6 pointers (`:1159-1180`);
   `PUGIXML_COMPACT` mode asserts `sizeof(xml_node_struct) == 12` (`:1120`) and
   `sizeof(xml_attribute_struct) == 8` (`:1102`) via relative-offset encodings.
6. **Single pass**, `goto`-based re-dispatch; the only optional prior pass is encoding conversion
   (`:2212`, `:2328`), skipped for UTF-8.
7. **No SIMD** — zero intrinsics; inner loops are manually 4×-unrolled scalar
   (`PUGI_IMPL_SCANWHILE_UNROLL`, `:2679`) over a 256-entry character-class table.

**pugixml's numeric benchmark table could NOT be obtained** — pugixml.org/benchmark.html renders
via Google Charts and WebFetch strips it. Methodology VERIFIED as published: Intel Core i7 @
2.67 GHz, MSVC, metric = **processor clocks per input character**, min of runs; corpus
`cathedral.xml` (1 MB), `employees-big.xml` (10 MB), `house.dae` (6 MB), `terrover.xml` (16 MB).

**rapidxml (VERIFIED from its published manual):** in-situ by default — *"does not make copies of
strings. Instead, it places pointers to the source text in the DOM hierarchy."* Destructive by
default; `parse_non_destructive` disables mutation at the cost of entity translation and
zero-terminated strings. Claims ~1 GB/s on a **50 kB** file (cache-resident — **UNVERIFIED as
representative**) and "3-12x faster than pugxml" (note: *pugxml*, the pre-pugixml ancestor — this
claim is routinely mis-cited as being about pugixml).

**Swift XML backends — all VERIFIED by reading source:**

| library | backend | evidence |
|---|---|---|
| **Fuzi** | libxml2 directly (DOM) | `Fuzi/Sources/Document.swift:23 import libxml2`, `:138 xmlReadMemory` |
| **SWXMLHash** | Foundation `XMLParser` (SAX) | `SWXMLHash/Source/FullXMLParser.swift:33` |
| **AEXML** | Foundation `XMLParser` (SAX) | `AEXML/Sources/AEXML/Parser.swift:12-13, :43` |
| **XMLCoder** | Foundation `XMLParser` (SAX) | `XMLCoder/Sources/XMLCoder/Auxiliaries/XMLStackParser.swift:50, :119` |
| **Foundation `XMLParser`** | libxml2 SAX2 bridge | `swift-corelibs-foundation/Sources/FoundationXML/XMLParser.swift:12` imports `_CFXMLInterface` |

**UNVERIFIED inference, well-supported:** the `XMLParser` route is the worst of both worlds — you
pay libxml2's copying tokenizer, *plus* an Obj-C-shaped delegate callback per element/attribute/
character-run, *plus* a `String`/`NSDictionary` materialization per callback, and then you rebuild
a tree in Swift anyway. Fuzi's direct `xmlReadMemory` is strictly better. Neither approaches
pugixml, because libxml2 copies and interns strings rather than pointing into the caller's buffer.

---

## 8. Anti-patterns: where the published benchmarks mislead

**(a) Pretty-printed corpora inflate GB/s enormously. SELF-MEASURED in this environment** on
`/home/claude/research/simdjson/jsonexamples/`:

| file | bytes | whitespace fraction |
|---|---|---|
| `twitter.json` | 631,515 | **26.6%** |
| `citm_catalog.json` | 1,727,204 | **71.1%** |

Method: counted `0x20 0x09 0x0A 0x0D` over the whole file. **citm_catalog.json is 71% whitespace.**
Every published "citm at N GB/s" figure is, to a first approximation, a whitespace-skipping
benchmark — and whitespace skipping is the single most SIMD-friendly operation in existence.
**A minified API response has essentially zero whitespace, so citm-derived GB/s does not transfer
at all.** yyjson's own benchmark set is explicitly mixed: `yyjson_benchmark` uses pretty
twitter/github_events/citm/gsoc/poet and minified twitterescaped/canada/lottie/fgo/otfcc
(VERIFIED from its README). yyjson even *branches on this*, dispatching to two entirely different
parsers by sniffing `cur[1]`/`cur[2]` (`yyjson.c:6314-6319`) — which also means **a pretty document
whose root is `{"a": ...` gets the minify parser**, a heuristic failure mode nobody benchmarks.

**(b) Huge files hide fixed per-document cost.** VERIFIED from simdjson issue #70:
che-1.geo.json (11.5 KB) → **0.303 GB/s**; twitter_api_response.json (15.3 KB) → **0.534 GB/s**;
twitter.json (631.5 KB) → 2.04 GB/s. That is a **4–7× penalty in the 10–15 KB range**, the exact
range Assay targets. (The maintainers attribute much of it to number density rather than size —
both effects are real and both are unfavourable to small-payload extrapolation.) `kostya` and
`large_random` in the flagship benchmark set are **137 MB and 46 MB** — hundreds to thousands of
times larger than a server request body.

**(c) Warm-cache, buffer-reuse assumptions.** `doc/performance.md` (VERIFIED) instructs users to
reuse the parser, reuse string buffers, enable transparent huge pages, and to amortize the
allocation cost — and the `parse` tool has a `-H` flag *to omit memory allocation from results*.
Published GB/s figures assume a hot, pre-allocated, reused parser. A server handling one 4 KB body
per request does not get any of that unless the library is explicitly designed for it.

**(d) "DOM built but never walked."** This is why `json_benchmark_results` exists at all; its
README states it directly (VERIFIED): *"JSON benchmarks typically only measure how long a parser
takes to read a JSON file… you need to measure how long it takes to (for example) look up object
fields."* Any benchmark table without a "use the data" phase is measuring the wrong thing.

**(e) Vendor benchmarks flatter the vendor.** sonic-rs's harness sets jemalloc as the global
allocator (`benchmarks/benches/deserialize_struct.rs:9-11`, VERIFIED) and runs serde_json with
`float_roundtrip` on — its slow path. Its README leads with **DOM** ratios (6.8×) when the
**struct** ratio is 2.8×.

**(f) DOM ratios ≠ struct ratios.** Stated once more because it is the most common misreading in
this literature. sonic-rs: 6.8× DOM, 2.8× struct on the same corpus. simd-json: big DOM win,
**zero** struct win on canada.json.

**(g) x86 numbers do not transfer to ARM.** VERIFIED from `ampere-clang11.json` vs
`skylake-clang11.json`: simdjson DOM's advantage over yyjson *reverses* on ARM. Vector width
(256-bit AVX2 vs 128-bit NEON) is the obvious explanation (**UNVERIFIED as the cause**).

### Which published numbers are and are not relevant to Assay

**Relevant:**
- `partial_tweets`, `distinct_user_id`, `top_tweet` on the 631 KB twitter.json — the closest
  published proxy for "API response, read some fields into structs".
- The **ARM (`ampere-clang11`) table** — Assay's actual target hardware class.
- yyjson's **Apple A14** table — the only published Apple-Silicon-family JSON number I found.
- serde_json DOM-vs-struct (1.7–1.8×) and simdjson DOM-vs-On-Demand (1.35×) — the architectural
  question, cleanly isolated.
- simdjson issue #70's 10–15 KB figures.

**Not relevant:**
- Anything on `canada.json`, `large_random`, `kostya`, `fgo`, `otfcc` — 2 MB to 137 MB, float-dense
  or enormous. These measure a number-parsing microbenchmark or a memory-bandwidth benchmark.
- `citm_catalog.json` throughput — 71% whitespace (self-measured).
- "Minify at 6 GB/s" / "validate UTF-8 at 13 GB/s" — pure stage-1-class work, not parsing.
- Anything measuring parse-and-discard.
- rapidxml's 1 GB/s on a 50 kB cache-resident file.

---

## 9. What this means for Assay — ranked

1. **The architecture (macro → direct-to-struct, no document) is correct, and worth ~1.4× over a
   good tape and 2–7× over anything dictionary-based.** Foundation is dictionary-based per object.
2. **Do not build SIMD first.** yyjson matches simdjson's instruction count with zero SIMD and beats
   it outright on ARM. Vector width is the last 15% on x86 and ~0% on ARM.
3. **The six yyjson techniques (one allocation, flat array, zero-copy escape-free strings, 16×
   unrolled table scan, whole-parser specialization, cold-marked options) are the entire game**,
   and all six are expressible in Swift.
4. **Number parsing is the biggest content-dependent term** (4.8× ins/byte for float-dense data).
   Integer fast path first; Eisel-Lemire for doubles. Foundation uses `strtod`.
5. **UTF-8: one whole-buffer pass, never per-string** (serde_json's per-string validation costs
   1.65×).
6. **Field dispatch: linear compare on compile-time literals.** simdjson and serde both do this; no
   published evidence favours a perfect hash.
7. **YAML tops out around 200 MB/s and cannot use a structural index.** Budget it at ~1/4.5 of
   your JSON path in the same library. Do not use Yams for the fast path.
8. **XML: the pugixml recipe is in-place mutation + arena + compact flat nodes.** Every Swift XML
   library today bottoms out in libxml2, three of five through a SAX delegate bridge.
9. **Benchmark on minified 1–100 KB bodies on ARM with a cold-ish parser**, or your numbers will
   be as misleading as everyone else's.

---

## Do not assert these

Things I could **not** confirm. Assay's documentation, README, or marketing should not claim any of
these as fact.

1. **Any Apple Silicon (M-series) JSON number.** yyjson's A14 table is the closest published data
   point and it is an iPhone SoC from 2020, DOM-only, vendor-run. ReerJSON's and ZippyJSON's
   benchmark results are **published only as images**; I could not extract any figure.
2. **What Swift/LLVM actually emits for a generated field-matching `switch`** — length switch,
   `memcmp` chain, or jump table. No toolchain was available. Same gap exists for serde_derive's
   `match &str` (the delegated agent could not compile either).
3. **That a perfect hash beats linear comparison for field dispatch** (or the reverse), at any
   struct width. No published measurement found in any of the four codebases.
4. **The isolated cost of avoiding per-string copies.** yyjson's insitu-vs-not delta (1.14×)
   measures the *input buffer* copy, not the per-string copy. I have no measurement of the latter.
5. **Any small-payload (1–100 KB) number for sonic-rs vs serde_json.** sonic-rs ships `book.json`
   (367 B) and `github_events.json` (52 KB) in testdata but publishes no results for them.
6. **pugixml's actual benchmark values** vs rapidxml/libxml2/expat/tinyxml. The comparison table is
   Google-Charts-rendered; only methodology, hardware (i7 @ 2.67 GHz), metric (clocks per input
   character), and corpus were extractable. No numeric cell.
7. **sonic-cpp throughput.** Its README publishes benchmarks only as PNGs.
8. **The CPU/compiler behind rapidyaml's headline "~200 MB/s"**, and whether it refers to
   `travis.yml` or a scatter average, and which of ~14 benchmark variants.
9. **libyaml/libfyaml throughput on an actual YAML corpus.** The only side-by-side table in ryml's
   README is a *JSON* corpus; the YAML plots live as PNGs in an external repo.
10. **That the `json_benchmark_results` figures still hold in 2026.** They are simdjson **v0.8.0**,
    January 2021, clang 11, on Skylake and Ampere Altra. simdjson is now 4.x (Phoronix reported a
    further ~30% gain in 4.3); yyjson has had five years of commits. **The *ratios* are the
    finding, not the absolute GB/s, and even the ratios may have drifted.**
11. **That the SIMD/scalar reversal on Ampere is caused by NEON's 128-bit width.** That is the
    obvious explanation and I believe it, but I have no measurement isolating vector width from
    core width, branch predictor quality, or memory subsystem.
12. **That simdjson's stage 1 is "~40% of the work."** I stated a decomposition of roughly
    85% structural / 15% vector. That is my synthesis of the ins/byte and IPC columns, not a
    published breakdown. No profile decomposition of simdjson by stage was found.
13. **Darwin's `XMLParser` implementation.** Inferred from swift-corelibs-foundation; Apple's is
    closed source.
14. **That serde_json's default (non-`float_roundtrip`) float path is incorrectly rounded in
    practice** — the code shape implies it, but I found no test or measurement demonstrating a
    wrong result.
15. **Absence of a SIMD YAML parser** is a negative result from four searches plus source greps
    across three codebases, not a proof.
