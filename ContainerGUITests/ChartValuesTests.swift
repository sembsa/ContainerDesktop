import XCTest
import Yams

/// The Helm values editor turns a chart's `values.yaml` into a form and the
/// user's edits back into a **minimal** overrides document.
final class ChartValuesTests: XCTestCase {
    private let sample = """
    # yaml-language-server: $schema=./values.schema.json
    # Number of replicas to run
    replicaCount: 1
    adminMode: false
    image:
      # -- Image tag to deploy
      tag: "2512.0.0"
      product: standard
    imagePullSecrets: []
    nameOverride: ""
    """

    func testInfersFieldKindsFromValues() throws {
        let fields = try ChartValues.fields(from: sample)
        let byPath = Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0) })

        XCTAssertEqual(byPath["replicaCount"]?.kind, .number)
        XCTAssertEqual(byPath["adminMode"]?.kind, .boolean)
        XCTAssertEqual(byPath["image.tag"]?.kind, .string)
        XCTAssertEqual(byPath["imagePullSecrets"]?.kind, .stringList)
        XCTAssertEqual(byPath["image.product"]?.defaultValue, "standard")
        XCTAssertEqual(byPath["image.tag"]?.group, "image")
        XCTAssertEqual(byPath["image.tag"]?.label, "tag")
    }

    func testHarvestsCommentsAsHelpText() throws {
        let fields = try ChartValues.fields(from: sample)
        let byPath = Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0) })

        XCTAssertEqual(byPath["replicaCount"]?.comment, "Number of replicas to run")
        // "# --" is a helm-docs marker, not part of the sentence.
        XCTAssertEqual(byPath["image.tag"]?.comment, "Image tag to deploy")
        // The tooling directive on line 1 must not leak into a field.
        XCTAssertNil(byPath["adminMode"]?.comment)
    }

    /// The whole point of the editor: `-f` should carry only what changed.
    func testOverridesContainOnlyEditedKeys() throws {
        let fields = try ChartValues.fields(from: sample)
        let yaml = try ChartValues.overridesYAML(
            edits: ["replicaCount": "3", "image.tag": "2601.0.0"],
            fields: fields
        )

        let loaded = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        XCTAssertEqual(loaded.keys.sorted(), ["image", "replicaCount"])
        // A number stays a number — a string would fail the chart's schema.
        XCTAssertEqual(loaded["replicaCount"] as? Int, 3)
        XCTAssertEqual((loaded["image"] as? [String: Any])?["tag"] as? String, "2601.0.0")
        XCTAssertNil((loaded["image"] as? [String: Any])?["product"])
    }

    func testBooleanAndListKeepTheirTypes() throws {
        let fields = try ChartValues.fields(from: sample)
        let yaml = try ChartValues.overridesYAML(
            edits: ["adminMode": "true", "imagePullSecrets": "[regcred]"],
            fields: fields
        )

        let loaded = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        XCTAssertEqual(loaded["adminMode"] as? Bool, true)
        XCTAssertEqual(loaded["imagePullSecrets"] as? [String], ["regcred"])
    }

    func testNoEditsProduceEmptyDocument() throws {
        let fields = try ChartValues.fields(from: sample)
        XCTAssertEqual(try ChartValues.overridesYAML(edits: [:], fields: fields), "")
    }

    /// Switching between the form and the YAML tab must not lose anything.
    func testEditsRoundTripThroughOverridesYAML() throws {
        let fields = try ChartValues.fields(from: sample)
        let edits = ["replicaCount": "5", "image.tag": "dev", "adminMode": "true"]

        let yaml = try ChartValues.overridesYAML(edits: edits, fields: fields)
        let recovered = ChartValues.edits(fromOverrides: yaml, fields: fields)

        XCTAssertEqual(recovered, edits)
    }

    func testValidateRejectsBrokenYAML() {
        XCTAssertNil(ChartValues.validate("replicaCount: 3"))
        XCTAssertNil(ChartValues.validate(""))
        XCTAssertNotNil(ChartValues.validate("replicaCount: [3\nbroken"))
    }

    /// Charts share blocks with YAML anchors (the Soneta chart does). Yams
    /// resolves aliases while composing, so the aliased block shows up as real,
    /// individually editable fields rather than an opaque `*anchor` blob.
    func testAliasedBlocksExpandIntoEditableFields() throws {
        let yaml = """
        common: &common
          pullPolicy: IfNotPresent
        web:
          settings: *common
        """
        let fields = try ChartValues.fields(from: yaml)
        let byPath = Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0) })

        XCTAssertEqual(fields.map(\.path), ["common.pullPolicy", "web.settings.pullPolicy"])
        XCTAssertEqual(byPath["web.settings.pullPolicy"]?.kind, .string)
        XCTAssertEqual(byPath["web.settings.pullPolicy"]?.defaultValue, "IfNotPresent")

        // Editing one side of the anchor overrides only that path.
        let overrides = try ChartValues.overridesYAML(
            edits: ["web.settings.pullPolicy": "Never"],
            fields: fields
        )
        let loaded = try XCTUnwrap(Yams.load(yaml: overrides) as? [String: Any])
        XCTAssertEqual(loaded.keys.sorted(), ["web"])
    }

    // MARK: - Scalar lists

    /// Charts are full of `key: []`. Adding one entry to an empty list is the
    /// most common edit there is, so it gets a row editor rather than a
    /// text field where the user types YAML punctuation.
    func testScalarListsGetARowEditorAndObjectListsDoNot() throws {
        let yaml = """
        imagePullSecrets: []
        args:
          - --verbose
          - --port=8080
        volumes:
          - name: data
            mountPath: /data
        resources: {}
        """
        let byPath = Dictionary(uniqueKeysWithValues: try ChartValues.fields(from: yaml).map { ($0.path, $0) })

        XCTAssertEqual(byPath["imagePullSecrets"]?.kind, .stringList)
        XCTAssertEqual(byPath["args"]?.kind, .stringList)
        // A list of objects cannot be rows of text fields.
        XCTAssertEqual(byPath["volumes"]?.kind, .yaml)
        XCTAssertEqual(byPath["resources"]?.kind, .yaml)
    }

    func testScalarListDefaultsRenderInFlowStyle() throws {
        let yaml = """
        args:
          - --verbose
          - --port=8080
        empty: []
        """
        let byPath = Dictionary(uniqueKeysWithValues: try ChartValues.fields(from: yaml).map { ($0.path, $0) })

        // Flow style keeps the stored edit a single line, so the form and the
        // YAML tab do not reformat it on every switch.
        XCTAssertEqual(byPath["args"]?.defaultValue, #"["--verbose", "--port=8080"]"#)
        XCTAssertEqual(byPath["empty"]?.defaultValue, "[]")
    }

    func testListItemsParsesBothFlowAndBlockStyle() {
        XCTAssertEqual(ChartValues.listItems(#"["a", "b"]"#), ["a", "b"])
        XCTAssertEqual(ChartValues.listItems("- a\n- b"), ["a", "b"])
        XCTAssertEqual(ChartValues.listItems("[]"), [])
        XCTAssertEqual(ChartValues.listItems(""), [])
        XCTAssertEqual(ChartValues.listItems("nonsense: {"), [])
    }

    func testEditedListStaysAListInTheOverrides() throws {
        let fields = try ChartValues.fields(from: "imagePullSecrets: []\n")
        let yaml = try ChartValues.overridesYAML(
            edits: ["imagePullSecrets": ChartValues.flowList(["regcred", "ghcr"])],
            fields: fields
        )

        let loaded = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        XCTAssertEqual(loaded["imagePullSecrets"] as? [String], ["regcred", "ghcr"])
    }

    /// Emptying a list must yield `[]`, not `null` — a chart's
    /// `range .Values.args` fails on null but iterates nothing on an empty list.
    func testEmptiedListStaysAnEmptyListNotNull() throws {
        let fields = try ChartValues.fields(from: "args:\n  - --verbose\n")
        let yaml = try ChartValues.overridesYAML(
            edits: ["args": ChartValues.flowList([])],
            fields: fields
        )

        let loaded = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        XCTAssertNotNil(loaded["args"] as? [Any])
        XCTAssertEqual((loaded["args"] as? [Any])?.count, 0)
    }

    func testListEditsRoundTripThroughTheYAMLTab() throws {
        let fields = try ChartValues.fields(from: "imagePullSecrets: []\nreplicaCount: 1\n")
        let edits = ["imagePullSecrets": ChartValues.flowList(["regcred"])]

        let yaml = try ChartValues.overridesYAML(edits: edits, fields: fields)
        let recovered = ChartValues.edits(fromOverrides: yaml, fields: fields)

        XCTAssertEqual(ChartValues.listItems(recovered["imagePullSecrets"] ?? ""), ["regcred"])
    }

    func testEmptyChartValuesYieldNoFields() throws {
        XCTAssertTrue(try ChartValues.fields(from: "").isEmpty)
        XCTAssertTrue(try ChartValues.fields(from: "# only a comment\n").isEmpty)
    }
}
