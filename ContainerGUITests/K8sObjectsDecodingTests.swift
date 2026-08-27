import XCTest

/// Decodes real `kubectl -o json` output into the app's models.
///
/// The fixtures were captured from a cluster created by `container k8s create`
/// on CLI 1.3.0 (Kubernetes v1.35.5). Secrets and the CA certificate are
/// redacted — the cluster was throwaway, but service-account tokens have no
/// business in a repository.
final class K8sObjectsDecodingTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        let resolved = try XCTUnwrap(url, "Brak fixtury \(name).json w bundlu testowym")
        return try Data(contentsOf: resolved)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try KubectlJSON.decoder.decode(type, from: try fixture(name))
    }

    // MARK: - Dates

    func testTimestampsWithFractionalSecondsStillDecode() throws {
        // kubectl emits both forms. `creationTimestamp` has no fractional part,
        // but nine-digit fractions do appear elsewhere in the same documents, and
        // the strict .iso8601 strategy rejects them outright — which is why this
        // decoder has its own.
        let json = """
        {"items":[
          {"metadata":{"name":"a","namespace":"default","creationTimestamp":"2026-08-27T05:45:06Z"}},
          {"metadata":{"name":"b","namespace":"default","creationTimestamp":"2026-08-27T05:45:06.406141170Z"}}
        ]}
        """.data(using: .utf8)!

        let list = try KubectlJSON.decoder.decode(K8sList<K8sPod>.self, from: json)

        XCTAssertEqual(list.items.count, 2)
        XCTAssertNotNil(list.items[0].metadata.creationTimestamp)
        XCTAssertNotNil(list.items[1].metadata.creationTimestamp)
    }

    // MARK: - Pods

    func testDecodesPods() throws {
        let list = try decode(K8sList<K8sPod>.self, "k8s-pods")
        let pod = try XCTUnwrap(list.items.first)

        XCTAssertEqual(pod.metadata.name, "coredns-7d764666f9-cq4mq")
        XCTAssertEqual(pod.metadata.namespace, "kube-system")
        XCTAssertEqual(pod.status?.phase, "Running")
        XCTAssertEqual(pod.status?.podIP, "10.244.0.2")
        XCTAssertEqual(pod.spec?.nodeName, "gui-k8s")
        XCTAssertNotNil(pod.metadata.creationTimestamp)
    }

    func testPodSummarisesItsContainers() throws {
        let list = try decode(K8sList<K8sPod>.self, "k8s-pods")
        let pod = try XCTUnwrap(list.items.first)

        // The names drive the container picker in the log viewer and in exec.
        XCTAssertEqual(pod.containerNames, ["coredns"])
        XCTAssertEqual(pod.readyContainers, 1)
        XCTAssertEqual(pod.totalContainers, 1)
        XCTAssertEqual(pod.restartCount, 0)
        XCTAssertTrue(pod.isReady)
    }

    // MARK: - Deployments

    func testDecodesDeployments() throws {
        let list = try decode(K8sList<K8sDeployment>.self, "k8s-deployments")
        let deployment = try XCTUnwrap(list.items.first)

        XCTAssertEqual(deployment.metadata.name, "coredns")
        XCTAssertEqual(deployment.desiredReplicas, 2)
        XCTAssertEqual(deployment.readyReplicas, 2)
        XCTAssertEqual(deployment.images, ["registry.k8s.io/coredns/coredns:v1.13.1"])
    }

    // MARK: - Services

    func testDecodesServicesIncludingANumericTargetPort() throws {
        let list = try decode(K8sList<K8sService>.self, "k8s-services")
        let service = try XCTUnwrap(list.items.first { $0.metadata.name == "kubernetes" })

        XCTAssertEqual(service.spec?.type, "ClusterIP")
        XCTAssertEqual(service.spec?.clusterIP, "10.96.0.1")
        let port = try XCTUnwrap(service.spec?.ports?.first)
        XCTAssertEqual(port.port, 443)
        XCTAssertEqual(port.protocolName, "TCP")
        XCTAssertEqual(port.targetPort?.text, "6443")
    }

    func testATargetPortCanAlsoBeANamedPort() throws {
        // The API type is IntOrString: `targetPort: http` is as valid as 8080, and
        // decoding it as Int would throw on a perfectly ordinary Service.
        let json = """
        {"items":[{"metadata":{"name":"web","namespace":"default"},
          "spec":{"type":"NodePort","ports":[
            {"port":80,"targetPort":"http","protocol":"TCP","nodePort":31000}]}}]}
        """.data(using: .utf8)!

        let list = try KubectlJSON.decoder.decode(K8sList<K8sService>.self, from: json)
        let port = try XCTUnwrap(list.items.first?.spec?.ports?.first)

        XCTAssertEqual(port.targetPort?.text, "http")
        XCTAssertEqual(port.nodePort, 31000)
    }

    // MARK: - Config

    func testDecodesConfigMapKeys() throws {
        let list = try decode(K8sList<K8sConfigMap>.self, "k8s-configmaps")
        let configMap = try XCTUnwrap(list.items.first)

        XCTAssertEqual(configMap.metadata.name, "kube-root-ca.crt")
        XCTAssertEqual(configMap.keys, ["ca.crt"])
    }

    func testDecodesSecretKeysWithoutExposingValues() throws {
        let list = try decode(K8sList<K8sSecret>.self, "k8s-secrets")
        let secret = try XCTUnwrap(list.items.first)

        XCTAssertEqual(secret.type, "bootstrap.kubernetes.io/token")
        XCTAssertTrue(secret.keys.contains("token-id"))
        // The keys are listed; a value is only ever read through `value(for:)`,
        // which the UI calls per key on an explicit reveal.
        XCTAssertNotNil(secret.value(for: "token-id"))
        XCTAssertNil(secret.value(for: "nie-ma-takiego"))
    }

    // MARK: - Cluster-scoped

    func testDecodesNodes() throws {
        let list = try decode(K8sList<K8sNodeObject>.self, "k8s-nodes")
        let node = try XCTUnwrap(list.items.first)

        XCTAssertEqual(node.metadata.name, "gui-k8s")
        XCTAssertEqual(node.kubeletVersion, "v1.35.5")
        XCTAssertTrue(node.isReady)
        XCTAssertEqual(node.capacityCPU, "5")
    }

    func testDecodesNamespaces() throws {
        let list = try decode(K8sList<K8sNamespace>.self, "k8s-namespaces")

        XCTAssertEqual(list.items.map(\.metadata.name),
                       ["default", "kube-node-lease", "kube-public", "kube-system"])
        XCTAssertEqual(list.items.first?.phase, "Active")
    }
}
