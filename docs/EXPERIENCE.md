# Assay — the developer experience

**Second edition.** Rewritten after four audits: macro feasibility (checked against swift-syntax 600.0.1 and the Swift 6.3 compiler sources), cross-platform reality (Apple / Linux / Windows / Android / Wasm, July 2026), a competitive benchmark against serde, Pydantic, Zod v4, Valibot, ArkType, Ecto and garde, and a naming + scope review.

Everything in the first edition that could not compile has been removed. Where a surface changed, the reason is stated inline rather than hidden — this document is meant to be argued with.

No internals. No parser design, no ARC, no SIL, no benchmark tables. Those live in `PERFORMANCE.md` and `FORMATS.md`. This is only what a developer sees, types, and reads.

---

## 0. The name

**Module: `Assay`. Protocol: `Assayable`. Macro: `@Schema`. Runtime value type: `Assayer<T>`.**

You asked whether the whole thing should be called `Assayable` instead of `Assay`. It shouldn't, and the reason is mechanical rather than aesthetic.

A module and a protocol cannot usefully share a name in Swift. If the module were `Assayable`, then `Assayable.Assayer` — the qualified reference every macro expansion has to emit, because macros are not hygienic and must fully qualify everything they generate — parses as a *nested type lookup inside the protocol*, not a module member. It fails. The same collision corrupts the generated `.swiftinterface` under library evolution. Swift's own module-selector proposal names this exact hazard in its motivation: the `Observation` module "might have been called `Observable` if it didn't have a type with that name."

Beyond the mechanics, `-able` is reserved by the API Design Guidelines for *capability* protocols — a thing that can be assayed. A module is a place, not a capability. Across the Swift Package Index only about 1.3% of packages end in `-able`, and Apple ships none.

So the capability keeps the `-able`:

```swift
import Assay

struct Money: Assayable { ... }
```

`Assay` reads as the noun (the analysis) and the verb (to assay). It is unclaimed on the Swift Package Index, on GitHub as a Swift package, and the `assay` GitHub topic is entirely biomedical. `Assayer<T>` is the runtime schema value — deliberately *not* `Schema<T>`, because `import SwiftData` also exports a `Schema` and the bare name would be ambiguous in any app that uses both.

Also settled by the same rule that makes qualification necessary: a client type named `Schema` **cannot** shadow the `@Schema` macro. Macro lookup uses a separate name-lookup path that rejects non-macro candidates. And if you ever do want to disambiguate explicitly, Swift 6.3 shipped module selectors: `@Assay::Schema`.

---

## 1. The thirty-second version

Here is the smallest complete program. Note what is *not* in it.

```swift
import Assay

@Schema
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var published: Date
    var tags: [String] = []
}

let article = try Article.parse(json: data)
```

No rules. No validation. No `CodingKeys`. This is a decoder.

That framing is the single biggest change from the first edition, and it came out of the competitive audit. The first edition led with three `@Validate` lines, which advertised Assay as a validation library that also happens to decode. The evidence says that is backwards.

In Rust, `serde` is genuinely good, so `garde` exists as a separate validation crate layered on top. In Swift, the layer underneath is the problem. `Codable` throws away all but the first error, cannot tell you where in the file the error was, cannot rename a key without a hand-written enum, and cannot be extended from the top level at all — Vapor's own source carries a comment describing the workaround it was forced into, decoding a throwaway sentinel type through `userInfo` because "top-level decoders like `JSONDecoder` do not actually conform to `Decoder`."

Adoption follows the pain. BetterCodable — pure decoding ergonomics, zero validation — sits at 1,804 stars three years after its last commit. SmartCodable's entire pitch is *never interrupting the parse*. Every Swift library that pitches itself as validation-first caps out around 100 stars.

**So: Assay is not "a validation library that also decodes." It is "the decoder that tells you what went wrong."** Validation is the upsell, not the entry fee.

Which answers your fourth question directly.

### Yes — it works as a pure serde, with nothing else on

There is one attribute. `@Schema` with no rules is a first-class mode, not a degenerate one. There is no separate `@Codec`, no "validation module" to avoid importing, no flag to turn validation off.

What you get for the plain struct above, with zero annotations:

- Every decoding failure in one pass, not just the first.
- Every failure carrying a path, a line, a column, and a byte range.
- Key renaming from the declared identifier, at compile time.
- The same struct decoding from JSON, YAML, XML or plists.
- No reflection and no dynamic casts on the decode path.

And when a field genuinely has a constraint, you write it in the same place:

```swift
@Validate(.min(1)) var title: String
```

That's the whole progression. The upgrade path is one attribute wide.

---

## 2. The core loop

Two verbs. The first edition had three; `validate` has been cut because it collided with `ParsableArguments.validate()` in swift-argument-parser and with Vapor's `Validatable.validate()`, and because two of the three verbs had the same shape.

**`parse` — you want the value, and a failure is exceptional.**

```swift
let user = try User.parse(json: data)
```

Throws `AssayError`, which contains *all* the issues, not the first one.

**`diagnose` — you want everything that happened, including the value.**

```swift
let d = User.diagnose(json: data)

d.value        // User?   — present if decoding produced a usable value
d.issues       // [Issue] — hard failures
d.warnings     // [Warning] — fallbacks that fired, aliases that matched,
               //             unknown keys that were tolerated
d.isValid      // Bool
try d.get()    // User, throwing if !isValid
```

`Diagnosis<T>` is a plain value. You can hold it, log it, pass it across an actor boundary, or render it.

This pair fixes a hole in the first edition. `try User.parse(json:)` returns `User` and therefore has nowhere to put a warning — so the whole "`@Fallback` records what it did" story silently did not work on the primary entry point. It works now, with one honest cost stated up front: **`parse` discards warnings.** If you use `@Fallback`, `@Key(or:)`, or tolerant unknown-key handling and you want to know they fired, use `diagnose`.

Every format has both:

```swift
try User.parse(json: data)          User.diagnose(json: data)
try User.parse(yaml: text)          User.diagnose(yaml: text)
try User.parse(xml: data)           User.diagnose(xml: data)
try User.parse(plist: data)         User.diagnose(plist: data)
try User.parse(bytes, as: .json)    User.diagnose(bytes, as: .json)
```

### Limits are part of the call, not a global

```swift
let d = User.diagnose(json: data, limits: .default)
```

`Limits` carries `maxIssues` (default 100), `maxDepth` (default 64), `maxBytes`, and for the formats that need it, entity expansion caps. When the issue cap is hit, the diagnosis says so explicitly — `d.truncatedIssues == true` — rather than quietly returning a hundred of ten thousand.

This was missing entirely from the first edition and it was a denial-of-service hole: a ten-megabyte array of malformed email addresses would have produced a hundred thousand issues, each retaining a source span.

---

## 3. Errors are the product

Everything else in this document is in service of this section.

When something fails, you get this — from a `String`, on every platform, with no debugger and no logging framework:

