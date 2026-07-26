import Testing
import Assay
import AssayCore
import AssayYAML
import AssayXML

// EXPERIENCE.md §12: "One struct, many formats. Same struct. Same rules. Same errors."
// This is the test that promise either passes or fails.

@Schema(keys: .snakeCase, formats: .all)
struct DatabaseConfig {
    var url: String
    var poolSize: Int
    var sslRequired: Bool
}

@Schema(keys: .snakeCase, formats: [.json, .yaml])
struct AppConfig {
    var serviceName: String
    var port: Int
    var workers: Int = 4
    var database: DatabaseConfig
    var features: [String] = []
}

/// XML has no numbers and no booleans — every leaf is text — so a schema decoding from it
/// must opt into coercion. Written on the struct, per EXPERIENCE.md §7.
@Schema(keys: .snakeCase, coerceScalars: true, formats: [.xml])
struct XMLDatabase {
    var url: String
    var poolSize: Int
    var sslRequired: Bool
}

@Schema(keys: .snakeCase, coerceScalars: true, formats: [.xml])
struct XMLConfig {
    var serviceName: String
    var port: Int
    var database: XMLDatabase
}

@Schema(keys: .snakeCase)
struct PerFieldCoerce {
    @Coerce var port: Int
    var host: String
}

@Suite("One struct, many formats")
struct MultiFormatTests {

    @Test("the same struct decodes from JSON and YAML to the same value")
    func jsonAndYaml() throws {
        let fromJSON = try AppConfig.parse(json: #"""
        {"service_name":"api","port":8080,"workers":8,
         "database":{"url":"postgres://x","pool_size":10,"ssl_required":true},
         "features":["metrics","tracing"]}
        """#)

        let fromYAML = try AppConfig.parse(yaml: """
        service_name: api
        port: 8080
        workers: 8
        database:
          url: postgres://x
          pool_size: 10
          ssl_required: true
        features:
          - metrics
          - tracing
        """)

        #expect(fromJSON.serviceName == fromYAML.serviceName)
        #expect(fromJSON.port == fromYAML.port)
        #expect(fromJSON.workers == fromYAML.workers)
        #expect(fromJSON.database.url == fromYAML.database.url)
        #expect(fromJSON.database.poolSize == fromYAML.database.poolSize)
        #expect(fromJSON.database.sslRequired == fromYAML.database.sslRequired)
        #expect(fromJSON.features == fromYAML.features)
    }

    @Test("defaults still apply through the YAML path")
    func yamlDefaults() throws {
        let c = try AppConfig.parse(yaml: """
        service_name: api
        port: 80
        database:
          url: u
          pool_size: 1
          ssl_required: false
        """)
        #expect(c.workers == 4)          // default
        #expect(c.features == [])        // default
    }

    @Test("missing required fields report the same code and path from YAML")
    func yamlMissing() {
        let d = AppConfig.diagnose(yaml: "port: 80\n")
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .missing })
        #expect(d.issues.contains { $0.path.pathDescription == "service_name" })
    }

    @Test("type mismatches report from YAML with the right path")
    func yamlMismatch() {
        let d = AppConfig.diagnose(yaml: """
        service_name: api
        port: not-a-number
        database:
          url: u
          pool_size: 1
          ssl_required: true
        """)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .typeMismatch })
    }

    @Test("XML decodes with coerceScalars, because XML has no types")
    func xml() throws {
        let c = try XMLConfig.parse(xml: """
        <config>
          <service_name>api</service_name>
          <port>8080</port>
          <database>
            <url>postgres://x</url>
            <pool_size>10</pool_size>
            <ssl_required>true</ssl_required>
          </database>
        </config>
        """)
        #expect(c.serviceName == "api")
        #expect(c.port == 8080)
        #expect(c.database.url == "postgres://x")
        #expect(c.database.poolSize == 10)
        #expect(c.database.sslRequired == true)
    }

    @Test("XML attributes decode the same as child elements")
    func xmlAttributes() throws {
        // The RawValue projection flattens attributes and elements into one keyspace, so
        // either spelling works. The distinction is available via XML.Node when it matters.
        let c = try XMLConfig.parse(xml: """
        <config service_name="api" port="8080">
          <database url="postgres://x" pool_size="10" ssl_required="true"/>
        </config>
        """)
        #expect(c.serviceName == "api")
        #expect(c.port == 8080)
        #expect(c.database.poolSize == 10)
    }

    @Test("WITHOUT coercion, XML fails on a non-String field — and that is correct")
    func xmlWithoutCoercion() {
        // DatabaseConfig does not opt into coercion, so `pool_size` arriving as the string
        // "10" is a type mismatch rather than a silent conversion. Coercion stays written
        // on the struct.
        let d = DatabaseConfig.diagnose(xml: """
        <db><url>u</url><pool_size>10</pool_size><ssl_required>true</ssl_required></db>
        """)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .typeMismatch })
    }

    @Test("per-field @Coerce works without coercing the whole type")
    func perFieldCoerce() throws {
        let v = try PerFieldCoerce.parse(json: #"{"port":"8080","host":"localhost"}"#)
        #expect(v.port == 8080)
        #expect(v.host == "localhost")

        // host is NOT coerced: a number where a string is declared stays an error.
        let d = PerFieldCoerce.diagnose(json: #"{"port":"8080","host":8080}"#)
        #expect(d.isValid == false)
    }

    @Test("coercion rules are boring: no truncation, no locale")
    func coercionRules() {
        // "8080.5" -> Int must be an ERROR, not 8080.
        let d = PerFieldCoerce.diagnose(json: #"{"port":"8080.5","host":"h"}"#)
        #expect(d.isValid == false)

        // 1.0 is exactly integral, so it converts.
        let ok = PerFieldCoerce.diagnose(json: #"{"port":8080.0,"host":"h"}"#)
        #expect(ok.value?.port == 8080)

        // 1.5 does not.
        let bad = PerFieldCoerce.diagnose(json: #"{"port":8080.5,"host":"h"}"#)
        #expect(bad.isValid == false)
    }

    @Test("multi-document YAML into an array of structs")
    func parseAllYAML() throws {
        let items = try DatabaseConfig.parseAll(yaml: """
        ---
        url: a
        pool_size: 1
        ssl_required: true
        ---
        url: b
        pool_size: 2
        ssl_required: false
        """)
        #expect(items.count == 2)
        #expect(items[0].url == "a")
        #expect(items[1].poolSize == 2)
    }

    @Test("a multi-document stream through parse(yaml:) is an error, not a silent first")
    func yamlMultiDocRejected() {
        let d = DatabaseConfig.diagnose(yaml: """
        ---
        url: a
        pool_size: 1
        ssl_required: true
        ---
        url: b
        pool_size: 2
        ssl_required: false
        """)
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .custom("yaml_multiple_documents") })
    }

    @Test("a YAML non-string mapping key is reported, not coerced")
    func yamlUnrepresentableKey() {
        let d = DatabaseConfig.diagnose(yaml: "? [1,2]\n: x\n")
        #expect(d.isValid == false)
        #expect(d.issues.contains { $0.code == .custom("yaml_unrepresentable_key") })
    }

    @Test("malformed input in each format reports rather than trapping")
    func malformed() {
        #expect(throws: (any Error).self) { try AppConfig.parse(yaml: "a: [1, 2") }
        #expect(throws: (any Error).self) { try XMLConfig.parse(xml: "<a></b>") }
        #expect(throws: (any Error).self) { try AppConfig.parse(json: "{") }
    }
}
