# Getting Started

Add the package, mark a struct, call `parse`.

## Add the package

```swift
// Package.swift
.package(url: "https://github.com/nerdmenot-swift/assay.git", from: "0.1.0")

.target(name: "App", dependencies: [
    .product(name: "Assay", package: "assay"),            // core + JSON
    .product(name: "AssayCore", package: "assay"),        // optional: values and rules, no macro
    .product(name: "AssayYAML", package: "assay"),        // optional
    .product(name: "AssayXML", package: "assay"),         // optional
    .product(name: "AssayTOML", package: "assay"),        // optional
    .product(name: "AssayPlist", package: "assay"),       // optional
    .product(name: "AssayFoundation", package: "assay"),  // Data / URL / mmap conveniences
])
```

Seven products, so a JSON-only app never links a YAML parser. The core takes bytes, not
`Data`, and imports no Foundation.

## Mark a type

```swift
import Assay

@Schema
struct User {
    var id: Int
    var name: String
    var email: String?
    var roles: [String] = []
}
```

Every stored property is a field. The five presence states are spelled by the declaration
itself:

| declaration | when the key is absent | when the value is invalid |
|---|---|---|
| `var name: String` | error | error |
| `var email: String?` | `nil` | error |
| `var roles: [String] = []` | the default | error |
| `@Fallback(0) var retries: Int` | `0` | `0`, with a warning |
| `@Ignore var cache: Cache?` | never read | never read |

## The two verbs

```swift
let user = try User.parse(json: bytes)        // throws AssayError with every issue

let d = User.diagnose(json: bytes)            // never throws
if d.isValid { use(d.value!) }
for issue in d.issues { print(issue) }        // "email must be an email address"
```

`parse` is for code that wants a value or an error. `diagnose` is for code that wants to
show someone what happened — a form, a config loader, a CLI — and it returns
``Diagnosis``, which carries the value (when there were no errors), every issue, every
warning, and the source bytes so a renderer can draw carets.

## Keys

```swift
@Schema(keys: .snakeCase)
struct Profile {
    var displayName: String                    // reads "display_name"
    @Key("id") var userID: Int                 // reads "id"
    @Key("email", or: "email_address") var email: String   // warns which alias matched
    @Key(path: "address.city") var city: String            // reaches into a nested object
}
```

Key conversion happens at compile time from the declared identifier, so `avatarURL`
round-trips exactly — the runtime `.convertFromSnakeCase` strategy cannot do that.

## Nesting

A `@Schema` type is a field type. Arrays, optionals, dictionaries with `String` keys, and
`Date` (with ``DateFormat(_:)``) all work on every path.

```swift
@Schema struct Order {
    var id: String
    var lines: [Line]
    var shippedAt: Date?
    var metadata: [String: String] = [:]
}
```

## What next

- <doc:Errors> — codes, paths, carets and the four renderers.
- <doc:Rules> — rules, checks, and what "type-checked at expansion" means.
- <doc:Formats> — the same struct from YAML, XML, TOML and plists.
