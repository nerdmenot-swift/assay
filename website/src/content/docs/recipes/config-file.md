---
title: An application config file
description: Load TOML or YAML at boot, apply defaults, catch typos, and print failures that read like compiler errors.
---

A config error at start-up should read like a compiler error, because that is exactly what
it is: a static mistake in a file, found before anything runs.

```swift
@Schema(keys: .snakeCase, unknownKeys: .warn, formats: .all)
struct AppConfig {
    @Validate(.min(1)) var serviceName: String
    var port: Int = 8080
    var logLevel: String = "info"
    @Validate(.range(1...64)) var workers: Int = 4
    @Validate(.url) var upstream: String?
}

func loadConfig(_ text: String, named name: String) -> (AppConfig?, String) {
    let d = AppConfig.diagnose(toml: text, sourceName: name)
    // `.plain` renders warnings alongside errors already. Looping over `d.warnings` and
    // appending them is the obvious next line and it prints every warning twice.
    return (d.isValid ? d.value : nil, d.render(.plain))
}
```

Three decisions in that declaration, and they are the whole recipe.

**Defaults live on the property.** `port` is `8080` when the file does not mention it.
There is no separate defaults table to keep in step, and no optional to unwrap at every use
site. See [presence](/guides/presence/) for the five states and when each applies.

**`unknownKeys: .warn` rather than the default `.ignore`.** For an API response, ignoring
unknown keys is right — the server adds fields without asking you. For a config file it is
the opposite: an unknown key is almost always a typo, and silence means someone's setting
does nothing for a week.

**`formats: .all`, so the same struct reads YAML and JSON too.** People have opinions about
config formats. This costs one attribute.

## A file that is fine

```toml
service_name = "checkout"
port = 9000
upstream = "https://inventory.internal"
```

```text
AppConfig(serviceName: "checkout", port: 9000, logLevel: "info", workers: 4, upstream: Optional("https://inventory.internal"))
```

`port` came from the file, `log_level` and `workers` from the declaration.

## A file that is not

```toml
service_name = ""
prot = 9000
workers = 900
upstream = "inventory"
```

```text
app.toml:1:16: error: service_name must be at least 1 character
  1 │ service_name = ""
    │                ^^
  2 │ prot = 9000

app.toml:3:11: error: workers must be between 1 and 64
  1 │ service_name = ""
  2 │ prot = 9000
  3 │ workers = 900
    │           ^^^
  4 │ upstream = "inventory"

app.toml:4:12: error: upstream must be a valid URL
  2 │ prot = 9000
  3 │ workers = 900
  4 │ upstream = "inventory"
    │            ^^^^^^^^^^^

app.toml:2:8: warning: unknown key "prot"; did you mean "port"?
  1 │ service_name = ""
  2 │ prot = 9000
    │        ^^^^
  3 │ workers = 900

3 errors, 1 warning
```

Every problem at once, each pointing at the line and the bytes.

The last one is the reason for `.warn`. `prot` is not a key this schema knows, and rather
than being dropped it is named, with a suggestion worked out by edit distance. That is
[did-you-mean](/guides/keys/#keys-you-did-not-declare), and it is the difference between a
five-second fix and an afternoon.

## Printing it

`.plain` is the render above: no colour, suitable for a log or a file. `.terminal` is the
same thing with colour, and it turns colour off by itself when output is not a terminal, so
you do not need to check.

```swift
let (config, report) = loadConfig(try String(contentsOf: url, encoding: .utf8),
                                  named: url.lastPathComponent)
guard let config else {
    FileHandle.standardError.write(Data(report.utf8))
    exit(78)                       // EX_CONFIG
}
```

Printing the report for a *valid* file is worth doing too. It is empty when there is
nothing to say, and it carries the warnings when there is.

## Environment overrides

Assay does not read the environment, and should not: the merge order between file, flags
and environment is your policy, not a decoder's. Decode the file, then overlay:

```swift
var config = try AppConfig.parse(toml: text)
if let p = ProcessInfo.processInfo.environment["PORT"], let n = Int(p) { config.port = n }
```

If you want the overlay validated too, `try AppConfig.validate(config)` runs the same rules
against the finished value without decoding anything. It is [a different
function](/guides/rules/#validating-something-you-already-have) from the parse verbs, and
the law it holds is that a value that came out of `parse` never fails it.

## Next

- [TOML](/formats/toml/) and [YAML](/formats/yaml/) — the formats, in full.
- [Presence](/guides/presence/) — defaults, optionals, and the two spellings that do not compile.
- [Keys](/guides/keys/) — naming conventions, aliases, and unknown-key policy.
