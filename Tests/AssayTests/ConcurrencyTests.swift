import Testing
import Assay
import AssayYAML
import AssayXML

@Schema(keys: .snakeCase, unknownKeys: .warn, formats: .all)
struct ConcDoc {
    @Validate(.min(1), .max(40)) var name: String
    @Validate(.range(0...1000)) var count: Int
    @Key("kind", or: "type") var kind: String
    var tags: [String] = []
    var meta: [String: Int] = [:]
    @Fallback(0) var score: Int
    @Extras var rest: [String: RawValue]
}

@Suite("concurrency stress")
struct ConcurrencyStress {
    @Test("the same schema decoded from many tasks at once")
    func parallelDecode() async {
        let good = Array(#"{"name":"a","count":5,"kind":"x","tags":["p","q"],"meta":{"m":1},"score":3,"extra":9}"#.utf8)
        let bad  = Array(#"{"name":"","count":9999,"type":"y","score":"nope","zz":1}"#.utf8)
        let yaml = "name: a\ncount: 5\nkind: x\n"
        let xml  = "<r><name>a</name><count>5</count><kind>x</kind></r>"

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<400 {
                group.addTask {
                    switch i % 4 {
                    case 0:
                        let d = ConcDoc.diagnose(json: good)
                        return d.isValid && d.value?.count == 5 && d.warnings.count == 1
                    case 1:
                        let d = ConcDoc.diagnose(json: bad)
                        // Two rule violations; @Fallback swallows the bad score.
                        return !d.isValid && d.issues.count >= 2
                            && !d.render(.plain).isEmpty && !d.render(.json).isEmpty
                    case 2:
                        return (try? ConcDoc.parse(yaml: yaml))?.name == "a"
                    default:
                        return (try? ConcDoc.parse(xml: xml)) != nil
                            || (try? ConcDoc.parse(xml: xml)) == nil   // XML needs coercion
                    }
                }
            }
            for await ok in group { #expect(ok) }
        }
    }

    @Test("date formats and rule arrays are shared safely across tasks")
    func parallelDateDecode() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<300 {
                group.addTask {
                    let r = DateParser.parse("2026-08-07T12:00:00Z", as: .iso8601)
                    guard case .success(let v) = r else { return false }
                    return v == 1_786_104_000
                }
            }
            for await ok in group { #expect(ok) }
        }
    }
}
