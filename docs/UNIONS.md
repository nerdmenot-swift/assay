# Unions

`EXPERIENCE.md` §9 specifies them. `ROADMAP.md` §5 says they were absent from the roadmap
entirely until cutting `@PickFirst` turned them up, and that they need this document first —
answering **how a composed failure is reported, what bounds the backtracking, and what
encoding a union means** — because those three are the design, and the code is downstream.

```swift
@Schema(discriminator: "type")
enum Event {
    case click(ClickEvent)
    case pageView(PageViewEvent)
    case purchase(PurchaseEvent)
}

@Schema(discriminator: .none)
enum StringOrNumber { case text(String), number(Double) }
```

---

## 1. Why this is the one construct the decode body was designed against

Every other feature in this library reads forward. The scanner has a cursor that only
advances; `PERFORMANCE.md`'s whole argument is a single pass with no lookahead beyond a byte.

A union cannot do that, for two different reasons:

- **Discriminated:** the branch depends on the tag, and `{"a": 1, "type": "click"}` is a legal
  document. The tag can arrive last.
- **Untagged:** there is nothing to look at. You try a branch and back out.

So both need **rewind**, and rewind is the thing the rest of the design avoids. That makes the
primitives question the first one to settle, and it was settled by measurement rather than by
reading — see `Tests/AssayTests/RewindTests.swift` and `AssayReader.Mark`:

| | restored by |
|---|---|
| cursor | `seek(to:)` |
| reported issues | `IssueSink.rollback(to:)` |
| **container depth** | **`restore(_:)`, added 2026-09-09** |

An *ordinary* failure was always balanced — a body that hits a type mismatch scans to the
closing brace, calls `leaveContainer`, and only then returns nil. A **malformed container** was
not: the generated arm for an unterminated array returned from inside the enclosing object
without unwinding it, so each attempt cost a depth level and twenty attempts against a budget
of four failed the twenty-first decode. An untagged union is a run of failed decodes over
attacker-chosen input, so that was reachable on purpose.

**That was fixed at source**, one `leaveContainer()` per array, dictionary and path-group error
arm — and measured, because the first instinct was *not* to: the argument for leaving it was
that nothing outside a union could observe the leak and that balancing every error path would
cost generated code against the compile-time budget. Both halves were wrong in the way that
matters. "Nothing observes it today" is the reasoning that produced several other bugs found
the same week, and the measured cost of the extra lines is nil — the `arrays` arm reads 99.2 ms
against 101.6 before, which is noise.

`restore(_:)` stays, now as the complete rewind rather than a workaround: a union driver should
not depend on every generated error path in every *future* feature staying balanced. The
invariant is asserted separately, with `seek(to:)` alone, so a regression in the emitter fails
a test rather than being absorbed.

---

## 2. How a composed failure is reported

**The whole reason to prefer a discriminator is that it makes this question go away**, and
`EXPERIENCE.md` §9 says why: "did not match any of 3 variants" followed by three sets of
irrelevant errors is the single most-complained-about thing in every validation library with
union types.

### 2.1 Discriminated — there is nothing to compose

Once the tag is read, exactly one branch is possible, and its issues are the union's issues,
reported at the union's own path. A malformed click event reports as a malformed click event.

Four outcomes, four reports:

| document | report |
|---|---|
| tag present, recognised, branch decodes | the value |
| tag present, recognised, branch fails | **the branch's issues, unchanged** |
| tag absent | one `.missing` at `path + [.key("type")]` |
| tag present, unrecognised | one `union_unknown_variant`, with the received tag and the known ones, **with did-you-mean** — the same Damerau machinery `unknownKeys` already uses |

Nothing is composed and nothing is summarised away.

### 2.2 Untagged — composition is unavoidable, so bound it

Every branch failed, and the reader has *n* sets of issues that are all equally "why". The two
usual answers are both bad: printing all of them is the wall of noise above, and printing only
"no variant matched" tells the author nothing about what to fix.

**The rule: one summary issue, plus the detail of exactly one branch, and say which.**

```
no variant of StringOrNumber matched; showing `text`, which came closest
  └─ text: expected string, received number
```

- The summary is `union_no_variant_matched`, carrying every variant's name in `params`.
- "Closest" is **fewest issues, ties broken by declaration order**. It is a heuristic and it is
  named as one in the message, which is the difference between a hint and a claim.
- The chosen branch's issues are reported at the union's path, unmodified.

The alternative — reporting every branch — is available deliberately and not by default:
`Limits.verboseUnions` turns it on for someone debugging a wire format they do not control,
which is the case untagged unions exist for.

---

## 3. What bounds the backtracking

**A budget, charged per branch attempt, and it has to be global rather than per-union.**

The exponential is not one union with many branches; it is *nested* unions. `[[U]]` where `U`
has three branches costs 3 attempts per element, 3ⁿ for n levels of nesting — and `maxDepth`
does not see it, because the depth is the array nesting and the blow-up is in the breadth.
This is structurally the same attack as the plist's shared-object amplification
(`docs/PLIST.md` §2.2), and it gets the same answer for the same reason.

- `Limits.maxUnionAttempts`, defaulting to **10,000**, charged one per branch attempt across
  the whole decode.
- Exhausting it is an issue (`union_budget_exhausted`), not a silent truncation.
- A *discriminated* union charges **one** attempt regardless of variant count, because it makes
  exactly one. Only the untagged form can multiply.

