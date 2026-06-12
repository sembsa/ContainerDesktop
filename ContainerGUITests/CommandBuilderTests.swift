import XCTest

/// Verifies that the run-container form maps to the correct `container run` argv.
final class CommandBuilderTests: XCTestCase {
    func testFullConfigurationProducesExpectedArguments() {
        var config = RunConfiguration()
        config.image = "nginx:latest"
        config.name = "web"
        config.cpus = "2"
        config.memory = "512M"
        config.network = "default"
        config.removeOnExit = true
        config.ports = [.init(host: "8080", container: "80", proto: "tcp")]
        config.environment = [.init(key: "FOO", value: "bar")]
        config.volumes = [.init(source: "demovol", destination: "/data", readOnly: true)]
        config.labels = [.init(key: "team", value: "dev")]
        config.command = "nginx -g daemon off;"

        let args = RunCommandBuilder.arguments(for: config)

        XCTAssertEqual(args.first, "run")
        XCTAssertTrue(args.contains("--detach"))
        XCTAssertTrue(args.contains("--rm"))
        assertPair(args, "--name", "web")
        assertPair(args, "--cpus", "2")
        assertPair(args, "--memory", "512M")
        assertPair(args, "--network", "default")
        assertPair(args, "--publish", "8080:80/tcp")
        assertPair(args, "--env", "FOO=bar")
        assertPair(args, "--label", "team=dev")
        assertPair(args, "--volume", "demovol:/data:ro")

        // Image must come after options, followed by the split command.
        XCTAssertEqual(Array(args.suffix(5)), ["nginx:latest", "nginx", "-g", "daemon", "off;"])
    }

    func testEmptyFieldsAreOmitted() {
        var config = RunConfiguration()
        config.image = "alpine:latest"
        config.ports = [.init(host: "", container: "", proto: "tcp")]
        config.environment = [.init(key: "", value: "x")]

        let args = RunCommandBuilder.arguments(for: config)

        XCTAssertFalse(args.contains("--publish"))
        XCTAssertFalse(args.contains("--env"))
        XCTAssertFalse(args.contains("--name"))
        XCTAssertEqual(args.last, "alpine:latest")
    }

    // MARK: - Tokenizer tests