```
deploy.yaml:4:13: error: replicas must be at least 1
  2 │ deployment:
  3 │   name: api
  4 │   replicas: 0
    │             ^
  5 │   image: api:1.4
```

That is `print(error)`. The format is the one Swift developers already read every day, because it is the compiler's.

For a nested field in a large document you get the path too:

```
config.json:118:22: error: services[2].healthCheck.timeoutSeconds must be positive
```

### An issue is data, not a sentence

```swift
for issue in d.issues {
    issue.path       // [PathComponent] — .key("services"), .index(2), .key("timeoutSeconds")
    issue.code       // IssueCode — .tooSmall, .typeMismatch, .missing, .custom("company_domain")
    issue.params     // [String: IssueValue] — ["minimum": .int(1), "inclusive": .bool(true)]
    issue.received   // what was actually there
    issue.location   // SourceSpan? — line, column, byte range
    issue.message    // rendered on demand, from code + params
}
```

The important part is that **`message` is derived, never stored.** Issues carry a code and a parameter dictionary; the English sentence is produced at render time. This is Ecto's `{template, params}` model, and it is the difference between a library you can localise and one you can't. The first edition stored strings, which meant every consumer downstream of the parse was stuck with English.

```swift
issue.message                                  // "must be at least 1"
issue.message(locale: "de_DE")                 // via String(localized:) / stringsdict
```

Note the parameter type: a locale **identifier string**, not a `Locale`. That is a cross-platform decision, and section 13 explains it — briefly, a `Locale` silently degrades to an unlocalised stub on platforms that don't link the internationalisation component, with no compile error and no runtime signal. Taking an identifier makes the caller own the lookup, which is both more portable and consistent with "nothing implicit."

Custom checks you write yourself default to a plain literal message, because forcing you to invent a code for a one-off rule would be obnoxious. If you want yours localisable, give it a code:

```swift
issues.add(.custom("must be a company address"))                        // fine, English
issues.add(code: "company_domain", "must be a company address",
           params: ["domain": .string("acme.com")])                     // localisable
```

That asymmetry is real and stated rather than papered over: **built-in rules are localisable by construction; yours are localisable if you opt in.**

### Rendering

```swift
d.render(.terminal)          // carets and colour, the block above
d.render(.plain)             // no ANSI
d.render(.json)              // machine-readable, stable shape
d.render(.problemDetails)    // RFC 9457 application/problem+json
```

`.terminal` detects a TTY and turns colour off when there isn't one — including on WebAssembly, where there is no TTY at all and colour resolves to off rather than to garbage.

Grouping by field for an API response:

```swift
let byField = Dictionary(grouping: d.issues, by: \.path.description)
    .mapValues { $0.map(\.message) }
```

---

## 4. Keys

This section did not exist in the first edition, and its absence was the largest single gap the audits found. More Swift developers hit snake_case on day one than will ever touch XML, and the first edition gave XML the largest share of its complexity budget and key renaming zero words.

### The default

```swift
@Schema(keys: .snakeCase)
struct UserProfile {
    var userID: String        //  user_id
    var displayName: String   //  display_name
    var avatarURL: URL        //  avatar_url
    var createdAt: Date       //  created_at
}
```

Also available: `.camelCase` (the default — identity), `.kebabCase`, `.pascalCase`, `.screamingSnakeCase`, and `.custom` for a function you supply.

### Why this is meaningfully better than `.convertFromSnakeCase`

Foundation's `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` runs at *runtime*, on the wire key, and it is lossy. `avatarURL` is encoded as `avatar_url`, which decodes back as `avatarUrl` — a different property. Round-tripping breaks on any acronym, and it breaks silently.

Assay converts at *compile time*, from the real declared identifier, with the acronym information still intact. `avatarURL → avatar_url → avatarURL` round-trips exactly. And because it happens during expansion, a mistake is a compiler error with a fix-it, not a nil at three in the morning.

### Per-field override

```swift
@Key("id")           var userID: String
@Key("e-mail")       var email: String
```

### Aliases, with a record of which one matched

```swift
@Key("email", or: "email_address", "mail")  var email: String
```

Tries them in order. If a non-primary alias matched, `d.warnings` records it:

```
warning: matched deprecated key "email_address"; prefer "email"
```

This is the piece Pydantic gets right with `AliasChoices` and serde gets right with `#[serde(alias)]`, and neither of them tells you which one fired. Migrating an API is a lot easier when your logs say how many clients are still on the old key.

### Reaching into nested shapes

```swift
@Key(path: "profile.display_name")  var displayName: String
@Key(path: "meta.tags[0]")          var primaryTag: String?
```

Pydantic's `AliasPath`. It saves you from declaring three throwaway structs to reach one field.

### Flattening

```swift
@Schema
struct Response {
    @Inline var page: Pagination     // page's keys read from this level
    var items: [Item]
}
```

serde's `flatten`. The macro knows `Pagination`'s keys at compile time, so unknown-key handling still works correctly through an `@Inline` — which is precisely the thing serde's runtime `flatten` cannot do.

### Keeping what you didn't declare

```swift
@Extras var extras: [String: RawValue]
```

Explicit, because the macro cannot guess which dictionary is the sink. `RawValue` is the format-neutral value type — deliberately not named `JSONValue`, since the same struct may have arrived as YAML.

### Unknown keys

```swift
@Schema(unknownKeys: .ignore)   // default — the Codable behaviour
@Schema(unknownKeys: .warn)     // a warning per key, decoding proceeds
@Schema(unknownKeys: .reject)   // an issue per key
@Schema(unknownKeys: .collect)  // routed to the @Extras field
```

`.warn` and `.reject` both produce a did-you-mean when the key is close to a real one:

```
config.json:12:3: error: unknown key "tiemout"
   │   did you mean "timeout"?
```

---

## 5. Saying what "valid" means

```swift
@Schema
struct Signup {
    @Validate(.min(3), .max(20), .regex(#"^[a-z0-9_]+$"#))  var username: String
    @Validate(.email)                                        var email: String
    @Validate(.min(12), "must be at least 12 characters")    var password: String
    @Validate(.range(13...120))                              var age: Int
    @Validate(.count(1...10), .each(.email))                 var recipients: [String]
}
```

### The message-as-a-rule trick, and why it exists

`@Validate(.min(12), "must be at least 12 characters")` reads naturally, but a parameter following a variadic in Swift **must** have a label. `@Validate(_ rules: Rule..., _ message: String)` does not compile — there are eight separate compiler tests asserting exactly that.

Rather than mangle the syntax into `@Validate(.min(12), message: "…")`, `Rule` conforms to `ExpressibleByStringLiteral`. The literal *is* a rule — one that carries no check, only a message, and overrides the message for every other rule in the same attribute. The syntax survives character for character and it compiles.

Per-rule messages are also available when one attribute has several rules that need different wording:

```swift
@Validate(.min(3, or: "too short"), .max(20, or: "too long"))
var username: String
```

A lone message with no check — `@Validate("nope")` — is a macro diagnostic, not a silent no-op.

### Rules are not generic, and that turns out to be an advantage

