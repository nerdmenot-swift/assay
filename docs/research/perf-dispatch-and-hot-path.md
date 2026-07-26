# Assay — hot path research: field dispatch, numbers, strings, validation, scanning, error model

Research date: 2026-07-25. No Swift toolchain available: **nothing here was compiled or benchmarked.**
Every claim is tagged **[V]** (read in source in `/home/claude/research/`, or a primary published doc)
or **[U]** (inference, derivation, or secondhand).

Repos read: `simdjson`, `yyjson`, `serde`/`serde_derive`, `serde-json`, `sonic-rs`, `sonic-cpp`,
`simd-json`, `swift` (full compiler + stdlib), `swift-foundation`, `swift-syntax`, `swift-evolution`,
`pydantic-core`, `rust-phf`.

---

## 1. Field name dispatch

### 1.1 What serde_derive actually emits — [V]

`serde_derive` does **not** hand-roll a length switch. It emits a flat `match` on the key and
delegates entirely to rustc.

`/home/claude/research/serde/serde_derive/src/de/identifier.rs:195-219` — `str_mapping` and
`bytes_mapping`:

```rust
let str_mapping = deserialized_fields.iter().map(|field| {
    let ident = &field.ident;
    let aliases = field.aliases;          // NOTE: "`aliases` also contains a main name"
    quote! { #( #aliases => _serde::#private2::Ok(#this_value::#ident), )* }
});
let bytes_mapping = ... .map(|alias| Literal::byte_string(alias.value.as_bytes())) ...
```

Emitted shape (`identifier.rs:444-470`):

```rust
fn visit_str<E>(self, __value: &str) -> Result<__Field, E> {
    match __value {
        "id"      => Ok(__Field::__field0),
        "user_id" => Ok(__Field::__field0),   // alias -> same field
        "text"    => Ok(__Field::__field1),
        _ => Err(Error::unknown_field(__value, FIELDS)),
    }
}
fn visit_bytes<E>(self, __value: &[u8]) -> ... { match __value { b"id" => ..., } }
```

**Aliases are flattened into additional match arms pointing at the same variant** —
`identifier.rs:198` comment *"`aliases` also contains a main name"*. This is exactly the right
model for Assay's `@Key(or:)`: an alias costs one more arm, nothing at runtime. **[V]**

`FIELDS` is a static `&[&str]` (`de/struct_.rs:129`) used only to render `unknown_field` errors. **[V]**

### 1.2 What rustc lowers that `match` to — [V], and it is worse than folklore suggests

- **`&str` patterns → `TestKind::StringEq` → a call to `<str as PartialEq>::eq`.**
  `compiler/rustc_mir_build/src/builder/matches/test.rs`, `string_compare`, with the source comment
  *"Compare two strings using `<str as std::cmp::PartialEq>::eq`. (Interestingly this means that
  exhaustiveness analysis relies, for soundness, on the `PartialEq` impl for `str` to be correct!)"*
  There is **no `SwitchInt` on length and no trie at MIR level**; `TestKind::SwitchInt` is chosen only
  for `PatConstKind::IntOrChar`. The result is an N-long chain of `len==K && bcmp(...)` after
  inlining. Any length-bucketing you observe is **LLVM SimplifyCFG/MergeICmps after the fact, not
  guaranteed.** **[V]**
- **`&[u8]` byte-string patterns take a different path** and *do* get the real decision tree:
  `compiler/rustc_mir_build/src/thir/pattern/const_to_pat.rs` decomposes `ty::Slice` valtrees
  element-wise into `PatKind::Slice`, giving `TestKind::SliceLen` (length compare) + per-byte
  `TestKind::SwitchInt` with prefix sharing. **[V]**
- **serde_json uses the slow one.** `deserialize_identifier` forwards to `deserialize_str`
  (`/home/claude/research/serde-json/src/de.rs:1903-1908`), so the `&str` StringEq chain is what
  actually runs. **[V]**
