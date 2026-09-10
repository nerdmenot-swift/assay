# ``Assay``

A decoder for Swift that tells you what went wrong.

## Overview

Assay decodes JSON, YAML, XML, TOML and property lists into ordinary Swift structs through
the ``Schema(keys:unknownKeys:coerceScalars:formats:encodes:sources:describes:discriminator:)``
macro — no `Codable`, no `CodingKeys` — and reports every failure with a code, a path and a
caret into the source.

```swift
@Schema
struct Article {
    var title: String
    var link: String
    var readingMinutes: Int
    var tags: [String] = []
}

let article = try Article.parse(json: data)
```

Zero-rule `@Schema` is a first-class mode: Assay is a complete serde with no validation at
all, not an on-ramp to one. When you want rules, `@Validate`, `@Check` and friends are
type-checked at macro expansion, and a validation failure renders exactly like a decoding
failure — the data is wrong, and here is where.

```
deploy.json:3:13: error: replicas must be at least 1
  1 │ {
  2 │ "name": "api",
  3 │ "replicas": 0,
    │             ^
  4 │ "image": "registry.internal/api"
```

The generated decoder is concrete, per-field code emitted into your module. There is no
`KeyedDecodingContainer` to cross, which is where most of a `Codable` decode's time goes;
measured, that is roughly 5–9× Foundation on the published corpus (`Benchmarks/RESULTS.md`).

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Errors>
- <doc:Rules>
- <doc:Formats>

### The macro and its attributes

- ``Schema(keys:unknownKeys:coerceScalars:formats:encodes:sources:describes:discriminator:)``
- ``Key(_:or:)``
- ``Key(path:)``
- ``Validate(_:)``
- ``Check()``
- ``Check(_:)``
- ``AsyncCheck()``
- ``Preprocess(_:)``
- ``Transform(_:)``
- ``Inverse(_:)``
- ``Fallback(_:)``
- ``Ignore()``
- ``Extras()``
- ``Coerce()``
- ``DateFormat(_:)``
- ``Inline()``
- ``OneOrMany()``
- ``Unknown(roundTrips:)``
- ``Wraps(_:_:)``
- ``XML(_:)``
- ``XML(root:)``

### Configuration

- ``SchemaFormats``
- ``KeyNamingStyle``
- ``UnknownKeys``
- ``Discriminator``
- ``XMLPlacement``

### Decoding without a declaration

- ``Assayer``
- ``AssayerBacked``

### Results

- ``Diagnosis``
- ``EncodeDiagnosis``
- ``Validation``

### Protocols the macro conforms your type to

- ``Assayable``
- ``JSONAssayable``
- ``RawDecodable``
- ``SourceDecodable``
- ``ContextualAssayable``
- ``ContextualJSONAssayable``
- ``ContextualRawDecodable``
- ``JSONEncodableSchema``
- ``RawEncodableSchema``
- ``XMLEncodableSchema``
- ``Validatable``
- ``ContextualValidatable``
- ``AsyncCheckAssayable``
- ``ContextualAsyncCheckAssayable``