`Rule` is a single non-generic type. It has to be: leading-dot syntax like `.min(1)` inside an attribute has no type context from which Swift could infer a generic parameter, so `Rule<Value>` would force you to write `Rule<String>.min(1)` at every call site.

The obvious cost is that the type system no longer stops you writing `@Validate(.email) var age: Int`. Except it does — just at a better layer. The macro sees both the rule text and the declared type, so it emits a real compiler error:

```
error: rule '.email' applies to String, but 'age' is declared Int
```

Which is a considerably kinder message than anything a generic constraint failure would have produced. Swift's generic diagnostics are not its strong suit; a purpose-written one beats them.

The same mechanism means `.min(1)` is polymorphic in the way people already expect from Zod — length on a `String`, count on an `Array`, magnitude on an `Int` — and the macro resolves which at expansion time.

### The built-in rules

Strings — `.min` `.max` `.length` `.notEmpty` `.regex` `.email` `.url` `.uuid` `.hostname` `.prefix` `.suffix` `.contains` `.oneOf` `.trimmed` `.lowercased` `.ascii`
Numbers — `.min` `.max` `.range` `.positive` `.negative` `.nonNegative` `.multipleOf` `.finite`
Collections — `.count` `.notEmpty` `.unique` `.each(...)`
Dates — `.before` `.after` `.between` `.past` `.future`
Optionals — rules apply to the wrapped value; `nil` skips them.

### The custom escape hatch moved

The first edition had `.custom { $0.hasSuffix("@acme.com") }`. That does not compile — a closure inside an attribute argument has no type context, so `$0` is untyped and inference fails. It is gone.

Arbitrary logic is a function instead:

```swift
@Schema
struct Signup {
    var workEmail: String

    @Check(\.workEmail)
    static func companyDomain(_ email: String) -> String? {
        email.hasSuffix("@acme.com") ? nil : "must be a company address"
    }
}
```

Real parameter, real type, real autocomplete, breakpoints work, and it is testable on its own without constructing a `Signup`. The issue lands on `workEmail` with the right path and the right source span, because the key path told the macro where it belongs.

Losing the inline closure is a genuine cost in brevity. It buys types.

### Rules compose without a macro

Anything you write twice becomes a value:

```swift
extension Rule {
    static let companySlug = Rule.all(.min(3), .max(40), .regex(#"^[a-z][a-z0-9-]*$"#))
}

@Validate(.companySlug) var slug: String
```

Because `Rule` is non-generic, `static let` on a plain extension works and leading-dot syntax finds it. This is the direct payoff for not being generic.

---

## 6. Missing, empty, wrong, defaulted and salvaged are five different things

Most decoding bugs are a conflation of these. Assay keeps them apart in the declaration, and the distinction is visible in the error.

```swift
@Schema
struct Settings {
    var name: String                    // required — absent is an error
    var nickname: String?               // optional — absent is nil, and that's fine
    var retries: Int = 3                // defaulted — absent is 3, present is validated
    @Fallback(0) var count: Int         // salvaged — absent OR invalid becomes 0, with a warning
}
```

The four errors read differently, on purpose:

```
error: name is required
error: retries must be an integer, found "many"
error: nickname must be a string, found 42          ← present but wrong is still an error
warning: count fell back to 0 (was "abc")
```

Note the third: `nickname` being optional means it may be *absent*. It does not mean anything is acceptable when it *is* there. That is the distinction `Codable` blurs and the one that costs people the most debugging time.

`= 3` and `@Fallback(0)` differ in exactly the way Valibot's `default` and `fallback` differ, and the difference is worth stating because it is easy to get wrong: **a default is only consulted when the key is absent, and the resulting value is still validated. A fallback is also consulted when the value is present but invalid, and its value is trusted without re-checking.** A fallback silently swallowing bad data is the point; the warning is how you find out it happened.

Which is why fallbacks only report through `diagnose`. If you use `parse`, you have said you don't want to know.

### Empty is not missing

```swift
@Validate(.notEmpty) var bio: String       // "" is an error; absent is a different error
@Schema(emptyStringIsNil: true)            // opt-in, per type, for form-encoded input
```

The second is off by default and exists because HTML forms send `""` for untouched fields and nobody enjoys writing that coalescing by hand fifty times.

### Two declarations that are hard errors

```swift
@Schema
struct Bad {
    var x = 3               // error: property 'x' needs an explicit type annotation
    let y: Int = 3          // error: 'let' with an initializer cannot be decoded
}
```

The first is a hard error rather than an inference because a macro only sees source text — it cannot ask the type checker what `3` is, and guessing `Int` would be wrong the moment someone writes `var timeout = 1.5` in a codebase where the wire type is a `Duration`. The message says so and offers a fix-it.

The second because a `let` with an initializer is already assigned and no generated initializer can write to it. Change it to `var y: Int = 3` and it becomes a default.

One more thing worth knowing: `lazy var cache: [String: Int] = [:]` looks exactly like a defaulted stored property from the macro's point of view. It is skipped, along with `static`, computed properties, and anything with a `willSet`/`didSet`-only accessor block. If you want a stored property excluded for a reason the macro can't see, say so:

```swift
@Ignore var scratch: [String] = []
```

### Your memberwise initializer still works

```swift
let s = Settings(name: "api", nickname: nil, retries: 5, count: 0)
```

This is not free — a macro that emits an `init` into the type body silently deletes the memberwise initializer Swift would have synthesised, which is a well-known and very annoying trap. Assay emits its initializer into an extension instead, so both exist.

---

## 7. Coercion is a decision you can see

Wire formats lie about types. YAML says `port: "8080"`. A form sends `active=true` as text. An older API sends `count` as a string this week and a number next week.

Coercion is never implicit and never global.

```swift
@Schema
struct ServerConfig {
    @Coerce var port: Int          // "8080" → 8080, and the coercion is recorded
    var host: String               // "8080" stays a string; 8080 is an error
}
```

Or once, for a whole type, when the source is a format that has no types at all:

```swift
@Schema(coerceScalars: true)
struct EnvConfig {
    var port: Int
    var debug: Bool
    var timeout: Double
}
```

Coercion rules are written down and boring, which is the property that matters: `"8080" → 8080`, `"8080.5" → Int` is an error rather than a truncation, `"true"`/`"yes"`/`"1"` → `true`, `1.0 → 1` succeeds and `1.5 → Int` does not. Nothing depends on the current locale, because nothing goes through a locale-sensitive formatter — which is also what makes it behave identically on Linux and on a Mac.

The first edition and `DESIGN.md` agree on this and the reason is worth keeping visible: a global strict/lax switch means the meaning of a struct depends on a setting somewhere else in the program, which is exactly the class of bug that makes a config library infuriating.

---

## 8. Types that carry their own validity

The best validation is the kind you only write once, because after that the type system carries it.

```swift
struct EmailAddress: Assayable {
    let raw: String
    static let schema = Assayer.string.email.map(EmailAddress.init)
}
```

Then anywhere:

