import XCTest

/// Verifies that `ComposeParser` maps docker-compose YAML onto `ComposeProject`.
final class ComposeParserTests: XCTestCase {

    // MARK: - Full happy path

    func testFullProjectParses() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            container_name: my-web
            command: ["nginx", "-g", "daemon off;"]
            ports:
              - "8080:80"
              - 9090
            environment:
              FOO: bar
              COUNT: 3
            volumes:
              - "src:/app:ro"
            depends_on:
              - db
          db:
            image: postgres:16
            environment:
              - "POSTGRES_PASSWORD=secret"
              - DEBUG
        """

        let project = try ComposeParser.parse(yaml, projectName: "demo")

        // Launch order: db before web (web depends on db).
        XCTAssertEqual(project.services.map(\.name), ["db", "web"])

        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        let db = try XCTUnwrap(project.services.first { $0.name == "db" })

        // image + container_name + resolvedName.
        XCTAssertEqual(web.image, "nginx:latest")
        XCTAssertEqual(web.containerName, "my-web")
        XCTAssertEqual(web.resolvedName(project: "demo"), "my-web")
        XCTAssertEqual(db.resolvedName(project: "demo"), "demo-db")

        // command list joined.
        XCTAssertEqual(web.command, #"nginx -g "daemon off;""#)

        // environment as map (web): bar + 3 (number → string).
        let webEnv = Dictionary(uniqueKeysWithValues: web.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(webEnv["FOO"], "bar")
        XCTAssertEqual(webEnv["COUNT"], "3")

        // environment as list (db): POSTGRES_PASSWORD + bare DEBUG.
        let dbEnv = Dictionary(uniqueKeysWithValues: db.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(dbEnv["POSTGRES_PASSWORD"], "secret")
        XCTAssertEqual(dbEnv["DEBUG"], "")

        // ports: string + bare number expanded.
        XCTAssertTrue(web.ports.contains("8080:80"))
        XCTAssertTrue(web.ports.contains("9090:9090"))

        // volumes preserved.
        XCTAssertEqual(web.volumes, ["src:/app:ro"])

        // depends_on.
        XCTAssertEqual(web.dependsOn, ["db"])
    }

    // MARK: - build: rejected

    func testBuildKeyThrows() {
        let yaml = """
        services:
          app:
            build: .
        """
        XCTAssertThrowsError(try ComposeParser.parse(yaml, projectName: "p")) { error in
            guard case ComposeParseError.service(let name, let problem) = error else {
                return XCTFail("Oczekiwano .service, otrzymano \(error)")
            }
            XCTAssertEqual(name, "app")
            XCTAssertTrue(problem.contains("build"), "Komunikat powinien wspominać build: \(problem)")
        }
    }

    // MARK: - Missing services

    func testNoServicesThrows() {
        let yaml = """
        version: "3.9"
        volumes:
          data: {}
        """
        XCTAssertThrowsError(try ComposeParser.parse(yaml, projectName: "p")) { error in
            guard case ComposeParseError.noServices = error else {
                return XCTFail("Oczekiwano .noServices, otrzymano \(error)")
            }
        }
    }

    // MARK: - Invalid YAML

    func testInvalidYAMLThrows() {
        // A scalar document (not a mapping) is invalid for compose.
        let yaml = "just-a-string"
        XCTAssertThrowsError(try ComposeParser.parse(yaml, projectName: "p")) { error in
            guard case ComposeParseError.invalidYAML = error else {
                return XCTFail("Oczekiwano .invalidYAML, otrzymano \(error)")
            }
        }
    }

    func testBrokenYAMLThrows() {
        // Unbalanced/garbage YAML structure.
        let yaml = "services:\n  - this: is\n    not: : valid: ["
        XCTAssertThrowsError(try ComposeParser.parse(yaml, projectName: "p")) { error in
            guard case ComposeParseError.invalidYAML = error else {
                return XCTFail("Oczekiwano .invalidYAML, otrzymano \(error)")
            }
        }
    }

    // MARK: - Environment list normalization

    func testEnvironmentListNormalization() throws {
        let yaml = """
        services:
          app:
            image: alpine
            environment:
              - "A=1"
              - B
        """
        let project = try ComposeParser.parse(yaml, projectName: "p")
        let app = try XCTUnwrap(project.services.first)
        let pairs = app.environment.map { ($0.key, $0.value) }
        XCTAssertTrue(pairs.contains(where: { $0.0 == "A" && $0.1 == "1" }))
        XCTAssertTrue(pairs.contains(where: { $0.0 == "B" && $0.1 == "" }))
    }

    // MARK: - depends_on as map with condition

    func testDependsOnMapWithCondition() throws {
        let yaml = """
        services:
          web:
            image: nginx
            depends_on:
              db:
                condition: service_healthy
          db:
            image: postgres
        """
        let project = try ComposeParser.parse(yaml, projectName: "p")
        let web = try XCTUnwrap(project.services.first { $0.name == "web" })
        XCTAssertEqual(web.dependsOn, ["db"])
        // A non-default condition produces a warning.
        XCTAssertTrue(
            project.warnings.contains { $0.contains("service_healthy") || $0.contains("depends_on") },
            "Powinno być ostrzeżenie o warunku depends_on: \(project.warnings)"
        )
    }

    // MARK: - Dependency cycle

    func testDependencyCycleThrows() {
        let yaml = """
        services:
          a:
            image: alpine
            depends_on: [b]
          b:
            image: alpine
            depends_on: [a]
        """
        XCTAssertThrowsError(try ComposeParser.parse(yaml, projectName: "p")) { error in
            guard case ComposeParseError.service(_, let problem) = error else {
                return XCTFail("Oczekiwano .service (cykl), otrzymano \(error)")
            }
            XCTAssertTrue(problem.contains("cykl"), "Komunikat powinien wspominać cykl: \(problem)")
        }
    }

    // MARK: - Unsupported field warning

    func testUnsupportedFieldWarning() throws {
        let yaml = """
        services:
          app:
            image: alpine
            restart: always
        """
        let project = try ComposeParser.parse(yaml, projectName: "p")
        XCTAssertTrue(
            project.warnings.contains { $0.contains("restart") },
            "Ostrzeżenie powinno wspominać restart: \(project.warnings)"
        )
    }

    // MARK: - Top-level name + normalization

    func testTopLevelNameOverridesAndNormalizes() throws {
        let yaml = """
        name: "My App"
        services:
          app:
            image: alpine
        """
        let project = try ComposeParser.parse(yaml, projectName: "fallback")
        XCTAssertEqual(project.name, "my-app")
    }

    func testProjectNameNormalizationFromFallback() throws {
        let yaml = """
        services:
          app:
            image: alpine
        """
        let project = try ComposeParser.parse(yaml, projectName: "My App")
        XCTAssertEqual(project.name, "my-app")
    }

    // MARK: - Project name from YAML vs fallback (Zadanie 2)

    func testNameFromYAMLOverridesFieldAndFlagsSource() throws {
        // YAML declares name: demoapp, field is "compose" → YAML wins.
        let yaml = """
        name: demoapp
        services:
          db:
            image: postgres
          web:
            image: nginx
        """
        let project = try ComposeParser.parse(yaml, projectName: "compose")
        XCTAssertEqual(project.name, "demoapp")
        XCTAssertTrue(project.nameFromYAML, "name pochodzi z YAML, więc nameFromYAML musi być true")
    }

    func testNameFromFallbackFlagsSourceFalse() throws {
        // No top-level name: → fallback used, nameFromYAML == false.
        let yaml = """
        services:
          app:
            image: alpine
        """
        let project = try ComposeParser.parse(yaml, projectName: "compose")
        XCTAssertEqual(project.name, "compose")
        XCTAssertFalse(project.nameFromYAML, "brak name w YAML → nameFromYAML musi być false")
    }

    // MARK: - x-init parsing (Zadanie 1)

    func testInitServiceFlaggedAndOrderedFirst() throws {
        // dbmgr is an init task declared AFTER regular services and alphabetically
        // last, yet must land at the front of the ordered list.
        let yaml = """
        services:
          web:
            image: nginx
          api:
            image: api:latest
          dbmgr:
            image: server:latest
            x-init: true
            entrypoint: /create-db
        """
        let project = try ComposeParser.parse(yaml, projectName: "p")
        let dbmgr = try XCTUnwrap(project.services.first { $0.name == "dbmgr" })
        XCTAssertTrue(dbmgr.isInit, "dbmgr powinno mieć isInit == true")

        // Init task must be first; regular services follow.
        XCTAssertEqual(project.services.first?.name, "dbmgr")
        let api = try XCTUnwrap(project.services.first { $0.name == "api" })
        XCTAssertFalse(api.isInit)
    }

    func testInitBoolAcceptsStringAndNumber() throws {
        let yaml = """
        services:
          a:
            image: alpine
            x-init: "true"
          b:
            image: alpine
            x-init: 1
          c:
            image: alpine
        """
        let project = try ComposeParser.parse(yaml, projectName: "p")
        XCTAssertTrue(try XCTUnwrap(project.services.first { $0.name == "a" }).isInit)
        XCTAssertTrue(try XCTUnwrap(project.services.first { $0.name == "b" }).isInit)
        XCTAssertFalse(try XCTUnwrap(project.services.first { $0.name == "c" }).isInit)
    }

    func testInitDependingOnInitIsOrdered() throws {
        // init `second` depends on init `first` → both init, ordered first→second.
        let yaml = """
        services:
          web:
            image: nginx
          second:
            image: server:latest
            x-init: true
            depends_on: [first]
          first:
            image: server:latest
            x-init: true
        """
        let project = try ComposeParser.parse(yaml, projectName: "p")
        let names = project.services.map(\.name)
        let firstIdx = try XCTUnwrap(names.firstIndex(of: "first"))
        let secondIdx = try XCTUnwrap(names.firstIndex(of: "second"))
        let webIdx = try XCTUnwrap(names.firstIndex(of: "web"))
        XCTAssertLessThan(firstIdx, secondIdx, "first (init) musi poprzedzać second (init)")
        XCTAssertLessThan(secondIdx, webIdx, "init tasks muszą poprzedzać zwykłe usługi")
    }

    func testInitDependingOnRegularThrows() {
        let yaml = """
        services:
          web:
            image: nginx
          dbmgr:
            image: server:latest
            x-init: true
            depends_on: [web]
        """
        XCTAssertThrowsError(try ComposeParser.parse(yaml, projectName: "p")) { error in
            guard case ComposeParseError.service(let name, let problem) = error else {
                return XCTFail("Oczekiwano .service, otrzymano \(error)")
            }
            XCTAssertEqual(name, "dbmgr")
            XCTAssertTrue(problem.contains("init") && problem.contains("web"),
                          "Komunikat powinien wspominać init i web: \(problem)")
        }
    }
}
