---
title: Cheatsheet
description: The whole surface on one page. Skim it, bookmark it, stop reading prose.
---

## Declaring

```swift
@Schema                                          // JSON only
@Schema(keys: .snakeCase)                        // .camelCase .kebabCase .pascalCase .screamingSnakeCase
@Schema(formats: [.json, .yaml, .xml, .toml])    // or .all
@Schema(unknownKeys: .ignore)                    // .warn, .reject, .collect
@Schema(coerceScalars: true)                     // "8080" decodes into an Int
@Schema(encodes: true)                           // adds the writer
@Schema(describes: true)                         // adds jsonSchema(for:)
@Schema(context: AppContext.self)                // decode needs a context value
@Schema(discriminator: "type")                   // a tagged union enum
```

## Presence

```swift
var id: Int                        // required
var nickname: String?              // absent or null → nil
var retries: Int = 3               // absent → 3; a present value is still validated
@Fallback(0) var score: Int        // absent OR invalid → 0, with a warning
@Ignore var cache: Cache?          // not a field

var x = 3                          // ✗ compile error: say the type
let y: Int = 100                   // ✗ compile error: use @Ignore
```

## Keys

```swift
@Key("id") var userID: Int
@Key("email", or: "email_address", "mail") var email: String    // warns which matched
@Key(path: "profile.display_name") var name: String             // reach into nested
@Extras var rest: [String: RawValue]                            // collect unknown keys
@Inline var address: Address                                    // flatten a nested type
```

## Rules

```swift
@Validate(.min(3), .max(24)) var username: String
@Validate(.min(1)) var replicas: Int
@Validate(.email) var email: String
@Validate(.min(8), "pick something longer") var password: String   // custom message
```

| Kind | Rules |
|---|---|
| Bounds | `.min`, `.max`, `.range`, `.positive`, `.negative`, `.nonNegative`, `.multipleOf`, `.finite` |
| Size | `.length`, `.notEmpty`, `.count`, `.unique`, `.each(…)` |
| Strings | `.email`, `.url`, `.uuid`, `.hostname`, `.ascii`, `.regex`, `.prefix`, `.suffix`, `.contains`, `.isTrimmed`, `.isLowercase` |
| Sets | `.oneOf([…])` |
| Dates | `.before("…")`, `.after("…")`, `.between(…)` |
| Combining | `.all(…)` — name a reusable set |

## Checks

```swift
// One field. Return a message or nil.
@Check(\Signup.email)
static func company(_ e: String) -> String? {
    e.hasSuffix("@acme.com") ? nil : "must be a company address"
}

// The whole value. Report wherever you like.
@Check
static func ordered(_ v: Range, _ issues: inout Issues<Range>) {
    if v.hi < v.lo { issues.add("must not be below lo", at: \.hi) }
}

// Async. Makes parse() async; runs only if the sync pass was clean.
@AsyncCheck
static func unique(_ v: Signup, _ issues: inout Issues<Signup>) async { … }
```

The key path needs the root: `\Signup.email`, not `\.email`. An attached macro's argument
has no type to infer it from.

## Transforming

```swift
@Preprocess(.trim, .lowercase) var email: String              // also .uppercase, .collapseWhitespace
@Transform({ (s: String) in URL(string: s) }) var link: URL?  // after rules
@Inverse({ (u: URL) in u.absoluteString }) var link: URL?     // for encoding
@Coerce var port: Int                                          // this field only
```

Order: preprocess → coerce → decode → field rules → cross-field checks → transform → async checks.

## Parsing

```swift
try T.parse(json: bytes)              // [UInt8] — the primary form
try T.parse(json: text)               // String, copied to UTF-8 for you
try T.parse(json: data)               // Data, AssayFoundation — decoded in place, no copy
try T.parse(yaml: text)               // AssayYAML
try T.parse(xml: bytes)               // AssayXML
try T.parse(toml: text)               // AssayTOML
try T.parse(plist: bytes)             // AssayPlist, either flavour
try T.parse(binaryPlist: bytes)       // require binary
try T.parse(xmlPlist: bytes)          // require XML
try T.parseAll(yaml: text)            // → [T], multi-document stream
try T.parse(mmapped: url)             // AssayFoundation, for large files
try T.parse(body: bytes, contentType: ct, accepting: [.json, .yaml])

T.diagnose(json: bytes)               // → Diagnosis<T>, never throws
try T.validate(existingValue)         // rules only, decodes nothing
```

## Reading a failure

```swift
let d = T.diagnose(json: bytes)
d.isValid                 // no errors
d.value                   // T?, nil when there were errors
d.issues                  // [Issue] — code, path, params, span, message
d.warnings                // [Warning]
d.truncatedIssues         // hit Limits.maxIssues
try d.get()               // the value, or throw

d.render(.terminal)       // carets, colour when attached to a TTY
d.render(.plain)          // carets, no colour
d.render(.json)           // machine-readable
d.render(.problemDetails) // RFC 9457, for an HTTP body
```

## Encoding

```swift
@Schema(encodes: true) struct T { … }

try value.encodedJSON()          // EncodedBytes (~Copyable; .withUnsafeBytes/.text()/.toArray())
try value.jsonText()             // String
try value.encodedYAML()          // AssayYAML
try value.encodedXML()           // AssayXML
try value.encodedTOML()          // AssayTOML
value.diagnoseEncodeJSON()       // → EncodeDiagnosis, never throws
```

## Value models, for when you do not know the shape

```swift
let v = try JSON.Value.parse(bytes)       // .int .double .string .bool .array .object
let n = try YAML.parse(text)              // + .resolvedInt, .tag, .anchor
let x = try XML.parse(bytes)              // .root, attributes, mixed content
let t = try TOML.parse(text)              // + .dateTime
v["user"]?["tags"]?[0]?.string
```

## Limits

```swift
Limits(maxIssues: 100, maxDepth: 64, maxBytes: 64 << 20)     // the defaults
try T.parse(json: bytes, limits: Limits(maxDepth: 16))
```

## Unions

```swift
@Schema(discriminator: "type")
enum Event {
    case click(Click)             // {"type": "click", …}
    @Key("pv") case pageView(View)
}

@Schema(discriminator: .untagged)
enum Value { case number(Num); case text(Text) }    // first match wins
```

JSON only, and encoding needs `encodes: true`. [Unions](/guides/unions/) says why.

## Where each format is documented

| | page |
|---|---|
| JSON, and the value model | [JSON](/formats/json/) |
| YAML, anchors, the Norway problem | [YAML](/formats/yaml/) |
| XML, placement, XXE | [XML](/formats/xml/) |
| TOML, tables, date-times | [TOML](/formats/toml/) |
| Property lists, both flavours | [Property lists](/formats/plist/) |
| `Content-Type` negotiation | [HTTP bodies](/formats/http/) |

For a whole job rather than a spelling, see [Recipes](/recipes/).
