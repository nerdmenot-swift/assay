# Roadmap

What `docs/EXPERIENCE.md` specifies but this repository does not yet implement, with the reason
each one was deferred rather than cut. Nothing here is abandoned; several items are one
afternoon's work sitting behind a decision that has not been made carefully enough yet.

The ordering is by what a user is most likely to reach for and be surprised is missing.

---

## 1. Encoding

**Status: BUILT 2026-08-09 for JSON, YAML and XML.** `EXPERIENCE.md` §14,
semantics in [`docs/ENCODING.md`](docs/ENCODING.md).

```swift
@Schema(encodes: true) struct Article { var title: String }
let bytes = try article.encode()            // throws AssayError, all issues
let d = article.diagnoseEncode()            // partial bytes + issues, same renderers
```

Opt-in, because generated body size dominates expansion cost and a decode-only type must not
pay for an encoder it never calls — the compile-time gate is unmoved at ~87 ms.

All six semantics questions were answered, accepted and implemented. The sixth
(`@Unknown(roundTrips:)`) was blocked on `@Unknown` existing at all; `@Unknown` shipped
2026-08-09 (§6), and encoding now refuses an unrecognised variant unless `roundTrips: true`.

YAML encodes through the `RawValue` seam — the decode pipeline run backwards. XML does not,
and cannot: placement is not expressible in `RawValue`, so XML has a generated body with
`@XML(.attribute)` / `.text` / `.wrapped` baked into the emitted calls. Both XML defaults
were settled by surveying Jackson, Go, .NET, serde-xml-rs and pydantic-xml rather than by
taste — see `docs/ENCODING.md`.

Round-trip is a stated law with a closed exception list, tested in
`Tests/AssayTests/EncodingTests.swift`.

This is the largest single gap, and it is deliberate: a decoder that also encodes has to answer
questions a decoder does not — what a `@Fallback` writes back, whether an `@Unknown` enum case
round-trips (either exactly right or a security hole, depending on who is asking), what
`@Transform` means in reverse when the closure has no inverse. Answering those badly and then
living with the answers is worse than not shipping them.

What matters is that the door is held open at real cost: **every piece of placement information
is preserved rather than consumed during decoding.** `@Key` renames, `@XML` element-vs-attribute
placement and `@DateFormat` patterns are all stored in the generated schema even though the
decode path does not read them back. That is why encoding is additive later instead of a
redesign, and it is being paid for now.

**Was blocked on:** deciding the semantics questions in [`docs/ENCODING.md`](docs/ENCODING.md),
in writing, before any code. That document enumerates six questions (this section originally
named three and miscounted them as five), and **all six were accepted and implemented on
2026-08-09** — its own header says so. The paragraph that stood here described them as
"proposals awaiting a yes or no" for some weeks after they had been answered and built.

---

## 2. `Date`, and `@DateFormat`

**Status: implemented 2026-08-06**, measured at **6.06× over Foundation's `.iso8601`
strategy** on the `uuids-and-dates` corpus shape (`Benchmarks/RESULTS.md`), with a
2,279-instant exact differential against Foundation in DiffFuzz.

```swift
var created: Date                                  // ISO 8601, the default
@DateFormat(.unixSeconds)          var ts: Date
@DateFormat(.rfc9110)              var expires: Date   // all 3 forms RFC 9110 requires
@DateFormat(.pattern("yyyy-MM-dd")) var day: Date      // checked at compile time
@DateFormat(.iso8601, .unixMillis) var updated: Date   // candidate chain; fallback warns
```

The blocking question — where the epoch conversion lives, given the core's no-Foundation
rule — dissolved once the conversion was recognised as *arithmetic*, not calendar lookup:
Hinnant's days-from-civil is a handful of integer operations, so the parsers live in
`AssayCore/Dates.swift` and return epoch seconds as `Double`. The macro emits
`Date(timeIntervalSince1970:)` **into the user's module**, where `var created: Date` had
already forced a Foundation flavour into scope. No protocol, no retroactive conformance,
no `AssayFoundation` requirement — and the seam is pinned by a test that decodes into a
local stub `Date`.

Rules `.before` / `.after` / `.between` ship with it, type-checked at expansion, bounds
parsed once at rule construction, violations rendered as dates.

**Still deferred, with reasons:**

- **`.past` / `.future` rules.** They need "now", the core has no clock, and a clock seam
  is a design decision (injected? ambient? testable how?) that deserves its own pass.
- **Full UTS-35 patterns** (locale month names, eras). Deliberately excluded from the
  core forever — `EXPERIENCE.md` §11's ICU-cost argument — and still unbuilt in the
  Foundation-dependent layer where it would be an opt-in.
- ~~**Date *encoding***~~ — **built 2026-08-09** with the rest of encoding (§1). The
  preserved `@DateFormat` placement data is what made it additive rather than a redesign,
  which was the whole bet §1 describes.

---

## 3. `@Inline` and `@Key(path:)` — both BUILT 2026-09-08

`EXPERIENCE.md` §4.

### `@Key(path:)` — BUILT 2026-09-08

```swift
@Schema
struct Card {
    @Key(path: "profile.display_name") var displayName: String
    @Key(path: "profile.avatar")       var avatar: String?
    @Key(path: "meta.stats.views")     var views: Int
    var id: String
}
```

Both open questions are answered, and the answers are in
`Sources/AssayMacros/PathKeys.swift` beside the code rather than here.

**Where the caret goes.** *The path names the segment that failed; the caret points at the
innermost thing that existed.* Three cases, because there are three failures:

