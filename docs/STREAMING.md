# Streaming

*Design note. "Can Assay support a streaming interface?" turns out to be three different
questions with three different answers.*

**Status: proposed. Not built.**

---

## 0. The answer in one line

**Yes for record streams, yes for large top-level arrays, no for incremental parsing of a
single huge document** — and the third is a refusal on architectural grounds rather than
an unbuilt feature.

---

## 1. Why this is not one question

| shape | example | verdict |
|---|---|---|
| **A. Record stream** | NDJSON / JSON Lines, multi-document YAML, a log file | **build it** — natural fit, high value |
| **B. Large top-level array** | `[{…}, {…}, …]` × 500 MB from an export endpoint | **build it** — feasible, some real work |
| **C. Incremental single document** | feed bytes as they arrive, get a partial value | **refuse** — see §4 |

Shape A is what most people mean and it costs Assay almost nothing. Shape C is what
"streaming parser" means in the abstract and it would cost Assay most of its design.

---

## 2. What the current design commits to that streaming touches

Four commitments, all load-bearing, all assuming full residency of the *current document*:

1. **Whole-buffer UTF-8 validation up front** (`PERFORMANCE.md` §5.4). The measured
   justification is serde_json's 1.65× penalty for per-string validation. §5.4 states the
   caveat outright: *"this is only sound if the input is a single contiguous buffer that
   does not change underneath the parse … which is a second reason the public API takes
   bytes and not a stream."*
2. **Zero-copy string slices.** The no-escape fast path is a byte range in the input
   buffer. If the buffer is a sliding window, that range can be recycled underneath a
   value that still refers to it.
3. **Byte-offset source spans.** `SourceSpan { lo, len }` is 8 bytes precisely because
   line/column is derived later from the buffer. Derive it from *which* buffer, if the
   bytes are gone?
4. **Synchronous decode** (`PERFORMANCE.md` §3.2, §8.3). `throws` returns in the
   callee-saved `swifterror` register; async functions do not get it, and
   `withUnsafeTemporaryAllocation` cannot span an `await`.

**Every one of these survives shapes A and B, because both keep exactly one record
resident at a time.** They survive by scoping full residency to the *record* rather than
the *stream* — which is a narrowing of what "contiguous buffer" means, not an abandonment.

Only shape C breaks all four at once.

---

## 3. The two that should be built

### 3.1 The async boundary goes at the record boundary, never inside a decode

This is the load-bearing API decision, and it is what lets §3.2's synchronous-decode
constraint survive contact with `AsyncSequence`:

```
   async I/O  →  buffer  →  find record boundary  →  SYNCHRONOUS decode  →  yield
   ^^^^^^^^^                                         ^^^^^^^^^^^^^^^^^^^
   awaits here                                       never awaits here
```

The decoder never becomes `async`. It is called, synchronously, once per record, from
inside an async driver that owns the buffering. So the `swifterror` register, the stack
scratch buffer, and every codegen constraint in §8 all still apply unchanged.

### 3.2 Shape A — record streams

```swift
// Synchronous, over bytes already in hand.
try Article.parseLines(json: bytes) { article in … }

// Asynchronous, over a byte stream.
for try await article in Article.stream(jsonLines: byteStream) { … }

// Per-record diagnosis, so one bad record does not abort the run.
for await result in Article.diagnoseStream(jsonLines: byteStream) {
    switch result { case .value(let a): …; case .invalid(let d): log(d.render(.plain)) }
}
```

The last shape is the one that makes this worth building: a 10 GB log file where record
847,231 is malformed should yield 847,230 values and one diagnosis, not one error. That
is the whole "errors are the product" thesis applied at stream scale, and it is not
expressible with `parse` returning `T`.

`parseAll(yaml:)` in `EXPERIENCE.md` §12 is already this shape for multi-document YAML,
so shape A is partly a promise already made.

**Record-boundary detection must respect string state.** Splitting NDJSON on `\n` is
wrong the moment a string contains an escaped newline. The boundary scanner is the same
depth-and-quote state machine `skipValue` already implements.