```swift
@Schema
struct Contact {
    var email: EmailAddress          // no @Validate — the type already means valid
    var backup: EmailAddress?
    var cc: [EmailAddress]
}
```

Errors still land in the right place with the right path, because the outer schema knows where it asked the inner one to look.

There is sugar for the extremely common wrapper case:

```swift
@Wraps(String.self, .email)
struct EmailAddress {}
```

which generates the storage, the `Assayable` conformance, `Equatable`, `Hashable`, `CustomStringConvertible` and a failable `init?(_:)`. This is an attribute on a **type declaration**. The first edition wrote `@Wraps(String.self, .email) var EmailAddress` — a variable named like a type, with no type annotation and no value — which is illegal three ways over. Corrected.

### Enums are free

```swift
enum Priority: String, Assayable {
    case low, medium, high
}
```

Conformance is the entire implementation. Any `RawRepresentable` enum with a `String` or integer raw value gets its schema for nothing — you write `: Assayable` and stop.

Invalid values produce a real suggestion rather than "cannot initialize":

```
error: priority must be one of "low", "medium", "high", found "urgent"
```

And for the case every long-lived API eventually needs — a server that adds a new variant before your client ships:

```swift
enum Priority: String, Assayable {
    case low, medium, high
    @Unknown case other(String)
}
```

serde's `#[serde(other)]`, with the raw value kept rather than discarded.

---

## 9. Composing bigger shapes

Nesting is nothing. A schema type is a type.

```swift
@Schema struct Address { var street: String; var city: String; @Validate(.length(2)) var country: String }
@Schema struct Company { var name: String; var address: Address; var employees: [Person] }
@Schema struct Person  { var name: String; var email: EmailAddress; var manager: Person? }
```

Recursion works. Arrays and dictionaries of schema types work. Errors carry the full path through all of it:

```
org.json:41:18: error: employees[3].address.country must be exactly 2 characters
```

### Discriminated unions

```swift
@Schema(discriminator: "type")
enum Event {
    case click(ClickEvent)
    case pageView(PageViewEvent)
    case purchase(PurchaseEvent)
}
```

`{"type": "click", ...}` picks the branch by the discriminator alone, so a malformed click event reports as a malformed click event — not as "did not match any of 3 variants" followed by three sets of irrelevant errors. That failure mode is the single most-complained-about thing in every validation library that has union types, and a discriminator is the fix.

Untagged unions exist for wire formats you don't control:

```swift
@Schema(discriminator: .none)
enum StringOrNumber { case text(String), number(Double) }
```

and when *those* fail you get the composed report — every branch, and why each one didn't match — because there is nothing better available.

### Collections that arrive in more than one shape

```swift
@OneOrMany var tags: [String]        // "swift" and ["swift", "ios"] both work
@PickFirst var id: StringOrInt       // tries each representation in order
```

Borrowed from `serde_with`, which exists because these two shapes account for a startling proportion of real-world API weirdness.

---

## 10. Rules that span more than one field

Some things are only wrong in combination.

```swift
@Schema
struct DateRange {
    var start: Date
    var end: Date

    @Check
    static func endAfterStart(_ r: DateRange, _ issues: inout Issues<DateRange>) {
        if r.end < r.start {
            issues.add("must be on or after start", at: \.end)
        }
    }
}
```

`Issues<DateRange>` is generic over the root type, which is what makes `\.end` resolve — the first edition wrote `inout Issues` and the key path had nothing to resolve against. Corrected.

The key path is doing real work: it is how the issue acquires a path (`end`), a source span, and therefore a caret pointing at the offending line of the original document. Cross-field errors get the same quality of report as field errors, which is unusual — most libraries degrade cross-field rules to a bare form-level message.

You can add several, and they all run:

```swift
@Check static func passwordsMatch(_ s: Signup, _ issues: inout Issues<Signup>) { ... }
@Check static func planAllowsSeats(_ s: Signup, _ issues: inout Issues<Signup>) { ... }
```

### One trap, and it is worth knowing about

**A `@Check` in an extension is invisible.** The macro can only see members declared in the type's own body — that is a hard limit of how attached macros receive their input, not an implementation shortcut.

```swift
extension DateRange {
    @Check static func endAfterStart(...) { }   // never runs
}
```

Because this would otherwise be a silent, maddening bug, `@Check` is itself a declared macro whose only job when it finds itself in an extension is to emit:

```
error: @Check must be declared in the body of the @Schema type, not in an extension
```

### Context

Some rules need something from outside — a database handle, a feature flag, the current tenant.

```swift
@Schema(context: AppContext.self)
struct Invitation {
    var email: EmailAddress
    var role: String

    @Check
    static func roleIsAllowed(_ i: Invitation, _ ctx: AppContext, _ issues: inout Issues<Invitation>) {
        if !ctx.availableRoles.contains(i.role) {
            issues.add("is not available on your plan", at: \.role)
        }
    }
}

let invite = try Invitation.parse(json: data, context: appContext)
```

Declaring a context makes `parse(json:context:)` the *only* signature. You cannot forget to pass it. `AppContext` is a real type in the check — no casting, no optionals, no `userInfo` dictionary.

This differs from what `DESIGN.md` settled on, which was a type-erased context threaded through `ParseState`, and the difference is deliberate rather than an oversight: they operate at different layers. The macro knows the context type at compile time and should use it. The runtime `Assayer<T>` value API — for schemas built dynamically, where there is no declaration to read — keeps the erased form. Both exist; the macro path is the one with the better types, which is the one almost everybody uses.

### Async checks

```swift
@AsyncCheck
static func emailIsAvailable(_ s: Signup, _ ctx: AppContext, _ issues: inout Issues<Signup>) async {
    if await ctx.users.exists(email: s.email) {
        issues.add("is already registered", at: \.email)
    }
}
```

A type with any `@AsyncCheck` gets an `async` `parse`. A type without one does not. This is decided by counting the attributes at compile time, so there is no `await` on schemas that don't need it and no overload ambiguity.

Ordering, stated precisely — the first edition contradicted itself here:

**All synchronous work runs first and collects everything.** Every field rule, every `@Check`, in one pass. Four problems produce four issues.

**Async checks run afterwards, and only if the synchronous pass was clean.** Not because collecting more errors is bad, but because an async check almost always means a network or database round trip, and spending one to ask "is this email registered?" about a value you already know is not an email address is waste you'd be paying on every malformed request. Once the sync pass is clean, all async checks run **concurrently** and all their issues are collected.

---

## 11. Transformations

Two attributes, at two different times, and the distinction is which side of validation they sit on.

`@Preprocess` runs on the raw value **before** rules, and its job is normalising input:

```swift
@Preprocess(.trim, .lowercase) @Validate(.email)
var email: String
```

`@Transform` runs **after** validation and changes the type:

```swift
@Transform { Set($0) }
var tags: Set<String>          // arrives as an array, ends up a set

@Transform(.milliseconds)
var timeout: Duration          // arrives as 5000, ends up .milliseconds(5000)
```

