# Value models — one per format, plus a neutral projection

*Design note, written before implementation. Supersedes an earlier draft that proposed a
single unified `RawValue`; that draft was wrong and §1 says why.*

**Status: models BUILT (2026-07-26). Parsers pending for YAML and XML.**

| | model | parser | projection to `RawValue` |
|---|---|---|---|
| `RawValue` | ✅ `AssayCore` | — | — |
| `JSON.Value` | ✅ `AssayCore` | ✅ on the existing scanner | ✅ total |
| `YAML.Node` | ✅ `AssayYAML` | ❌ | ✅ lossy, fails on non-string keys |
| `XML.Node` | ✅ `AssayXML` | ❌ | ✅ lossy |

51 tests, and the tests pin the **losses** as hard as the fidelity — a projection that
quietly stopped being lossy would be as much a regression as one that lost more.

`@Extras` and `unknownKeys: .collect` are **wired** (71 tests). Open question 2 below is
**resolved, and the desirable property holds**: declaring `[String: XML.Node]` and calling
`parse(json:)` is a *compile* error, not a runtime one —

```
error: global function '_assayCollect(_:from:into:at:)' requires that 'XML.Node'
       conform to 'JSONCollectible'
```

The mechanism is one protocol **per format** in the core (`JSONCollectible`), which the
core can name without depending on `AssayXML`. Generated code routes through a constrained
generic rather than calling the protocol requirement directly, purely so the diagnostic
names the conformance instead of leaking `has no member '_collectJSON'`.

---

## 0. The decision

**Each format gets its own full-fidelity value model. `RawValue` survives, but demoted
from *the* model to *a projection* that `@Extras` can opt into when a schema genuinely
needs to be format-neutral.**

| module | namespace | purpose |
|---|---|---|
| `AssayCore` | `RawValue` | the lossy, format-neutral projection |
| `Assay` (core + JSON) | `JSON.Value` | full-fidelity JSON |
| `AssayYAML` | `YAML.Node` | full-fidelity YAML |
| `AssayXML` | `XML.Node` | full-fidelity XML |

---

## 1. Why the unified type was wrong

The first draft proposed one `RawValue` with an `Origin` tag (`.member` / `.attribute` /
`.text`) so XML could be squeezed in. That is a JSON-shaped type wearing an XML costume,
and two concrete losses expose it:

**YAML permits any node as a mapping key.** `{[1, 2]: x}` and `{? {a: b} : c}` are legal
YAML. A `[String: RawValue]`-shaped model cannot represent them, so the unified design had
to *reject* valid documents with a diagnostic. Rejecting valid input because the value
model is too narrow is a design failure, not a narrowing.

**XML has no object and no array.** It has elements, attributes, character data, CDATA,
comments and processing instructions, with ordering that is semantically significant and
duplicate sibling names that are ordinary rather than exceptional. Modelling that as
"mapping with a tag on the key" loses mixed-content interleaving and makes every consumer
reconstruct XML's actual shape from a flattened approximation.

A lowest-common-denominator serves the format it was modelled on and taxes the other two.

## 2. Why `RawValue` still exists

Deleting it entirely breaks a headline promise. `EXPERIENCE.md` §12: *"One struct, many
formats. Same struct. Same rules. Same errors."* §18: *"The format is a parameter."* If
`@Extras` can only be format-specific, then a schema that uses it is silently
single-format, and the promise develops a visible crack.

So both exist, and **the user chooses by declaring the type**, which is exactly the
"nothing is implicit — everything that affects the meaning of a struct is written on the
struct" principle from §18:

```swift
@Schema struct Config {
    var name: String
    @Extras var rest: [String: RawValue]     // neutral. parses from any format. lossy.
}

@Schema struct Feed {
    var title: String
    @Extras var rest: [String: XML.Node]     // full fidelity. XML only, by construction.
}
```

That is a real trade the caller can see and reason about, rather than one the library
made for them.

---

## 3. Naming

The instinct toward `XMLNode` over `XMLArray`/`XMLObject` was right — XML has neither an
array nor an object, and importing JSON vocabulary into it is the same transplant error as
§1. But the obvious spellings are unavailable.

