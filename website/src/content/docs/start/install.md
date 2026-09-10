---
title: Install
description: One line in Package.swift, and which of the six products you actually need.
---

Add the package:

```swift
// Package.swift
.package(url: "https://github.com/nerdmenot-swift/assay.git", from: "0.1.0")
```

And depend on the bit you want:

```swift
.target(name: "App", dependencies: [
    .product(name: "Assay", package: "assay"),
])
```

That is it for most people. `Assay` is the macro plus the JSON decoder, and JSON is what
most apps read.

## The other products

Formats are separate products so that a JSON-only app does not link a YAML parser it never
calls. Add the ones you need, skip the rest.

| Product | What it gives you | Add it when |
|---|---|---|
| `Assay` | `@Schema`, `parse(json:)`, all the rules and errors | always |
| `AssayYAML` | `parse(yaml:)`, `YAML.Node` | you read YAML |
| `AssayXML` | `parse(xml:)`, `XML.Document` | you read XML |
| `AssayTOML` | `parse(toml:)`, `TOML.Node` | you read TOML |
| `AssayPlist` | `parse(plist:)`, binary and XML | you read property lists |
| `AssayFoundation` | `Data`/`URL` conveniences, `parse(mmapped:)`, `Date`/`UUID` in column stores | you want any of those |
| `AssayCore` | `Issue`, `Rule`, `RawValue`, the renderers — no macro | you are writing a library that *consumes* Assay's values |

`Assay` re-exports `AssayCore`, so you never need both.

A type that reads two formats depends on both products and says so in the attribute:

```swift
import Assay
import AssayYAML

@Schema(formats: [.json, .yaml])
struct Config { var name: String; var replicas: Int }
```

Calling `parse(yaml:)` on a type that did not list `.yaml` is a **compile** error, not a
runtime one. The conformance that entry point needs simply is not there.

## What it needs

- **Swift 6.2 or newer.** The package uses `swift-tools-version: 6.2`.
- **macOS 11 / iOS 14 / tvOS 14 / watchOS 7 / visionOS 1**, or Linux, or Windows. The
  parsers are hand-written Swift with no C to vendor, which is why the platform list is
  that long.
- **No dependencies** at runtime. `swift-syntax` is a build-time dependency of the macro
  and does not ship in your binary.

## The one thing that surprises people

The first build after adding Assay is slow, because SwiftPM builds `swift-syntax` to run
the macro. Subsequent builds do not.

Swift 6.2 and later ship a prebuilt `swift-syntax` that skips this entirely — but only when
the version Assay resolves matches the one your toolchain ships. Assay pins the 603 line
for exactly that reason. If you see a long `swift-syntax` build on every clean checkout,
check that nothing else in your dependency graph has pulled a different major line.

## Next

[Your first schema](/start/first-schema/) — five minutes, one struct, one error.
