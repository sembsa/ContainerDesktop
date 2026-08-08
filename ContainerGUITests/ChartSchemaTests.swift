import XCTest

/// A chart's `values.schema.json` can require keys that `values.yaml` never
/// defaults. The form is generated from values.yaml, so without reading the
/// schema those keys simply have no field — and the install fails validation
/// with nowhere to fix it. Fixture captured from the real `soneta/soneta` chart.
final class ChartSchemaTests: XCTestCase {
    private func schemaFixture() throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: "soneta-values.schema", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "soneta-values.schema", withExtension: "json")
        return try Data(contentsOf: try XCTUnwrap(url, "Brak fixtury schematu"))
    }

    func testFindsKeysRequiredThroughOneOfBranches() throws {
        let properties = ChartSchema.properties(fromSchema: try schemaFixture())
        let byPath = Dictionary(properties.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        // The chart spells "either dblist or listaBazDanych" as a top-level
        // oneOf; both must surface or the user cannot satisfy either branch.
        XCTAssertEqual(byPath["dblist"]?.isRequired, true)
        XCTAssertEqual(byPath["listaBazDanych"]?.isRequired, true)
        XCTAssertEqual(byPath["image"]?.isRequired, true)
        XCTAssertEqual(byPath["dblist"]?.type, "string")
        XCTAssertNotNil(byPath["dblist"]?.description)
        // Something not in any required list stays optional.
        XCTAssertEqual(byPath["replicaCount"]?.isRequired, false)
    }

    func testResolvesLocalRefsAndMixedTypeOneOf() throws {
        let schema = """
        {
          "$defs": {
            "Quantity": { "oneOf": [{"type": "string"}, {"type": "number"}],
                          "description": "A Kubernetes quantity." }
          },
          "type": "object",
          "required": ["cpu"],
          "properties": {
            "cpu": { "$ref": "#/$defs/Quantity" },
            "mode": { "type": "string", "enum": ["fast", "slow"] }
          }
        }
        """
        let properties = ChartSchema.properties(fromSchema: Data(schema.utf8))
        let byPath = Dictionary(uniqueKeysWithValues: properties.map { ($0.path, $0) })

        XCTAssertEqual(byPath["cpu"]?.type, "string")
        XCTAssertEqual(byPath["cpu"]?.description, "A Kubernetes quantity.")
        XCTAssertEqual(byPath["cpu"]?.isRequired, true)
        XCTAssertEqual(byPath["mode"]?.enumValues, ["fast", "slow"])
    }

    func testWalksNestedObjectProperties() throws {
        let schema = """
        {
          "type": "object",
          "properties": {
            "image": {
              "type": "object",
              "required": ["tag"],
              "properties": {
                "tag": { "type": "string" },
                "pullPolicy": { "type": "string" }
              }
            }
          }
        }
        """
        let byPath = Dictionary(
            uniqueKeysWithValues: ChartSchema.properties(fromSchema: Data(schema.utf8)).map { ($0.path, $0) }
        )

        XCTAssertEqual(byPath["image.tag"]?.isRequired, true)
        XCTAssertEqual(byPath["image.pullPolicy"]?.isRequired, false)
    }

    func testMalformedSchemaDegradesToNoProperties() {
        XCTAssertTrue(ChartSchema.properties(fromSchema: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(ChartSchema.properties(fromSchema: Data("{}".utf8)).isEmpty)
    }

    // MARK: - Merging into the values.yaml-derived form

    func testUndefaultedRequiredKeysAreAppendedToTheForm() throws {
        let fields = try ChartValues.fields(from: "replicaCount: 1\nimage:\n  tag: \"1.0\"\n")
        XCTAssertFalse(fields.contains { $0.path == "dblist" })

        let merged = ChartValues.merge(fields: fields, schema: ChartSchema.properties(fromSchema: try schemaFixture()))
        let byPath = Dictionary(merged.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        let dblist = try XCTUnwrap(byPath["dblist"], "dblist musi trafić do formularza ze schematu")
        XCTAssertTrue(dblist.isRequired)
        XCTAssertEqual(dblist.kind, .string)
        XCTAssertEqual(dblist.defaultValue, "")
        XCTAssertNotNil(dblist.comment)
    }

    func testMergeKeepsValuesYAMLDefaultsAndAnnotatesThem() throws {
        let fields = try ChartValues.fields(from: "replicaCount: 1\n")
        let merged = ChartValues.merge(fields: fields, schema: ChartSchema.properties(fromSchema: try schemaFixture()))
        let replicaCount = try XCTUnwrap(merged.first { $0.path == "replicaCount" })

        // The default from values.yaml wins; the schema only annotates.
        XCTAssertEqual(replicaCount.defaultValue, "1")
        XCTAssertEqual(replicaCount.kind, .number)
        XCTAssertFalse(replicaCount.isRequired)
    }

    func testMergeWithoutASchemaChangesNothing() throws {
        let fields = try ChartValues.fields(from: "replicaCount: 1\n")
        XCTAssertEqual(ChartValues.merge(fields: fields, schema: []).map(\.path), fields.map(\.path))
    }

    /// Required keys are what block the install, so they must not be buried at
    /// the bottom of a 128-line form.
    func testRequiredAdditionsSortAheadOfOptionalOnes() throws {
        let merged = ChartValues.merge(
            fields: [],
            schema: ChartSchema.properties(fromSchema: try schemaFixture())
        )
        let addedPaths = merged.map(\.path)
        let dblistIndex = try XCTUnwrap(addedPaths.firstIndex(of: "dblist"))
        let optionalIndex = try XCTUnwrap(addedPaths.firstIndex(of: "replicaCount"))
        XCTAssertLessThan(dblistIndex, optionalIndex)
    }
}
