# Property lists

**Built 2026-09-09.** `EXPERIENCE.md` §1 named `parse(plist:)`; `ROADMAP.md` §10 deferred it
with one sentence — *"Binary and XML plists, as a separate product on the `RawValue`
projection path the YAML and XML decoders already use. Mechanically the smallest item on this
list."*

That sentence was wrong in both halves, and this document is mostly about why, because the
part it got wrong is the part with a security surface.

```swift
import AssayPlist

@Schema(keys: .snakeCase, formats: .all)
struct Settings {
    var name: String
    var retryCount: Int
}

let s = try Settings.parse(plist: bytes)     // either flavour
```

---

## 1. It is two formats, and only one of them is a projection

| | XML plist | binary plist |
|---|---|---|
| shape | a document, read front to back | a **random-access object graph** |
| reached by | nesting | an offset table in a trailer at the **end** of the file |
| containers hold | children | **references** |
| a projection of something existing? | yes — `AssayXML`'s parser | no |
| lines of implementation | ~150 | ~380, most of them bounds checks |

The XML flavour is what the roadmap described. It reuses `AssayXML`'s parser — which matters
for one reason beyond not writing a second one: **every XML plist ever written carries**

```xml
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
```

A plist reader that resolved that `SYSTEM` identifier would be the textbook XXE. Assay's XML
parser refuses external entities *by construction* — no resolution path exists — so the
refusal is inherited rather than reimplemented, and there is no second implementation to get
it wrong later.

The binary flavour is a different exercise. Reading it is closer to reading an object file
than to reading a document: parse a 32-byte trailer, read an offset table, resolve every value
by index through it. Nothing about the YAML or XML path applies.

---

## 2. The two amplification attacks, neither of which any existing limit covered

`Limits` already bounded bytes, issues and depth. **None of the three stops either of these.**

### 2.1 Reference cycles

An array whose element reference points at the array itself. There is no syntax that prevents
it — the format is a graph, and a cycle is a well-formed graph. A naive recursive reader never
returns.

```
object 0: array [ ref 0 ]      # 20 bytes on disk, infinite to read
```

**Closed by a visiting set on the reference path** — pushed on descent, popped on return.
Deliberately *not* a global "seen" set: an object referenced twice from two different branches
is **shared**, which is legal and common (Foundation's own writer deduplicates repeated values
into exactly that shape). Only an object reached from inside itself is a cycle.

Issue code: `plist_cycle`.

### 2.2 Shared-object amplification

Ten arrays, each holding a thousand references to the one below it. Under a kilobyte on disk;
10³⁰ nodes materialised. **No cycle** — every reference is to a distinct, real, forward
object — and `maxDepth` does not fire, because the depth is *ten*.

This is the plist spelling of billion-laughs, and it is the one the roadmap's one-sentence
deferral hid. Depth cannot bound it because the expansion is wide, not deep.

**Closed by a node budget**, charged per materialised node against a ceiling derived from the
input size: a real document cannot materialise more nodes than it has bytes to describe them
with, and a bomb can. The same device the YAML parser already uses for alias bombs, for the
same reason.

Issue code: `plist_amplification`.

Both bombs are **constructed byte by byte** in `Tests/AssayTests/PlistTests.swift`, not
described. A test that asserts a limit exists without building the input it bounds is a test
that keeps passing when the limit is deleted.

---

## 3. What the fuzz arm found, and why it exists

`Benchmarks/Sources/DiffFuzz/PlistOracle.swift` mutates and truncates documents Foundation
wrote — 12,234 inputs per run, weighted towards the trailer.

**The trailer is why this arm is not optional.** In every other format Assay reads, a flipped
byte produces a parse error a few bytes later. In a binary plist the trailer at the *end* of
the file carries the offset width, the reference width, the object count and the address of
the offset table; changing one byte there redirects every subsequent read to somewhere the
file did not intend. That is the shape that produces out-of-bounds reads and integer traps
rather than diagnostics.

It found one before it had run a hundred inputs, and the same bug had already been found
minutes earlier by the truncation test:

> `Int(someUInt64)` **traps** on anything above `Int.max`. The object count, the top-object
> index and the offset-table address are all read as `UInt64` straight out of the file, and
> the obvious narrowing turns a malformed document into a crash rather than an issue.

Fixed by range-checking against the file size before narrowing, in three places plus every
object reference. The fuzz arm is what keeps it fixed.

**And it missed a second one of exactly the same kind, which is worth recording.** A day later,
reading the code rather than running it turned up three unchecked multiplications:

```swift
guard start + n * 2 <= limit               // UTF-16 string
guard start + n * objectRefSize <= limit   // array
guard start + n * objectRefSize * 2 <= limit  // dictionary, keys then values
```