| document | reports |
|---|---|
| `{"id":"x"}` | `.missing` at `profile` — **once for the group**, not once per field under it |
| `{"profile":42}` | `.typeMismatch` at `profile`, caret on the `42` |
| `{"profile":{}}` | `.missing` at `profile.display_name` — the full path |

And the half the question did not name, which the five presence states force: **a missing
intermediate is absence** (an optional stays nil, a default applies, `@Fallback` fires), while
**a wrong-typed intermediate is an error even when every field under it is optional**, because
`missing != wrong` is law everywhere else here.

**What it costs.** It shares the dispatch machinery completely; there is no second pass.
`profile` is an ordinary top-level key with one arm in the same window-dispatch table every
other key uses, and that arm descends. Two fields under one prefix are **one arm**, not two.

Measured against the fallback this section used to recommend, with the ship-or-refuse rule
written before the number — *within 1.15× of the nested-`@Schema` alternative or it does not
ship*:

```
shape              bytes   nested ns    paths ns     ratio
4 leaves             170         419         411     0.98x
+3 plain keys        208           -         469     1.14x
```

**0.97–1.01× over four runs** (`Benchmarks/Sources/AssayBench/KeyPathBench.swift`). Read that
as "the walk costs no more than the nesting" rather than "paths are faster": the nested arm
also materialises two structs the caller then reaches through, and that asymmetry favours
paths. Compile time is reported, not gated, like the `arrays` arm beside it: **101 ms/type**
for a type where *every* field is behind a path, against 72 ms for the flat scalar arm.

**The inner dispatch is a linear chain, not a second window table**, which is a deliberate
departure from the shape sketched above. A window table is 256 bytes of array literal and
`COMPILE-TIME.md` rule 1 is that never emitting one bought 16% of expansion time; a group
holds one to three fields, and `Experiments/01-jump-table` measured that LLVM gives a balanced
binary search tree below ten arms anyway. The table would buy nothing at runtime and cost real
time at compile.

**Encoding merges prefixes.** Two paths sharing `profile` write one nested object, because
`{"profile.name": ...}` is a document this schema cannot read back and that would break
`ENCODING.md`'s round-trip law for every path field at once.

**One thing found by reading the expansion rather than by a test.** The sparse key-table
emitter writes every entry differing from a sentinel, and the sentinel was the field count —
which stops equalling the arm count the moment two fields share a prefix. The result still
decoded correctly (the `default:` arm catches it) and every test passed, while the expansion
carried a **253-assignment table literal**, the exact cost rule 1 exists to prevent. A
compile-time regression with no runtime symptom is invisible to a test suite.

**Index segments are refused**, with a diagnostic naming the alternative. `EXPERIENCE.md` §4
advertises `meta.tags[0]`; it is not built. Walking a key and indexing an array are different
operations — an index needs the element counted during the array's own decode, and every rule
in the table above would need a fourth answer for "the array was shorter than that". That is a
feature, not a segment type; it is listed in §14 rather than half-built here.

### `@Inline` — BUILT 2026-09-08

```swift
@Schema
struct Response {
    struct Pagination { var page: Int; @Key("per_page") var perPage: Int }
    @Inline var pagination: Pagination
    var items: [Item]
}
```

**The recorded blocker was the wrong blocker, and correcting it is what built the feature.**
It said detection "across module boundaries where the macro cannot see the other type's
members may be expensive or impossible". An attached macro receives the syntax of the
declaration it is attached to and nothing else — it cannot see another type's members in
**any** module, including one declared three lines above in the same file. There is no
lexical peer access and no compile-time string evaluation with which to compare two key sets.
The question was never what detection costs; it was whether a spelling exists in which it is
possible at all.

**Requiring the inlined type to be nested is that spelling.** Verified rather than assumed:
`DeclGroupSyntax.memberBlock.members` contains the nested `StructDeclSyntax`, and walking it
yields each member *with its attributes* — the probe read `perPage` and its
`@Key("per_page")` back out.

- **Collision detection is total and at expansion**, falling out of the duplicate-key check
  that already ran. No module asymmetry to be silent about.
- **Unknown-key handling works through the inline** — the claim serde's runtime `flatten`
  cannot make — because the flattened keys are in the outer type's known-key set.
- **Runtime cost is zero.** One dispatch table, one presence mask, one pass; only the
  memberwise initialiser reassembles the nested value, and a test asserts an inlined type
  decodes identically to the flat equivalent, including on a missing key.
- Compile time unmoved at 65.8 ms, and it should be *negative* for a type that would
  otherwise be two — flattening deletes a second type's fixed cost, which is
  `docs/COMPILE-TIME.md` §4's own advice made literal.

An optional inline is refused: with the keys at this level, "all absent" and "some absent"
are indistinguishable and there is no honest answer for which means nil. A non-nested type
gets a diagnostic that says why, not just what.

Building it merged the two near-identical construction blocks in `CodeGen` and `RawCodeGen`
into one helper. They were copies, and adding group reconstruction to one and not the other
is exactly the drift that makes a feature work on JSON and silently not on YAML — which the
multi-format test caught on its first run.

---

## 4. Format-specific placement: `@XML` — and XML arrays

