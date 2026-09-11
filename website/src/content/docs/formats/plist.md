---
title: Property lists
description: Binary and XML behind one entry point, with the two amplification attacks that no depth limit catches — and why this is not content sniffing.
---

```swift
import AssayPlist

@Schema(keys: .snakeCase, formats: .all)
struct Deployment {
    var name: String
    var image: String
    var replicas: Int
}

let settings = try Deployment.parse(plist: bytes)     // either flavour
```

`PropertyListSerialization` is not linked, not referenced, and not needed. This decodes the
same way on Linux and Windows as it does on a Mac.

## Two flavours, one entry point

The XML flavour is a document:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>name</key><string>api</string>
  <key>image</key><string>img:1</string>
  <key>replicas</key><integer>3</integer>
</dict>
</plist>
```

```text
Deployment(name: "api", image: "img:1", replicas: 3, region: "eu-west-1", healthCheck: nil)
```

The binary flavour is not a document at all. It is a random-access object graph: a trailer at
the end of the file, an offset table, and every value resolved by index through it.

```text
// 'bplist00' + 86 bytes, written by PropertyListSerialization
62 70 6c 69 73 74 30 30 d3 01 02 03 04 05 06 54 …
```

```text
Deployment(name: "api", image: "img:1", replicas: 3, region: "eu-west-1", healthCheck: nil)
```

Same call, same struct, same result. If you have a reason to require one encoding, say so:

```swift
try Settings.parse(plist: bytes)          // either
try Settings.parse(binaryPlist: bytes)    // binary only
try Settings.parse(xmlPlist: bytes)       // XML only
```

### This is not sniffing, and the distinction matters

Elsewhere on this site there is a hard rule: Assay never guesses a format from bytes.
[Content negotiation](/formats/http/) makes you pass `accepting:` with no default, precisely
so no one can hand your server an XML bomb by writing a different `Content-Type`.

A plist is the exception that proves the rule, because it is not an exception. You already
said "this is a property list". Binary and XML are two *encodings* of the one format you
named, the same way UTF-8 and UTF-16 are two encodings inside XML, which every XML parser
resolves from the bytes without anyone calling it sniffing.

The discriminator is also exact rather than heuristic: `bplist00`, eight magic bytes at
offset zero. Not a shape somebody recognised.

## The XML flavour inherits the XXE refusal

Every XML plist ever written carries this:

```xml
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
```

A reader that resolved that `SYSTEM` identifier would be the textbook XXE, in a format people
parse without thinking about it. The XML flavour reuses [Assay's XML
parser](/formats/xml/#xxe-is-refused-by-construction), which has no code path that fetches an
external entity — so the refusal is inherited rather than reimplemented, and there is no
second implementation to get it wrong later.

## The binary flavour has two attacks that depth limits miss

Worth knowing about even if you never write a parser, because they explain why the entry
point takes a `Limits` and what it is protecting.

**Reference cycles.** An array whose element reference points at the array itself. Twenty
bytes on disk, infinite to read. There is no syntax that forbids it, because the format is a
graph and a cycle is a well-formed graph.

The guard is a visiting set on the *reference path* — pushed on descent, popped on return.
Deliberately not a global "seen" set: an object referenced twice from two different branches
is **shared**, which is legal and common, since Foundation's own writer deduplicates repeated
values into exactly that shape. Only an object reached from inside itself is a cycle. The
issue code is `plist_cycle`.

**Shared-object amplification.** Ten arrays, each holding a thousand references to the one
below it. Under a kilobyte on disk, 10³⁰ nodes if you materialise it. No cycle, every
reference to a distinct real object, and `maxDepth` never fires because the depth is *ten*.

This is the plist spelling of billion laughs, and depth cannot bound it because the expansion
is wide rather than deep. The guard is a node budget charged per materialised node against a
ceiling derived from the input size: a real document cannot describe more nodes than it has
bytes to describe them with, and a bomb can. The issue code is `plist_amplification`.

Both bombs are constructed byte by byte in the test suite rather than described. A test that
asserts a limit exists without building the input it bounds is a test that keeps passing when
the limit is deleted.

## Errors

Same carets, same codes, same everything:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>name</key><string>api</string>
  <key>image</key><string>img:1</string>
  <key>replicas</key><string>three</string>
</dict>
</plist>
```

```text
Settings.plist: error: replicas must be an integer, found "three"

1 error
```

The binary flavour cannot give you a caret, because there is no text to point at. You get the
path and the code, which is what a binary format can honestly offer.

## Next

- [HTTP bodies](/formats/http/) — the entry point that does refuse to guess.
- [Limits](/reference/limits-and-security/) — every budget, and what each one stops.
- [XML](/formats/xml/) — the parser this borrows.