    func testTokenizeDoubleQuotedGroup() {
        // sh -c "echo a b" → ["sh", "-c", "echo a b"]
        XCTAssertEqual(RunCommandBuilder.tokenize(#"sh -c "echo a b""#), ["sh", "-c", "echo a b"])
    }

    func testTokenizeSingleQuotedGroup() {
        // echo 'a  b' → ["echo", "a  b"]
        XCTAssertEqual(RunCommandBuilder.tokenize("echo 'a  b'"), ["echo", "a  b"])
    }

    func testTokenizeEscapedQuotesInsideDoubleQuotes() {
        // echo "say \"hi\"" → ["echo", "say \"hi\""]
        XCTAssertEqual(RunCommandBuilder.tokenize("echo \"say \\\"hi\\\"\""), ["echo", "say \"hi\""])
    }

    func testTokenizeBackslashEscapedSpace() {
        // a\ b → ["a b"]
        XCTAssertEqual(RunCommandBuilder.tokenize(#"a\ b"#), ["a b"])
    }

    func testTokenizeMultipleWhitespace() {
        // "a   b\tc" → ["a", "b", "c"]
        XCTAssertEqual(RunCommandBuilder.tokenize("a   b\tc"), ["a", "b", "c"])
    }

    func testTokenizeEmptyString() {
        XCTAssertEqual(RunCommandBuilder.tokenize(""), [])
    }

    func testTokenizeWhitespaceOnly() {
        XCTAssertEqual(RunCommandBuilder.tokenize("   "), [])
    }

    func testTokenizeOptionWithQuotedValue() {
        // --opt="x y" → ["--opt=x y"]
        XCTAssertEqual(RunCommandBuilder.tokenize(#"--opt="x y""#), ["--opt=x y"])
    }

    func testTokenizeUnclosedDoubleQuote() {
        // echo "abc  (unclosed) → ["echo", "abc"]
        XCTAssertEqual(RunCommandBuilder.tokenize("echo \"abc"), ["echo", "abc"])
    }

    // MARK: - Progress flag tests

    func testProgressFlagAppearsBeforeImage() {
        var config = RunConfiguration()
        config.image = "alpine:latest"

        let args = RunCommandBuilder.arguments(for: config, progress: "plain")

        guard let progressIdx = args.firstIndex(of: "--progress"),
              let imageIdx = args.firstIndex(of: "alpine:latest") else {
            XCTFail("Brak --progress lub obrazu w argumentach")
            return
        }
        XCTAssertLessThan(progressIdx, imageIdx, "--progress musi poprzedzać obraz")
        XCTAssertEqual(args[progressIdx + 1], "plain")
    }

    func testProgressAbsentWhenNil() {
        var config = RunConfiguration()
        config.image = "alpine:latest"

        let args = RunCommandBuilder.arguments(for: config, progress: nil)
        XCTAssertFalse(args.contains("--progress"), "--progress nie powinno być w argumentach gdy progress == nil")
    }

    func testCommandWithQuotePassesThroughTokenize() {
        // sh -c "sleep 1" in config.command should produce [..., "sh", "-c", "sleep 1"]
        var config = RunConfiguration()
        config.image = "alpine:latest"
        config.command = #"sh -c "sleep 1""#

        let args = RunCommandBuilder.arguments(for: config)
        XCTAssertTrue(args.suffix(3).elementsEqual(["sh", "-c", "sleep 1"]),
                      "Koniec argumentów powinien być [\"sh\", \"-c\", \"sleep 1\"], ale był: \(Array(args.suffix(3)))")
    }

    // MARK: - Arch flag tests

    func testArchAmd64ProducesArchFlag() {
        var config = RunConfiguration()
        config.image = "ubuntu:latest"
        config.arch = "amd64"

        let args = RunCommandBuilder.arguments(for: config)

        assertPair(args, "--arch", "amd64")
        // --arch must appear before the image
        guard let archIdx = args.firstIndex(of: "--arch"),
              let imageIdx = args.firstIndex(of: "ubuntu:latest") else {
            XCTFail("Brak --arch lub obrazu")
            return
        }
        XCTAssertLessThan(archIdx, imageIdx, "--arch musi poprzedzać obraz")
    }

    func testArchEmptyOmitsArchFlag() {
        var config = RunConfiguration()
        config.image = "alpine:latest"
        config.arch = ""

        let args = RunCommandBuilder.arguments(for: config)
        XCTAssertFalse(args.contains("--arch"), "--arch nie powinno być gdy arch jest puste")
    }

    // MARK: - joinCommand tests

    func testJoinCommandSimpleArgs() {
        XCTAssertEqual(RunCommandBuilder.joinCommand(["sh", "-c", "echo a b"]),
                       #"sh -c "echo a b""#)
    }

    func testJoinCommandRoundtrip() {
        let cases: [[String]] = [
            ["sh", "-c", "echo hello world"],
            ["nginx", "-g", "daemon off;"],
            ["/bin/sh"],
            ["python3", "-m", "http.server", "8080"],
        ]
        for argv in cases {
            let joined = RunCommandBuilder.joinCommand(argv)
            XCTAssertEqual(RunCommandBuilder.tokenize(joined), argv,
                           "Roundtrip nie działa dla: \(argv)")
        }
    }

    func testJoinCommandArgsWithQuotes() {
        // arg containing a double-quote should be escaped
        let result = RunCommandBuilder.joinCommand(["echo", "say \"hi\""])
        XCTAssertEqual(result, #"echo "say \"hi\"""#)
    }

    func testJoinCommandNoQuotesNeeded() {
        XCTAssertEqual(RunCommandBuilder.joinCommand(["ls", "-la"]), "ls -la")
    }

    // MARK: - previewLines tests

    func testPreviewLinesBasicStructure() {
        var config = RunConfiguration()
        config.image = "nginx:latest"
        config.ports = [.init(host: "8080", container: "80", proto: "tcp")]
        config.command = "sleep 10"

        let lines = RunCommandBuilder.previewLines(for: config)

        // First line must start with "container run --detach"
        XCTAssertTrue(lines.first?.hasPrefix("container run --detach") == true,
                      "Pierwsza linia powinna zaczynać się od 'container run --detach', ale była: \(lines.first ?? "")")

        // A line with --publish must exist
        XCTAssertTrue(lines.contains(where: { $0.contains("--publish") && $0.contains("8080:80/tcp") }),
                      "Powinna istnieć linia z '--publish 8080:80/tcp'")

        // Last line must contain the image
        XCTAssertTrue(lines.last?.contains("nginx:latest") == true,
                      "Ostatnia linia powinna zawierać obraz, ale była: \(lines.last ?? "")")

        // No line should contain a literal newline character
        for line in lines {
            XCTAssertFalse(line.contains("\n"), "Żadna linia nie powinna zawierać znaku nowej linii: \(line)")
        }
    }

    // MARK: - Private helpers

    private func assertPair(_ args: [String], _ flag: String, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let index = args.firstIndex(of: flag) else {
            XCTFail("Brak flagi \(flag)", file: file, line: line)
            return
        }
        XCTAssertLessThan(index + 1, args.count, "Flaga \(flag) bez wartości", file: file, line: line)
        XCTAssertEqual(args[index + 1], value, file: file, line: line)
    }
}
