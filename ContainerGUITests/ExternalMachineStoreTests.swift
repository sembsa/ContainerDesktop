import XCTest

@MainActor
final class ExternalMachineStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("external-machines.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-machines-tests-" + UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(
        check: @escaping @Sendable (DockerEndpoint) async -> Result<String, Error> = { _ in .success("Colima") }
    ) -> ExternalMachineStore {
        ExternalMachineStore(
            fileURL: fileURL,
            checker: check,
            tunnelCloser: { _ in },
            fileExists: { $0 == "/keys/id_ed25519" }
        )
    }

    private func sample(_ label: String = "Home", host: String = "nas.local") -> DockerEndpoint {
        DockerEndpoint(label: label, engine: .colima, host: host, sshPort: 2222, sshUser: "rick")
    }

    // MARK: - CRUD and persistence

    func testAddEditRemoveAndPersistRoundTrip() throws {
        let store = makeStore()
        XCTAssertTrue(store.machines.isEmpty)

        var added = try store.add(sample())
        XCTAssertEqual(store.machines.count, 1)

        added.label = "  NAS  "
        added.identityFile = "/keys/id_ed25519"
        added.remoteSocketPath = "/run/user/1000/docker.sock"
        try store.update(added)
        XCTAssertEqual(store.machines.first?.label, "NAS", "stored trimmed")

        let second = try store.add(sample("Lab", host: "10.0.0.7"))

        // A fresh store on the same file sees exactly the same entries.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.machines, store.machines)
        XCTAssertEqual(reloaded.machines.first?.sshPort, 2222)
        XCTAssertEqual(reloaded.machines.first?.engine, .colima)
        XCTAssertEqual(reloaded.machines.first?.identityFile, "/keys/id_ed25519")
        XCTAssertEqual(reloaded.machines.first?.remoteSocketPath, "/run/user/1000/docker.sock")

        store.remove(second.id)
        XCTAssertEqual(makeStore().machines.map(\.label), ["NAS"])
    }

    func testPersistedFileContainsNoSecrets() throws {
        let store = makeStore()
        var entry = sample()
        entry.identityFile = "/keys/id_ed25519"
        try store.add(entry)
        let text = try String(contentsOf: fileURL, encoding: .utf8).lowercased()
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("passphrase"))
        XCTAssertTrue(text.contains("id_ed25519"), "only the path is kept")
    }

    func testEnabledMachinesAndOnChange() throws {
        let store = makeStore()
        var notifications: [[DockerEndpoint]] = []
        store.onChange = { notifications.append($0) }

        let first = try store.add(sample("A"))
        _ = try store.add(sample("B", host: "b.local"))
        store.setEnabled(first.id, false)

        XCTAssertEqual(store.enabledMachines.map(\.label), ["B"])
        XCTAssertEqual(notifications.count, 3)
        XCTAssertEqual(notifications.last?.count, 2, "disabled entries are still listed, just not enabled")
        XCTAssertFalse(makeStore().machines.first { $0.label == "A" }!.enabled)
    }

    func testInvalidEntriesAreRejectedAndNotSaved() {
        let store = makeStore()
        XCTAssertThrowsError(try store.add(DockerEndpoint())) { error in
            let issues = (error as? ExternalMachineStore.ValidationError)?.issues ?? []
            XCTAssertTrue(issues.contains(.emptyLabel))
            XCTAssertTrue(issues.contains(.emptyHost))
        }
        XCTAssertTrue(store.machines.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDuplicateLabelsAreRejectedCaseInsensitively() throws {
        let store = makeStore()
        let first = try store.add(sample("Home"))
        XCTAssertThrowsError(try store.add(sample("home", host: "other.local"))) { error in
            XCTAssertEqual((error as? ExternalMachineStore.ValidationError)?.issues, [.duplicateLabel])
        }
        // Editing an entry must not clash with itself.
        XCTAssertNoThrow(try store.update(first))
    }

    func testCorruptFileYieldsEmptyList() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(makeStore().machines.isEmpty)
    }

    // MARK: - Connection test

    func testConnectionTestSetsStatus() async throws {
        let ok = makeStore()
        let entry = try ok.add(sample())
        await ok.test(entry.id)
        XCTAssertEqual(ok.status[entry.id], .online)

        struct Refused: LocalizedError { var errorDescription: String? { "connection refused" } }
        let bad = ExternalMachineStore(
            fileURL: directory.appendingPathComponent("bad.json"),
            checker: { _ in .failure(Refused()) },
            tunnelCloser: { _ in },
            fileExists: { _ in true }
        )
        let other = try bad.add(sample("Other"))
        await bad.test(other.id)
        XCTAssertEqual(bad.status[other.id], .offline("connection refused"))
    }

    // MARK: - Form validation

    func testValidationRules() {
        func issues(_ change: (inout DockerEndpoint) -> Void) -> [DockerEndpoint.Issue] {
            var endpoint = sample()
            change(&endpoint)
            return endpoint.validate(fileExists: { _ in true })
        }
        XCTAssertEqual(issues { _ in }, [])
        XCTAssertEqual(issues { $0.label = "   " }, [.emptyLabel])
        XCTAssertEqual(issues { $0.host = "" }, [.emptyHost])
        XCTAssertEqual(issues { $0.host = "-oProxyCommand=evil" }, [.invalidHost], "would be read as an ssh option")
        XCTAssertEqual(issues { $0.host = "a b" }, [.invalidHost])
        XCTAssertEqual(issues { $0.host = "fe80::1" }, [])
        XCTAssertEqual(issues { $0.sshPort = 0 }, [.invalidPort])
        XCTAssertEqual(issues { $0.sshPort = 65536 }, [.invalidPort])
        XCTAssertEqual(issues { $0.sshPort = 65535 }, [])
        XCTAssertEqual(issues { $0.sshUser = "-l" }, [.invalidUser])
        XCTAssertEqual(issues { $0.sshUser = "a;b" }, [.invalidUser])
        XCTAssertEqual(issues { $0.sshUser = "" }, [], "user is optional")
        XCTAssertEqual(issues { $0.remoteSocketPath = "relative/docker.sock" }, [.invalidSocketPath])
        XCTAssertEqual(issues { $0.remoteSocketPath = "/a:b/docker.sock" }, [.invalidSocketPath])
        XCTAssertEqual(issues { $0.remoteSocketPath = "/a b/docker.sock" }, [.invalidSocketPath])
        XCTAssertEqual(issues { $0.remoteSocketPath = "~/.colima/default/docker.sock" }, [])
        XCTAssertEqual(issues { $0.remoteSocketPath = "  " }, [], "blank means the engine default")
    }

    func testIdentityFileMustExistWhenGiven() {
        var endpoint = sample()
        endpoint.identityFile = "/nope"
        XCTAssertEqual(endpoint.validate(fileExists: { _ in false }), [.identityFileNotFound])
        XCTAssertEqual(endpoint.validate(fileExists: { _ in true }), [])
        endpoint.identityFile = nil
        XCTAssertEqual(endpoint.validate(fileExists: { _ in false }), [])
    }

    func testEngineDefaultSocketPaths() {
        var endpoint = DockerEndpoint()
        endpoint.engine = .colima
        XCTAssertEqual(endpoint.effectiveSocketPath, "~/.colima/default/docker.sock")
        endpoint.engine = .dockerDesktop
        XCTAssertEqual(endpoint.effectiveSocketPath, "~/.docker/run/docker.sock")
        endpoint.engine = .ssh
        XCTAssertEqual(endpoint.effectiveSocketPath, "/var/run/docker.sock")
        endpoint.remoteSocketPath = "/custom.sock"
        XCTAssertEqual(endpoint.effectiveSocketPath, "/custom.sock")
        XCTAssertEqual(DockerEndpoint.defaultSSHPort, 22)
    }

    // MARK: - ssh command line

    func testTunnelArguments() {
        var endpoint = sample()
        endpoint.identityFile = "/keys/id_ed25519"
        let args = SSHCommand.tunnel(endpoint: endpoint, localSocket: "/tmp/x.sock", remoteSocket: "/var/run/docker.sock")
        XCTAssertTrue(args.contains("BatchMode=yes"), "never prompts")
        XCTAssertEqual(args.last, "rick@nas.local", "target is last, after every option")
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(args[args.firstIndex(of: "-i")! + 1], "/keys/id_ed25519")
        XCTAssertEqual(args[args.firstIndex(of: "-L")! + 1], "/tmp/x.sock:/var/run/docker.sock")
        endpoint.sshUser = ""
        XCTAssertEqual(SSHCommand.tunnel(endpoint: endpoint, localSocket: "/a", remoteSocket: "/b").last, "nas.local")
    }

    /// An ssh_config alias: no user, default port. Nothing may override the
    /// alias' own settings.
    func testAliasEntryPassesNoUserPortOrKey() {
        let alias = DockerEndpoint(label: "studio", engine: .colima, host: "studio")
        XCTAssertEqual(alias.validate(fileExists: { _ in false }), [])
        let args = SSHCommand.tunnel(endpoint: alias, localSocket: "/a", remoteSocket: "/b")
        XCTAssertEqual(args.last, "studio")
        XCTAssertFalse(args.contains("-p"))
        XCTAssertFalse(args.contains("-i"))
        XCTAssertFalse(args.contains { $0.contains("@") })
    }

    // MARK: - Auto-detect

    func testProbeOutputParsing() {
        let output = """
        HOME /Users/rick
        SOCK /Users/rick/.docker/run/docker.sock
        SOCK /Users/rick/.colima/default/docker.sock
        SOCK /var/run/docker.sock
        CTX unix:///Users/Shared/studio-runtime/.run/docker.sock
        CTXNAME colima
        APPLE /usr/local/bin/container
        garbage line
        """
        let result = RemoteEngineProbe.parse(output)
        XCTAssertEqual(result.home, "/Users/rick")
        XCTAssertEqual(result.sockets.count, 3)
        XCTAssertEqual(result.contextSocket, "/Users/Shared/studio-runtime/.run/docker.sock")
        XCTAssertEqual(result.appleBinary, "/usr/local/bin/container")
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forContext: result.contextName), "Colima")
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forContext: "desktop-linux"), "Docker Desktop")
        XCTAssertNil(RemoteEngineProbe.engineTitle(forContext: "mystery"))
        // Context first, then an extra path, then the rest, each once.
        let candidates = RemoteEngineProbe.candidates(from: result, extra: "/var/run/docker.sock")
        XCTAssertEqual(candidates, [
            "/Users/Shared/studio-runtime/.run/docker.sock",
            "/var/run/docker.sock",
            "/Users/rick/.docker/run/docker.sock",
            "/Users/rick/.colima/default/docker.sock",
        ])
    }

    /// What the Mac Studio prints: Homebrew's binaries are found by absolute
    /// path even though the ssh PATH has no /opt/homebrew/bin.
    func testProbeOutputWithHomebrewAppleBinary() throws {
        let output = """
        HOME /Users/rick
        SOCK /Users/Shared/studio-runtime/.run/docker.sock
        DOCKER /opt/homebrew/bin/docker
        CTX unix:///Users/Shared/studio-runtime/.run/docker.sock
        CTXNAME colima
        APPLE /opt/homebrew/bin/container
        """
        let result = RemoteEngineProbe.parse(output)
        XCTAssertEqual(result.appleBinary, "/opt/homebrew/bin/container")
        XCTAssertEqual(result.dockerBinary, "/opt/homebrew/bin/docker")
        XCTAssertEqual(result.contextName, "colima")
        XCTAssertEqual(RemoteEngineProbe.candidates(from: result, extra: nil), ["/Users/Shared/studio-runtime/.run/docker.sock"])

        // The runtime built from it invokes the absolute path, quoted.
        let endpoint = DockerEndpoint(label: "studio", host: "studio")
        let apple = RemoteAppleRuntime(endpoint: endpoint, binary: try XCTUnwrap(result.appleBinary))
        guard case .sshCommand(let args) = apple.terminalTarget("studio-nginx") else { return XCTFail("expected ssh target") }
        XCTAssertEqual(args.last, "'/opt/homebrew/bin/container' 'exec' '-it' 'studio-nginx' 'sh'")
    }

    func testProbeScriptSearchesAbsoluteCandidatesThenPath() {
        let script = RemoteEngineProbe.script
        XCTAssertEqual(RemoteEngineProbe.appleCandidates, [
            "/opt/homebrew/bin/container", "/usr/local/bin/container", "~/.local/bin/container",
        ])
        XCTAssertTrue(RemoteEngineProbe.dockerCandidates.starts(with: [
            "/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]))
        // Apple: the three absolute paths in order (~ becomes "$HOME"), then `command -v`.
        let apple = #""/opt/homebrew/bin/container" "/usr/local/bin/container" "$HOME/.local/bin/container""#
        let appleAt = script.range(of: apple)
        XCTAssertNotNil(appleAt)
        XCTAssertNotNil(script.range(of: "command -v container"))
        XCTAssertNotNil(script.range(of: "command -v docker"))
        XCTAssertNotNil(script.range(of: #""/opt/homebrew/bin/docker" "/usr/local/bin/docker" "/Applications/Docker.app/Contents/Resources/bin/docker""#))
        // The docker CLI is invoked by the discovered path, never a bare name.
        XCTAssertTrue(script.contains(#""$DOCKER_BIN" context inspect"#))
        XCTAssertFalse(script.contains("\n docker context"))
    }

    func testCandidateQuotingNeutralisesShellMetacharacters() {
        XCTAssertEqual(RemoteEngineProbe.shellWord("~/.local/bin/container"), #""$HOME/.local/bin/container""#)
        XCTAssertEqual(RemoteEngineProbe.shellWord("/a b/$x`y`\"z"), "\"/a b/\\$x\\`y\\`\\\"z\"")
        XCTAssertEqual(RemoteEngineProbe.shellWord("/a\\b"), "\"/a\\\\b\"")
    }

    func testRemoteAppleRuntimeRefusesBareBinaryName() async {
        let apple = RemoteAppleRuntime(endpoint: DockerEndpoint(label: "s", host: "studio"), binary: "container")
        do {
            _ = try await apple.list(includeStopped: false)
            XCTFail("a bare name must not be run over ssh")
        } catch {
            XCTAssertTrue(error is CLIError)
        }
    }

    func testNonUnixContextIsNotUsedAsASocket() {
        let result = RemoteEngineProbe.parse("CTX tcp://10.0.0.5:2375\n")
        XCTAssertNil(result.contextSocket)
        XCTAssertEqual(result.contextOther, "tcp://10.0.0.5:2375")
        XCTAssertTrue(RemoteEngineProbe.candidates(from: result, extra: nil).isEmpty)
    }

    func testEngineTitlesFromSocketPaths() {
        let home = "/Users/rick"
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forSocket: "/Users/rick/.colima/default/docker.sock", home: home), "Colima")
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forSocket: "/Users/rick/.colima/dev/docker.sock", home: home), "Colima (dev)")
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forSocket: "/Users/agent/.colima/default/docker.sock", home: home), "Colima [agent]")
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forSocket: "/Users/rick/.docker/run/docker.sock", home: home), "Docker Desktop")
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forSocket: "/var/run/docker.sock", home: home), "Docker")
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forSocket: "/Users/Shared/studio-runtime/.run/docker.sock", home: home), "Docker")
        XCTAssertEqual(RemoteEngineProbe.engineTitle(forSocket: "/Users/rick/.orbstack/run/docker.sock", home: home), "OrbStack")
    }

    func testProbeScriptIsReadOnly() {
        let script = RemoteEngineProbe.script
        for forbidden in ["rm ", "mv ", "cp ", "chmod", "chown", "kill", "docker run", "docker rm", "docker stop", ">>", "tee ", "sudo"] {
            XCTAssertFalse(script.contains(forbidden), "probe must not contain \(forbidden)")
        }
    }

    func testContainerReferenceEncodingKeepsEngineAndName() throws {
        let reference = ExternalMachineRuntime.encode(engine: "/var/run/docker.sock", name: "web")
        let decoded = try XCTUnwrap(ExternalMachineRuntime.decode(reference))
        XCTAssertEqual(decoded.engine, "/var/run/docker.sock")
        XCTAssertEqual(decoded.name, "web")
        XCTAssertNil(ExternalMachineRuntime.decode("plain-name"))
    }

    func testRemoteCommandsAreQuoted() {
        let endpoint = DockerEndpoint(label: "s", engine: .appleContainer, host: "studio")
        let args = SSHCommand.remote(endpoint: endpoint, command: ["/usr/local/bin/container", "rm", "a'b; reboot"])
        XCTAssertEqual(args.last, "'/usr/local/bin/container' 'rm' 'a'\\''b; reboot'")
    }

    func testNewEntriesDefaultToAutoDetect() {
        XCTAssertEqual(DockerEndpoint().engine, .auto)
        XCTAssertEqual(DockerEndpoint().effectiveSocketPath, "")
    }

    // MARK: - Live (skipped unless the `studio` alias answers)

    /// Read-only: auto-detects every engine on the Mac Studio and lists their
    /// containers through the runtime layer, tagged with machine and engine.
    func testLiveStudioAutoDetectComesThroughTheRuntime() async throws {
        let probe = try await ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "studio", "true"],
            timeout: .seconds(15)
        )
        try XCTSkipUnless(probe.exitCode == 0, "ssh alias 'studio' not reachable")
        try XCTSkipUnless(DockerBinaryResolver.resolve() != nil, "docker CLI not installed")

        let endpoint = DockerEndpoint(label: "studio", host: "studio")   // engine defaults to auto
        let runtime = ExternalMachineRuntime(endpoint: endpoint)
        defer { Task { await SSHTunnelManager.shared.close(endpoint.id) } }

        let summary = try await runtime.ping()
        print("STUDIO_LIVE engines:", summary)
        for engine in try await runtime.engines() {
            switch engine.backend {
            case .apple(let apple): print("STUDIO_LIVE engine:", engine.title, "binary:", apple.binary)
            case .docker: print("STUDIO_LIVE engine:", engine.title, "key:", engine.key)
            }
        }
        let containers = try await runtime.list(includeStopped: true)
        XCTAssertFalse(containers.isEmpty)
        // Both engines on the Studio: Colima (shared socket) and Apple `container`.
        XCTAssertTrue(containers.contains { $0.machineLabel == "studio" && $0.engine == .colima }, "Colima engine missing")
        XCTAssertTrue(containers.contains { $0.machineLabel == "studio" && $0.engine == .apple }, "Apple engine missing")
        for container in containers {
            XCTAssertEqual(container.runtimeID, runtime.id)
            XCTAssertEqual(container.location, .external)
            XCTAssertEqual(container.machineLabel, "studio")
            XCTAssertEqual(container.sourceTags.count, 3)
            XCTAssertNotNil(ExternalMachineRuntime.decode(container.reference), "reference carries its engine")
        }
        // The merge must not list one engine twice.
        XCTAssertEqual(Set(containers.map(\.reference)).count, containers.count)
        if let first = containers.first {
            let raw = try await runtime.inspect(first.reference)
            XCTAssertTrue(raw.contains("\"Name\""))
        }
        for container in containers {
            print("STUDIO_LIVE container:", container.id, "state:", container.state, "tags:", container.sourceTags.map(\.text))
        }
    }
}