**`XMLNode`, `XMLElement` and `XMLDocument` are all taken by Foundation** (macOS and Mac
Catalyst only — see `cross-platform-audit.md` §4, confirmed via Apple's DocC API). On
macOS, `import Foundation` plus `import AssayXML` would make every one of them ambiguous.

This is precisely the case the project has already ruled on. `EXPERIENCE.md` §0:

> `Assayer<T>` is the runtime schema value — deliberately *not* `Schema<T>`, because
> `import SwiftData` also exports a `Schema` and the bare name would be ambiguous in any
> app that uses both.

Same rule, same answer: **namespace them.**

```swift
public enum XML {}      // caseless namespace
extension XML {
    public struct Document { … }
    public indirect enum Node { … }
    public struct Element { … }
    public struct Attribute { … }
    public struct Name { … }        // local name + namespace URI
}
```

`XML.Element` and `Foundation.XMLElement` are different identifiers, so the ambiguity
never arises. Applied consistently across all three for symmetry: `JSON.Value`,
`YAML.Node`, `XML.Node`. Flat aliases (`typealias JSONValue = JSON.Value`) can be added
for familiarity if they earn their keep, but the namespaced spelling is canonical because
it is the one that is collision-free in all three cases.

---

## 4. The three models

### `JSON.Value`

```swift
extension JSON {
    public enum Value: Sendable, Hashable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([Value])
        case object(Members)          // ORDERED, duplicates preserved
    }
}
```

Ordered members rather than a `Dictionary`, for two reasons that agree: the RFC leaves
duplicate keys undefined and silently dropping one is the worst available answer, and a
`Dictionary` costs a SipHash per key on construction — the exact overhead
`PERFORMANCE.md` §1.2 identifies as Foundation's largest structural cost.

Numbers split `.int`/`.double` rather than retaining source bytes. This forfeits JSON's
nominal arbitrary precision; see open question 1.

### `YAML.Node`

```swift
extension YAML {
    public indirect enum Node: Sendable, Hashable {
        case scalar(Scalar)
        case sequence([Node])
        case mapping([(key: Node, value: Node)])    // ANY node as a key
    }
    public struct Scalar: Sendable, Hashable {
        public var content: String                   // unresolved text
        public var style: Style                      // plain, single, double, literal, folded
        public var tag: String?                      // !!int, !Foo — preserved, not dropped
        public var anchor: String?
    }
}
```

Three things this gets that the unified type could not:

- **Non-string keys**, so no valid document is rejected.
- **Tags survive.** `!Foo` on a value is data, and the earlier draft dropped it with a
  warning. Here it round-trips.
- **Scalar style is retained**, which matters for the deferred encoder: rewriting a
  literal block as a double-quoted scalar is technically equivalent and practically a
  diff nobody wants.

Content stays unresolved text with the tag alongside, so resolution is the *consumer's*
call — which is also how `.scalar` sidesteps the Norway problem rather than inheriting it.
Anchors and aliases are expanded during the parse under a `Limits` cap (billion-laughs),
with the anchor name retained for encoding.

### `XML.Node`

```swift
extension XML {
    public struct Name: Sendable, Hashable {
        public var local: String
        public var namespaceURI: String?      // resolved from prefix; prefix is presentation
    }
    public struct Attribute: Sendable, Hashable {
        public var name: Name
        public var value: String
    }
    public struct Element: Sendable, Hashable {
        public var name: Name
        public var attributes: [Attribute]     // ordered
        public var children: [Node]            // ordered; mixed content interleaves naturally
    }
    public indirect enum Node: Sendable, Hashable {
        case element(Element)
        case text(String)
        case cdata(String)
        case comment(String)
        case processingInstruction(target: String, data: String)
    }
}
```

`children: [Node]` is the whole point: mixed content (`<p>Hello <b>x</b>!</p>`) is
*ordinary* here rather than a special case, repeated sibling names are natural, and
attribute-versus-element is a type distinction rather than a tag. Convenience accessors
(`element["href"]`, `element.elements(named:)`, `element.text`) sit on top; the storage
stays faithful.

Everything in XML is text — there is no number or boolean — so coercion remains the
schema's visible job via `@Coerce`, never implicit.

---

## 5. `RawValue`, as a projection

```swift
public enum RawValue: Sendable, Hashable {
    case null, bool(Bool), int(Int64), double(Double), string(String)
    case sequence([RawValue])
    case mapping([(key: String, value: RawValue)])
}
```

Deliberately the *narrow* intersection, with no origin tags and no format-specific fields,
because its entire job is to be the thing that means the same in all three. Each format
package provides `init?(_:)` from its own node type, and each projection documents its
losses:

- **JSON → RawValue**: total.
- **YAML → RawValue**: fails on non-string keys; drops tags, styles, anchors.
- **XML → RawValue**: every scalar becomes `.string`; attributes and elements flatten
  together; mixed content, comments, PIs and namespaces are dropped.

Being explicitly lossy is what makes it honest. A caller who declares `RawValue` has said
"I want portability more than fidelity," and that sentence is now true rather than a
compromise the library imposed.

---

## 6. What this costs

Stated because the unified design's one real advantage was that it was cheaper:

1. **Three models to build, test, document and evolve**, instead of one.
2. **Three projections**, each with its own loss table.
3. **The macro must dispatch on the declared `@Extras` type** — see open question 2, which
   is the main implementation risk in this note.
4. **§17's "not a document API" needs re-reading.** These types do not *make* Assay a
   document API — there is no mutation and no writer — but they are most of what one would
   need. That refusal was written when the value model was an afterthought; it should
   probably be softened to "not a document *mutation* API" rather than quietly contradicted.

---

## 7. Open questions

1. **Should `JSON.Value` retain number source bytes** instead of splitting `.int`/`.double`?
   It would make JSON's arbitrary-precision spec representable and let callers choose,
   at the cost of an allocation on the common path. Leaning: keep the split; revisit on a
   reported precision loss. Note `YAML.Scalar` already keeps unresolved text, so YAML does
   not have this problem.

2. ~~**How does the macro wire up `@Extras` for a type it has never heard of?**~~
   **RESOLVED.** One protocol per format (`JSONCollectible`) declared in the core, which
   `RawValue` and `JSON.Value` conform to and `YAML.Node`/`XML.Node` deliberately do not.
   The compile-error property was the point of the exercise and it holds — verified, not
   assumed. Cost: `.ignore` stays allocation-free, while `.collect`/`.warn`/`.reject` each
   materialise the unknown key as a `String`, which is unavoidable since an unknown key has
   no compile-time literal it was matched against.

3. **`Hashable` with `.double`.** NaN makes the conformance quietly dishonest. Either
   document a total-order caveat or drop `Hashable` where floats are reachable.

4. **Does `YAML.Node` need `Hashable` at all**, given mapping keys are `Node`? It must, to
   be usable as a key — which means the NaN problem from (3) is load-bearing there rather
   than cosmetic.

5. **Flat aliases or not.** `JSONValue` is what the ecosystem expects. Adding it costs
   nothing until someone has their own; not adding it costs a little familiarity.
