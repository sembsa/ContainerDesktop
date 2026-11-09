import Darwin
import Foundation

/// One newline-delimited JSON connection to a QEMU Unix socket (QMP or the
/// guest agent).
///
/// I/O is blocking but runs on the connection's own serial queue, never on the
/// Swift cooperative pool; `transact` hands a whole request/response exchange
/// to that queue, so two callers can never interleave inside one.
final class QEMUSocket: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case connect(String, Int32)
        case closed
        case timeout
        case protocolError(String)
        case qemu(String)

        var errorDescription: String? {
            switch self {
            case .connect(let path, let code):
                String(format: String(localized: "Nie można połączyć się z %@ (%@)."),
                       path, String(cString: strerror(code)))
            case .closed: String(localized: "QEMU zamknęło połączenie.")
            case .timeout: String(localized: "QEMU nie odpowiedziało na czas.")
            case .protocolError(let detail): detail
            case .qemu(let message): message
            }
        }
    }

    let path: String
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var buffer = Data()

    /// Runs once per new connection, inside the first `transact` — QMP reads
    /// its greeting there, the guest agent resynchronises.
    private let onConnect: @Sendable (QEMUSocket) throws -> Void

    init(path: String, onConnect: @escaping @Sendable (QEMUSocket) throws -> Void) {
        self.path = path
        self.onConnect = onConnect
        queue = DispatchQueue(label: "qemu-socket")
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    /// Runs `body` on the connection's queue, connecting first if needed. Any
    /// failure drops the connection: whatever the other side still sends for a
    /// request that timed out must not be read as the answer to the next one.
    func transact<T: Sendable>(_ body: @escaping @Sendable (QEMUSocket) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.fd < 0 { try self.open() }
                    continuation.resume(returning: try body(self))
                } catch {
                    self.disconnect()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.disconnect()
                continuation.resume()
            }
        }
    }

    // MARK: - On the queue only

    private func open() throws {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw Failure.connect(path, errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketFD)
            throw Failure.connect(path, ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw Failure.connect(path, code)
        }
        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        fd = socketFD
        buffer.removeAll()
        try onConnect(self)
    }

    private func disconnect() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        buffer.removeAll()
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw Failure.closed }
                offset += written
            }
        }
    }

    /// Writes raw bytes — the guest agent's resync marker is not JSON.
    func sendRaw(_ bytes: [UInt8]) throws {
        guard Darwin.write(fd, bytes, bytes.count) == bytes.count else { throw Failure.closed }
    }

    /// The next JSON object, waiting at most `timeout`. Lines that are not a
    /// JSON object (the agent's 0xFF resync byte, blank lines) are skipped.
    func receive(timeout: Duration) throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<newline]
                // The agent's delimiter: whatever came before it is a stale half-reply.
                if let marker = line.lastIndex(of: 0xFF) { line = line[line.index(after: marker)...] }
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    return object
                }
                continue
            }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw Failure.timeout }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let millis = Int32(min(Double(remaining.components.seconds) * 1000
                                   + Double(remaining.components.attoseconds) / 1e15 + 1, 60_000))
            let ready = poll(&poller, 1, millis)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { throw Failure.closed }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// Sends one command and returns its `return` value, skipping the async
    /// events QMP interleaves with replies.
    func execute(_ command: String, _ arguments: [String: Any]? = nil,
                 timeout: Duration = .seconds(10)) throws -> Any {
        var request: [String: Any] = ["execute": command]
        if let arguments { request["arguments"] = arguments }
        try send(request)
        while true {
            let reply = try receive(timeout: timeout)
            if reply["event"] != nil { continue }
            if let error = reply["error"] as? [String: Any] {
                throw Failure.qemu(error["desc"] as? String ?? "\(error)")
            }
            if let value = reply["return"] { return value }
        }
    }
}