`n` came from the "0xF in the size nibble, then an integer object holding the real count"
escape, bounded only by `Int.max`. In Swift an overflowing `*` **traps**; the process died
rather than returning an error. Every other bound in the reader was checked and these three
were not.

The fuzzer had run 12,000 inputs over it and found nothing, for a reason that generalises:
reaching the bug needs a specific nibble AND a well-formed integer marker AND an extreme value
**in the same object**, and single-byte mutation of a valid document produces that combination
essentially never. Random mutation is good at malformed bytes and bad at malformed *structure*.

Fixed at the source — `count()` now bounds the count by the file's own size, which is both true
(no object can have more elements than there are bytes to describe them with) and sufficient
for all three multiplications, so a fourth call site added later cannot forget. The fuzz arm
gained a generator that constructs the 0xF escape deliberately across every container marker
and several extreme counts, which is what would have found it.

---

## 4. The type mapping, and the two places the flavours deliberately disagree

| plist | `RawValue` |
|---|---|
| `<true/>` `<false/>` / marker `0x08` `0x09` | `.bool` |
| `<integer>` / `0x1n` | `.int` |
| `<real>` / `0x2n` | `.double` |
| `<string>` / `0x5n` ASCII, `0x6n` UTF-16BE | `.string` |
| `<data>` / `0x4n` | `.string`, **base64** |
| `<array>` / `0xAn` | `.sequence` |
| `<dict>` / `0xDn` | `.mapping` |
| UID / `0x8n` | `.int` |
| `<date>` / `0x33` | **see below** |

**`<data>` becomes base64 rather than a new `RawValue.data` case.** Adding a case would break
every exhaustive `switch` over `RawValue` in this package and in user code, for one format's
one type. Base64 is also what the XML flavour writes for the same bytes, so the two flavours
produce the *identical* `RawValue` — which is the property that makes "either flavour" a
sound default rather than a convenience with a footnote.

**Dates are the one place the flavours differ, and it is deliberate.** Each yields what it
actually stores:

- binary → `.double`, seconds since **2001-01-01 UTC** (the epoch the format uses)
- XML → `.string`, the ISO-8601 text as written

Converting either one would mean choosing an epoch inside a Foundation-free core, and
`@DateFormat(.unix)` is not it — the epochs differ by 978,307,200 seconds. The conversion is
the caller's, and it is stated here rather than left to be discovered.

**A UID is an `.int`.** UIDs appear in `NSKeyedArchiver` output, which this does not pretend to
decode: a keyed archive is a different format that happens to be *written* in a plist, and
reading one properly is a separate feature nobody has asked for.

---

## 5. Where this is stricter than Foundation, on purpose

- **A `<key>` with no value, or a value with no `<key>`, is a malformed document.**
  Foundation is lenient. Being lenient about *which value belongs to which key* is not a
  leniency worth having — it silently produces a different document than the one written.
- **An integer that does not fit `Int64` is refused, not saturated** (`plist_int_out_of_range`,
  and `plist_int_too_wide` for the binary format's 128-bit integers). A number read as a
  *different number* is the one failure a decoder must never have.
- **`<data>` that is not valid base64 is refused**, rather than passed through as a string that
  looks like data and is not.
- **An unpaired surrogate in a UTF-16 string is refused**, not replaced with U+FFFD. A decoder
  that silently repairs its input is a decoder whose output nobody can reason about.
- **A non-string dictionary key is refused** (`plist_unrepresentable_key`) — plists allow them,
  `RawValue.Member.key` is a `String`. The same refusal the YAML entry point already makes.

---

## 6. Two flavours, one entry point — and that is not sniffing

`parse(body:contentType:accepting:)` refuses to guess a **format** from bytes, and that
refusal stands: it is the difference between a caller who said "this is JSON" and a decoder
that decided.

`parse(plist:)` is a different situation on both counts. The caller has already said the
format is "property list"; binary and XML are two *encodings* of the one format they named —
the same relation UTF-8 and UTF-16 have inside XML, which every XML parser resolves from the
bytes. And the discriminator is **exact**: `bplist00`, eight magic bytes at offset zero, not a
shape someone recognised.

A caller with a reason to require one encoding has `parse(binaryPlist:)` and
`parse(xmlPlist:)`. `Plist.encoding(of:)` answers the question directly.

---

## 7. What is not built

- **Writing.** `@Schema(encodes: true)` produces JSON, YAML and XML. Plist output is not
  built, and unlike the deferrals above there is nothing subtle about it — it has simply not
  been asked for. The `RawValue` seam the YAML writer uses would carry it.
- **Keyed archives.** See §4.
- **`bplist15`/`bplist16`.** Undocumented, unstable, and not what Apple's public tooling
  writes. Only `bplist00` is recognised; anything else is `plist_bad_magic`.
