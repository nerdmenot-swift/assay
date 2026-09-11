---
title: Names
description: Key conventions, renaming one field, aliases, reaching into nested objects, collecting the rest, and rejecting typos.
---

## A convention for the whole type

```swift
@Schema(keys: .screamingSnakeCase)
struct Env: Equatable { var databaseUrl: String; var maxRetries: Int }
```

```json
{"DATABASE_URL": "postgres://x", "MAX_RETRIES": 3}
```

```text
Env(databaseUrl: "postgres://x", maxRetries: 3)
```

`.camelCase` (the default), `.snakeCase`, `.kebabCase`, `.pascalCase` and
`.screamingSnakeCase`. The conversion happens **at compile time** from the declared
identifier, so `avatarURL` round-trips exactly — a runtime converter turns it into
`avatarUrl` and cannot get back.

## One key at a time

```swift
@Schema(keys: .snakeCase)
struct Names: Equatable {
    @Key("id") var identifier: Int
    @Key("email", or: "email_address", "mail") var email: String
    @Key(path: "profile.display_name") var displayName: String
    var `default`: Bool = false               // a keyword is fine, backticks and all
    @Extras var rest: [String: RawValue]
}
```

```json
{"id": 1, "mail": "jo@example.com", "profile": {"display_name": "Jo"},
 "default": true, "extra_one": 1, "extra_two": "two"}
```

```text
Names(identifier: 1, email: "jo@example.com", displayName: "Jo", default: true, rest: ["extra_two": RawValue.string("two"), "extra_one": RawValue.int(1)])

warnings: alias_matched
```

Four things at once.

**`@Key("id")`** renames one field and leaves the type convention alone.

**Aliases** are tried in order, and the one that matched is reported as a warning. That is
the point: a compatibility shim you cannot see is a compatibility shim you never delete.

**`@Key(path:)`** walks into nested objects without declaring a type for the wrapper. An
index segment (`tags[0]`) is refused — that is a different operation, with a fourth answer
for "the array was shorter than that".

**`@Extras`** collects everything undeclared as `RawValue` instead of dropping it, and
implies `unknownKeys: .collect`.

## Typos, caught

```swift
@Schema(keys: .snakeCase, unknownKeys: .reject)
struct ApiConfig: Equatable { var apiKey: String; var timeoutSeconds: Int }
```

```json
{"api_key": "sk-1", "timeout_secs": 30}
```

```text
cfg.json:1:22: error: unknown key "timeout_secs"
  1 │ {"api_key": "sk-1", "timeout_secs": 30}
    │                      ^^^^^^^^^^^^

cfg.json: error: timeout_seconds is required

2 errors
```

Four policies: `.ignore` (the default, right for an API that adds fields), `.warn`,
`.reject`, `.collect`. The middle two run a Damerau edit-distance check against the keys
the schema knows, so a typo gets named rather than merely counted.

For a config file, `.warn` or `.reject`. For someone else's API, `.ignore`.

## Next

- [Rules](/recipes/rules/) — validating what arrived.
- [Keys, explained](/guides/keys/) — including why conversion happens at compile time.