### 3.3 Shape B — large top-level arrays

```swift
try Item.parseElements(json: bytes) { item in … }
for try await item in Item.stream(jsonArray: byteStream) { … }
```

Mechanically the same as shape A once the leading `[` is consumed: each element is a
bounded window found by depth counting, decoded synchronously, yielded. Harder than A only
in that elements can straddle chunk boundaries, so the buffer must compact rather than
reset.

This is the shape that answers "large data" for the common case — a paginated export, a
bulk endpoint — where the *document* is huge but every *record* is 1–50 kB, i.e. exactly
Assay's measured band, repeated.

### 3.4 Consequences to design for

- **Limits become per-record.** `maxBytes` bounds a record, not the stream, plus a
  separate cap on how far the boundary scanner will look before declaring a malformed
  record. Without the second one, a stream with no delimiter is an unbounded buffer —
  a denial-of-service hole of exactly the kind §2's `Limits` exists to close.
- **Spans become record-relative, plus a record index.** `Issue` gains the index; carets
  render against the current record's bytes, which are still resident. Stream-absolute
  offsets would be prettier and would require retaining bytes already discarded.
- **UTF-8 validation runs per record**, which is per *buffer*, not per *string* — so
  §5.4's 1.65× finding still does not apply.
- **`Assayer<T>`'s scratch reuse gets more valuable, not less.** A stream decodes the same
  type millions of times; steady-state zero scratch allocations is the entire point.

---

## 3.5 What the rest of the ecosystem actually does — researched 2026-07-26

Before refusing shape C, it is worth knowing what everyone else built. Four findings, and
the fourth changes §4.

**Finding 1 — every ecosystem solves it at the TOKEN level, and every one of them hands
the hard part to the user.** Jackson's `NonBlockingJsonParser` + `ByteArrayFeeder`, .NET's
`Utf8JsonReader` + `JsonReaderState`, Go's `json.Decoder.Token()`/`More()`, Python's
`ijson`, Rust's `struson`. All genuinely incremental, all requiring the caller to write a
state machine over an event stream. That is a real solution and it is the opposite of
Assay's thesis, which is that the *declaration* is the schema.

**Finding 2 — the elegant version is a HYBRID, and Go's standard library has the best
one.** Interleave `Token()` to walk the skeleton with `Decode(&v)` to bind a *bounded
subtree* into a typed value:

```go
dec.Token()                 // consume '['
for dec.More() {
    var item Item
    dec.Decode(&item)       // full typed decode of one bounded element
}
```

Elegant precisely because it does *not* try to be incremental. Each `Decode` sees a
complete, bounded value. Jackson has the same shape via `parser.readValueAs(Class)` at a
token position; `ijson.items(f, 'item.author')` is the path-driven variant.

