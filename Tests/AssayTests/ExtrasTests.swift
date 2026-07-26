import Testing
import Assay
import AssayCore

// docs/EXPERIENCE.md §4 — the four unknown-key policies, and @Extras as the sink.
// docs/VALUE-MODELS.md open question 2 — @Extras dispatching on a type the macro has
// never heard of, via a per-format protocol.

@Schema(unknownKeys: .collect)
struct Collected {
    var id: String
    @Extras var rest: [String: RawValue]
}

/// The same shape, but keeping full JSON fidelity instead of portability. The only
/// difference is the declared value type — that is the whole trade, written on the struct.
@Schema(unknownKeys: .collect)
struct CollectedFidelity {
    var id: String
    @Extras var rest: [String: JSON.Value]
}

@Schema(unknownKeys: .warn)
struct Warned {
    var timeout: Int
    var retries: Int
}

@Schema(unknownKeys: .reject)
struct Rejected {
    var timeout: Int
}

@Schema
struct IgnoredByDefault {
    var timeout: Int
}

@Suite("Unknown keys and @Extras")
struct ExtrasTests {

    @Test("collect routes unknown keys into the @Extras property")
    func collect() throws {
        let c = try Collected.parse(json: #"""
        {"id":"x","count":3,"ratio":1.5,"on":true,"none":null,"tags":["a","b"],
         "nested":{"k":"v"}}
        """#)
        #expect(c.id == "x")
        #expect(c.rest.count == 6)
        #expect(c.rest["count"] == .int(3))
        #expect(c.rest["ratio"] == .double(1.5))
        #expect(c.rest["on"] == .bool(true))
        #expect(c.rest["none"] == .null)
        #expect(c.rest["tags"] == .sequence([.string("a"), .string("b")]))
        #expect(c.rest["nested"]?["k"] == .string("v"))
        // Declared keys never land in extras.
        #expect(c.rest["id"] == nil)
    }

    @Test("nothing unknown means an empty extras dictionary, not a missing field")
    func collectNothing() throws {
        let c = try Collected.parse(json: #"{"id":"x"}"#)
        #expect(c.id == "x")
        #expect(c.rest.isEmpty)
    }

    @Test("the declared value type picks fidelity vs portability")
    func fidelityVariant() throws {
        // RawValue and JSON.Value are both legal sinks; the struct chooses.
        let f = try CollectedFidelity.parse(json: #"{"id":"x","n":[1,2.5]}"#)
        #expect(f.rest["n"]?[0]?.int == 1)
        #expect(f.rest["n"]?[1]?.double == 2.5)
    }

    @Test("warn produces warnings, not issues, and decoding proceeds")
    func warn() {
        let d = Warned.diagnose(json: #"{"timeout":5,"retries":2,"tiemout":9,"zzz":1}"#)
        #expect(d.isValid)                       // warnings do not invalidate
        #expect(d.value?.timeout == 5)
        #expect(d.warnings.count == 2)
        #expect(d.warnings.allSatisfy { $0.code == .unknownKey })
    }

    @Test("did-you-mean fires on a near miss and stays quiet on a far one")
    func didYouMean() {
        let d = Warned.diagnose(json: #"{"timeout":5,"retries":2,"tiemout":9,"zzz":1}"#)

        let typo = d.warnings.first { $0.params["received"] == .string("tiemout") }
        #expect(typo?.params["didYouMean"] == .string("timeout"))

        // "zzz" is not close to anything. A wrong suggestion is worse than none.
        let far = d.warnings.first { $0.params["received"] == .string("zzz") }
        #expect(far?.params["didYouMean"] == nil)
    }

    @Test("reject turns unknown keys into issues")
    func reject() {
        let d = Rejected.diagnose(json: #"{"timeout":5,"nope":1}"#)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .unknownKey })
        #expect(d.issues.first { $0.code == .unknownKey }?.received == "nope")
    }

    @Test("ignore is the default and stays silent")
    func ignoreDefault() throws {
        let v = try IgnoredByDefault.parse(json: #"{"timeout":5,"a":1,"b":{"c":[1,2]}}"#)
        #expect(v.timeout == 5)
        let d = IgnoredByDefault.diagnose(json: #"{"timeout":5,"a":1}"#)
        #expect(d.warnings.isEmpty)
        #expect(d.issues.isEmpty)
    }

    @Test("collected values keep their source spans for carets")
    func spans() {
        let d = Rejected.diagnose(json: #"{"timeout":5,"nope":1}"#)
        let issue = d.issues.first { $0.code == .unknownKey }
        #expect(issue?.location != nil)
        // The span points at the key itself, not the whole object.
        #expect(issue?.location?.len == 4)       // "nope"
    }

    @Test("deeply nested unknown values are collected whole, not flattened")
    func nestedCollection() throws {
        let c = try Collected.parse(json: #"""
        {"id":"x","deep":{"a":{"b":{"c":[1,{"d":true}]}}}}
        """#)
        #expect(c.rest["deep"]?["a"]?["b"]?["c"]?[1]?["d"] == .bool(true))
    }

    @Test("edit distance is bounded, so unrelated keys suggest nothing")
    func editDistanceBounds() {
        // Short keys allow 1 edit, longer ones 2. Verified through the public behaviour
        // rather than the internal helper.
        let d = Warned.diagnose(json: #"{"timeout":1,"retries":1,"retrie":9,"qqqqqqqq":1}"#)
        let near = d.warnings.first { $0.params["received"] == .string("retrie") }
        #expect(near?.params["didYouMean"] == .string("retries"))
        let far = d.warnings.first { $0.params["received"] == .string("qqqqqqqq") }
        #expect(far?.params["didYouMean"] == nil)
    }
}
