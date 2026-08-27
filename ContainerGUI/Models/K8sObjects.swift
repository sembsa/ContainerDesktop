import Foundation

/// The Kubernetes objects the app displays, decoded from `kubectl -o json`.
///
/// These are deliberately partial. A faithful transcription of the API schema
/// would be enormous and would break on every field Kubernetes adds; what is
/// modelled here is what the views actually draw, and `Decodable` ignores the
/// rest. Every optional is optional because the API really does omit it — a
/// pending pod has no `podIP`, a stopped deployment no `readyReplicas`.

// MARK: - Envelope

struct K8sList<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
}

struct K8sMetadata: Decodable, Sendable, Hashable {
    let name: String
    let namespace: String?
    let creationTimestamp: Date?
    let labels: [String: String]?
}

/// `targetPort` and friends are the API's IntOrString: `8080` and `http` are
/// both valid, and decoding either one as the other throws.
struct K8sIntOrString: Decodable, Sendable, Hashable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            text = String(number)
        } else {
            text = try container.decode(String.self)
        }
    }
}

// MARK: - Pod

struct K8sPod: Decodable, Sendable, Hashable, Identifiable {
    let metadata: K8sMetadata
    let spec: Spec?
    let status: Status?

    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }

    struct Spec: Decodable, Sendable, Hashable {
        let nodeName: String?
        let containers: [Container]?

        struct Container: Decodable, Sendable, Hashable {
            let name: String
            let image: String?
        }
    }

    struct Status: Decodable, Sendable, Hashable {
        let phase: String?
        let podIP: String?
        let startTime: Date?
        let containerStatuses: [ContainerStatus]?

        struct ContainerStatus: Decodable, Sendable, Hashable {
            let name: String
            let ready: Bool?
            let restartCount: Int?
        }
    }

    var containerNames: [String] { spec?.containers?.map(\.name) ?? [] }

    /// Statuses come from the cluster and specs from the manifest; a pod that has
    /// not been scheduled yet has the second but not the first.
    var totalContainers: Int {
        status?.containerStatuses?.count ?? spec?.containers?.count ?? 0
    }

    var readyContainers: Int {
        status?.containerStatuses?.filter { $0.ready == true }.count ?? 0
    }

    var restartCount: Int {
        status?.containerStatuses?.reduce(0) { $0 + ($1.restartCount ?? 0) } ?? 0
    }

    var isReady: Bool { totalContainers > 0 && readyContainers == totalContainers }
}

// MARK: - Deployment

struct K8sDeployment: Decodable, Sendable, Hashable, Identifiable {
    let metadata: K8sMetadata
    let spec: Spec?
    let status: Status?

    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }

    struct Spec: Decodable, Sendable, Hashable {
        let replicas: Int?
        let template: Template?

        struct Template: Decodable, Sendable, Hashable {
            let spec: PodSpec?
            struct PodSpec: Decodable, Sendable, Hashable {
                let containers: [K8sPod.Spec.Container]?
            }
        }
    }

    struct Status: Decodable, Sendable, Hashable {
        let replicas: Int?
        let readyReplicas: Int?
        let availableReplicas: Int?
        let updatedReplicas: Int?
    }

    var desiredReplicas: Int { spec?.replicas ?? 0 }
    var readyReplicas: Int { status?.readyReplicas ?? 0 }
    var images: [String] { spec?.template?.spec?.containers?.compactMap(\.image) ?? [] }
}

// MARK: - Service

struct K8sService: Decodable, Sendable, Hashable, Identifiable {
    let metadata: K8sMetadata
    let spec: Spec?

    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }

    struct Spec: Decodable, Sendable, Hashable {
        let type: String?
        let clusterIP: String?
        let ports: [Port]?

        struct Port: Decodable, Sendable, Hashable {
            let name: String?
            let port: Int?
            let targetPort: K8sIntOrString?
            let nodePort: Int?
            /// `protocol` is a Swift keyword.
            let protocolName: String?

            enum CodingKeys: String, CodingKey {
                case name, port, targetPort, nodePort
                case protocolName = "protocol"
            }
        }
    }
}

// MARK: - ConfigMap and Secret

struct K8sConfigMap: Decodable, Sendable, Hashable, Identifiable {
    let metadata: K8sMetadata
    let data: [String: String]?

    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }
    var keys: [String] { data?.keys.sorted() ?? [] }
}

/// A secret's values are base64 in the JSON and stay that way until something
/// asks for one. The list view shows keys only.
struct K8sSecret: Decodable, Sendable, Hashable, Identifiable {
    let metadata: K8sMetadata
    let type: String?
    let data: [String: String]?

    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }
    var keys: [String] { data?.keys.sorted() ?? [] }

    /// Decodes one value on demand. Binary contents that are not valid UTF-8
    /// come back nil rather than as mojibake.
    func value(for key: String) -> String? {
        guard let encoded = data?[key],
              let bytes = Data(base64Encoded: encoded),
              let text = String(data: bytes, encoding: .utf8)
        else { return nil }
        return text
    }
}

// MARK: - Cluster-scoped

/// A node as `kubectl` reports it. Distinct from `K8sNode`, which is a row of
/// the `container k8s list` table and carries the CLI's own columns.
struct K8sNodeObject: Decodable, Sendable, Hashable, Identifiable {
    let metadata: K8sMetadata
    let status: Status?

    var id: String { metadata.name }

    struct Status: Decodable, Sendable, Hashable {
        let capacity: [String: String]?
        let allocatable: [String: String]?
        let conditions: [Condition]?
        let nodeInfo: NodeInfo?

        struct Condition: Decodable, Sendable, Hashable {
            let type: String
            let status: String
        }

        struct NodeInfo: Decodable, Sendable, Hashable {
            let kubeletVersion: String?
            let osImage: String?
            let architecture: String?
            let containerRuntimeVersion: String?
        }
    }

    var kubeletVersion: String? { status?.nodeInfo?.kubeletVersion }

    var isReady: Bool {
        status?.conditions?.contains { $0.type == "Ready" && $0.status == "True" } ?? false
    }

    var capacityCPU: String? { status?.capacity?["cpu"] }
    var capacityMemory: String? { status?.capacity?["memory"] }
}

struct K8sNamespace: Decodable, Sendable, Hashable, Identifiable {
    let metadata: K8sMetadata
    let status: Status?

    var id: String { metadata.name }

    struct Status: Decodable, Sendable, Hashable {
        let phase: String?
    }

    var phase: String? { status?.phase }
}
