# `Assayer<T>` — the runtime value API

*Built 2026-09-08. `ROADMAP.md` §7, `EXPERIENCE.md` §8 and §17.*

## The question this was held back on

§7 did not defer this on difficulty. It deferred it on whether it belongs in a 1.0 at all:

> shipping it means committing to maintaining two front doors forever, and the domain-type
> use case that motivates half of it might be covered by a narrower protocol.

**It is one front door with two receivers, and it is a conformance-authoring API rather than
a second parse API.** The static verbs are spelled on a *type* — `User.parse(json:)`. These
are spelled on a *value* — `schema.parse(json:)`. Same `Diagnosis`, same `Issue` codes, same
`AssayError`, same renderers, same `Limits`. Nothing about the vocabulary forks.

What forks is the receiver, and it forks for two things the static door cannot express:

- **There is no declaration.** A form schema in a database row, a plugin manifest, a
  JSON-Schema document fetched at runtime. There is no `T` to call `.parse` on, and a macro
  reads syntax — this is structurally out of its reach.
- **There is no object to decode.** `EmailAddress` is a validated `String`. `@Schema` decodes
  an object with keys and has no spelling for *"this type is a constrained scalar"*.

And the narrower protocol §7 suspected is real — it does not compete, it is the
**requirement** that `Assayer` fills. Ship both; they are one feature.

## Two laws

1. **No `Assayer` constructor rebuilds a `@Schema` type's fields.** There is no way to
   express a declared struct as a hand-built combinator that behaves subtly differently.
2. **Once a conformance is installed, the type is used through the ordinary door.**
   `var email: EmailAddress` emits the same generated line as any other nested type.

## The load-bearing consequence: no macro change

`CodeGen.swift` already emits `Base._assay(from:into:at:)` for any type token it does not
recognise. So an `AssayerBacked` type is **already, syntactically, a nested schema type**.
Zero new generated code per field, zero added expansion cost, no movement against the 100 ms
gate — measured at 67.4 ms, unchanged.

`Tests/AssayTests/AssayerTests.swift` pins this: `wrapperIsAnOrdinaryField` passes with
`Sources/AssayMacros/` untouched. **If that test ever needs the macro changed, the design is
wrong and the right move is to stop rather than make it fit.**

## Shape

```swift
public struct Assayer<T: Sendable>: Sendable {
    let plan: AssayerPlan                       // NON-generic; one interpreter, one copy
    let build: @Sendable (RawValue) -> T?       // the generic parameter enters here, last
}

public protocol AssayerBacked: JSONAssayable, RawDecodable {
    static var assaySchema: Assayer<Self> { get }
}
```

The interpreter is non-generic on purpose — one copy in `Assay`, no specialisation pressure,
no code-size multiplication per `T`. Same insight that made `ColumnDecodable` free: the
generic work happens once, the per-value work is concrete.

Two interpreter arms mirror the split the macro already emits, which is why **YAML and XML
work with no additional code** — they project to `RawValue`, so a conforming type decodes
from all three formats the moment it conforms.

## A correction to `EXPERIENCE.md`

§8 and §19 both write `struct EmailAddress: Assayable { static let schema = ... }`. That
cannot work: `Assayable` is a marker protocol with no requirements, so nothing would ever
call `schema`. The spelling has to name a protocol that requires it — `AssayerBacked`.

The `Assayer.string` spelling itself was **probed before any code was written**, because it
needs Swift to infer `T` from a constrained static member on an unbound generic reference,
which is the fragile corner. It resolves, including as a function argument.

## The depth limit is not optional here

The bytes path gets depth charging from `AssayReader.enterContainer`. The `RawValue`
interpreter has to do it itself, and it must: **a runtime-built plan can contain a `.lazy`
cycle that no macro-emitted schema can.** That is a denial-of-service surface the static door
does not have, and it is closed in the first commit rather than later —
`recursionIsBounded` asserts a self-referential plan is refused by `maxDepth` rather than
running out of stack.

## What a `map` gives up

A mapped `Assayer` cannot conform `Validatable`. `T.validate(_ value:)` runs the schema's
rules against a constructed value, and there is no way back from `EmailAddress` to the
`String` the rules were type-checked against. Documented rather than discovered; `@Inverse`
is the spelling that would lift it, and it belongs with `@Wraps`.

## Not in this increment

**`Assayer.schema(User.self)` — a `@Schema` type as a leaf.** The plan interprets to
`RawValue` and `build` converts, so a schema leaf either decodes twice or `build` has to take
the sink and the path. The second is right and is a signature change worth making
deliberately. Nothing depends on it, and law 1 holds *more* strongly while there is no route
at all than while there is one.

**A bytes-driven interpreter.** The current bytes path collects a `RawValue` and then
interprets. The fast shape reads scalar leaves straight off the reader with no tree built,
and a wrapper field should then cost what a plain field costs. That is worth building against
a measurement rather than a prediction, so it is owed rather than done.

**Scratch reuse.** `CLAUDE.md`'s build order attributes "steady-state scratch reuse" to
`Assayer<T>`. **That premise is stale.** It assumed `Assayer` was the decoder object; it
shipped as an immutable schema *value* that must be `Sendable` for `static let assaySchema`
to be legal — and a `Sendable` value cannot own mutable scratch. Scratch belongs in a
separate `~Copyable`, non-`Sendable`, `inout`-passed type usable by *both* doors, and if it
does not move the arms by ≥10% it should not ship at all.