**Status: BUILT 2026-08-09.** `@XML(.attribute)`, `@XML(.text)` and `@XML(.wrapped)` all
exist, checked at expansion (an `.attribute` on an array, or a `.wrapped` on a scalar, is a
compile error). `@XML(root:)` **shipped 2026-09-08**; the deferred decision was what the default should be
when unannotated, and the answer is an asymmetry: encoding always writes a root (the
declared name, or the type's), decoding checks one only if you declared it. A root element
is very often a wrapper the schema does not model — `<soap:Envelope>`, `<response>` — so
checking one nobody asked for would refuse documents that are fine; but if you wrote it
down you asserted a fact about the wire, and a mismatch is an **issue**, not a warning.
Matched on the local name, consistent with the projection.

**The array bug this uncovered is also fixed.** `[T]` fields did not decode from XML at all
before 2026-08-09, in any shape — see below for what was wrong.

**What that bug was, and it is fixed in both shapes.** `[T]` fields did not decode from XML
at all: the projection produced a `.mapping` with repeated keys where the schema path expected
a `.sequence`. Repeated members were preserved (a `Dictionary` would have dropped them), so
the information was there and ungrouped. Both spellings now work, and they work differently
on purpose — verified 2026-09-08:

```swift
var tags: [String]                  // <tags>a</tags><tags>b</tags>  — repeated siblings
@XML(.wrapped) var tags: [String]   // <tags><item>a</item></tags>   — a wrapper element
```

Repeated siblings need no annotation because that is simply how XML spells a sequence. The
wrapper form does need one, and that is the right asymmetry: `<tags>` containing `<item>`
elements is indistinguishable from a nested object without the schema saying which it means.

This matters for encoding beyond being a bug: `docs/ENCODING.md` question 5 commits the
encoder to targeting `.input` — writing the document `parse` accepts — so an XML encoder
cannot emit an array shape the XML decoder refuses. **XML encoding is therefore blocked on
two decisions, not one**, and they are listed in `docs/ENCODING.md`'s "what remains".

```swift
@XML(.attribute) var id: String
@XML(.element)   var title: String
@XML(.text)      var body: String
```

Without these, XML decoding maps elements to fields by name and cannot distinguish an attribute
from a child element. That covers a real slice of documents and not the interesting half.

**Was blocked on:** a decision about the default when unannotated, recorded above.

One implementation note worth carrying to `@Schema(context:)`, which has the same shape: the
obvious way to make a check optional per type — a no-op on the wide protocol, shadowed by a
real one on a constrained extension — **does not work**. Overloads resolve from the static
type, and inside `extension RawDecodable` the compiler does not know `Self: XMLRooted`, so
the no-op wins for every type including the ones that opted in. It compiles, runs, and checks
nothing. A metatype cast (`Self.self as? any XMLRooted.Type`), once per document, does work.

---

## 5. Shape-tolerance attributes — `@OneOrMany` BUILT, `@PickFirst` CUT

### `@OneOrMany` — built 2026-09-08

```swift
@OneOrMany var tags: [String]     // "swift" and ["swift"] both decode
```

**Building it surfaced an undeclared asymmetry.** The `RawValue` path already accepted a
single value where an array was declared, so `tags: swift` decoded from YAML and was a type
mismatch as JSON — the same declaration meaning different things per format, which
`EXPERIENCE.md` §12 explicitly refuses for `coerceScalars`.

It **cannot** simply be made strict, and that is the finding. XML spells a sequence as
repeated sibling elements, each arriving as its own decode call with the same key, so the raw
path appends rather than assigns. At that layer a lone `<tag>a</tag>` is indistinguishable
from `tags: swift` — there is nothing to branch on. Strictness there would break every XML
array.

So the attribute lands where the tolerance is a genuine choice (the JSON byte path), and the
asymmetry is stated as a contract with a test pinning it rather than left to be discovered.
**Closing it properly means grouping repeated members into a `.sequence` in the XML
projection**, which §4 records as deliberately not done — the members are preserved ungrouped,
so the information is there. That is the change this waits on, and it is its own.

Encoding always writes an array: the tolerant shape is input-only, which keeps
`docs/ENCODING.md`'s round-trip law intact.

### `@PickFirst` — cut, and this section's stated blocker was wrong

It said `@PickFirst` "needs a sum-type story first, which is item 6". Item 6 is
`@Wraps`/`@Unknown`, and **`@Unknown` is a catch-all case on a string enum, not a union** — it
was never the prerequisite.

The real one is `@Schema(discriminator:)`, which `EXPERIENCE.md` §9 specifies and which is
absent from this roadmap and from the code entirely. And `@PickFirst var id: StringOrInt`
cannot be built as spelled regardless: the macro would need `StringOrInt`'s branches and sees
a token. The sound spelling is an untagged union — `@Schema(discriminator: .none)` — which
*is* pick-first by definition. `CLAUDE.md`'s governing principle exactly: a different
construct, not a transliteration.

### Discriminated and untagged unions — NOT BUILT, and not previously on this roadmap

`EXPERIENCE.md` §9 specifies `@Schema(discriminator: "type")` and `discriminator: .none`.
Neither exists, and neither was listed here — this is a gap in the roadmap itself, found
while cutting `@PickFirst`.

They force the one thing the decode body was designed never to do: **rewind**. A
discriminated union must find the tag before choosing a branch (the `"type"` key may appear
last); an untagged one must try branches and back out, which is exponential under nesting
without a budget. Both primitives already exist — `AssayReader.seek(to:)` and
`IssueSink.rollback(to:)` — so this is a real design pass rather than a blocked one, and it
needs `docs/UNIONS.md` answering how a composed failure is reported, what bounds the
backtracking, and what encoding a union means.

## 6. `@Wraps` and `@Unknown` — BOTH BUILT

`@Unknown` shipped 2026-08-09. **`@Wraps` shipped 2026-09-08**, and it waited for
`Assayer<T>` for a concrete reason rather than by accident: before `AssayerBacked` existed a
wrapper had to hand-write `_assay` twice — bytes and `RawValue` — so this macro would have
emitted two decode bodies per wrapper, a real compile-time cost on a type whose whole job is
to hold one scalar.

It now emits a `static let assaySchema` and nothing else; the bodies come from
`AssayerBacked`'s `@inlinable` defaults, which exist once in `Assay` rather than once per
wrapper. That is sugar over a hand-writable spelling, which is the layering the rest of the
library uses.

```swift
@Wraps(String.self, .email)
struct EmailAddress {}
```

- **`init?(_:)` and the decoder run the same rule array**, which is what makes "this type
  cannot hold an invalid value" true rather than nearly true.
- **The wrapped type is restricted** to `String`, `Int64`, `Double`, `Bool`. A macro sees a
  type's name and nothing else, so it cannot emit a reader for one it does not recognise;
  anything else gets a diagnostic naming the alternative.
- **Rules are type-checked at expansion** by the same `RuleTypeCheck` `@Validate` uses, so
  `.email` on an `Int64` wrapper is a compile error in both places for the same reason.
- `Equatable`/`Hashable`/`CustomStringConvertible` are *declared* and synthesised — the macro
  cannot check that `String` is `Equatable`, so letting the type checker do it is the only
  sound route.

The test that matters is that a wrapper and `@Validate(.email)` on a plain `String` produce
**identical issues** — same code, path and params. A wrapper is not a second validation
mechanism; it is the same one, reached differently.

## 7. `Assayer<T>` — BUILT 2026-09-08

**The open question is answered: it is one front door with two receivers.** The static verbs
are spelled on a type, these on a value; same `Diagnosis`, same codes, same renderers. It
exists for two things `@Schema` cannot express — a schema with no declaration, and a type
that *is* a constrained scalar rather than an object.

The narrower protocol this section suspected might cover the domain-type case does cover it,
and does not compete: `AssayerBacked` is the requirement, `Assayer` is the value that fills
it. Both shipped.

**No macro change.** `CodeGen.swift` already emits `Base._assay(...)` for any unrecognised
token, so a conforming type is already a nested schema type; the checkpoint test passes with
`Sources/AssayMacros/` untouched, and the compile-time gate is unmoved at 67.4 ms.

Deliberately not in the first increment, with reasons in `docs/ASSAYER.md`:
`Assayer.schema(_:)` as a leaf, a bytes-driven interpreter, and scratch reuse — whose
premise in `CLAUDE.md`'s build order is **stale**, since a `Sendable` schema value cannot own
mutable scratch.

## 8. `@Schema(context:)` — BUILT 2026-09-08

```swift
@Schema(context: TenantContext.self)
struct Invitation {
    var email: String
    var role: String

    @Check
    static func roleIsAllowed(_ i: Invitation, _ ctx: TenantContext,
                              _ issues: inout Issues<Invitation>) {
        if !ctx.availableRoles.contains(i.role) { issues.add("is not available", at: \.role) }
    }
}

let invite = try Invitation.parse(json: data, context: tenant)
```

**Why the deferral stopped holding**, since "no users, and an API shaped for imagined users is
an API shaped wrong" was the right call when it was made. `@Check` shipped in the meantime, so
a cross-field rule needing a tenant ID has exactly one option today — a global or a `static
var`, in a library whose types are `Sendable` and whose entire posture is against ambient
state. And `@AsyncCheck`'s own motivating example in `EXPERIENCE.md` §10,
`await ctx.users.exists(email:)`, could not be written at all. That is a hole a shipped
feature created, not an imagined user.

**The macro half only.** The type-erased runtime context §10 describes for `Assayer<T>` is
still not built and is not on the way: that one would be designing for an imaginary user
twice over, once for the API and once for the erasure.

**"You cannot forget to pass it" is enforced, not advised.** A contextual type conforms to
`ContextualJSONAssayable` and *not* to `JSONAssayable`, so `parse(json:)` does not exist for
it. A defaulted `context: C? = nil` on the existing entry point would have made §10's sentence
false and handed the checks an optional to unwrap — `userInfo` again with better syntax.

**Every check takes the context, uniformly** — cross-field and field forms both. The macro
reads a token, not a signature, so a per-check opt-in is not something it could see; getting
it wrong is an ordinary "cannot convert" at the call site, which names both types.

**Zero cost to types that declare none.** The context type is threaded through code generation
as a string that is empty in the overwhelming case, so a context-free expansion is
byte-for-byte what it was before this existed — verified by dumping one and grepping for
`context`, not assumed. The gate measured 71 ms/type against 100.

**Three things it cost, all overload resolution, all the same lesson.**

1. A plain `@Schema` type containing a contextual one cannot work — there is no context to
   pass — and the macro cannot detect it, because it sees the token `Membership` and not what
   `Membership` declared. The bare error was "no exact matches in call to `_assay`", pointing
   into an expansion nobody wrote. An `@available(*, unavailable)` overload turns it into a
   sentence naming the fix: what the macro cannot detect, overload resolution can, because it
   runs after the type checker knows what `Membership` is.
2. `AssayContext` is declared once on a root `ContextualAssayable` rather than four times.
   Four copies compile and leave a type conforming to two of them with two same-named
   associated types a constrained extension cannot equate. The generated body also spells
   `typealias AssayContext = ...` rather than relying on inference across the refinement,
   which stops working as soon as a second conformance is in play.
3. **The async door silently resolved to the synchronous one.** The constrained extension had
   the `[UInt8]` overload of `diagnose` and not the `String` one, so
   `await T.diagnose(json: "...", context: c)` had exactly one candidate — the sync overload —
   and compiled, ran, and skipped every async check. Caught only by a test asserting that a
   taken email was rejected.

Point 3 is the third time this shape has bitten this library, after `@XML(root:)` and the
absorbing overload in point 1. The lesson each time: **an overload that is merely not selected
produces no diagnostic at all.** A feature whose correctness depends on which overload wins
needs a test that fails when the wrong one does.

---

## 9. Content negotiation — BUILT 2026-09-08

```swift
let user = try User.parse(body: bytes,
                          contentType: request.headers["Content-Type"],
                          accepting: [.json])
```

`accepting:` is **required, with no default**, as specified. What was actually missing was
not the code but a place to put it: `Assay` cannot depend on `AssayYAML` (the dependency runs
the other way), and `AssayYAML` cannot host a json+yaml+xml entry point without depending on
`AssayXML` too. One overload per combination is 2^n entry points.

**Formats are values.** `WireFormat` carries a media-type predicate and a decoder into
`RawValue`; `AssayCore` vends `.json`, `AssayYAML` vends `.yaml`, `AssayXML` vends `.xml`,
each in the module that owns its parser. The dependency moves to the call site, where it
already exists — a caller writing `accepting: [.json, .yaml]` has imported `AssayYAML`.

Decided while building:

- **RFC 6839 structured suffixes are honoured.** `application/vnd.github.v3+json` is JSON.
  Not a nicety: most versioned APIs spell their content type that way, and a negotiator that
  misses it rejects all of them.
- **`charset` is checked, never transcoded.** The core has no converter; `iso-8859-1` is
  refused rather than quietly read as UTF-8.
- **No sniffing, ever** — not even when the bytes are obviously JSON and JSON is accepted. A
  missing or unparseable `Content-Type` is an issue.
- **`unsupported_media_type` is its own code**, so a server maps it to 415 rather than 400.
- **A `.json` match routes to the byte path**, via an overload constrained on `JSONAssayable`.
  Without it, adding negotiation to a service would quietly move every JSON request onto the
  tree path — the boundary this library exists to delete.

The load-bearing test is that a rejected media type never reaches a parser: a billion-laughs
XML payload offered to `accepting: [.json]` produces exactly one issue, from negotiation, and
the XML parser is never entered.

## 10. Property lists

**Status: not implemented.** `EXPERIENCE.md` §1 lists `parse(plist:)`.

Binary and XML plists, as a separate product on the `RawValue` projection path the YAML and XML
decoders already use. Mechanically the smallest item on this list.

---

## 11. `jsonSchema(for:)` and `StandardSchema`

**Status: not implemented.** `EXPERIENCE.md` §§14–15.

```swift
let schema = Article.jsonSchema(for: .input)     // JSON Schema 2020-12
```

Emitting a JSON Schema document from a `@Schema` type, for OpenAPI generation and client
validation. `StandardSchema` conformance ships as a **separate zero-dependency package**, so
Assay never gains a dependency for the sake of an interop protocol.

Both need item 1's placement data to be complete before they can describe output shapes
faithfully.

---

## 12. Source spans for YAML and XML

**Status: BUILT 2026-08-13.** Schema issues on YAML and XML now carry a caret, as JSON's
always have.

The gap was structural rather than an oversight. JSON decodes from bytes with the cursor in
hand, so a rule violation reports the offset it is standing on. YAML and XML parse to a node
model, project it to `RawValue`, and decode from that — and the byte offset was gone by the
time a `@Validate` rule ran. The same failure rendered with a caret through JSON and without
one through YAML, which is the wrong way round for the library's headline feature.

`RawValue.Member` now carries an optional `span`, filled by whichever parser knows the
offset. YAML records it per mapping pair, XML per element content and per attribute value —
inside the quotes, so a schema issue underlines the value and not the name. Every one of
those fields is **excluded from `==` and `hash`**, so two documents differing only in
whitespace stay equal; a span is provenance, not value.

Two things it cost, both measured:

- **~2% on YAML** (`YAML.parse` 6.86x over Yams to 6.69x; struct decode 11.50x to 11.27x),
  and nothing on XML or JSON. The first implementation cost **25%** by scanning forward from
  the value looking for a trailing comment, which is O(value) per pair; scanning backward
  from the end and stopping at the previous newline is O(one line) and got it back.
- Two guards keep the backward scan correct without tracking quote state: a value ending in
  a quote is a quoted scalar whose `#` is content, and a walk that reaches a newline is
  looking at a multi-line value that cannot have a trailing comment.

**Still without spans:** elements inside a sequence or dictionary value. `Member.span` is
per mapping member, which is the granularity a schema field needs — "the value at this key".
An `@Validate` rule on an array *element* reports with a path and no caret, exactly as it did
before.

## 13. Index segments in `@Key(path:)`

**Status: not implemented, and deliberately not folded into §3.** `EXPERIENCE.md` §4
advertises `@Key(path: "meta.tags[0]")`; the macro refuses it with a diagnostic naming the
alternative.

It is not a missing segment type, it is a different operation. Walking a key asks a mapping
for a name; indexing asks an array for its *n*-th element, which means counting during the
array's own decode loop rather than dispatching on a key. And every rule in §3's caret table
needs a fourth answer — "the array was shorter than that" — which is neither absence (the
array was there) nor a type mismatch (the elements are the right type). Half-building it
would mean shipping a path spelling whose failure mode had no defined report.

Until then: declare the array and take the element in Swift, or use a nested `@Schema` type.

---

## 14. Streaming

**Status: out of scope, documented in `docs/STREAMING.md`.**

Not deferred — decided against, with the reasoning written down. `diagnose` returning issues
incrementally for very large documents is `EXPERIENCE.md` §20's first open question, and the
issue cap already covers the memory concern that motivates it.

---

## Windows: diagnosed, and the first hypothesis was wrong

**Recorded because the wrong guess is the useful part.** `swift test` on Windows ended in
`error: fatalError` with no source location. This document previously blamed expansion size,
reasoning that Windows threads default to a 1 MB stack against Unix's 8 MB and that
swift-syntax walks generated source recursively — which is a coherent story, matches a note
already in `ci.yml` about WebAssembly needing a 16 MB stack, and is **not what was happening**.

A throwaway diagnostic workflow settled it in two runs by asking three questions at once:

1. Does the library build? **Yes.**
2. Does a minimal package containing one large `formats: .all, encodes: true` type build?
   **Yes** — so expansion size is not the trigger and the stack theory is dead.
3. What does a verbose test-target build actually print?

Question 3 gave nothing on the first attempt, because the generated decode bodies emit
hundreds of "trailing closure is confusable" warnings and a 120-line tail was every one of
them and none of the error. Rebuilding with `-suppress-warnings` produced a single line:

```
MappedFileTests.swift:51:9: error: '_open' is unavailable: Variadic function is unavailable
```

`_open` is variadic in ucrt — `int _open(const char*, int, ...)` — and Swift cannot import a
C variadic function. The cause was a Windows shim added days earlier in the belief it was the
portable spelling; it had never been compiled on Windows because Windows had never been
tested. The fix replaces POSIX `open`/`write`/`close`/`unlink` with `fopen`/`fwrite`/
`fclose`/`remove`, which are not variadic, are C89, and exist under exactly those names on
Darwin, Glibc, Musl and ucrt alike — so the platform branching disappeared rather than
gaining a third arm.

Two things worth keeping from this:

- **`error: fatalError` is SwiftPM saying "a compile subprocess died", nothing more.** It
  carries no location and no stack. The same message appeared while verifying this fix on
  Linux, where the cause was `signal 9` — four stray containers competing for a 4 GiB VM.
  Two entirely different causes, one message. Treat it as "something died, go find out
  what", and suppress warnings before theorising: the actual Windows diagnostic was an
  ordinary unavailability error buried under hundreds of them.
- **A plausible mechanism is not evidence.** The stack story explained the symptom, cited a
  real platform difference, and was wrong. It cost one diagnostic run to disprove and would
  have cost far more to act on.

## Known behavioural gaps found by the pre-release audit

| gap | state |
|---|---|
| **A skipped value's contents are not validated** | `skipValue` checks a value's EXTENT — matching brackets, string state, depth — and never what is inside it. `{"known": 1, "unknown": NaN}` decodes through a schema; `JSON.Value.parse` refuses it. Deliberate: skipping is what makes the prefix path 6.3x, and validating a value to discard it spends what skipping saves. Stated so it is a contract rather than a surprise — `T.parse(json:)` validates the structure and the fields it declares, not the whole document. |
| ~~**Compiled regexes are not cached**~~ | **Fixed 2026-09-08, 28×.** The pattern is compiled once at `Rule` construction — where `.before(_:)` already parses its ISO bound — rather than once per validated value. `.regex` went 12,427 ns → 439; `.each(.regex)` over 20 elements went 12,427 ns/element → 514. The stated blocker ("a cache needs synchronisation the validation path has none of") was real but pointed at the wrong fix: no cache is needed, and the synchronisation problem is that `Regex` carries **no `Sendable` conformance** while `Rule` must be `Sendable` to be a `static let` element. `CompiledPattern` is `@unchecked Sendable` and earns it — the initialiser warms the matching program with a throwaway match while the instance is still local, and a task-group test runs under `--sanitize=thread`. A global pattern→`Regex` cache was rejected: it hashes per value, needs a lock on a path documented as allocation-free, and grows unbounded. **There was no `.regex` row in the per-rule benchmark table** until this change, which is part of why the cost survived so long — it never appeared in the table anyone read. |
| ~~**Anchors defined in flow style are not recorded**~~ | **Fixed 2026-09-08.** `[&a x, *a]` resolves. Two things came out of it. The Yams/libyaml differential rejected the first version on its first run: it recorded `&q *p` as an alias, and an anchor on an alias is not YAML — an alias is a reference to an already-anchored node, not a node of its own. Block style had accepted that since anchors existed, silently discarding the anchor so a later `*q` failed with "undefined alias" and named the wrong problem; both paths now refuse it with `yaml_anchor_on_alias`. And the obvious rewrite — one `var node` with a shared exit — cost **3.3%** on the YAML node-parse arm by turning four tail calls into an Optional round-trip, so the unanchored path is left byte-for-byte as it was and the duplication is deliberate. **Flow tags (`[!!str 1]`) are the same shape and remain unhandled** — consuming them changes how documents that currently parse `!!str x` as a plain scalar behave, which is its own change. |

---

## The third decode path — built, measured, REMOVED

**Status: withdrawn 2026-08-10 on its own numbers.** `docs/KEYED-SOURCE.md` is the record.

A `KeyedSource` protocol for decoding one record at a time from anything already parsed and
addressable by key — database rows, CSV, plists, form data — was designed, built and
benchmarked. It was removed, and the reason is worth having on the roadmap rather than only
in a header, because the idea is attractive enough to be proposed again:

- **The premise was false and unchecked.** It was justified by "the `RawValue` path costs an
  allocation per value per record." `RawValue.mapping` is *one* allocation per record.
- **It lost to the path it was meant to beat**: 311 ns/record against 95 ns for building a
  `RawValue` and decoding through the tree path.
- **It could not accept the borrowed rows it existed for.** A zero-copy row view is
  `~Escapable`, and this library refuses an experimental-feature gate on its public surface.
- **Its cost landed per row in a driver**, where `@inlinable` is forbidden on generated
  bodies (SE-0193) and the witness-table call stands: 1.6–4.7×.

**What survives.** `ColumnarSource` and `_assayBatch`, behind `@Schema(sources: true)`: a
column store hands over whole arrays, so it has no per-row borrow, no per-row dispatch and no
per-row presence ambiguity — the three things that sank the other half. 1.27× over the tree
path at a flat ~53 ns/row, and 1.03× when called generically from another module.

**What replaces it.** `T.validate(_:)` — `docs/VALIDATE.md`. A specialised reader decodes at
its own speed in its own module, and Assay runs the rules afterwards. That is the seam the
decode path was reaching for, and neither side pays for the other.

Still deferred: nested and collection fields on a `sources: true` type, which remain compile
errors naming the field rather than runtime surprises.

## Verification gaps

Not features, but they are equally part of "done":

| gap | what is missing |
|---|---|
| ~~**Windows**~~ | **Closed 2026-08-29.** The row below is what this said until then, and it is worth keeping visible: *"The CI leg is enabled and has never run — the repository has no remote. Cannot be built from macOS either, so every Windows claim is unverified."* A remote exists, `Test (Windows)` runs on `windows-latest` on every push and gates, and it found a real bug on its first green-to-red transition — `_open` is variadic in ucrt and Swift cannot import C variadics, in a shim that had never been compiled on Windows because Windows had never been tested. |
| ~~**x86-64 Linux performance**~~ | **Closed 2026-08-20.** Measured on a GitHub-hosted runner via `.github/workflows/benchmark.yml`: **struct decode 10.89×**, the best of the three platforms, and XML **1.39×** over libxml2-backed Foundation. It also found an x86-64-only crash — a struct-returning libc call declared with `@_silgen_name` — that macOS and aarch64 Linux both ran green. `Experiments/01-jump-table`'s threshold is now measured on both architectures and is **not** target-independent: a table appears at N ≥ 4 for `UInt8` on x86-64 against N ≥ 10 on arm64. |
| ~~**SIMD decoder comparison**~~ | **Closed 2026-08-08.** Measured against yyjson (hand-tuned C, `-O3`): **0.65×** on the use-case arm, **0.78×** on float-dense, **0.06×** DOM-vs-DOM. The predicted loss arrived and is published in `Benchmarks/RESULTS.md`. Still not compared to simdjson itself (C++, needs an interop shim) or to ZippyJSON. |
| **Multi-megabyte documents** | Outside the target band and unmeasured. The corpus stops at 64 kB. |
| ~~**`[String: T]` dictionary fields**~~ | **Closed 2026-08-07** — implemented on both decode paths, recursive, non-String keys diagnosed at expansion. The "worst case" measured **6.95× over Foundation** (`Benchmarks/RESULTS.md`); the predicted narrowing is visible in the size trend, the predicted risk was not. |
| **Total malloc traffic** | The allocation gate counts *live* blocks, which misses transient allocations freed inside a decode. `.mallocCountTotal` would catch those and needs jemalloc, which cannot run on the musl or wasm legs at all — so closing this is either a bounded Darwin/Linux-only addition or a permanent gap, and it should be recorded as whichever it turns out to be. |
| ~~**Encoding throughput**~~ | **Closed 2026-09-08.** `EncodeBench.swift`: **2.85×** over `Encodable` + `JSONEncoder` at 50 and 200 items, 4.54× at one item where Foundation's fixed cost dominates. YAML and XML are absolute ns/document — no comparable Foundation encoder exists to divide by, and a ratio against nothing is how a benchmark starts lying. A measurement rather than a thesis: the decode multiple has an argument behind it, this one does not. |
| **Cold start** | Named in `CLAUDE.md`'s "Start here now" and never measured. A macro emitting no `CodingKeys` should win structurally, which is exactly the kind of should that this file exists to stop anyone asserting. |

**A note on how two of these closed, because it is the more useful lesson.** The Windows and
x86-64 rows sat here describing a repository with no remote for some time after the remote
existed and both legs were green. Nothing detected that; a reader asking "what is unverified?"
was told something false by the document whose job is to answer exactly that. Rows here are
now expected to be struck through with a date and a number when they close, and a plan that
touches verification should re-read this table rather than trusting it.

---

## Phases 4 and 5 of the performance plan

`CLAUDE.md`'s build order runs to five phases. Phases 1 through 3 are done — the thesis is
proven, the unclaimed wins that were taken are taken, the codegen discipline holds.

**Both are RETIRED as of 2026-08-08, unbuilt, on evidence.** Not deferred — cancelled. The
plan always said "if the numbers say stop, stop and publish it"; the numbers said stop.

- UTF-8 validation, which is what a SIMD kernel replaces, is **5.0–5.3% of decode** on the
  API-shaped payload. A *perfect* validator therefore buys ~5% there, ~13.6% at absolute best on
  the friendliest shape.
- The measured gap to hand-tuned C (yyjson) is **~1.5×** on the use-case arm. A 5% slice does not
  close it.
- Phase 5 was gated on phase 4's x86-64 numbers. Phase 4 will not produce any.

Full reasoning and tables: `docs/PERFORMANCE.md` §14 and `Benchmarks/RESULTS.md`. `Sources/AssaySIMD/`
stays empty. Experiments #2–#4 remain valid and are worth keeping — they establish that `Builtin`
intrinsics resolve, emit real NEON, and survive versioned dependency resolution, and that
`-mattr=+avx2` does nothing. That is a door left open, not a plan.

## Small integer widths — BUILT 2026-08-31

`Int8`, `Int16`, `UInt8`, `UInt16`, `UInt32` and `UInt64` are field types on every path:
JSON, `RawValue` (YAML/XML), validation rules, all three encoders, and the columnar
manifest. `[UInt8]` works with them, and now maps to `bytesColumn` through the
`ColumnDecodable` conformance that was written and withheld — see
`docs/COLUMN-DECODABLE.md`.

**`UInt64` cannot reach its own maximum**, and that is inherited rather than introduced:
`scanInt64` returns `Int64`, so any unsigned value above `Int64.max` fails to scan. `UInt`
has had exactly this ceiling since it was added. Lifting it needs a `scanUInt64` in the
number parser — its own change, with its own tests. There is a test pinning the current
behaviour so whoever writes it finds a green assertion rather than a surprise.

Two pre-existing bugs surfaced while doing this and were fixed with it, both in the
functions being extended:

- **`decodeInt64` and `decodeInt32` never called `beginValue()`**, so validation carets on
  those fields pointed at the wrong bytes — for `{"wide": 999, ...}` the span came out as
  (lo: 0, len: 9), the start of the document. `Int` was correct, which is why it survived
  the golden caret tests.
- **`write(_ v: UInt)` reinterpreted the bit pattern** rather than converting, so every
  unsigned value above `Int64.max` encoded as negative: `UInt.max` came out as `-1`.
  Well-formed JSON carrying a different number, against a stated round-trip law. Not
  reachable by decoding, since the scanner caps input at `Int64.max`; reachable by any
  program that constructs the value and encodes it.

## Array element issues — FIXED 2026-09-08, and one worse thing found next to it

`[Int32]`, `[UInt8]` or any array with a bad element reported `[.key("xs")]` and named no
element. It now reports `[.key("xs"), .index(1)]`.

The index is passed to the decode primitive as a **scalar argument** and consumed inside the
cold `@inline(never)` failure path, so the emitted loop still contains no `path + [...]` and
allocates nothing per element — that is structural, not a hope that the optimiser sinks
something, and the emitted source was read to confirm it. Measured anyway: struct decode
8.94× before, 9.01× after; prefix+skip 6.19× before, 6.18× after.

**Not** the empty-`StaticString` sentinel the rule engine uses for the same purpose. The XML
projection stores an `@XML(.text)` field under a reserved EMPTY key, so a sentinel spelled
that way has a real collision in it. An explicit defaulted `Int` has none.

**The worse defect, found by a test written for this one.** A collection field whose whole
value is wrong — `{"xs": 5}` against `var xs: [String]` — reported an issue whose path was
**empty**. Not a missing index: no field name at all. Both the array and dictionary arms now
name the field. That is fixed here because it is the same three lines and the same reader,
and leaving it would have meant shipping a better element diagnostic next to a worse field
one.

**Still open:** an element inside a *nested* array (`[[Double]]`) gets the outer index only.
The inner index needs a prebuilt path prefix per outer element rather than a scalar, which is
a different trade — it is the one place this change would have added an allocation, so it was
not taken blind.

## The eagerly-built diagnostic path — RESOLVED 2026-09-07, no change needed

A report measured `path + [.index(__r)]` per row on the columnar path and
`path + [.key(k), .index(i)]` per element on the JSON path, and proposed removing both. Its
measurements reproduce exactly; its conclusion does not survive checking against the real
generated code.

**Columnar: the optimiser already does it.** Emitting the row path inside the failure
branches produces *byte-identical machine code* to emitting it once per row — same 548
instructions, same five `PathComponent` buffer calls, empty `diff` of the disassemblies. The
macro change was made, measured, found to be a no-op and reverted.

**JSON: not justified.** Deleting the concat outright from the macro, purely to measure,
moved a nested array element from 61.89 to 60.66 ns. The invasive redesign it was proposed
for — a parent pointer instead of a materialised `[PathComponent]`, touching `Issue`,
`IssueSink` and every `_assay` signature — buys nothing.

**The instability was the benchmark.** Every arm observed only `.count` of the decoded
array, which lets the optimiser discard the decode non-deterministically; that produced
~4 ns/row in some builds and ~45 in others and sent the investigation after a
specialisation theory that was wrong. Forcing the values live through an `@inline(never)`
consumer makes every arm stable. `@inlinable` on `SourceDecodable.batch(from:)` was tried
on the same wrong theory and had no reliable effect; also reverted.

`Benchmarks/Sources/AssayBench/DiagnosticPathBench.swift` keeps the measurements and the
methodological trap: a hand-rolled reproduction needs `@inline(never)`, which is exactly
what prevents the optimisation being measured, so reproductions look worse than the product.