**Finding 3 — .NET tried to make the hybrid work at the typed layer and it is broken.**
`JsonSerializer.Deserialize(ref reader)` on a *resumed* `Utf8JsonReader` fails, because the
serializer copies the whole object into a separate buffer *including the `{` the reader
already consumed*. [dotnet/runtime#67454] is open, milestone "Future", no PR.
[dotnet/runtime#29911] is worse: `Utf8JsonReader` retains state that `JsonReaderState`
does not capture, so resumption is not reliably possible from the documented state object
at all. **The most-cited "solved" implementation has the hybrid broken in exactly the
place Assay would need it.**

**Finding 4 — the fastest parser in existence refuses outright**, and for a structural
reason: simdjson's stage-1 structural index is O(n) in document size. From the maintainers:
*"If it is one big JSON document, simdjson does not support such a use case currently, and
the developers do not expect they will ever support it with the DOM API."*

### And the finding that changes the answer: mmap

A 1.5 GB document parsed under a **64 MB** memory limit: the load-everything approach was
killed by the OOM killer at 5.1s; mmap plus a streaming handler completed in 3.35s
([tinselcity](https://tinselcity.github.io/Large-Json-Stream/)).

The reason this matters here is specific. §2's first constraint is *"a single contiguous
buffer that does not change underneath the parse."* **An mmap'd file satisfies that
literally.** Virtual address space is contiguous; physical residency is not, and the kernel
demand-loads and evicts pages. So for a file on disk:

- zero-copy string slices still point into valid mapped memory;
- byte-offset source spans still resolve, and rendering a caret faults the page back in;
- whole-buffer UTF-8 validation is still one linear pass — sequential, prefetch-friendly,
  and the pages it touches are immediately evictable;
- **RSS stays bounded by what the OS chooses to keep, not by document size.**

No incremental parser, no resumable state machine, no redesign. The recursive-descent
decoder does not need to know the buffer is mapped.


### Measured, 2026-07-26

387 MB JSON document, `{"version":"1","items":[…8,000,000 records…]}`, Apple silicon,
macOS 26.5.2, `swift build -c release`, `/usr/bin/time -l`.

**Case 1 — extract only `version`** (the shape mmap exists for: a few fields out of a huge
document, `items` undeclared so it is structurally skipped):

| | wall | max RSS | **peak footprint** |
|---|---|---|---|
| read file into `[UInt8]` | 0.76 s | 412 MB | **407 MB** |
| `parse(mmappedPath:)` | **0.21 s** | 412 MB | **1.88 MB** |

**216× less footprint, 3.6× faster.**

**Case 2 — decode all 8,000,000 items:**

| | wall | max RSS | **peak footprint** |
|---|---|---|---|
| read into `[UInt8]` | 0.71 s | 1.07 GB | **1.067 GB** |
| `parse(mmappedPath:)` | 0.68 s | 1.07 GB | **661 MB** |

**406 MB apart — exactly the file size.** An earlier draft of this note reported case 2 as
"identical both ways" and concluded mmap "buys nothing" when the output is large. That was
measured on **max RSS only**, and it was wrong. RSS is identical because both have the same
pages resident; footprint differs because 387 MB of them are clean in one case and dirty in
the other.

The model that actually holds:

```
peak accountable memory  =  input  +  output
   read():  387 MB (dirty)  +  661 MB  ≈  1.05 GB
   mmap():   ~0   (clean)   +  661 MB  =   661 MB
```

**mmap saves exactly the size of the file, always.** What varies is whether that constant
matters next to the output — 216x when you keep a header, 1.6x when you keep everything.
The absolute saving is the same both times.

Both rows matter, and the second is the one that keeps this from being oversold: **mmap
bounds the INPUT, not the total.** It does not let you decode a 10 GB file into a 10 GB
array on a 4 GB machine; it lets you *read* a 10 GB file cheaply. Bounded total memory
needs both halves — mmap for the input and per-record yielding for the output (shape B),
which is not built.

### Correcting an imprecise claim

An earlier draft of this note said mmap means "resident memory is bounded by what the OS
keeps, not by document size." **Max RSS is the same either way** — 412 MB — because the
whole-buffer UTF-8 validation pass touches every page and, under no memory pressure, the
kernel simply keeps them.

The right metric is **footprint**: dirty, anonymous memory attributable to the process.
That is what memory limits, jetsam and the OOM killer act on. Mapped pages are *clean and
file-backed*, so they evict for free; an `[UInt8]` is dirty anonymous memory that must be
written to swap before it can be reclaimed. Hence 407 MB against 1.88 MB, and hence
tinselcity's result — a 1.5 GB document under a 64 MB limit is OOM-killed when read into
memory and completes in 3.35 s when mapped.

The accurate claim: **mmap does not reduce how many pages are touched; it changes them
from irreclaimable to free-to-reclaim, and removes the copy.**

And the honest boundary: mmap removes the *input* from your accountable memory and does
nothing about the *output*. Extract a header from something huge and that is the whole
story; decode everything and it is a fixed 387 MB off a 1.07 GB total. Useful either way,
decisive only in the first.

### Caveats

It is **files only** — a socket cannot be mapped, so the network case is untouched; the *output* values still cost RAM proportional to what you retain, so
decoding a 10 GB document into one struct that keeps all of it still fails; and
`Limits.maxDepth` matters more, not less, since recursion depth is now the binding
constraint rather than input size.

---

## 4. Shape C, and why the answer is still no — with one correction

**Correction to an earlier draft of this note.** It claimed shape C requires abandoning
all four commitments in §2. For the **file** case that is wrong: mmap satisfies the
contiguous-buffer requirement (§3.5), so a huge single document on disk is reachable with
no design change at all. The refusal below applies to the case mmap cannot serve — bytes
arriving over a socket.

True incremental parsing — feed arbitrary byte chunks, receive a partially-built value,
resume — would require:

- abandoning whole-buffer UTF-8 validation for a resumable validator carrying
  partial-sequence state across chunk boundaries;
- abandoning zero-copy strings, since any retained slice may outlive its chunk;
- a resumable state machine at *every* nesting level, replacing recursive descent — which
  also means the generated per-field code becomes a state machine rather than straight-line
  code, destroying the monomorphic-body property that §8.2 identifies as the reason a
  macro decoder can be fast at all;
- either retaining the whole document for source spans, or giving up carets.

That is not an increment on the current design; it is a second decoder. Apple has the same
open problem — swift-foundation issue **#1827, "Break assumptions on full input
residency"** — and has not solved it either.

The honest position, in the same spirit as `PERFORMANCE.md` §12.5's scope statement:

> Assay streams *records*, and reads arbitrarily large single documents **from a file**
> via mmap. It does not incrementally parse a single document arriving over a socket. If
> you have one 10 GB JSON object on the wire, Assay is the wrong tool and a pull parser
> is the right one.

The ecosystem evidence supports this line rather than embarrassing it: nobody has made
incremental typed decoding elegant, the one that came closest has it open-bugged, and
simdjson has publicly given up on it. What is *not* defensible is refusing the mmap case,
which is most of what "large file" means in practice and costs nothing to support.

Worth stating plainly rather than discovering: **shape C is the only one where "large
data" genuinely means one enormous value**, and in practice large JSON is nearly always
many records in a trench coat.

---

## 5. Relationship to the open question already on record

`EXPERIENCE.md` §20 asks whether `diagnose` needs a streaming form — issues yielded as
found rather than an array at the end — and answers *"probably no… but a large-file user
would know better."*

Shapes A and B answer it, differently and better than a streaming `diagnose` would: issues
are naturally batched **per record**, so a caller gets `Diagnosis<T>` per record with
bounded issue counts, and the existing `maxIssues` cap keeps working unchanged. No
streaming-issues API is needed. §20 question 1 can be closed.

---

## 6. Where it goes in the build order

Not phase 1, and not before allocation counts exist. Streaming multiplies whatever the
per-record allocation figure is by the record count, so shipping it before that number is
known would be shipping a multiplier on an unmeasured quantity.

Natural slot: **after phase 2** (`PERFORMANCE.md` §14), alongside steady-state scratch
reuse in `Assayer<T>`, which is the optimization streaming most depends on.

---

## 7. Open questions

1. **Does the async driver need `AsyncSequence`, or is a callback enough?** A callback is
   simpler, avoids the `AsyncSequence` existential, and composes worse. Leaning: ship the
   synchronous callback form first — it covers file-on-disk, which is most of the demand —
   and add the async form once there is a user for it.
2. **Back-pressure.** An `AsyncSequence` that decodes eagerly into a buffer will outrun a
   slow consumer. Bounded, and the bound belongs in `Limits`.
3. **Should shape B detect the leading `[` automatically**, so one API covers NDJSON and
   arrays? Convenient, and it makes the accepted input shape implicit — which §18 says not
   to do. Leaning: separate entry points.
4. **What does a record-boundary failure do to the stream?** Skip to the next boundary and
   continue, or terminate? Per-record `Diagnosis` implies skip-and-continue, but a stream
   that has lost sync will emit garbage indefinitely. Probably: a consecutive-failure
   threshold in `Limits`.