Here the closure *does* have type context — it is a member-level attribute on a declaration with a known type annotation — so `$0` infers. That is why `@Transform { }` survives and `.custom { }` in section 5 did not.

Order is fixed and total: **preprocess → coerce → decode → field rules → cross-field checks → transform → async checks.** No configuration.

### Dates

```swift
var createdAt: Date                          // ISO 8601, the default
@DateFormat(.unixSeconds)  var ts: Date
@DateFormat(.unixMillis)   var ts: Date
@DateFormat(.rfc9110)      var expires: Date // HTTP dates
@DateFormat(.pattern("yyyy-MM-dd")) var day: Date
```

`.pattern` is not `DateFormatter`, and section 13 explains why at length. Short version: it supports a small fixed set of fields (`yyyy MM dd HH mm ss SSS Z` plus literals), it is implemented directly, and it produces identical results on every platform. The full Unicode UTS-35 pattern language, with locale-dependent month names and era handling, is available — but only in the Foundation-dependent layer, and it is a deliberate opt-in rather than the default, because it pulls in an internationalisation component that costs roughly forty megabytes per architecture on Android and dominates a WebAssembly bundle.

---

## 12. One struct, many formats — that the struct asks for

*Built: `@Schema(formats:)`, `parse(json:)`, `parse(yaml:)`, `parse(xml:)`,
`parseAll(yaml:)`, `parse(mmapped:)`, `coerceScalars`. Still specified but not built:
`parse(plist:)`, `parse(bytes, as:)`, `parse(body, contentType:accepting:)`,
`parse(contentsOf:)`, and the `@XML` placement attributes.*

```swift
@Schema(formats: [.json, .yaml])
struct Config {
    var serviceName: String
    var port: Int
}

try Config.parse(json: data)
try Config.parse(yaml: text)
```

Same struct. Same rules. Same errors, pointing into whichever document you actually handed
it. This is the argument for a schema being a *declaration* rather than a decoder
conformance: a `Codable` type is coupled to whichever decoder happens to be walking it; a
declared schema is coupled to none of them.

**But the formats are opt-in, and the default is `.json` alone.** The first edition of this
section implied they were automatic. They are not, and the reason is measured rather than
aesthetic.

### Why opt-in

Supporting YAML and XML means the macro emits a *second* decode body — see "The two paths"
below — and `docs/COMPILE-TIME.md` measures it at **~34 ms per type, about 41% of total
expansion cost**. Emitting that for a type that will only ever see JSON would make every
JSON user pay for a capability they do not use.

That is the same sentence as "JSON users never pay for XML", which this document has
always claimed. It used to be a *linking* claim, true because `AssayYAML` and `AssayXML`
are separate products. Opt-in formats make it a *compile-time* claim too.

It is also §18's principle applied rather than excepted: everything that affects the
meaning of a struct is written on the struct, where you can see it.

```swift
@Schema                                   // JSON only. The default.
@Schema(formats: [.json, .yaml])          // both
@Schema(formats: .all)                    // JSON, YAML and XML
@Schema(formats: [.yaml])                 // YAML only — no JSON body emitted at all
```

### Forgetting to opt in is a compile error, not a runtime one

`Assayable` is a marker; two protocols refine it and carry the actual work.
`JSONAssayable` has the byte-decode body, `RawDecodable` has the `RawValue` one, and each
format's entry points live on the protocol that can serve them. So the mistake is caught
where it is written:

```
error: referencing static method 'parse(yaml:limits:sourceName:)' on 'RawDecodable'
       requires that 'JSONOnly' conform to 'RawDecodable'
```

The same split catches a subtler case for free: a `.yaml` schema containing a nested
`.json`-only schema fails to compile, rather than failing at parse time on a real payload.

### The two paths, and why they differ

They are not the same machinery, and pretending otherwise would misrepresent both the
speed and the fidelity.

**JSON decodes direct to struct.** The generated body reads bytes straight into your
fields — no intermediate document, no dictionary per object. That is where the measured
5.5× over Foundation comes from.

**YAML and XML go through their own full-fidelity model, then a projection.** Bytes →
`YAML.Node` / `XML.Document` → `RawValue` → your struct. That is a DOM hop, and
`PERFORMANCE.md` §1.3 measures a DOM at 2–7× against direct-to-struct.

Three reasons that trade is accepted rather than fought:

1. **Neither format can use a JSON-style structural index anyway.** YAML's `:` and `-` have
   no byte-local classification, and the single most valuable SIMD primitive in JSON —
   "find the next quote" — has no YAML analogue. The best C implementations top out around
   200 MB/s.
2. **One extra generated body instead of two** keeps the compile-time budget survivable.
3. It reuses projections that already exist and are already tested.

The consequence to know: the `RawValue` projection is lossy in the ways
`docs/VALUE-MODELS.md` §5 documents. YAML tags, scalar styles and anchors do not reach your
struct, and a non-string YAML mapping key is a hard error rather than a coerced one. If you
need any of that, parse to `YAML.Node` or `XML.Node` directly and work with the node model.

### XML has no types, and that is visible

Every XML leaf is text — there is no number and no boolean. So a schema with an `Int` field
**will not decode from XML** unless it opts into coercion:

```swift
@Schema(coerceScalars: true, formats: [.xml])
struct ServerConfig {
    var port: Int          // "8080" -> 8080
    var debug: Bool        // "true" -> true
}
```

That is §7 working as designed rather than a gap. Coercing silently *because the format
happened to be XML* would make a struct mean different things depending on where its bytes
came from, which is exactly the property this library refuses to have.

### Content negotiation is explicit about what it accepts

```swift
try Config.parse(body, contentType: header, accepting: [.json, .yaml])
```

`accepting:` is required, with no default. A single function that sniffs a header and dispatches to any available parser turns an XML external-entity attack, a billion-laughs expansion, or a YAML tag exploit into a one-line vulnerability in an application whose author only ever meant to accept JSON. Making the allowed set explicit costs one array literal and closes the whole category.

### YAML

The parser is hand-written and pure Swift, not a libyaml binding. Multi-document files,
anchors, aliases, merge keys, all five scalar styles and flow collections work.

```swift
let manifests = try Manifest.parseAll(yaml: text)   // [Manifest], one per ---
```

Errors carry offsets into the original YAML, not into some JSON the YAML was converted to
first.

**Nothing is resolved at parse time.** A scalar keeps its raw text, style and tag, and
`resolvedInt` / `resolvedBool` / `isNull` are consulted on demand. `country: NO` stays the
string `"NO"`; `yes` and `off` are *not* booleans, because that is YAML 1.1. Whether `NO`
means false becomes a question the schema answers, never one the parser answers silently.
That is how the Norway problem is sidestepped rather than inherited.

It is a *subset* of YAML 1.2 — the subset a configuration file uses. Not supported, and
stated here rather than discovered: multi-line plain scalars in flow context, YAML 1.1
sexagesimals, binary and timestamp resolution, and the set/omap/pairs types. Those parse as
scalars or fail with a real diagnostic; none is silently mis-resolved.

### XML lives behind one attribute

