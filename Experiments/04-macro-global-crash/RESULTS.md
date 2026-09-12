# A generic, function-typed macro parameter on a global variable crashes the compiler

**Swift 6.3.3 (swift-6.3.3-RELEASE), arm64 macOS. Found 2026-09-13.**

Not an Assay bug. This package contains no Assay code — a peer macro that returns `[]`, a
macro declaration, and one line of client code. It is here because two of Assay's public
macros have the triggering signature, and because "we hit a compiler crash" is worth
exactly nothing without a reproducer somebody else can run.

    swift run --package-path Experiments/04-macro-global-crash Run

## The trigger

A peer macro whose parameter is **generic and function-typed**, attached to a **file-scope
variable**:

```swift
@attached(peer)
public macro Closure<In, Out>(_ f: (In) -> Out) = #externalMacro(module: "Impl", type: "NoOp")

@Closure({ (s: String) in s.count }) var a: Int = 0     // signal 11
```

`swift-frontend` dies with a stack dump and no source location the author can act on:

```
3. While evaluating request TypeCheckPrimaryFileRequest (main.swift)
4. While type-checking statement at [main.swift:4:1 - line:4:36]
5. While type-checking declaration
6. While evaluating request IsGetterMutatingRequest(a)
7. While evaluating request StorageImplInfoRequest(a)
8. While evaluating request ExpandAccessorMacros(a)
```

The shape of that stack — asking for the variable's storage kind in order to type-check the
attribute, and asking for the attribute in order to know the storage kind — reads like an
undetected request cycle, and signal 11 rather than a diagnostic is consistent with stack
exhaustion. That is an inference from the trace, not a claim about the compiler's source.

## What narrows it, measured

Each row is this package with one line changed.

| | result |
|---|---|
| generic + closure parameter, file-scope `var` | **CRASH** |
| generic + closure parameter, file-scope `let` | **CRASH** |
| generic + closure parameter, inside a `struct` | clean |
| generic + closure parameter, local `var` in a function | clean |
| generic + **value** parameter (`macro Value<T>(_ v: T)`), file scope | clean |

So it is not "generic macros" and not "macros on globals" — it needs both the function-typed
generic parameter and file scope. The declared types are fully explicit in the crashing case
(`var a: Int`, `(s: String)`), so it is not driven by the obvious inference gap.

## Assay's exposure, and why there is no workaround here

Two public macros have the signature:

```swift
public macro Transform<In, Out>(_ transform: (In) -> Out)
public macro Inverse<Value, Wire>(_ inverse: (Value) -> Wire)
```

`@Fallback<T>(_ value: T)` is generic and does **not** crash, which is the value-parameter
row above. `@Preprocess`, `@Wraps`, `@Validate`, `@Key` and `@Coerce` are non-generic and do
not crash.

**Assay cannot intercept this.** A guard in `TransformMacro` was written and reverted,
because the macro body never runs: instrumenting it to print on entry and diagnose
unconditionally produces no output at all in the crashing case, while the same
instrumentation fires normally for the same attribute inside a type. The compiler dies
before peer expansion. A check that cannot fire is the thing this codebase keeps removing,
so the guard did not ship.

The only change that would avoid it is dropping the function-typed generic parameter — and
that parameter *is* the feature. `(In) -> Out` is how the closure's annotation names the
wire type the value arrives as, which is what the macro decodes by (`docs/EXPERIENCE.md`
§11). There is no version of `@Transform` without it.

The practical consequence is small: `@Transform` and `@Inverse` are field attributes, and a
global variable is never a field. Nobody reaches this by writing Assay correctly. It is
recorded because a user who typos one into file scope gets a compiler crash instead of a
sentence, and because the next person to see that stack dump should not have to re-derive
what it is.
