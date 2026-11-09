import Foundation
import Network
import CoreGraphics

/// A VNC session with one server: handshake, then a read loop that turns
/// framebuffer updates into images, while input is sent from any thread.
///
/// Each finished update yields one `CGImage` and immediately asks for the next
/// incremental one, so the server sets the pace — on an idle screen it sends
/// nothing at all.
actor RFBClient {

    enum Event: Sendable {
        case connected(width: Int, height: Int, name: String)
        case frame(Frame)
        case disconnected(String?)
    }

    /// `CGImage` is immutable once made; the wrapper only tells the compiler so.
    struct Frame: @unchecked Sendable { let image: CGImage }

    enum Failure: LocalizedError {
        case closed
        case authFailed(String)
        case unsupportedSecurity([UInt8])
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .closed: String(localized: "Serwer VNC zamknął połączenie.")
            case .authFailed(let reason):
                reason.isEmpty ? String(localized: "Błędne hasło VNC.") : reason
            case .unsupportedSecurity: String(localized: "Serwer VNC wymaga nieobsługiwanego uwierzytelniania.")
            case .protocolError(let detail): detail
            }
        }
    }

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let connection: NWConnection
    private let password: String
    private var inbox: [UInt8] = []
    private var framebuffer = RFBFramebuffer(width: 0, height: 0)
    private var finished = false

    init(host: String = "127.0.0.1", port: UInt16, password: String) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        self.password = password
    }

    func start() {
        Task { await run() }
    }

    func stop() {
        finish(nil)
    }

    // MARK: - Input (fire and forget)

    nonisolated func sendKey(_ keysym: UInt32, down: Bool) {
        send(RFB.keyEvent(keysym: keysym, down: down))
    }

    /// Presses the keys in order and releases them in reverse, like a person would.
    nonisolated func sendCombo(_ keysyms: [UInt32]) {
        keysyms.forEach { sendKey($0, down: true) }
        keysyms.reversed().forEach { sendKey($0, down: false) }
    }

    nonisolated func sendPointer(buttons: UInt8, x: Int, y: Int) {
        send(RFB.pointerEvent(buttons: buttons, x: x, y: y))
    }

    nonisolated private func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    // MARK: - Session

    private func run() async {
        do {
            try await waitUntilReady()
            try await handshake()
            continuation.yield(.connected(width: framebuffer.width, height: framebuffer.height, name: serverName))
            send(RFB.updateRequest(incremental: false, width: framebuffer.width, height: framebuffer.height))
            while !finished {
                try await readServerMessage()
            }
        } catch {
            finish((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private var serverName = ""

    private func handshake() async throws {
        let version = try await read(12)
        guard version.starts(with: Array("RFB ".utf8)) else {
            throw Failure.protocolError(String(localized: "To nie jest serwer VNC."))
        }
        send(RFB.version)

        let count = Int(try await read(1)[0])
        if count == 0 { throw Failure.authFailed(try await readReason()) }
        let types = try await read(count)
        if types.contains(2) {
            send([2])
            send(RFB.vncAuthResponse(challenge: try await read(16), password: password))
        } else if types.contains(1) {
            send([1])
        } else {
            throw Failure.unsupportedSecurity(types)
        }
        if RFB.u32(try await read(4), 0) != 0 { throw Failure.authFailed(try await readReason()) }

        send([1]) // ClientInit: shared, so the agent and this window can both be connected.
        let initMessage = try await read(24)
        framebuffer.resize(width: RFB.u16(initMessage, 0), height: RFB.u16(initMessage, 2))
        serverName = String(decoding: try await read(Int(RFB.u32(initMessage, 20))), as: UTF8.self)

        send(RFB.setPixelFormat)
        send(RFB.setEncodings)
    }

    private func readReason() async throws -> String {
        let length = Int(RFB.u32(try await read(4), 0))
        return String(decoding: try await read(length), as: UTF8.self)
    }

    private func readServerMessage() async throws {
        let type = try await read(1)[0]
        switch type {
        case 0: try await readFramebufferUpdate()
        case 1: // SetColourMapEntries — irrelevant with true colour, but must be consumed.
            let header = try await read(5)
            _ = try await read(RFB.u16(header, 3) * 6)
        case 2: break // Bell
        case 3: // ServerCutText
            let header = try await read(7)
            _ = try await read(Int(RFB.u32(header, 3)))
        default:
            throw Failure.protocolError(String(localized: "Serwer VNC wysłał nieznany komunikat."))
        }
    }

    private func readFramebufferUpdate() async throws {
        let header = try await read(3)
        for _ in 0..<RFB.u16(header, 1) {
            let rect = try await read(12)
            let x = RFB.u16(rect, 0), y = RFB.u16(rect, 2), w = RFB.u16(rect, 4), h = RFB.u16(rect, 6)
            switch RFB.Encoding(rawValue: Int32(bitPattern: RFB.u32(rect, 8))) {
            case .raw:
                framebuffer.applyRaw(x: x, y: y, w: w, h: h, data: try await read(w * h * 4))
            case .copyRect:
                let source = try await read(4)
                framebuffer.copyRect(fromX: RFB.u16(source, 0), fromY: RFB.u16(source, 2), x: x, y: y, w: w, h: h)
            case .desktopSize:
                framebuffer.resize(width: w, height: h)
                continuation.yield(.connected(width: w, height: h, name: serverName))
            case nil:
                throw Failure.protocolError(String(localized: "Serwer VNC użył nieobsługiwanego kodowania."))
            }
        }
        if let image = framebuffer.makeImage() { continuation.yield(.frame(Frame(image: image))) }
        send(RFB.updateRequest(incremental: true, width: framebuffer.width, height: framebuffer.height))
    }

    // MARK: - Transport

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(resume)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume()
                case .failed(let error), .waiting(let error): once.resume(throwing: error)
                case .cancelled: once.resume(throwing: Failure.closed)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInteractive))
        }
    }

    private func read(_ count: Int) async throws -> [UInt8] {
        while inbox.count < count {
            if finished { throw Failure.closed }
            inbox += try await receiveChunk()
        }
        let bytes = Array(inbox.prefix(count))
        inbox.removeFirst(count)
        return bytes
    }

    private func receiveChunk() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { resume in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error { resume.resume(throwing: error) }
                else if let data, !data.isEmpty { resume.resume(returning: [UInt8](data)) }
                else if isComplete { resume.resume(throwing: Failure.closed) }
                else { resume.resume(returning: []) }
            }
        }
    }

    private func finish(_ reason: String?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        continuation.yield(.disconnected(reason))
        continuation.finish()
    }
}

/// `stateUpdateHandler` fires repeatedly; a continuation must resume exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func resume(throwing error: Error? = nil) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