- Open issue [rust-lang/rust#39525](https://github.com/rust-lang/rust/issues/39525) "make
  string/slice more efficient with match" — a commenter reports it "seemed to just use repeated
  string comparison, instead of a more clever set of comparisons using some sort of trie." **[V]**
  (that the issue says this). Community claims that LLVM reliably builds a length-first tree are
  **[U]** and should not be relied on.

**Takeaway: serde is the baseline to beat, not the target to copy.** Its dispatch is a linear
`str::eq` chain whose quality depends on LLVM's mood.

### 1.3 Perfect hashing — gperf and rust-phf

- **gperf [V]:** GNU manual — *"The generated `hash` function returns an integer value created by
  adding *len* to several user-specified *str* key positions indexed into an **associated values**
  table."* i.e. `h = len + asso[p0][s[p0]] + asso[p1][s[p1]] + …`, then one full string compare to
  confirm.
- **rust-phf [V]:** `phf_shared/src/lib.rs:41-54` — **SipHash-1-3, 128-bit output** split into
  `g,f1,f2`. `:63-67` — `get_index` = `disps[g % disps.len()]` (dependent load), then
  `displace(f1,f2,d1,d2) = d2 + f1*d1 + f2`, then `% len`; **two modulos on runtime slice lengths.**
  `phf/src/map.rs:170-181` indexes `entries[index]` (**second dependent load**) and **always** runs
  `entry.0.phf_eq(key)` — a full compare. `DEFAULT_LAMBDA = 3` (`phf_generator/src/lib.rs:11`).
- **Cost shape [U, derived]:** hash all L bytes → dependent L1 load → mul/add/mod → second dependent
  L1 load → full compare. ≥2 L1 round-trips (~4-5 cycles each) on the critical path, ~15-25 cycles
  minimum, and it *still* pays the memcmp. A word compare is one 8-byte load + XOR + predicted
  branch, ~1-2 cycles.

**Published benchmark [V that it was published, U on methodology]:**
[lmammino/mega-match-vs-phf](https://github.com/lmammino/mega-match-vs-phf), Apple M1, **~300 keys**:
`match` = 1.877 ns (first key), 29.4 ns (middle), 2.84 ns (last), 6.89 ns (missing);
`phf` = **13.0–17.5 ns flat**. Even at N≈300 match wins on 3 of 4 positions.

**Maintainer statement [V]:** [rust-phf#85](https://github.com/rust-phf/rust-phf/issues/85) — phf is
intended for large tables (HTTP codes, HTML5 tokens); an if-else chain is acknowledged to beat phf
for small cases.

**Counter-evidence [V]:** PostgreSQL replaced *binary search* over ~450 SQL keywords with a
hand-rolled perfect hash: *"total time for raw parsing (flex + bison phases) drops by ~20%"*
([commit thread](https://www.postgresql.org/message-id/E1ghOVt-0007os-2V@gemulon.postgresql.org)).
Note: ~450 keys, and it replaced binary search, not a word-compare chain.

**Verdict for N=5..30: a general MPH is the wrong tool.** [U, but well-supported] Break-even against
a length-bucketed word-compare chain is roughly 10-15 *in-bucket* candidates; length bucketing over
5-30 keys typically leaves 2-5 per bucket. MPH's only real advantage is worst-case stability under
adversarial key ordering.

### 1.4 The 8-byte-prefix / word-compare trick

- **nginx [V], with a correction to the common folklore.** `src/http/ngx_http_parse.c` defines
  `ngx_str4cmp/5/6/9` under `#if NGX_HAVE_LITTLE_ENDIAN && NGX_HAVE_NONALIGNED`:
  `#define ngx_str4cmp(m, c0,c1,c2,c3) *(uint32_t *) m == ((c3<<24)|(c2<<16)|(c1<<8)|c0)`, with a
  byte-by-byte `#else`. **But these are used for HTTP *methods* (~9 of them), not header names.**
  Header names are matched by building a lowercased copy via a 256-entry `lowcase[]` table while
  incrementally computing `ngx_hash()` in the state machine, then a hash-table lookup. nginx chose
  word-compare for N≈9 and hashing for N≈30-50 — but note its header hash is *free*, folded into a
  lowercasing pass it had to do anyway. Assay has no such mandatory pass.
- **simdjson [V]:** `include/simdjson/generic/atomparsing.h:32-49` —
  `str4ncmp` does `memcpy(&srcval, src, 4); return srcval ^ string_to_uint32(atom);` with the comment
  *"all decent optimizing compilers will compile memcpy to a single instruction."*
- **Tail over-read [V]:** every real implementation solves this with **buffer padding, not masking**.
  `SIMDJSON_PADDING = 64` (`include/simdjson/base.h:37`), *"The input buf should be readable up to
  buf + SIMDJSON_PADDING"*. For >8-byte keys the standard fallback is chunking into consecutive
  u64s and OR-ing the XORs, with the final chunk **overlapping** the previous one (read the *last* 8
  bytes rather than a masked partial) — which requires knowing `len`, and a JSON key does, since the
  closing quote position is known.

### 1.5 simdjson's `key_selector.h` — the decisive finding [V, read in full]

`/home/claude/research/simdjson/include/simdjson/generic/ondemand/key_selector.h` (1374 lines) is a
`consteval` compile-time key dispatcher: `key_selector<"id","text","user">::match_raw(rjs)`. It has
three tiers, and **tier 1 is the one Assay should emit.**

**Tier 1 — single 8-bit window.** Verbatim from `key_selector.h:905-928`:

> Many small key sets can be told apart by inspecting a *single* 8-bit window of the key bytes -- and
> that window need not be byte-aligned. Because every JSON key is terminated by a `"`, the bytes at
> and before a key's length are well defined for any key at least that long: byte i is the key
> character when i is inside the key and the closing quote when i == len. So we read two bytes at a
> fixed offset, extract 8 consecutive bits at a fixed intra-byte shift, and if that value is distinct
> for every key, a 256-entry table maps it straight to a candidate key. The match then needs no hash
> and -- in the length-free overload -- no SIMD length scan: load two bytes, shift, mask, index the
> table, and confirm the candidate with one comparison.
>
> Allowing an *unaligned* window (a shift of 1..7) mixes bits from two adjacent bytes and
> discriminates key sets that no single aligned byte can. For example, the partial_tweets keys
> {created_at,id,text,in_reply_to_status_id,user,retweet_count,favorite_count} share a colliding byte
> at every aligned position 0,1,2, yet the 8 bits starting at bit offset 2 are unique across all
> seven. Simpler cases fall out as the shift==0 special case: {"id","screen_name"} splits on byte 0,
> {"jo","joe"} on the quote at byte 2.
>
> The window is confined to the first (shortest key length + 1) bytes so the two-byte read never
> crosses a key's closing quote into uncontrolled value bytes; that final byte is the shortest key's
> quote.

The compile-time search, `compute_window` at `key_selector.h:962-1001`:

```cpp
for (std::size_t off = 0; off <= min_len; ++off) {
  for (std::size_t shift = 0; shift < 8; ++shift) {
    if (shift != 0 && off + 1 > min_len) { continue; }
    bool distinct = true;
    for (i...) for (j = i+1...) if (window_value(keys,i,off,shift) == window_value(keys,j,off,shift))
        { distinct = false; break; }
    if (!distinct) continue;
    out.ok = true; out.byte_offset = off; out.shift = shift;
    for (b in 0..256) out.window_to_key[b] = N;                    // N == "no key"
    for (i in 0..N)  out.window_to_key[window_value(keys,i,off,shift)] = i;
    return out;
  }
}
return out; // ok == false
```

and the crucial virtual-byte trick, `window_byte_at` at `key_selector.h:944-948`:

```cpp
if (idx < keys[i].size()) { return (unsigned char)keys[i][idx]; }
return (unsigned)'"';   // the closing quote stands in for "past the end"
```

This is what makes `{"jo","joe"}` separable and removes the need for a separate length test.

Runtime (`read_window`, `key_selector.h:1003-1010`): `memcpy` a `uint16_t` at `p + byte_offset`,
`>> shift`, `& 0xFF`, index a 256-byte table. Then confirm with `compare_key_bytes` where the
`index_sequence` fold at `:1027-1043` turns the runtime candidate index into a **compile-time
constant length**, so the confirming compare specializes to a fixed-size compare. **[V]**

**Tier 2 — gperf-style asso_values** (`key_selector.h:275-282, 288-442`): `table_size` is a power of
two so `slot = h & (table_size-1)`; reject via `slot_key_len[slot] != len`; confirm via SIMD
`compare_key_bytes`. **Tier 3 — hash-and-displace** (`:490-596, 677-686`). **[V]**

### 1.6 Case-insensitive matching

- **simdjson [V]**, `atomparsing.h:39-49`:
  ```c
  // Checks that the first 8 characters ... in a case-insensitive manner.
  // 'atom' must consist of only lowercase letters.
  uint64_t str8ncmp_case_insensitive(const uint8_t *src, const char* atom) {
    memcpy(&srcval, src, sizeof(uint64_t));
    return (srcval | 0x2020202020202020ull) ^ string_to_uint64(atom);
  }
  ```
  Note the stated precondition: **the pattern must be all lowercase letters.**
- **Correctness caveats [V]**
  ([Cloudflare, "The oldest trick in the ASCII book"](https://blog.cloudflare.com/the-oldest-trick-in-the-ascii-book/)):
  OR-`0x20` is injective-safe only on `[A-Za-z]`. Collateral folds: `@`↔`` ` ``, `[`↔`{`, `\`↔`|`,
  `]`↔`}`, `^`↔`~`, and `_`(0x5F)↔`DEL`(0x7F). Digits `0-9` (0x30-0x39) already have bit 0x20 set, so
  OR-0x20 is a **no-op on digits — digits are safe.**
- **Correct pattern [U]:** use `|0x20` as a *cheap filter* to select a candidate, then confirm with a
  real ASCII case-insensitive compare. A false positive then costs only a wasted branch. Never use it
  as the sole test.

### 1.7 Recommendation for Assay's macro

Emit, in this priority order, chosen **at macro-expansion time** by running the same searches the
`consteval` code above runs:

1. **Single 8-bit window** (simdjson tier 1). Search `(byte_offset ∈ 0...minLen, shift ∈ 0...7)` for a
   window distinct across all keys *and all aliases*, using `'"'` (0x22) as the virtual byte at
   `idx == len`. Emit a 256-byte `StaticString`/`[UInt8]` table plus a `switch` on the candidate
   index. Runtime: `loadUnaligned(fromByteOffset:as: UInt16.self)`, shift, mask, table index, then one
   fixed-length confirm.
2. **Length bucket + `UInt64` word compares.** `switch keyLength { case 5: ... }`, and within each
   bucket compare 8 bytes at a time. Fuse the length test into the content test the way simdjson's
   `unsafe_is_equal` does (`raw_json_string-inl.h:71-82`):
   `(raw()[target.size()] == '"') && !memcmp(raw(), target.data(), target.size())` — **the trailing
   quote check makes a prefix-safe comparison possible without a separate length compare.** **[V]**
3. **gperf-style asso-value sum** only if N grows large (>~50) or the window search fails.

Awkward cases:
- **Keys > 8 bytes:** chunk into consecutive `UInt64`s, OR the XORs together, and make the final chunk
  *overlap* the previous one (read the last 8 bytes) rather than masking a partial. Length is known
  from the quote position, so this is safe. **[U, standard technique]**
- **Shared prefixes:** exactly the case the *unaligned* window solves — the partial_tweets set is
  simdjson's own worked example of keys that collide at every aligned position 0,1,2. Fall back to
  length bucketing, which separates `created_at`/`created_at_ms` for free.
- **Case-insensitive:** OR-0x20 filter then exact confirm (§1.6). Restrict the window search to
  case-folded key bytes.
- **Aliases / `@Key(or:)`:** flatten every alias into the candidate set before running the window
  search, mapping multiple window values to the same field index — precisely serde's model
  (`identifier.rs:198`), but resolved at compile time instead of as extra match arms. **[U]**
- **Buffer padding:** require ≥8 bytes readable past the key, or clamp the window offset to `minLen`
  as simdjson does. Do not mask tails.

---

## 2. Number parsing

### 2.1 Eisel–Lemire and fast_float

Algorithm **[V]**: parse the significand into a `u64` `w` (≤19 digits) with decimal exponent `q`;
normalize `w`; look up a 128-bit truncated approximation of `5^q`; compute the 128-bit product; the
top 64 bits give ~64 correct bits. If the low 9 bits of the high word are not all ones you provably
have ≥55 correct bits — shift, round, fold the power-of-2 part into the exponent, done. Otherwise a
second 128-bit multiply against the next 64 table bits (192-bit truncated product). Only then fall
back to arbitrary precision.

- simdjson `compute_float_64`: `/home/claude/research/simdjson/include/simdjson/generic/numberparsing.h:52`.
  Clinger fast path `:64-88` (`power in [-22,22] && i <= 9007199254740991` → one FP mul/div). Magic
  log₂(5) at `:145`: `(((152170 + 65536) * power) >> 16) + 1024 + 63`. First product `:175`. **Second-
  multiply trigger `:192`: `if((firstproduct.high & 0x1FF) == 0x1FF)`**; second product `:211`; comment
  at `:215` cites Mushtak & Lemire "Fast Number Parsing Without Fallback"
  ([arXiv:2212.06644](https://arxiv.org/abs/2212.06644)) proving **no third step is ever needed**. **[V]**
- sonic-rs: `/home/claude/research/sonic-rs/sonic-number/src/lemire.rs:29`, "cloned from rust-lang". **[V]**
- yyjson does **not** use Eisel–Lemire but a structurally similar scheme: Clinger path
  `/home/claude/research/yyjson/src/yyjson.c:4187`; single 128-bit product `:4262-4269`;
  second-multiply test `:4280` (`bits = hi & 0x1FF; if (bits - 1 < 0x1FF - 1)`); second product `:4296`;
  bigint/diy_fp fallback `:4359-4460`. `pow10_sig_table` at `:1233`, documented **10.4 KB** (`:1230`),
  exp10 −343…324 (`:1219-1222`). **[V]**

**Fallback frequency [V]:** the paper states *"In our experiments, we never need to fall back on a
higher-precision approach."* Lemire's blog: exact *"99,99% of the time"*.

### 2.2 Published figures — [V], [arXiv:2101.11408](https://arxiv.org/abs/2101.11408)

Table 9, **millions of floats/sec** (netlib / double-conversion / strtod / abseil / **fast_float**):

| machine | dataset | netlib | dbl-conv | strtod | abseil | fast_float |
|---|---|---|---|---|---|---|
| Intel Skylake | canada | 9.6 | 9.4 | **9.0** | 18 | **45** |
| AMD Zen 2 | canada | 10 | 9.0 | **9.3** | 21 | **51** |
| AMD Zen 2 | integer | 57 | 24 | 18 | 30 | **70** |
| Ampere Skylark (ARM) | canada | 8.1 | 5.4 | **3.9** | 9.1 | **22** |

Table 10 (Zen 2, per float): **strtod 1100 instructions / 370 cycles; fast_float 280 instructions /
66 cycles**, 0.01 branch misses, 4.2 IPC; bare string-scan floor 215 instr / 46 cycles.
Blog: 1.5 GB/s on canada on **Apple M1**, vs conventional parsers *"on the order of 200 MB/s"*.

**The number to internalize [V]:** Go's adoption (CL 260859, Go 1.16) improved
`Atof64RandomBits` 299 ns → **166 ns (−44%)**, but end-to-end `canada.json` decode by only **1.08×**.
Rust PR 86761 reported up to 10× on the primitive. **Float parsing is rarely the whole cost.**

### 2.3 Integers and the SWAR trick

Canonical form, `/home/claude/research/simdjson/include/simdjson/fallback/numberparsing_defs.h:24-30`
(credited to johnnylee-sde) **[V]**:

```c
memcpy(&val, chars, sizeof(uint64_t));
val = (val & 0x0F0F0F0F0F0F0F0F) * 2561 >> 8;
val = (val & 0x00FF00FF00FF00FF) * 6553601 >> 16;
return uint32_t((val & 0x0000FFFF0000FFFF) * 42949672960001 >> 32);
```

Masking strips ASCII `0x30`. `2561 = 256*10 + 1` does `d[i]*10 + d[i+1]` for all four pairs in one
multiply; `6553601 = 65536*100 + 1` folds pairs into 4-digit groups; `42949672960001 = 2^32*10000 + 1`
folds those into one 8-digit value. Three multiplies + three masks + one unaligned load replaces 8
mul-adds and 8 branches. SIMD variant at `haswell/numberparsing_defs.h:18`. sonic-rs equivalent at
`sonic-number/src/swar.rs:32`, with `is_eight_digits` at `:13`:
`((val+0x4646..) | (val-0x3030..)) & 0x8080..`. **[V]**

**Honest verdict for 1-6 digit API integers: SWAR is a loss.** [V evidence, U conclusion]
- simdjson invokes it only *after the decimal point* (`generic/numberparsing.h:404`, in
  `parse_decimal_after_separator`, comment *"this helps if we have lots of decimals!"*). Its **integer**
  path (`:378-385`) is a plain `i = 10*i + digit` loop.
- yyjson never uses SWAR for integers. `yyjson.c:3992-3995` is a macro-unrolled 18-deep
  `if (digit) sig = num + sig*10; else goto digi_sepr_i;` ladder — a fully unrolled dependent chain
  with an early exit per digit.
- sonic-rs documents an anti-SIMD note at `sonic-number/src/lib.rs:156`: *"Use SWAR (integer pipeline)
  instead of SSE simd_str2int (FP pipeline). On AMD Zen, SSE maddubs/madd go through FP ports causing
  ALU saturation."* **[V]**

Break-even is roughly ≥8 digits with high probability. Typical REST IDs/counts are 1-10 digits and
highly variable, so the branch misprediction on `is_eight_digits` costs more than the trick saves.
Milliseconds-since-epoch (13 digits) is the one common win.

### 2.4 What Swift actually does — this changed recently [V]

**`Double(String)` is now pure Swift.** `/home/claude/research/swift/stdlib/public/core/FloatingPointFromString.swift`
(~2800 lines, © 2025) replaces the old C `strtod_l` stub. Per
[swiftlang/swift#85797](https://github.com/swiftlang/swift/pull/85797) "Reimplement Floating-Point
Parsing in pure Swift" (merged 2025-12-10), the C implementations were removed from
`stdlib/public/stubs/Stubs.cpp`; the claimed win is *"up to 20%"*, **attributed to eliminating the
String→C-string copy, not a faster core.** Header `:24-26` states the decimal point is always `.` —
**no locale lookup.**

Structure: `fastParse64` `:742` (19-digit `u64` accumulator using deliberate `&*=`/`&+=`, `:872-887`);
`parse_float64` `:2441`; Clinger single-FP-op path `:2465-2489` with an **FMA trick at `:2482-2487`**
splitting digits into 53-bit high and 11-bit low so `u.addingProduct(highDigits, p10)` covers 19
digits exactly. Then **fixed-width interval arithmetic** (`:2493+`) rather than Eisel–Lemire proper:
a rounded-down bound plus a fixed `intervalWidth` (12 or 80, `:2515`), two-table decomposition
(`coarseIndex = (exp*585 + 256) >> 14`) at `:2519-2523`. Header `:157-160` claims the bounds coincide
*"for more than 99% of all inputs"*. Fallback `slowDecimalToBinary` `:1851`. 128-bit primitive
`multiply64x64RoundingDown` `:389`. The shim direction is **inverted**: `_swift_stdlib_strtod_clocale`
`:2406` is now a Swift function exported to C.

**swift-foundation gets none of this. [V]**
`/home/claude/research/swift-foundation/Sources/FoundationEssentials/JSON/JSONScanner.swift:1181-1190`
— `Double.init?(prevalidatedBuffer:)` calls `Platform.strtod_clocale`, which at
`Sources/FoundationEssentials/Platform.swift:424-431` is **literally `strtod_l(nptr, endptr, Self.cLocale)`**.
It does avoid `String` (operates on `BufferView<UInt8>`, `JSONDecoder.swift:962`).
Two micro-optimizations worth stealing, documented at `JSONDecoder.swift:964` and `:986`: they
**refuse to touch `errno`** (*"setting errno to 0 first and then check the result is surprisingly
expensive"*) and detect underflow via an `isTrueZero(numberBuffer)` digit scan.

Integers: `JSONScanner.swift:1212` `_parseInteger` → `CodableUtilities.swift:357` `_parseIntegerDigits`
— a plain byte loop with `multipliedReportingOverflow(by: 10)` + `addingReportingOverflow`/
`subtractingReportingOverflow` per digit (`:378-383`). Negatives accumulate **downward** to handle
`Int.min` — copy that. **[V]**

### 2.5 Pure-Swift ports and stdlib entry points

- **No pure-Swift fast_float package exists [V by exhaustive absence].** The fast_float family has
  C++, Java, C#, Rust, Zig, Ruby ports — no Swift. **swift-numerics is definitively no** (RealModule,
  ComplexModule, IntegerUtilities only). The nearest thing is now *inside* the stdlib and not
  extractable.
- **Stdlib integer path [V]:** `/home/claude/research/swift/stdlib/public/core/IntegerParsing.swift:127`
  `init?<S: StringProtocol>(_ text: S, radix: Int = 10)` → `_parseInteger(ascii:radix:)` `:61` →
  `_parseIntegerDigits` `:14`. **The byte-level entry point you want,
  `_parseIntegerDigits(ascii: UnsafeBufferPointer<UInt8>, radix: Int, isNegative: Bool)` at `:14`,
  is `internal` and not `@usableFromInline` — you cannot call it.** Because `radix` is a runtime
  value, the generic init **cannot** constant-fold `*10`; a macro-generated specialization can.
- **`multipliedFullWidth(by:)` exists and is usable [V]:** protocol requirement at
  `stdlib/public/core/Integers.swift:2290`; `@_transparent` per-type implementations generated at
  `IntegerTypes.swift.gyb:484` (lowering to `mulx`/`umulh`); generic default at `Integers.swift:2588`.
  **`UInt128` is also available and the stdlib itself uses it for exactly this**
  (`FloatingPointFromString.swift:390`). So Swift can express Eisel–Lemire's 128-bit product natively,
  two ways, with no C shim.

### 2.6 Recommendation

**Integers (the case that matters).** Generate a monomorphic, non-generic function per concrete type
over `UnsafeRawBufferPointer`/`Span<UInt8>`:
1. Consume `-`, then **accumulate negatively** (`result = result &* 10 &- digit`), negating at the end.
   `Int.min` falls out for free. (Foundation does this, `CodableUtilities.swift:380-382`.)
2. **Skip per-digit overflow checks for the first N digits**, N = `String(T.max).count - 1` (18 for
   Int64, 9 for Int32, 2 for UInt8). Within those, `&*10 &+ d` provably cannot overflow → wrapping
   operators, no branch per digit. This is the single biggest win. yyjson does exactly this
   (`yyjson.c:3992`).
3. For `UInt8`/`Int16`, fully unroll with a `switch` on length.
4. **Do not emit SWAR** unless a field is annotated as wide numeric (epoch-millis, 64-bit IDs).

**Doubles.** In order: (a) ≤15 significant digits and `|exp| ≤ 22` → `Double(sig) * / powersOf10[exp]`,
one FP op, correctly rounded, covers most human-authored JSON; (b) no fraction/exponent → parse as
Int64 and convert; (c) otherwise **call the stdlib** `Double(...)`. **Do not hand-roll Eisel–Lemire in
v1** — on a recent toolchain the stdlib path is already pure Swift with a Clinger fast path, an FMA
19-digit path, and 99%-coverage interval arithmetic; you'd be reimplementing it for what Go measured
as ~8% end-to-end. Revisit only if profiling a float-heavy payload shows it dominating.

**Two free wins regardless:** never round-trip through `String` (the stdlib's own 20% claim was
attributed almost entirely to removing that copy); never touch `errno`.

---

## 3. String handling and unescaping

### 3.1 The no-escape fast path

**yyjson — zero-copy, in-situ NUL termination [V].** `read_str_opt` at
`/home/claude/research/yyjson/src/yyjson.c:4760`. Detection is a **16×-unrolled byte-at-a-time table
lookup**, not SWAR/SIMD (`:4790-4826`): `repeat16_incr(expr_jump)` expands to 16 copies of
`if (likely(char_is_ascii_skip(src[i]))) {} else goto skip_ascii_stop##i;` then `src += 16`.
`char_is_ascii_skip` (`:890-893`) is `char_table1[c] & CHAR_TYPE_ASCII`; `CHAR_TYPE_ASCII` (`:749`) is
documented *"Except: `["\]`, `[0x00-0x1F, 0x80-0xFF]`"*. The source comment at `:4791-4803` says the
compiler wouldn't emit this from a natural loop, so they wrote the gotos and link a godbolt reference.

The zero-escape case is **fully zero-copy** (`:4840-4849`):
```c
if (likely(*src == quo)) {
    val->tag = ((u64)(src - hdr) << YYJSON_TAG_BIT) | YYJSON_TYPE_STR |
               (quo == '"' ? YYJSON_SUBTYPE_NOESC : 0);
    val->uni.str = (const char *)hdr;
    *src = '\0';
```
No memcpy — it points at the original buffer and overwrites the closing quote with NUL. **The
`YYJSON_SUBTYPE_NOESC` tag is the "needed no unescaping" bit.** Non-ASCII does *not* leave the fast
path: `skip_utf8` (`:4852-4890`) validates by run length and jumps back to `skip_ascii`.

**simdjson — unconditional SIMD copy, then find [V].**
`include/simdjson/haswell/stringparsing_defs.h:31-43`:
```cpp
simd8<uint8_t> v(src);
// store to dest unconditionally - we can overwrite the bits we don't like later
v.store(dst);
return { (v == '\\').to_bitmask(), (v == '"').to_bitmask() };
```
`BYTES_PROCESSED = 32` (`:19`). `src/generic/stage2/stringparsing.h:187-192` advances both by 32 when
neither bitmask fires. Ordering is branchless: `has_quote_first()` = `((bs_bits - 1) & quote_bits) != 0`
(`defs:22-23`). **On Demand goes further — `raw_json_string` is a bare `const uint8_t*` into the source
buffer; `unescape()` is on demand.**

### 3.2 `\uXXXX` and surrogate pairs

- **yyjson [V]:** `read_uni_esc` `yyjson.c:4696-4747`. BMP: `hex_load_4`, one predicted-taken
  `(hi & 0xF800) != 0xD800`, 1-3 stores. Surrogate: second `hex_load_4`,
  `uni = (((hi-0xD800)<<10) | (lo-0xDC00)) + 0x10000`, 4 stores. ~10-20 instructions per escape.
- **The real cost is losing zero-copy, not the escape [V]:** at `yyjson.c:4900` the moment any escape
  appears, `dst = src;` — from then on the string is copied in place, and the value loses
  `YYJSON_SUBTYPE_NOESC` (`:4965-4967`). Still unrolled, not a per-byte slow path.
- **simdjson [V]:** `handle_unicode_codepoint` `stringparsing.h:57-100`. The low-surrogate `\u` check
  is `((src_data[0] << 8) | src_data[1]) != (('\\' << 8) | 'u')` with the comment *"Compiler
  optimizations convert this to a single 16-bit load and compare on most platforms"*. **Escapes do not
  drop simdjson out of SIMD** — 32-byte chunking resumes immediately (`:187-192`).
- Escape frequency in ordinary API/log JSON: small single-digit percentage, `\u` far fewer. **[U]** —
  design implication is robust regardless: the no-escape path must be fast; the escape path only needs
  to be correct.

### 3.3 Swift String — the numbers that matter

- **Small-string capacity is 15 bytes on 64-bit [V]:**
  `/home/claude/research/swift/stdlib/public/core/SmallString.swift:78-90`; `8` on 32-/16-bit, `10` on
  watchOS 32-bit, **`14` on Android arm64** (`os(Android) && arch(arm64)`). `_SmallString` is
  `(UInt64, UInt64)` (`:31-36`) — truly inline, **no allocation**.
- **The "is small" check is branchless [V]:** `StringObject.swift:475-482`, `isSmall` =
  `(discriminatedObjectRawBits & 0x2000_0000_0000_0000) != 0`. Layout table `:22-46`. `getSmallCount` =
  `(x & 0x0F00_0000_0000_0000) >> 56` (`:638-645`). Source comment: *"A 'dedicated' bit is used for the
  most frequent fast-path queries so that they can compile to a fused check-and-branch."*
- **`isASCII` computed branchlessly at construction [V]:** `SmallString.swift:307` —
  `let isASCII = (leading | trailing) & 0x8080_8080_8080_8080 == 0`. Two ORs and a test over 16 bytes.
- **`String(decoding:as:)` VALIDATES AND REPAIRS [V]:** `String.swift:443-468` → `_fromUTF8Repairing`
  (`:459`) → `StringCreate.swift:178-190`: `validateUTF8(input)` → `_uncheckedFromUTF8` or `repairUTF8`.
  **So it is a full validation pass plus a copy — two passes over the bytes minimum.**
- **The ASCII prescan IS SIMD [V]:** `_allASCII` at `StringCreate.swift:15-90` — x86 `pmovmskb` over
  32 bytes/iter; arm64 `umaxv(block.0 | block.1) < 0x80`; otherwise 4×word SWAR against `0x8080...`.
  Loads via `UnsafeRawPointer.loadUnaligned`. Sub-word inputs fall back to `allSatisfy { $0 < 0x80 }`
  (`:75`).
- **`validateUTF8` is byte-at-a-time when not pure ASCII [V]:** `StringUTF8Validation.swift:113-269`;
  `:114` short-circuits on `_allASCII`, otherwise a scalar `while let cu = iter.next()` loop with a
  `switch` over lead-byte ranges and per-continuation-byte closures (`:216-262`). No SIMD, no DFA.
  **One non-ASCII byte anywhere demotes the entire buffer to the scalar loop.**
- **`String(unsafeUninitializedCapacity:initializingUTF8With:)` [V]:** public,
  **`@available(SwiftStdlib 5.3, *)` = macOS 11 / iOS 14** (`String.swift:645-660`) →
  `String(_uninitializedCapacity:initializingUTF8With:)` at **`String.swift:723-748`**:
  ```swift
  if _fastPath(capacity <= _SmallString.capacity) {
    let smol = try _SmallString(initializingUTF8With: { ... })
    if _fastPath(smol.isASCII) { self = String(_StringGuts(smol)); return }   // NO validation
    else { self = smol.withUTF8 { String._fromUTF8Repairing($0).result } }
  }
  self = try String._fromLargeUTF8Repairing(...)
  ```
  **It is the one-copy path. It validates/repairs EXCEPT for ≤15-byte all-ASCII, which is completely
  validation-free and allocation-free.** Above 15 bytes `_fromLargeUTF8Repairing`
  (`StringCreate.swift:191-207`) still runs `validateUTF8`.
- **Unsafe skip-validation entry points exist but are all `internal` [V]** — not public, not `@_spi`:
  `String._uncheckedFromUTF8` (`StringCreate.swift:216,226,238,249,268`), `_uncheckedFromASCII`
  (`:140-150`), `_tryFromUTF8` (`:169-175`), `_fromUTF8Repairing` (`:178`). **Unusable from Assay.**

### 3.4 Keys without Strings — the biggest available win

- **`loadUnaligned` exists and is essentially free [V]:**
  `/home/claude/research/swift/stdlib/public/core/UnsafeRawPointer.swift:490-497`:
  ```swift
  @_transparent
  public func loadUnaligned<T: BitwiseCopyable & ~Escapable>(
    fromByteOffset offset: Int = 0, as type: T.Type) -> T {
    return Builtin.loadRaw((self + offset)._rawValue)
  }
  ```
  One `Builtin.loadRaw` → one unaligned `mov`. **The non-`BitwiseCopyable` overload at `:523-541` is
  much slower** (temporary allocation + `memcpy`) — always constrain to a concrete `UInt64`/`UInt16`.
  The stdlib uses this exact trick in `_allASCII` (`StringCreate.swift:43,49`).
  [SE-0349](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0349-unaligned-loads-and-stores.md),
  Swift 5.7. **There is no `@available` annotation on `loadUnaligned` in this checkout [V]**; being
  `@_transparent` it is emitted into the client, so **[U]** it should back-deploy to any OS with a
  5.7+ compiler — unlike `String(unsafeUninitializedCapacity:)`'s macOS 11 floor.
- **`StaticString` gives you what you need [V]:** `utf8Start: UnsafePointer<UInt8>`
  (`StaticString.swift:132`), `utf8CodeUnitCount: Int` (`:156`), `isASCII`, `hasPointerRepresentation`
  — compile-time constants in `_startPtrOrData` / `_utf8CodeUnitCount: Builtin.Word` / `_flags`
  (`:82, :103-111`).
- **`switch someString` IS A LINEAR SCAN — the smoking gun [V]:**
  `/home/claude/research/swift/stdlib/public/core/StringSwitch.swift:20-33`, `_findStringSwitchCase`:
  ```swift
  for (idx, s) in cases.enumerated() {
    if String(_builtinStringLiteral: s.utf8Start._rawValue, ...) == string { return idx }
  }
  return -1
  ```
  A literal O(n) linear scan doing a full `String ==` per case. The cached variant
  `_findStringSwitchCaseWithCache` (`:66-90`) uses `Builtin.onceWithContext` to build a
  **`Dictionary<String, Int>`** (`_createStringTableCache`, `:93-108`) — so after warmup it is a String
  hash + Dictionary probe per key, **and it still requires a fully materialized `String` as input.**

  **This is the core argument for Assay [U]:** the naive `Codable` route costs (1) a String allocation
  per key, (2) a UTF-8 validation pass per key, (3) a String hash, (4) a Dictionary probe. A
  macro-generated decoder replaces all four with a 2-byte load + table index + one fixed-length compare
  on bytes already in L1, and materializes **no String for keys at all.**

### 3.5 swift-foundation's JSON strings — the baseline to beat [V]

- **It does have a no-escape fast path.** `JSONScanner.swift:773-800`
  `skipUTF8StringTillNextUnescapedQuote(isSimple:)`; `isSimple` recorded as a distinct tag
  `.simpleString` vs `.string` (`:78, 93, 155, 572`). But the scan loop is **byte-at-a-time**
  (`while let byte = self.peek()`, `switch byte`, `moveReaderIndex(forwardBy: 1)`) — no unrolling, no
  SWAR, no SIMD. Compare yyjson's 16× unroll and simdjson's 32-byte vectors.
- **Even the "simple" path validates and copies.** `JSONDecoder.swift:863-882` `unwrapString`:
  `if isSimple { String._tryFromUTF8(stringBuffer) }` = `validateUTF8` + `_uncheckedFromUTF8`. The
  general path (`JSONScanner.swift:887-910`) re-scans byte-at-a-time and calls `_slowpath_stringValue`
  (`:912+`) which does `output += stringChunk` — **repeated String concatenation, realloc churn per
  escape.**
- **It creates a String for EVERY key, including ignored ones, and builds a Dictionary per object.**
  `JSONDecoder.swift:1264-1303`:
  ```swift
  var result = [String:JSONMap.Value]()
  result.reserveCapacity(objectRegion.count / 2)
  while let (keyValue, value) = iter.next() {
      let key = try impl.unwrapString(from: keyValue, ...)
      result[key]._setIfNil(to: value)
  }
  ```
  Called unconditionally from `init` (`:1308`). **No interning, no caching.** For a 40-field object
  where the type wants 3 fields: 40 String allocations, 40 UTF-8 validations, 40 String hashes, 40
  Dictionary inserts, plus Dictionary storage growth — to answer 3 lookups (`getValue(forKey:)` `:1522`).
  `convertFromSnakeCase` (`:1279-1287`) adds another String allocation per key on top.
- **It is two-pass.** `JSONScanner.scan()` (`JSONScanner.swift:345-377`) walks the entire document
  building `JSONPartialMapData` (`:297-333`) and only then hands a `JSONMap` to the decoder. Every
  value is tagged and offset-recorded even if never decoded.

---

## 4. UTF-8 validation

### 4.1 Is it required?

**RFC 8259 §8.1 [V]:** *"JSON text exchanged between systems that are not part of a closed ecosystem
MUST be encoded using UTF-8."* **The MUST binds the producer/interchange format, not the parser's
checking obligation** — the RFC nowhere says a parser MUST reject invalid UTF-8. §8.2 warns only that
ill-formed sequences make behavior *"unpredictable; ... implementations might return different values
for the length of a string value or even suffer fatal runtime exceptions."* BOM: *"Implementations
MUST NOT add a byte order mark"*, but parsers *"MAY ignore the presence of a byte order mark."*

Security consequences of skipping **[U, standard reasoning]**: overlong encodings (`C0 AF` for `/`)
defeat byte-level filters applied before decoding; surrogate halves (`ED A0 80`) and >U+10FFFF
sequences produce non-scalar values downstream converters mishandle. **The Swift-specific hazard is
sharper: `String` guarantees valid UTF-8 storage, so an unvalidated byte range fed through an
unchecked path is a type-invariant violation, not just a correctness bug.**

### 4.2 simdjson — validation rides along free [V]

`src/generic/stage1/utf8_lookup4_algorithm.h:16-95` — three 16-entry `pshufb`/`tbl` lookups
(`byte_1_high`, `byte_1_low`, `byte_2_high`) producing error bits `TOO_SHORT=1<<0, TOO_LONG=1<<1,
OVERLONG_3=1<<2, TOO_LARGE=1<<3, SURROGATE=1<<4, OVERLONG_2=1<<5, TOO_LARGE_1000/OVERLONG_4=1<<6,
TWO_CONTS=1<<7`. It genuinely rides along: `src/generic/stage1/json_structural_indexer.h:239-247`
calls `checker.check_next_input(in)` on the **same `simd8x64` register already loaded for structural
scanning**, guarded by `#if SIMDJSON_UTF8VALIDATION` (default `1`, `include/simdjson/common_defs.h:337-338`).
PERF NOTES at `json_structural_indexer.h:176-190` state UTF-8 checks run *"while we're waiting"*
because step 1 *"does not use enough capacity"* — it fills otherwise-idle issue slots.

**Published figures [V], [arXiv:2010.03090](https://arxiv.org/pdf/2010.03090):** lookup algorithm
**0.21 instructions/byte on ASCII, 0.97 on mixed**; **28 GB/s on JSON, 18 GB/s on HTML** (AMD EPYC
7262 Rome @3.2 GHz), vs branchy 2.5 GB/s / 6-12 ins-per-byte and finite-state (DFA) 2.0 GB/s / 7.0
ins-per-byte constant. Abstract: *"outperforms UTF-8 validation routines used in many libraries and
languages by more than 10 times."*

### 4.3 yyjson — scalar, always-on, strings only [V]

`char_table1` marks all of 0x80-0xFF as `0x00` (`yyjson.c:770-803`), so non-ASCII falls out of the
ASCII loop into `skip_utf8:` (`:4852-4896`) / `copy_utf8:` (`:5019-5073`). Validation uses 4-byte-load
bitmask macros `is_utf8_seq1..4` at `:1120-1177`, correctly rejecting overlongs (`b2_requ=1E`,
`b3_requ=0F 20`) and surrogates (`b3_erro=0D 20 00`). Runtime opt-out
`YYJSON_READ_ALLOW_INVALID_UNICODE` (`:4893, 4973, 5065, 5157, 5220`); compile-time
`YYJSON_DISABLE_UTF8_VALIDATION` (`yyjson.h:101-102`).

**Published cost [V]:** *"Disabling UTF-8 validation improves performance for non-ASCII strings by
about 3% to 7%"* (`/home/claude/research/yyjson/doc/BuildAndTest.md:293-305`). That doc also states the
failure mode: *"Ending quotes may be ignored ... causing the string to merge with the next value"* and
*"the string's end may be accessed out of bounds, potentially causing a segmentation fault."*

### 4.4 Can Assay defer or skip it? — Yes, with one precise caveat

**For key byte ranges only ever compared against known ASCII literals, validation adds nothing [U,
but the reasoning is airtight]:** (a) equality of byte sequences is exact and encoding-independent;
(b) if the literal is pure ASCII, any range equal to it is *by construction* valid UTF-8, so a match
self-certifies; (c) a non-match means the range is discarded, so no invalid bytes escape into a String.

**The caveat is structural, not semantic.** The *string-boundary scan* must still be correct — this is
exactly yyjson's documented hazard: with validation off, a stray `0x80` lead byte can make the scanner
mis-locate the closing quote. So decompose as: **structural correctness (mandatory) ≠ scalar-value
validation (deferrable).** The scanner must handle `\` and `"` and must not let a truncated multi-byte
sequence swallow the terminator; the *semantic* checks (overlong, surrogate, >U+10FFFF) defer to the
point of `String` materialization.

**For value strings that DO become `String`s, validation is unavoidable in Swift** — `String` requires
well-formed UTF-8 as a type invariant, and the unchecked constructors are `internal` (§3.3). You either
pay `validateUTF8` or you validate yourself. **The win: skip validation on keys, skipped values,
numbers, and whitespace; pay it only on materialized strings.** On a typical API response that is most
of the payload.

### 4.5 Lookup-table vs SIMD

**Hoehrmann's DFA [V via mirror]:** `static const uint8_t utf8d[]` = **256 byte-class entries + 9
states × 16 classes = 400 bytes** (often cited as 364 trimmed). Per byte:
`type = utf8d[byte]; *state = utf8d[256 + *state*16 + type];` — 2 dependent loads + shift/add.
Measured by Lemire as "finite-state": **7.0 instructions/byte, ~2.0 GB/s constant** regardless of
input. Branchless (immune to adversarial input) but has a **serial load-to-load dependency chain** that
cannot ILP.

**Recommendation for a scalar Swift decoder [U]:** ASCII SWAR fast path (8 bytes/iteration,
`& 0x8080808080808080`) + yyjson-style masked range checks on the non-ASCII tail — **not a DFA.** The
DFA's constant 7 ins/byte is worse than SWAR-ASCII's ~0.5 ins/byte on the ASCII majority.

---

## 5. Structural scanning without SIMD

### 5.1 What yyjson actually does [V]

Three 256-entry `u8` tables = **768 bytes total**, generated by `misc/make_tables.c`:
- `char_table1[256]` `yyjson.c:770` — `CHAR_TYPE_ASCII 1<<0` (all except `"`, `\`, 0x00-0x1F,
  0x80-0xFF), `ASCII_SQ 1<<1`, `SPACE 1<<2` (` \t\n\r`), `SPACE_EXT 1<<3`, `NUM 1<<4` (`.-+0-9`),
  `COMMENT 1<<5` (`/`). Flags declared `:749-754`.
- `char_table2[256]` `:805` — `EOL 1<<0`, `EOL_EXT 1<<1`, `ID_START 1<<2`, `ID_NEXT 1<<3`,
  `ID_ASCII 1<<4` (JSON5 identifiers).
- `char_table3[256]` `:840` — `SIGN 1<<0`, `DIGIT 1<<1`, `NONZERO 1<<2`, `EXP 1<<3`, `DOT 1<<4`.
  (`'0'`→`0x02`, `'1'-'9'`→`0x06`, `'.'`→`0x10`, `'e'/'E'`→`0x08`.)

Predicates are one table load + AND + `!!` (`:876-958`). The main FSM is a **goto machine, not a
table-driven parser**: `read_root_minify` `:5349`, `read_root_pretty` `:5776`. Structural dispatch
(`arr_val_begin:` `:5452-5521`) is an **ordered chain of direct byte compares** — `{`, `[`,
`char_is_num`, `"`, `t`, `f`, `n`, `]`, and only *last* the whitespace test at `:5501`:
`if (char_is_space(*cur)) { while (char_is_space(*++cur)); goto arr_val_begin; }`. **So whitespace
costs zero in the common minified case.** `read_root_pretty` additionally opens with a 16×-unrolled
`byte_match_2(cur, "  ")` two-space indent skipper (`:5880-5893`) — a 2-byte SWAR compare, the closest
yyjson gets to vectorization in the structural path. `skip_trivia` (`:3390-3437`) is `static_noinline`
(cold).

### 5.2 SWAR haszero/hasvalue

Primary-source verbatim quote for the canonical macro **NOT obtained** — WebFetch of
graphics.stanford.edu/~seander/bithacks.html truncates before the macro block. It did return the
alternate 5-op form `~((((v & 0x7F7F7F7F) + 0x7F7F7F7F) | v) | 0x7F7F7F7F)` and the 4-op pretest
`((v + 0x7efefeff) ^ ~v) & 0x81010100` with its caveat *"the test also returns true if the high byte is
0x80, so there are occasional false positives"* **[V, that quote]**.

`haszero(v) = (v - 0x01010101) & ~v & 0x80808080` and `hasvalue(x,n) = haszero(x ^ (~0UL/255 * n))` are
**[U] as a quotation but [V] by derivation**: a lane is flagged only if `v_i < 0x80` (from `~v`) and the
subtraction wrapped; wrapping needs `v_i == 0` (no borrow) or `v_i <= 1` (with borrow). **So spurious
flags occur only on a lane holding `0x01` immediately above a true zero lane — the predicate has no
false positives, and `trailingZeroBitCount >> 3` of the mask still yields the correct first-match
index**; only higher lanes can carry extra bits. Cost: 3 ALU ops + 1 unaligned load per 8 bytes
(~0.5 ops/byte), plus one `ctz` on a hit.

**Real uses in the local repos: exactly one [V].**
`/home/claude/research/sonic-cpp/include/sonic/internal/arch/riscv/simd.h:37-100` — sonic-cpp's RISC-V
Zbb fallback. Defines `kByteMsb = 0x8080808080808080`, `kByteLsb = 0x0101010101010101`,
`kMovemaskMultiplier = 0x0002040810204081`, and builds
`eq_mask16(ptr, value) = zero_byte_mask(load_u64(ptr) ^ (kByteLsb * value))` — **exactly `hasvalue`** —
then a multiply-shift to compress the 8 lane-MSBs into an 8-bit movemask (`byte_msb_to_mask`, `:52-55`).
**A directly transcribable blueprint for a Swift SWAR movemask.** simd-json's SWAR is number-parsing
only (`src/numberparse.rs:125`); yyjson uses no 64-bit SWAR in its scanner at all.

### 5.3 Scalar vs SIMD throughput [V]

`/home/claude/research/yyjson/README.md:36-58`, twitter.json (~630 KB), **DOM API**:

| | AMD EPYC 7R32 | Apple A14 |
|---|---|---|
| yyjson insitu | **1.80 GB/s** | **3.51 GB/s** |
| yyjson | 1.72 | 2.39 |
| simdjson | 1.52 | 2.19 |
| sajson | 1.16 | — |
| rapidjson insitu | 0.77 | — |

**A well-written scalar parser beats simdjson's DOM path on both x86 and ARM.** Caveat stated in the
README itself (`:30-31`): *"The simdjson's new `On Demand` API is faster if most JSON fields are known
at compile-time. This benchmark project only checks the DOM API."* Data dated 2020-12-12.

**Small payloads [V for the facts, U for the 20% figure]:** `SIMDJSON_PADDING = 64`
(`include/simdjson/base.h:37`), described at `:30-36` as *"The input buf should be readable up to
buf + SIMDJSON_PADDING ... this is a stopgap"*. For a 200-byte API response that padding is **32%
buffer overhead**, and if you can't over-allocate you pay a full copy (`padded_string` allocates
`length + SIMDJSON_PADDING`, `padded_string-inl.h:36`) — a `malloc` + `memcpy` that can exceed the
parse. simdjson's own docs quantify the alternative: `parse_unpadded` *"is slower than parsing an
already-padded buffer"*, penalty *"on the order of a few percent of total parsing time"* (`doc/dom.md:938`)
— but on twitter.json (630 KB), where the tail amortizes to nothing; **on a sub-1KB input the tail IS
the document.** Further evidence of a size floor: `iterate_many`'s docs say *"Setting the window size
too small (e.g., less than 100 kB) may also impact performance negatively"* (`doc/basics.md:3044`).
Stage 1 processes 128 bytes/step (`json_structural_indexer.h:221-229`), so a 200-byte document is
**1.5 steps** — the deliberately-pipelined two-block design (`:176-190`) never reaches steady state.
**A direct published GB/s-vs-size curve was not found [U].**

### 5.4 Swift's SIMD is not usable for this [V]

`SIMD16<UInt8>`/`SIMD32<UInt8>` and `SIMDMask` exist (`stdlib/public/core/SIMDVector.swift:702`).
**There is no portable movemask.** The only public reductions are `any(_:)` (`:1563`) and `all(_:)`
(`:1570`), both returning `Bool` — "is there a match" but not "where". `SIMDMask.trailingZeroBitCount`
(`:773-775`) is a **lane-wise** operation (`for i in indices { result[i] = ... }`), not mask-to-integer
bit extraction. Extracting a match *index* portably means a scalar loop over 16 lanes, which destroys
the win.

**The stdlib's own workaround proves the point:** `_allASCII` (`StringCreate.swift:24-39`) drops to
`Builtin.bitcast_Vec16xInt1_Int16` on x86 and `Builtin.int_vector_reduce_umax_Vec16xInt8` on arm64 —
**`Builtin.*` is stdlib-private and unavailable to third-party packages** — and falls back to word-SWAR
everywhere else (`:38, :55`). Additional friction: gated on `SWIFT_STDLIB_ENABLE_VECTOR_TYPES`, and
Swift offers no `@_target_clones`/runtime dispatch to compile an AVX2 kernel into a portable binary.

**Conclusion: for Assay, scalar + SWAR is not a compromise, it is the right answer.**

---

## 6. Assay-specific design questions

### 6.1 Single-pass streaming vs two-pass indexing

**How serde handles out-of-order keys — VERIFIED in full.** It is single-pass in document order with
`Option<T>` locals, then an assembly phase.

Declarations, `/home/claude/research/serde/serde_derive/src/de/struct_.rs:216-222`:
```rust
let mut __field0: Option<FieldTy> = None;
```
The loop, `struct_.rs:303-310`:
```rust
while let Some(__key) = MapAccess::next_key::<__Field>(&mut __map)? {
    match __key {
        __Field::__field0 => {
            if Option::is_some(&__field0) {
                return Err(<__A::Error as Error>::duplicate_field("id"));
            }
            __field0 = Some(MapAccess::next_value::<FieldTy>(&mut __map)?);
        }
        ...
        _ => { let _ = MapAccess::next_value::<IgnoredAny>(&mut __map)?; }   // struct_.rs:288
    }
}
```
Assembly, `struct_.rs:313-325`:
```rust
let __field0 = match __field0 { Some(v) => v, None => /* missing_field("id") */ };
...
Ok(Struct { id: __field0, ... })
```

So: **key order is irrelevant to serde — it never rewinds and never re-scans.** Cost is one
`Option<T>` local per field (stack, usually collapsed into registers by LLVM) and one `is_some` check
per assignment for duplicate detection. Unknown fields are skipped with `IgnoredAny` (`struct_.rs:288`),
not materialized. **[V]**

**The contrast — simdjson On Demand's rewind [V].** `find_field_raw`
(`include/simdjson/generic/ondemand/value_iterator-inl.h:132`) scans forward only. `find_field_unordered_raw`
(`:229`) records `search_start`, scans forward, and **if it hits the end calls `reset_object()` and
rescans from the first field**, re-skipping every value it already skipped. In-source performance note
at `:356-360`: *"it maybe wasteful to rewind to the beginning when there might be no other query
following. Indeed, it would require reskipping the whole object."* **Worst case (query order exactly
reversed) is O(N²) in skip work.** Docs, `doc/ondemand_design.md:726`: field lookup *"is more
performant when the order of lookups matches the order of fields in the document, but which will still
work with out-of-order fields, with a performance hit"*; `doc/basics.md:596-598`: *"we still encourage
you to look up fields in the order you expect them in the JSON, as it is still faster."*

**The decisive evidence — simdjson has abandoned the rewind for its new reflective path [V].**
`/home/claude/research/simdjson/doc/basics.md:1693-1701`, "Order-independent reflective deserialization
(C++26)":

> By default, reflective deserialization (`doc.get<T>()` / `simdjson::from`) builds a compile-time
> [key selector](#key-selectors) from the struct's members and walks each object **once** with
> `object::for_each`, classifying every key through a perfect hash regardless of its position. This
> deserializes structs correctly even when the JSON keys are not in declaration order, **without
> forcing a rescan of the object per out-of-order key.**

**This is exactly serde's design, plus a compile-time key dispatcher — i.e. exactly what Assay should
be.** Two independent state-of-the-art implementations converged on it.

**Recommendation: single-pass streaming, document order, one local per field.** Concretely:
- Emit `var _f0: FieldTy? = nil` per field — or better, for types with a natural sentinel, a raw
  storage slot plus a `UInt64` presence bitmask (fields ≤ 64, which covers essentially every struct).
  A bitmask makes duplicate detection one `and`/`or` and makes "which fields are missing" a single
  `~mask & requiredMask` at the end — one instruction instead of N branches. **[U]**
- Walk the object once, dispatching each key through the §1.7 window table.
- Unknown keys: skip the value structurally without materializing it (serde's `IgnoredAny`).
- After the loop, assemble in declaration order and report **all** missing required fields from the
  bitmask in one pass.

**Do not two-pass.** swift-foundation's two-pass design (§3.5) is precisely why it is slow: it tags and
offset-records every value in the document even if never decoded, and builds a `[String: JSONMap.Value]`
per object. The only thing two-pass buys is out-of-order random access, which the presence-bitmask
gives you for free.

**One genuine caveat [U]:** single-pass means a field's value is decoded before you know whether a
*later* duplicate key will override it. serde resolves this by erroring on duplicates
(`struct_.rs:270-272`). Assay should do the same — it is both faster and better validation behavior.
"Last one wins" would force buffering.

### 6.2 Collect every error, with spans, for free on the happy path

**Lazy line/column is confirmed as universal practice. [V]**

- **Swift's compiler:** `SourceLoc` is *one pointer*, nothing more —
  `/home/claude/research/swift/include/swift/Basic/SourceLoc.h:48-57`, comment *"`SourceLoc` just wraps a
  `const char *`"*, field `const char *_Nullable Pointer = nullptr;` — **8 bytes, no line, no column, no
  buffer ID.** `SourceRange` = two `SourceLoc` = 16 bytes (`:145-151`); `CharSourceRange` (`:231`) is
  `SourceLoc Start` + `unsigned ByteLength`. Line/column is computed **only on demand** from
  diagnostic-rendering paths: `include/swift/Basic/SourceManager.h:491-499`
  (`getPresumedLineAndColumnForLoc`) and `:506-510` (`getLineAndColumnInBuffer`), both forwarding to
  `LLVMSourceMgr.getLineAndColumn`. Callers are print paths — `lib/Basic/SourceLoc.cpp:599, :618`.
- **LLVM — the exact design to copy.** `llvm/include/llvm/Support/SourceMgr.h`, `SrcBuffer`:
  `mutable void *OffsetCache = nullptr;` with the comment *"Vector of offsets into Buffer at which there
  are line-endings (**lazily populated**). Once populated, the '\n' that marks the end of line number N
  from [1..] is at Buffer[OffsetCache[N-1]]. Since these offsets are in sorted (ascending) order, they
  can be binary-searched... Since we're storing offsets into relatively small files (often smaller than
  2^8 or 2^16 bytes), we select the offset vector element type **dynamically based on the size of
  Buffer**."* `getLineAndColumn` is documented O(log n). `llvm/lib/Support/SourceMgr.cpp`
  `GetOrCreateOffsetCache<T>` returns the existing cache or scans the buffer once. **Zero cost until the
  first diagnostic is rendered; one linear scan then; O(log n) per location thereafter.**
- **Clang:** `SourceLocation` is `using UIntTy = uint32_t; UIntTy ID = 0;` — *"It is important that this
  type remains small. It is currently 32 bits wide."* **4 bytes.**
- **swift-syntax — the informative counter-example.** `AbsolutePosition` is one `Int`
  (`Sources/SwiftSyntax/AbsolutePosition.swift:15-21`), same offset-only design. But
  `SourceLocationConverter` (`Sources/SwiftSyntax/SourceLocation.swift:144-168`) is a `final class`
  whose `init` **eagerly** copies the source and builds the line table (`computeLines`, `:613/:688`).
  Lookup is `lineEnds.upperBoundIndex(position)` — binary search over a `SortedArray` (`:432, :501,
  :538-557`). Eagerness is fine there because you construct a converter only when you intend to print.
  **Assay should be lazy like LLVM, but reuse this shape: `[UInt32]` of newline offsets +
  `upperBoundIndex`.**
- **serde_json does the same [V]:** `/home/claude/research/serde-json/src/read.rs:421-430`,
  `position_of_index` uses `memchr::memrchr(b'\n', ...)` for the line start and `memchr_iter(...).count()`
  to count lines — **computed at error-construction time only.** No line tracking during parsing.

**Happy-path cost in Swift.**
- **`throws` return is near-free [V].** Errors return in a dedicated callee-saved register:
  `/home/claude/research/swift/docs/ABI/CallingConventionSummary.rst:48` (`r12` on x86-64) and `:153`
  (`x21` on arm64). IRGen marks the slot `swifterror`: `lib/IRGen/GenCall.cpp:5504-5512`
  (`setSwiftError(true)` when `IGM.ShouldUseSwiftError && !isAsync`), null-initialized at `:5515-5518`.
  `docs/ErrorHandlingRationale.md:712-724`: *"a function call could return an optional error in a special
  result register; the caller would check this register... Branches involved in testing for errors are
  usually very easy to predict, so in hot code the direct performance impact is quite small, and the
  total impact is dominated by decreased code locality."* **Caveat [V] at `GenCall.cpp:5508-5511`: async
  functions do NOT get the register — errors go indirectly through the async context. Keep Assay's
  decode functions synchronous.**
- **Typed throws avoids boxing [V].** SE-0413 `:221`: *"Untyped errors have the existential type
  `any Error`, which incurs some necessary overhead, in code size, **heap allocation overhead**, and
  execution performance"*; `:89`: typed throws *"open up the potential for more efficient code, because
  they avoid the overhead associated with existential types."* → use `throws(AssayError)` with a
  concrete, small, frozen error type.
- **Empty `[Issue]` does not allocate [V].** `stdlib/public/core/ContiguousArrayBuffer.swift:121-127`:
  *"The empty array prototype. We use the same object for all empty `[Native]Array<Element>`s"* —
  `_emptyArrayStorage` is `Builtin.addressof(&_swiftEmptyArrayStorage)`, **the address of a global, not
  a heap object.** `_ContiguousArrayBuffer.init()` (`:500-503`) just stores it;
  `SwiftNativeNSArray.swift:588` asserts it is never deallocated. **`var issues: [Issue] = []` is a store
  of a constant global pointer — genuinely free until the first `append`.**
- **`inout [Issue]` is statically enforced — no `swift_beginAccess` [V].** SE-0176 `:271-274`: *"Local
  variables, inout parameters, and struct properties can generally enforce the rule **statically**."*
  `:577-588`: *"non-escaping variables can always use static enforcement... we are essentially able to
  guarantee that the variable will have **C-like performance**... This guarantee also ensures that only
  static enforcement is needed for `inout` parameters, which cannot be captured in escaping closures."*
  Corroborated by `docs/OwnershipManifesto.md:650-661` and `:632-635` (*"imposes no runtime costs"*).
  The deciding pass is `lib/SILOptimizer/Mandatory/AccessEnforcementSelection.cpp`
  (`setStaticEnforcement` `:50`, `setDynamicEnforcement` `:57`); dynamic is selected only for
  boxed/escaping captures (`:112, :487`).
  > **The one trap [V]:** the guarantee holds only if the array is a local `var` or `inout` param
  > **never captured by an escaping closure**. If generated code captures it escapingly it gets boxed →
  > `alloc_box` → dynamic enforcement → a `swift_beginAccess`/`swift_endAccess` pair **per field**.
  > **Avoid escaping closures in generated code entirely.** You should not need
  > `-enforce-exclusivity=unchecked` (that flag exists at `include/swift/Option/Options.td:1841`;
  > Embedded Swift defaults to it, `lib/Frontend/CompilerInvocation.cpp:3481-3484`).
- **Keep `Issue` out of the hot return type [V].** serde_json's own comment is the best evidence:
  `/home/claude/research/serde-json/src/error.rs:17-22` — *"This `Box` allows us to keep the size of
  `Error` as small as possible. A **larger `Error` type was substantially slower** due to all the
  functions that pass around `Result<T, Error>`."* → make Assay's thrown type pointer-sized (an index
  into the sink, or a single-word enum) and keep the payload in the sink array.

**How pydantic-core collects all errors [V], `/home/claude/research/pydantic-core/src/errors/`:**
`line_error.rs:35-40` — `enum ValError { LineErrors(Vec<ValLineError>), InternalErr(PyErr), Omit,
UseDefault }`; `ValLineError` (`:101-106`) = `{ error_type, location, input_value }`. **The path is not
a String** — `location.rs:15-25`: `enum LocItem { S(String), I(i64) }`; `:86-98`:
`enum Location { #[default] Empty, List(Vec<LocItem>) }` with the comment *"no location, avoid creating
an unnecessary vec"*, and *"location in List is stored in **REVERSE** so adding an 'outer' item to
location involves **pushing to the vec which is faster than inserting and shifting** everything along"*.
The path is built **outward as the error unwinds** (`ValError::with_outer_location`, `line_error.rs:83-95`)
— **no path is materialized on the happy path at all.** Its one weakness Assay can beat:
`src/validators/model_fields.rs:164` does `Vec::with_capacity(self.fields.len())` **unconditionally** —
a real heap allocation per model validation even when nothing fails. Swift's non-allocating empty array
avoids that. It also has a `fail_fast` option (`src/validators/tuple.rs:24,98`, `dict.rs:26,120`) checked
as `fail_fast && !errors.is_empty()` — a user-facing schema option, not a perf default.

**Span representation.** rustc packs a `Span` into 8 bytes with an interner side table
(`compiler/rustc_span/src/span_encoding.rs`) **[V]**:
```rust
pub struct Span { lo_or_index: u32, len_with_tag_or_marker: u16, ctxt_or_parent_or_marker: u16 }
```
Module doc: *"`SpanData` is 16 bytes, which is too big to stick everywhere. `Span` only takes up 8
bytes, with less space for the length, parent and context."* `lo` at 32 bits *"allows up to 4 GiB of
code in a crate"*; the length field gets ~15 bits because *"15 bits is enough for 99.99%+ of cases"*,
with a side interner for the rest.

**For Assay [U]:** you have no `ctxt`/`parent`, so the pressure is far lower. Use
**`@frozen struct Span { let lo: UInt32; let len: UInt32 }` = 8 bytes** — rustc's budget with none of
the tagging complexity. Length is what you need to underline a token; re-deriving it would require
re-lexing at render time, the one thing that isn't free. **Do not store line/column in the span.**

**Net design.** `Span { lo, len }` per issue; issues appended into an `inout ErrorSink` **struct**
(static exclusivity, empty-array singleton, no allocation until first failure) — not a class
(retain/release + *dynamic* exclusivity on class properties, SE-0176 `:276-279`), not
`UnsafeMutablePointer` (loses safety for no measurable win since static enforcement is already
zero-cost). Decode functions `throws(AssayError)` with a pointer-sized concrete error, and synchronous.
A `LineIndex` built lazily on first render by one newline scan, then binary-searched.
**Happy-path cost ≈ one predicted branch per decode call and one dead store of an immortal pointer —
no allocation, no runtime exclusivity check, no line/column work.**

---

## Summary of the highest-confidence recommendations

1. Emit a **compile-time 8-bit window dispatcher** (simdjson `key_selector.h` tier 1), falling back to
   length bucketing + `UInt64` compares. Never materialize a `String` for a key.
2. **Single-pass streaming in document order**, one slot per field + a `UInt64` presence bitmask.
   Both serde and simdjson's newest reflective path do this.
3. **Integers: unrolled, wrapping-arithmetic, overflow-check-free for the first N digits.** Skip SWAR.
   **Doubles: Clinger fast path, then defer to the stdlib.**
4. **Skip UTF-8 validation on keys and skipped values**; pay it only where a `String` is materialized.
   Keep the *structural* scan correct regardless.
5. **Scalar + SWAR, not SIMD** — Swift cannot portably express movemask, and yyjson demonstrates scalar
   beating simdjson's DOM path.
6. **Byte offsets only; line/column lazily.** `throws(ConcreteError)`, `inout ErrorSink` struct, no
   escaping closures in generated code.

---

## Do not assert these

- **The 20%-of-SIMD claim for small payloads.** No published GB/s-vs-input-size curve was found. The
  supporting facts (64-byte padding, 128-byte stage-1 steps, the 100 kB `iterate_many` floor) are
  verified; the specific percentage is not.
- **That LLVM/rustc turns `match` on strings into a length-bucketed trie.** rustc emits a `str::eq`
  call chain; any bucketing is an unguaranteed LLVM peephole. Community claims to the contrary are
  anecdotal.
- **The MPH-vs-compare-chain crossover point (~10-15 in-bucket candidates).** Derived from cycle
  reasoning, not measured. The mega-match-vs-phf figures are real but single-machine, N≈300, and the
  methodology was not audited.
- **Escape-frequency percentages in real JSON.** Asserted from experience, not from a corpus study.
- **That `loadUnaligned` back-deploys freely.** It carries no `@available` in this checkout and is
  `@_transparent`, which strongly implies it, but this was not confirmed against a shipping toolchain.
- **Anything about zod/valibot internals** — not read from source.
- **Any performance number for Assay itself.** Nothing here was compiled or benchmarked. Every
  recommendation is a hypothesis to be measured, and several (SWAR-vs-loop for integers, window-table
  vs length bucketing at small N) could plausibly invert on real hardware.
- **The exact `haszero`/`hasvalue` macro text as a Bit Twiddling Hacks quotation** — the page truncated
  before that block. The formula is correct by derivation, not by citation.
