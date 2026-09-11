---
title: A JSON API endpoint
description: Read a request body, validate it, and answer with RFC 9457 problem details and the right status code.
---

The whole handler. Nothing is elided.

```swift
@Schema(keys: .snakeCase, formats: [.json, .yaml])
struct CreateDeployment {
    @Validate(.min(1), .max(63)) var name: String
    var image: String
    @Validate(.range(1...100)) var replicas: Int
    @Validate(.url) var healthCheck: String?
}

struct Reply { var status: Int; var body: String }

func handleCreate(body: [UInt8], contentType: String?) -> Reply {
    let d = CreateDeployment.diagnose(body: body, contentType: contentType,
                                      accepting: [.json, .yaml], sourceName: "body")
    guard d.isValid, let deployment = d.value else {
        // 415 when the body was never parsed, 422 when it was parsed and rejected.
        // The code carries that distinction so the handler does not read messages.
        let refused = d.issues.contains { $0.code == .unsupportedMediaType }
        return Reply(status: refused ? 415 : 422, body: d.render(.problemDetails))
    }
    return Reply(status: 201, body: #"{"created":"\#(deployment.name)"}"#)
}
```

Four requests through it.

## The happy path

```text
POST /deployments
Content-Type: application/json

{"name":"api","image":"img:1","replicas":3}
```

```text
201
{"created":"api"}
```

## A body that parsed and then failed

```text
POST /deployments
Content-Type: application/json

{"name":"","image":"img:1","replicas":0,"health_check":"not a url"}
```

```text
422
{"type":"about:blank","title":"Validation failed","status":422,"errors":[{"path":"name","code":"too_small","message":"must be at least 1 character","params":{"minimum":1,"unit":"characters"}},{"path":"replicas","code":"not_in_range","message":"must be between 1 and 100","params":{"maximum":100,"minimum":1}},{"path":"health_check","code":"invalid_url","message":"must be a valid URL"}]}
```

Three problems, one response. The client does not have to fix one, resubmit, and discover
the next.

Each error carries a `code` and its `params`, so a client can render its own wording
without matching on English. `message` is there for the case where it will not.

## A body that was never parsed

```text
POST /deployments
Content-Type: application/xml

{"name":"api","image":"img:1","replicas":3}
```

```text
415
{"type":"about:blank","title":"Unsupported media type","status":415,"errors":[{"path":"","code":"unsupported_media_type","message":"media type application/xml is not in the accepted list","params":{"received":"application/xml"}}]}
```

The XML never entered a parser. `accepting:` is checked before anything reads the bytes,
which is the point of it having no default: an [XML bomb](/reference/limits-and-security/)
sent to a JSON endpoint costs you one comparison.

Notice that the `status` inside the body matches the status you send. RFC 9457 asks for
that, and the renderer derives it from the issues rather than assuming everything is a
validation failure. A malformed body reports 400, a body over your byte limit 413.

## The same handler, a YAML body

```text
POST /deployments
Content-Type: application/yaml

name: api
image: img:1
replicas: 3
```

```text
201
{"created":"api"}
```

Because `accepting:` listed it and the schema opted into `.yaml`. One handler, one struct,
one set of rules. There is no second code path.

## Wiring it to a framework

`Reply` is a stand-in for whatever yours calls a response. The two things to carry across
are the status and `application/problem+json` as the content type:

```swift
// Vapor, roughly
app.post("deployments") { req async throws -> Response in
    let reply = handleCreate(body: Array(req.body.data?.readableBytesView ?? []),
                             contentType: req.headers.first(name: .contentType))
    var headers = HTTPHeaders()
    headers.contentType = reply.status == 201
        ? .json : HTTPMediaType(type: "application", subType: "problem+json")
    return Response(status: .init(statusCode: reply.status), headers: headers,
                    body: .init(string: reply.body))
}
```

## Next

- [HTTP bodies](/formats/http/) — negotiation, suffixes, charsets, custom formats.
- [Errors](/guides/errors/) — the four renderers and what each is for.
- [A file you do not trust](/recipes/untrusted-input/) — limits on top of this.
