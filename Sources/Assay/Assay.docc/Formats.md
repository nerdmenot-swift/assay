# Formats

One struct, several formats — the ones the struct asks for.

## Overview

Formats are opt-in per type, because generated code is not free and a JSON-only type should
not pay for a YAML decode body it never uses.

```swift
@Schema(formats: [.json, .yaml, .toml])
struct Config {
    var name: String
    var replicas: Int
}

try Config.parse(json: bytes)          // Assay
try Config.parse(yaml: text)           // AssayYAML
try Config.parse(toml: text)           // AssayTOML
```

Calling `parse(yaml:)` on a type that did not opt into `.yaml` is a **compile** error: the
conformance that entry point requires is simply absent. ``SchemaFormats/all`` is JSON, YAML,
XML and TOML.

## How the non-JSON formats decode

JSON decodes directly from bytes into the struct — that is the fast path. Every other
format parses to its own value model first and decodes the struct from a format-neutral
projection, `RawValue`:

| format | product | value model | notes |
|---|---|---|---|
| YAML 1.2 | `AssayYAML` | `YAML.Node` | scalars keep their text; the Norway problem is the schema's decision |
| XML 1.0 | `AssayXML` | `XML.Node` | every leaf is text — use `coerceScalars: true`; XXE refused by construction |
| TOML 1.0.0 | `AssayTOML` | `TOML.Node` | typed on the wire; 710/710 on the official toml-test suite |
| plist | `AssayPlist` | `RawValue` | binary and XML behind one entry point |

Each model is full-fidelity and separately documented; the projection is deliberately
lossy in stated ways (a YAML tag, an XML namespace, a TOML date-time's kind) so a caller
who needs fidelity parses to the model directly.

## Content negotiation

For a server, the format is a value:

```swift
let body = try Config.parse(body: bytes, contentType: request.contentType,
                            accepting: [.json, .yaml])
```

`accepting:` is required and has no default — a body offered as XML to a type that only
accepts JSON never enters the XML parser, which is the billion-laughs case handled by not
parsing at all. `unsupported_media_type` is its own code so a server can map it to 415.

## Encoding

`@Schema(encodes: true)` adds the reverse direction — `encodedJSON()`, `encodedYAML()`,
`encodedXML()`, `encodedTOML()` and their `diagnoseEncode…` and `…Text()` forms. Round trip
is a stated law with a closed exception list, and every document Assay writes is read back
by an independent parser in CI.

## Large files

`AssayFoundation` adds `parse(mmapped:)`, which maps the file and decodes in place — a
fraction of the memory of reading into `Data` first.
