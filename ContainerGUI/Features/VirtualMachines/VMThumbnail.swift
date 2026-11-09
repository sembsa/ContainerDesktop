import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The small picture of a machine's screen on its card: grabbed over VNC while
/// it runs, kept as `thumbnail.png` so a stopped machine still shows its last one.
enum VMThumbnail {
    static let fileName = "thumbnail.png"
    static let width = 480

    static func url(in directory: URL) -> URL { directory.appending(path: fileName) }

    static func load(from directory: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(in: directory) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Connects, takes the first full frame, disconnects, and writes it scaled
    /// down. Gives up after `timeout`: a hung handshake must not stall the loop.
    static func capture(port: UInt16, password: String, into directory: URL,
                        timeout: Duration = .seconds(5)) async throws {
        let client = RFBClient(port: port, password: password)
        await client.start()
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            await client.stop()
        }
        defer {
            watchdog.cancel()
            Task { await client.stop() }
        }
        for await event in client.events {
            switch event {
            case .frame(let frame):
                let image = scaled(frame.image, toWidth: width) ?? frame.image
                try write(image, to: url(in: directory))
                return
            case .disconnected(let reason):
                throw RFBClient.Failure.protocolError(reason ?? RFBClient.Failure.closed.localizedDescription)
            case .connected:
                continue
            }
        }
        throw RFBClient.Failure.closed
    }

    /// Keeps the aspect ratio; never scales up.
    static func scaled(_ image: CGImage, toWidth width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = max(1, image.height * width / image.width)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".\(fileName).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        // rename(2) replaces atomically, so a card never reads half a PNG.
        guard rename(temp.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
