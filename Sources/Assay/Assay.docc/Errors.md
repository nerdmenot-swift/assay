# Errors

Every failure is a code with parameters, a path, and a place in the source.

## Overview

Assay collects *all* the issues in a document rather than throwing on the first, and it
never stores a rendered string: an `Issue` is a code plus structured parameters, and the
English sentence is derived on demand. That is what lets a downstream consumer branch on
`issue.code`, render its own words, or hand the whole list to a form.

```swift
let d = Deployment.diagnose(json: bytes)
for issue in d.issues {
    issue.code          // .tooSmall
    issue.path          // [.key("replicas")]
    issue.params        // ["minimum": .int(1)]
    issue.location      // SourceSpan(lo: 27, len: 1)
    issue.message       // "must be at least 1"
}
```

## Codes

The codes a decoder reports are a closed set — `missing`, `typeMismatch`, `numberOverflow`,
`unknownKey`, `duplicateKey`, `depthExceeded`, `malformedDocument`, and so on — and every
rule and every format parser has its own, all named as statics on `IssueCode` and each with a
stable string (`too_small`, `yaml_undefined_alias`, `toml_redefined_table`). Branch on the
code; the wording is not part of the API contract.

## Rendering

``Diagnosis`` and `AssayError` render four ways:

```swift
print(d.render(.terminal))        // carets, colour when attached to a TTY
print(d.render(.plain))           // the same, no colour
d.render(.json)                   // [{"code":"too_small","path":"replicas",...}]
d.render(.problemDetails)         // RFC 9457, ready for an HTTP 4xx body
```

The terminal render is a golden test, not a mock-up:

```
deploy.json:3:13: error: replicas must be at least 1
  1 │ {
  2 │ "name": "api",
  3 │ "replicas": 0,
    │             ^
  4 │ "image": "registry.internal/api"

1 error
```

Carets work on every format. YAML, XML and TOML documents carry a `SourceSpan` on every
mapping member, so a schema issue found after the parse still points at the bytes.

## Warnings

A warning is an issue with softer consequences: the value decoded, but something is worth
knowing. `@Key("email", or: "email_address")` warns which alias matched;
`@Fallback(0)` warns when it applied; `unknownKeys: .warn` warns about keys the schema did
not declare, with a did-you-mean.

```swift
d.warnings.first?.message   // "unknown key \"replcas\" — did you mean \"replicas\"?"
```

## Limits

`Limits(maxIssues:maxDepth:maxBytes:)` bounds every parse. When issue collection is capped,
`d.truncatedIssues` says so rather than pretending the list is complete.