XML is the one format where a struct genuinely cannot describe the wire shape on its own, because an element and an attribute are different things.

```swift
@Schema
struct Book {
    @XML(.attribute) var isbn: String
    var title: String
    @XML(.wrapped("authors", item: "author")) var authors: [String]
    @XML(.text) var summary: String
    @XML(.namespace("http://purl.org/dc/elements/1.1/")) var creator: String
}
```

Everything else follows the general rules. `@XML` annotations describe the wire shape; they are not present on the JSON path and cost nothing there.

### The three parsers are three products

```swift
.product(name: "Assay",           package: "assay")   // core + JSON
.product(name: "AssayFoundation", package: "assay")   // Data, URL, FileManager conveniences
.product(name: "AssayYAML",       package: "assay")
.product(name: "AssayXML",        package: "assay")
```

The first edition claimed "JSON users never pay for XML." That sentence is only literally true if XML is a separate product — importing Foundation's XML support pulls in libxml2, which on Android drags in liblzma and libiconv behind it. So it is a separate product. Adding a format is adding a dependency line, and you can see it in your manifest.

It is now true in the second sense too. A format costs a dependency line in the manifest *and* a `formats:` entry on the struct, and a type that names neither pays for neither — not in binary size, and not in build time.

### File I/O is in the Foundation layer

```swift
import AssayFoundation
try Config.parse(contentsOf: url)          // sniffs by extension — specified, not built
try Config.parse(mmapped: url)             // built
```

File I/O, URL handling and extension sniffing are all Foundation. On WebAssembly they need
an explicit directory mount to work at all. Keeping them in a separate layer means the core
stays usable where they don't exist, and the byte-taking overloads are always available.

**`parse(mmapped:)` is how Assay reads a file larger than memory**, and it needed no
change to the decoder at all. `PERFORMANCE.md` §5.4 requires "a single contiguous buffer
that does not change underneath the parse", and a memory-mapped file satisfies that
literally: the address range is contiguous while physical residency is not, because the
kernel demand-loads and evicts pages.

Measured on a 387 MB document, extracting one top-level field:

| | wall | peak footprint |
|---|---|---|
| read into `[UInt8]` | 0.76 s | 407 MB |
| `parse(mmapped:)` | 0.21 s | **1.88 MB** |

The honest boundary, also measured: decoding *all* 8,000,000 records costs 1.067 GB
footprint read against 661 MB mapped — still exactly the file size apart. **mmap removes
the input from your accountable memory and does nothing about the output**, which is dirty
anonymous memory however it arrived. So it bounds the *input*, not the total: it will not
decode a 10 GB file into a 10 GB value on a 4 GB machine. `docs/STREAMING.md` has the rest,
including why incremental parsing of a document arriving over a *socket* is refused.

---

## 13. Cross-platform, stated as things you can observe

You said this has to be efficient everywhere. The honest version of that promise is narrower and more useful than "we benchmarked it on Linux."

**The claim: identical behaviour and near-identical performance on every platform, by construction rather than by measurement.**

The reasoning is that the platform asymmetries in Swift do not live in the language. Swift's own reference counting, generics and calling conventions are the same code on Darwin and on Linux. The asymmetries live in Foundation's platform-variable paths: the internationalisation engine, the regular expression engine, `Data`'s legacy ABI on Apple platforms, XML's dependency on libxml2. A decoder that walks UTF-8 bytes and dispatches through compile-time-generated code touches none of them. So the way to be fast everywhere is not to tune per platform — it is to not route through the parts that differ.

That principle produces a list of things you can actually see.

### Rules that behave the same everywhere, because they're implemented here

`.email`, `.uuid`, `.hostname` and the date formats are all implemented directly rather than delegated.

This is not gold-plating. `UUID(uuidString:)` has two different C implementations selected by platform, and the non-Darwin one is `sscanf`-based with libc-dependent edge cases — meaning a UUID string that your Mac accepts can be rejected on Linux. Nothing in Foundation or the standard library validates an email address at all. And a hand-written `.email` needs no regular expression engine, which means it keeps working in environments where `.regex` cannot.

**Dates are the biggest win available.** ISO 8601 in Foundation is genuinely internationalisation-free — it is hand-rolled and imports nothing. So `.iso8601`, `.unixSeconds`, `.unixMillis` and `.rfc9110` cost nothing anywhere. Making those the defaults, and putting the full pattern language behind an explicit opt-in, is the difference between a library that adds forty megabytes to an Android binary and one that adds none.

### `.regex` is the one rule that isn't universally portable

It works, but it is the exception, and pretending otherwise would be dishonest.

No `Regex` value appears in any public signature — not in a rule case, not in a stored property, not as a parameter type. `@Validate(.regex(#"^[a-z0-9_]+$"#))` takes a `String`, always. That is what keeps a platform availability annotation from spreading onto every call site that touches a schema, which is the failure mode that makes availability-gated APIs miserable to adopt.

Your pattern is validated when the rule is constructed, not when a document is parsed, so a typo in a pattern is caught the first time the schema is used rather than on whichever unlucky request first reaches that field.

### Locales are identifier strings, not `Locale` values

Section 3 mentioned this. The reason: on a platform that links only the essential part of Foundation, a `Locale` silently degrades to an unlocalised stub with an `en_001` identifier, and `Calendar` silently offers only Gregorian and Hebrew. There is no compile error and no runtime signal — your date parsing just quietly means something different. Taking an identifier string and letting the caller do the lookup makes that impossible to stumble into.

### The core takes bytes

```swift
try User.parse(bytes, as: .json)        // some Collection<UInt8>, or a RawSpan
```

`Data` overloads live in `AssayFoundation`. Two reasons, and one of them is the reverse of what you'd expect: `Data` is Foundation, so a `Data`-typed core API is not portable; and `Data`'s performance story now *favours* the non-Apple platforms, because Apple platforms retain a legacy ABI for compatibility that the others were free to drop. Byte access measured 787% faster on the new ABI against 147% on the existing one. A `Data`-typed hot path is therefore the one place where performance would genuinely differ by platform — which is exactly the thing you asked me to avoid.

### The package declares no platform floor

No `platforms:` clause in the manifest, following swift-nio, swift-log, swift-collections, swift-crypto, swift-argument-parser and Yams. A `platforms:` clause only constrains Apple platforms anyway, and pinning one is how a library accidentally excludes people. Individual APIs that genuinely need a floor carry their own availability annotation, and the design goes to some length to keep that list to one item.

### What "supported" would have to mean

A platform is only supported if continuous integration runs the test suite on it. The intended matrix is Linux, Windows, macOS, iOS, Android (on an emulator), WebAssembly and static-Linux/musl. Worth noting, because it is a trap: the standard Swift package testing workflow tests **Linux and Windows only** out of the box. Every other platform is an opt-in flag that defaults to false, which is how libraries end up claiming a platform list nobody ever ran.

Two specific things that will bite otherwise: WebAssembly needs an increased stack size, because the default is too small for a recursive-descent parser and the failure looks like a mysterious trap rather than a stack overflow. And the most common Swift setup action for CI does not support Windows at all — it throws an error saying so.