The default is deliberately far above any real document: a hand-written schema nests unions two
or three deep at most, and 10,000 attempts is unreachable by anything but an attack or a bug.

---

## 4. What encoding a union means

**Not built for either form** — `@Schema(encodes: true)` on a union is refused at expansion
rather than silently ignored. This section is the settled answer for when it is, and the
duplicate-payload check it argues for **is** built, because decoding needs it too.

`ENCODING.md`'s round-trip law is that decoding what was encoded returns an equal value, with a
closed exception list. Unions add one exception and refuse the case that would add a second.

**Discriminated encodes the payload plus the tag.** `Event.click(e)` writes `e`'s object with
`"type": "click"` added. The tag name is the *case* name, transformed by the type's `keys:`
style, so `case pageView` writes `"page_view"` under `.snakeCase` — the same rule field names
already follow, rather than a second convention to remember.

**Untagged encodes the payload alone**, and here the law can genuinely break:

```swift
@Schema(discriminator: .none)
enum Ambiguous { case a(Int), b(Int) }      // refused at expansion
```

`.b(1)` encodes as `1`, which decodes as `.a(1)`. That is a round-trip violation the library
cannot repair — so it is **refused at expansion**, where the macro can see that two cases carry
the same payload token. It is the one union check a macro *can* do: it needs no conformance
lookup, only the tokens it already has.

What it cannot see is a subtler collision — two distinct `@Schema` types that accept the same
document. `case a(Empty), b(Empty)` where both are `@Schema struct Empty {}`. The tokens
differ, so expansion cannot refuse it; the first branch wins and the second never
round-trips. **That is the exception on the list**, and it is the untagged form's cost.

**A discriminated union has no such exception**, which is the last of several reasons to prefer
one.

---

## 5. Two things a variant must know

**The tag key reaches the variant.** The union consumes the object once; the branch decodes the
same bytes, tag included. With the default `unknownKeys: .ignore` that is invisible. A variant
declaring `unknownKeys: .reject` will reject the tag unless it also declares the field — and
the macro cannot warn, because it sees the token `ClickEvent` and not that type's policy.
Stated here, and the runtime error names the key.

**A variant must be a `@Schema` type or a scalar.** Enforced the way `@Key(path:)`'s nested
types are: the emitted call names the type concretely, so the type checker produces the
diagnostic the macro cannot.

---

## 6. Status

**Both forms built 2026-09-09**, decode only, JSON only. Encoding is refused at expansion for
either — §4 above is the settled answer for when it is built.

The build order this document argued for held: tagged first, because three of the four hard
questions do not apply to it. Untagged then needed all three, and each cost something the
design did not fully anticipate.

**§2.2's composed report, and what it costs to produce.** One summary
(`union_no_variant_matched`, naming the type, the guess, and every variant) plus the closest
branch's detail. Producing that detail means **running the winning branch twice**: the
measuring pass rolls every branch back, so by the time the closest is known its issues are
gone. The alternative — snapshotting each branch's issues as it goes — is an allocation per
branch on *every* decode, including the ones that succeed on branch one. Replaying costs one
extra decode of a single branch, only when the union has already failed. The replay does not
charge the budget again: it is the same attempt re-run for its diagnostics.

**§3's budget, and a correction to how it is reached.** `Limits.maxUnionAttempts`, default
10,000, global, charged per attempt, and **not refunded by a rewind** — a `Mark` restores where
the reader *is*, not work already done. Worth recording: a failing union inside an array does
not make very many attempts, because `arrayDecode` breaks on the first element that will not
decode. A test written with a budget of three never reached it.

**`verboseUnions` suppresses the sink rollback and NOT the reader restore.** The first version
suppressed both, so branch two started wherever branch one stopped and reported nonsense about
a position it was never meant to see. Caught by asserting that verbose mode names a field only
the non-closest branch has.

**§4's duplicate-payload refusal is built**, and it turns out decoding needs it as much as
encoding does: `case a(Int), b(Int)` makes `b` unreachable whether or not anything is ever
encoded. What the macro still cannot see — two *distinct* types accepting the same documents —
is pinned by a test asserting that it is **not** refused, so the limit is recorded rather than
assumed.

What the tagged form cost, beyond the rewind primitive:

- **A resynchronisation the design did not anticipate.** When the tag is absent or not a
  string, the union returns nil having reported — and the pre-scan has left the cursor
  part-way through the value, so the top-level entry point finds bytes remaining and adds
  `trailingContent`. A missing tag was reported as *two* errors. The failure paths now restore
  and skip the value, which is what the unknown-variant path already did. Caught by a test
  asserting `issues.count == 1`, which is the assertion this whole feature is about.
- **Two expansion-time refusals** that protect the "exactly one branch is possible" property:
  two cases spelling the same tag (the second could never be chosen, silently), and `@Unknown`
  on a union case (an unrecognised tag already has a better answer — `union_unknown_variant`
  with a did-you-mean — and a catch-all would have nothing to hold).
- **JSON only.** The `RawValue` path — YAML and XML — is refused at expansion rather than
  silently omitted, because a union that decoded from JSON and not from YAML while declaring
  `formats: .all` would be a trap.
- **Encoding likewise refused**, for the same reason: §4 settles what it should mean, and
  accepting `encodes: true` while emitting no encoder is the worse failure.
