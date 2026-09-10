---
title: Keys
description: Naming, renaming, aliases, paths into nested objects, and what to do with keys you did not declare.
---

Your properties are camelCase. The wire is whatever the wire is. This page is how you
reconcile the two.

## A whole-type convention

```swift
@Schema(keys: .snakeCase)
struct User {
    var displayName: String       // reads "display_name"
    var avatarURL: String         // reads "avatar_url"
}
```

Five styles: `.camelCase` (the default — no conversion), `.snakeCase`, `.kebabCase`,
`.pascalCase`, `.screamingSnakeCase`.

The conversion happens **at compile time**, from the identifier you wrote. Foundation's
runtime `.convertFromSnakeCase` cannot do this correctly: it converts in the other
direction, `avatarURL` → `avatar_url` → `avatarUrl`, and your property is now unreachable.
Converting *from* the declaration round-trips exactly, because the declaration is the
source of truth.

## One key, by hand

```swift
@Key("id") var userID: Int
@Key("$type") var kind: String
@Key("first name") var firstName: String
```

A wire key is an arbitrary string. Spaces, punctuation, unicode — all fine, on every
format. `@Key` overrides the type's `keys:` style for that field.

## Aliases

An API that renamed a field and still serves both:

```swift
@Key("email", or: "email_address", "mail") var email: String
```

The first name is the primary — it is what encoding writes, and what the error messages
say. The rest are tried in order when the primary is absent, and when one matches you get a
warning naming it:

```
warning: e-mail was read from its alias "email_address"
```

So a deprecation is visible in your logs rather than invisible until the alias is removed.

## Reaching into a nested object

When the document nests but your struct should not:

```swift
@Schema(keys: .snakeCase)
struct Profile {
    @Key(path: "user.profile.display_name") var name: String
    @Key(path: "user.profile.avatar") var avatar: String?
    @Key(path: "user.id") var id: Int
}
```

That decodes `{"user": {"id": 7, "profile": {"display_name": "…", "avatar": "…"}}}` into a
flat struct.

It is not a second pass. Two fields under one prefix share one arm of the same dispatch,
so a path costs the same as the nested `@Schema` type you would otherwise have written —
measured at 0.97–1.01× of it.

The errors follow one rule worth knowing: **the path names the segment that failed; the
caret points at the innermost thing that actually existed.**

```
error: user.profile.display_name is required        ← "profile" existed, the key did not
error: user.profile must be an object, found 42     ← "profile" was there but wrong
```

A missing intermediate is *absence*. A wrongly-typed one is an *error*, even when
everything under it is optional — because `{"user": 42}` is not a document where
`user.profile.avatar` is merely missing.

Index segments (`tags[0]`) are refused at expansion. That is a different operation — it
needs the element counted during the array's own decode, and a fourth answer for "the array
was shorter than that".

## Flattening a nested type

When you *do* have a type and just want its fields inline:

```swift
@Schema(keys: .snakeCase)
struct Order {
    var id: Int
    @Inline var address: Address       // Address's fields read from THIS object

    @Schema
    struct Address { var street: String; var city: String }
}
```

`{"id": 1, "street": "…", "city": "…"}`.

The inlined type must be **nested inside** the outer one. That is not a style preference:
a macro cannot see another type's members in any module, so nesting is what makes
collision detection possible at expansion. It also makes unknown-key handling work
*through* the inline, which serde's runtime `flatten` cannot do.

## Keys you did not declare

Four policies, chosen per type:

```swift
@Schema(unknownKeys: .ignore)     // the default, and Codable's behaviour
@Schema(unknownKeys: .warn)       // a warning each, decoding continues
@Schema(unknownKeys: .reject)     // an error each
@Schema(unknownKeys: .collect)    // route them to an @Extras property
```

`.warn` and `.reject` both come with did-you-mean, by edit distance against the keys the
schema knows:

```
warning: unknown key "newsleter"; did you mean "newsletter"?
```

`.ignore` is the default because that is what Codable does and what most APIs need — a
server adding a field should not break your client.

## Collecting the rest

```swift
@Schema(unknownKeys: .collect)
struct Event {
    var name: String
    var timestamp: Int
    @Extras var rest: [String: RawValue]
}
```

Everything undeclared lands in `rest` as `RawValue`, the format-neutral value type. Useful
for a passthrough proxy, an audit log, or a type that must round-trip fields it does not
understand.

`@Extras` implies `.collect`, so you can leave the policy off. The value type must be
`[String: RawValue]` or `[String: JSON.Value]` — anything else is refused at expansion,
because those are the only two that can hold an arbitrary document.

## Keywords as property names

```swift
@Schema
struct Row {
    var `default`: Int
    var `class`: String
}
```

Works. The backticks are Swift's, not the wire's — the key is `default`, and the error
message says `default`.

## Next

- [Rules](/guides/rules/) — validating what you decoded.
- [Formats](/guides/formats/) — the same keys, in YAML, XML and TOML.
