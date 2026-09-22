---
title: Attributes
description: Every attribute and every `@Schema` option, in one table each.
---

## `@Schema` options

```swift
@Schema(keys:unknownKeys:coerceScalars:formats:encodes:describes:discriminator:)
@Schema(context:…)              // the contextual overload
```

| Option | Type | Default | What it does |
|---|---|---|---|
| `keys:` | `KeyNamingStyle` | `.camelCase` | Converts every property name to a wire key at compile time. `.camelCase`, `.snakeCase`, `.kebabCase`, `.pascalCase`, `.screamingSnakeCase` |
| `unknownKeys:` | `UnknownKeys` | `.ignore` | `.ignore`, `.warn`, `.reject`, `.collect`. `.warn` and `.reject` include did-you-mean |
| `coerceScalars:` | `Bool` | `false` | `"8080"` decodes into an `Int`. Required for XML; usual for CSV |
| `formats:` | `SchemaFormats` | `.json` | `.json`, `.yaml`, `.xml`, `.toml`, `.all`, or `[]`. Each adds a decode body |
| `encodes:` | `Bool` | `false` | Adds the writer for every format in `formats:` |
| `describes:` | `Bool` | `false` | Adds `jsonSchema(for:)` |
| `discriminator:` | `Discriminator?` | `nil` | On an enum: a tag key, or `.untagged` |
| `context:` | `Any.Type` | — | Decoding takes a context value; a different overload |

`formats: []` with `encodes: true` or any validation is a real configuration — a type
decoded by something else that still wants rules. `formats: []` with neither is refused,
with a message naming the fix.

## Field attributes

| Attribute | Applies to | What it does |
|---|---|---|
| `@Key("name")` | a property | The wire key for this field |
| `@Key("name", or: "alias", …)` | a property | Aliases, tried in order; warns which matched |
| `@Key(path: "a.b.c")` | a property | Reaches into nested objects. Index segments refused |
| `@Ignore` | a property | Not a field. Needs a default or to be optional |
| `@Extras` | `[String: RawValue]` | Collects undeclared keys. Implies `unknownKeys: .collect` |
| `@Inline` | a nested `@Schema` type | Its fields read from this object. The type must be nested inside |
| `@Fallback(value)` | a property | Absent **or invalid** → `value`, with a warning; not re-validated |
| `@Validate(rules…, "message")` | a property | Rules, checked against the field's type at expansion |
| `@Preprocess(ops…)` | a `String` field | `.trim`, `.lowercase`, `.uppercase`, `.collapseWhitespace`. Runs before rules |
| `@Transform({ … })` | a property | Decodes the closure's parameter type, keeps the field's type. Runs last |
| `@Inverse({ … })` | a transformed property | The reverse, for encoding. Required there |
| `@Coerce` | a property | `coerceScalars` for this field only |
| `@DateFormat(formats…)` | a `Date` field | `.iso8601`, `.unixSeconds`, `.unixMillis`, `.rfc9110`, `.pattern("…")`. Several = a candidate chain |
| `@OneOrMany` | an array field | Accepts a bare scalar as a one-element array. JSON path |
| `@XML(.attribute/.text/.wrapped)` | a property | XML placement. Default is a child element |
| `@Wraps(T.self, rules…)` | a struct | Makes the struct a constrained scalar. `T` is `String`, `Int64`, `Double` or `Bool` |
| `@Unknown` | an enum case with a `String` payload | Captures unrecognised raw values. `roundTrips: true` to write them back |

## Type-level attributes

| Attribute | Applies to | What it does |
|---|---|---|
| `@XML(root: "name")` | a type | Checks the root element's name. Unannotated does not check it |
| `@Check` | a static func | `(Self, inout Issues<Self>)` — cross-field |
| `@Check(\T.field)` | a static func | `(FieldType) -> String?` — one field |
| `@AsyncCheck` | a static func | The async form. Makes `parse` async for the type |

## Entry points

| Call | Needs | Returns |
|---|---|---|
| `T.parse(json:)` | `Assay` | `T`, throws `AssayError`. Takes `[UInt8]` or `String` |
| `T.parse(json: Data)` | `AssayFoundation` | `T`. Decoded in place — no copy of the input |
| `T.parse(yaml:)` / `parseAll(yaml:)` | `AssayYAML` + `formats: [.yaml]` | `T` / `[T]` |
| `T.parse(xml:)` | `AssayXML` + `formats: [.xml]` | `T` |
| `T.parse(toml:)` | `AssayTOML` + `formats: [.toml]` | `T` |
| `T.parse(plist:)` / `binaryPlist:` / `xmlPlist:` | `AssayPlist` | `T` |
| `T.parse(mmapped:)` | `AssayFoundation` | `T` |
| `T.parse(body:contentType:accepting:)` | — | `T`. `accepting:` has no default |
| `T.diagnose(…)` | as above | `Diagnosis<T>`, never throws |
| `T.validate(_ value:)` | any rules | throws; decodes nothing |
| `T.diagnose(_ value:)` | any rules | `Diagnosis<T>` |
| `T.jsonSchema(for:)` | `describes: true` | a JSON Schema descriptor |
| `value.encodedJSON()` / `jsonText()` | `encodes: true` | `EncodedBytes` / `String`, throws |
| `value.diagnoseEncodeJSON()` | `encodes: true` | `EncodeDiagnosis` |

Every `parse`/`diagnose` takes `limits:` and `sourceName:`.

## Reading a result

```swift
Diagnosis<T>      .value  .issues  .warnings  .isValid  .truncatedIssues
                  .get()  .render(_:)  .source  .sourceName
EncodeDiagnosis   .bytes  .issues  .warnings  .isValid
AssayError        .issues .render(_:)   — description renders with carets
Issue             .code   .path  .params  .received  .location  .message
```

## Refused, on purpose

`Set<T>`, `T??`, `[T?]`, tuples, function types, `Any`, `T!`, `Character`, `Data`, `URL`,
`Decimal`, and generic types. Each is a build error naming the alternative —
[Advanced](/guides/advanced/#types-the-macro-refuses) has the table with reasons.

Also refused: `var x = 3` without a type, `let y: Int = 3`, `@Key("")`, a `@Check` in an
extension, `@Ignore` alongside any acting attribute,
and a union with a non-JSON format.