Enforcing the layering mechanically rather than by discipline is one compiler flag: an explicit-target-dependency import check turns an accidental `import Foundation` in the core into a build failure. Without it, "the core has no Foundation dependency" is a claim that decays.

### Embedded Swift is not a target

Stated plainly because someone will ask. Embedded Swift has no `Codable`, no reflection, no Foundation, no regular expressions, and casting to an existential is permanently forbidden there. Macros work fine in Embedded, and the architecture Embedded forces — compile-time code generation, no dynamic casts — is the architecture this library wants anyway. So a subset may become possible later. It is not promised now.

### Build time is the real cost, and it is worth naming

Macros are not free. Every macro expansion is a round trip to a separate compiler plugin process, and the published field reports are not gentle: a 30-second build going to 5 minutes, a 44-second build going to 338 seconds. One developer reported that a macro which did nothing at all doubled their release build times.

Swift 6.2 shipping a prebuilt swift-syntax fixed the fixed cost — the one-off price of building the macro infrastructure — but not the per-expansion cost. Which means the honest advice is: `@Schema` on forty types is fine, `@Schema` on four thousand is something to measure. Concretely, the mitigations that exist are keeping schema types in a module that changes rarely so they cache, and preferring one `@Schema` type with `@Inline` members over many small ones.

I would rather say this here than have you find it out in month three.

---

## 14. Going the other way

The first edition listed "it doesn't encode" among the things Assay refuses to do. That refusal does not survive contact with the evidence, so it is now a **deferral**, which is a different and more honest thing.

Zod is the only major library in this space that changed its mind about encoding, and it changed *toward* it — codecs shipped in 4.1 and were called the flagship feature. Effect's schema library went bidirectional from the start and simply never had the argument. Nobody has gone the other way.

So: **v1 decodes. Encoding is reserved, not refused.**

What that means concretely, and why it isn't just a promise:

Every piece of placement information — `@Key` renaming, `@XML(.attribute)`, `@DateFormat` — is preserved in the generated schema rather than consumed during decoding. That is a real design constraint being honoured now, and it is what makes encoding additive later instead of a rewrite.

What is deliberately **not** promised is symmetry. Every library that went bidirectional built two engines, not one — Pydantic's Rust core is roughly twelve thousand lines of validators alongside eleven thousand lines of serializers — plus a separate error channel for encode-side failures, because "this value cannot be represented in this format" is a different kind of problem from "this document is malformed." Anyone who tells you encoding is decoding backwards has not written one.

Related, and moved *into* the feature set from the first edition's refusals:

```swift
let schema = Article.jsonSchema(for: .input)     // 2020-12
```

The macro already has everything needed to emit JSON Schema — the field names, the types, the rules, the optionality. Refusing to expose it was leaving value on the table. `.input` and `.output` differ once transforms are involved, which is the distinction Zod added in v4 after discovering the single-document version was wrong.

`Encodable` conformance synthesis moves out of the refusals for the same reason: it is a strictly easier problem than a full encoder, it is what people actually ask for, and the key renaming information needed to do it correctly is already there.

---

## 15. Talking to everything else

```swift
// A separate, tiny, zero-dependency package
import StandardSchema
```

The mechanism that turned Zod from a library into a hub was not a feature of Zod. It was a fifty-line interface specification that any validation library could implement and any framework could consume, so that a web framework could accept "a schema" without depending on a particular one.

Nothing like it exists in Swift. Every framework that wants validation either invents its own protocol or hard-codes a dependency.

Publishing that package on day one — separately, with no dependency on Assay, and with Assay merely being one conformer — is the highest-leverage thing available, and it costs almost nothing. If it works, other libraries implement it and Assay benefits. If it doesn't, you lost a weekend.

```swift
extension Article: StandardSchema.Validatable {}   // that's the whole conformance
```

---

## 16. A realistic five minutes

You have a YAML config file, a service that reads it, and an HTTP endpoint that accepts JSON.

```swift
import Assay

@Schema(keys: .snakeCase, unknownKeys: .warn)
struct AppConfig {
    @Validate(.notEmpty)                    var serviceName: String
    @Validate(.range(1...65535))            var port: Int
    @Validate(.min(1))                      var workers: Int = 4
    @Fallback(.seconds(30))                 var requestTimeout: Duration
                                            var database: DatabaseConfig
                                            var features: [String: Bool] = [:]
                                            var logLevel: LogLevel = .info
}

@Schema(keys: .snakeCase)
struct DatabaseConfig {
    @Validate(.prefix("postgres://"))       var url: String
    @Validate(.range(1...100))              var poolSize: Int = 10
    @Coerce                                 var sslRequired: Bool = true
}

enum LogLevel: String, Assayable { case debug, info, warning, error }
```

At startup you want everything wrong at once, plus the warnings:

```swift
let d = AppConfig.diagnose(yaml: text, sourceName: "config.yaml")

for w in d.warnings { logger.warning("\(w)") }

guard let config = d.value, d.isValid else {
    FileHandle.standardError.write(Data(d.render(.terminal).utf8))
    exit(1)
}
```

```
config.yaml:3:9: error: port must be between 1 and 65535
  2 │ service_name: api
  3 │   port: 99999
    │         ^
  4 │   workers: 0

config.yaml:4:12: error: workers must be at least 1
  3 │   port: 99999
  4 │   workers: 0
    │            ^
  5 │ database:

config.yaml:7:8: error: database.url must start with "postgres://"
  6 │ database:
  7 │   url: "mysql://localhost/app"
    │        ^
  8 │   pool_size: 500

config.yaml:8:14: error: database.pool_size must be between 1 and 100
  7 │   url: "mysql://localhost/app"
  8 │   pool_size: 500
    │              ^

config.yaml:9:1: warning: unknown key "reties"
  │ did you mean "retries"?

4 errors, 1 warning
```

Four problems, four errors, one run, with the misspelled key caught as well. Not one error, fixed, rebuilt, one error, fixed, rebuilt.

The HTTP endpoint, same library, different verb:

```swift
app.post("signup") { req async throws in
    let signup = try Signup.parse(json: req.body, context: req.appContext)
    return try await users.create(signup)
}
```

and one error handler for the whole application:

```swift
app.catch(AssayError.self) { error in
    Response(status: .unprocessableEntity,
             body: error.render(.problemDetails))
}
```

```json
{
  "type": "https://example.com/probs/validation",
  "title": "Validation failed",
  "status": 422,
  "errors": [
    { "path": "email",    "code": "invalid_email", "message": "must be a valid email address" },
    { "path": "password", "code": "too_small",     "message": "must be at least 12 characters",
      "params": { "minimum": 12 } }
  ]
}
```

Note that the response carries codes and parameters alongside the messages, so a client can localise or branch without string-matching English.

---

## 17. What it deliberately does not do

**It is not schema-first.** There is no `.assay` file and no code generator. Swift types are the source of truth. Generating a *JSON Schema document* from your types is supported — going the other direction is not.

**It is not a document API.** If you want to walk arbitrary JSON, mutate it and write it back, that is a different library. Assay's job is document in, typed value out.

**It has no global configuration.** No `Assay.configure { }`, no ambient strict mode, no thread-local anything. Everything that affects the meaning of a struct is written on the struct. This costs a little repetition and buys the property that you can read a declaration and know what it does without grepping the codebase for a setup call.

**It is not a `z` namespace.** There is no `Assayer.object([...])` route for ordinary use. `Assayer` exists as a value type for the genuinely dynamic case — a schema built at runtime from a database row — and for domain types like `EmailAddress` in section 8. For everything else the declaration is the schema.

**It does not do Protocol Buffers, Thrift, Avro or CSV.** Those are schema-first by nature, or record-oriented rather than document-oriented. Different library.

**It does not encode, in v1.** Section 14 — a deferral, with the placement data preserved so it stays additive.

**It does not target Embedded Swift.** Section 13.

**It does not promise a fixed message for every rule.** Messages are derived from codes and parameters. Match on `issue.code`, not on `issue.message`.

---

## 18. The principles

**The type is the schema.** Not a description of a schema, not a builder that produces one.

**Nothing is implicit.** Coercion, fallbacks, key renaming, format acceptance and unknown-key handling are all written down where you can see them. A struct means the same thing regardless of what is configured elsewhere.

**Failure is a value.** `Diagnosis` is data. You can hold it, log it, render it four ways and send it across an actor boundary.

**All the errors, all the time.** One pass, everything wrong with the document, ordered by position. The only exception is async checks, and section 10 explains exactly why and exactly when.

**Errors are structured, not sentences.** Code plus parameters, rendered on demand. Anything else is a library that can only ever speak English.

**The format is a parameter.** One declaration, five formats, and none of them is privileged in the type.

**Portable by construction.** Not "we tuned it for Linux" — routed around the parts of the platform that differ, so there is less to tune.

**Simple things stay one line.** A plain struct with no annotations is a complete, useful program. Complexity is available and it is opt-in, attribute by attribute.

---

## 19. Cheat sheet

```swift
// Decode — no validation at all, and this is a first-class mode
@Schema struct T { var a: String; var b: Int }
try T.parse(json: data)

// Two verbs
try T.parse(json: data)              // T, throws, discards warnings
T.diagnose(json: data)               // Diagnosis<T> — value + issues + warnings

// Keys
@Schema(keys: .snakeCase)
@Key("id") var userID: String
@Key("email", or: "email_address") var email: String
@Key(path: "profile.name") var name: String
@Inline var page: Pagination
@Extras var rest: [String: RawValue]
@Schema(unknownKeys: .warn)          // .ignore .warn .reject .collect

// Rules
@Validate(.min(3), .max(20))
@Validate(.email, "must be a company address")
@Validate(.min(3, or: "too short"))
@Validate(.count(1...10), .each(.email))

// Presence
var a: String                        // required
var b: String?                       // optional
var c: Int = 3                       // default — absent only, still validated
@Fallback(0) var d: Int              // fallback — absent or invalid, not re-validated
@Ignore var e: [String] = []

// Coercion
@Coerce var port: Int
@Schema(coerceScalars: true)

// Transformation
@Preprocess(.trim, .lowercase)
@Transform { Set($0) }

// Dates
@DateFormat(.iso8601)                // default; also .unixSeconds .unixMillis .rfc9110
@DateFormat(.pattern("yyyy-MM-dd"))  // fixed subset, portable

// Domain types
struct Email: Assayable { static let schema = Assayer.string.email.map(Email.init) }
@Wraps(String.self, .email) struct Email {}
enum P: String, Assayable { case low, high; @Unknown case other(String) }

// Cross-field — must be in the type body, never an extension
@Check static func f(_ v: T, _ issues: inout Issues<T>)
@Check(\.field) static func g(_ x: String) -> String?
@Schema(context: Ctx.self)
@AsyncCheck static func h(_ v: T, _ ctx: Ctx, _ issues: inout Issues<T>) async

// Unions
@Schema(discriminator: "type") enum E { case a(A), b(B) }
@OneOrMany var tags: [String]
@PickFirst var id: StringOrInt

// Formats — opt in on the struct; the default is JSON alone
@Schema                                  // JSON only
@Schema(formats: [.json, .yaml])         // adds the YAML/XML decode body
@Schema(formats: .all)
@Schema(coerceScalars: true)             // required for XML: every leaf is text
try T.parse(json: data) / parse(yaml: text) / parse(xml: data)
try T.parseAll(yaml: text)
try T.parse(mmapped: url)                // AssayFoundation; files larger than memory
// specified, not built:
//   parse(plist:) / parse(bytes, as:) / parse(body, contentType:accepting:)
//   @XML(.attribute) @XML(.text) @XML(.wrapped(_:item:)) @XML(.namespace(_:))

// Output
d.render(.terminal) / .plain / .json / .problemDetails
T.jsonSchema(for: .input)
```

---

## 20. What is still open

Everything in the first edition's open questions about the macro shape, the `@Wraps` spelling and async parsing has been resolved and is written into the sections above. These are the ones that remain.

**1. Does `diagnose` need a streaming form?** For a very large document you might want issues as they are found rather than an array at the end. It complicates the primary API for a rare case, and the issue cap already covers the memory concern. Probably no, but a large-file user would know better.

**2. How much does `@Inline` cost at the diagnostic level?** Flattening means two structs' keys share a namespace, so a collision is possible. A compile-time error is the right answer, but it may be surprisingly expensive to detect across module boundaries where the macro can't see the other type's members.

**3. Should `.regex` fail closed on platforms without a regular expression engine?** Right now the plan is that it works everywhere the library is claimed to support. If a stripped-down environment ever lacks one, the choice is between a rule that always passes, a rule that always fails, and a hard build error. Build error, probably.

**4. Is `@Fallback` too dangerous to be this easy?** It swallows bad data by design, and the warning is only visible through `diagnose`. There's an argument that it should require an explicit acknowledgement. There's a counter-argument that it exists precisely for the cases where you have already decided to keep going.

**5. What does an `@Unknown case other(String)` enum do on the encode side, once encoding exists?** Round-tripping an unknown variant is either exactly right or a security hole, depending on who is asking.

**6. Should the runtime `Assayer<T>` API be in the initial release at all?** It exists for dynamic schemas and for domain types. The domain-type use is small enough that a narrower protocol might cover it, and shipping a full value-level combinator API means committing to maintaining two front doors forever.

---

*Second edition. Nothing in this document has been compiled — there is no Swift toolchain in this environment, so every API here is designed against the compiler's source and its test suite rather than against a build. The macro-shaped claims were checked against swift-syntax 600.0.1 and the Swift 6.3 compiler tests; the platform claims against the Foundation and package sources listed in `_crossplatform_audit.md`. The first thing to do on a machine with a toolchain is prove the `@Validate` attribute in section 5 actually compiles.*
