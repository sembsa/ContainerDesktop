import Foundation
import CommonCrypto
import CoreGraphics

/// The pure half of the RFB (VNC) protocol: message encoding, VNC authentication
/// and the framebuffer the server paints into. No I/O here, so it can be tested
/// with canned bytes — `RFBClient` does the talking.
///
/// Only what a localhost viewer needs: Raw and CopyRect pixels plus the
/// DesktopSize pseudo-encoding (Windows changes resolution mid-session). No
/// compression, because the server is on the same machine.
enum RFB {

    static let version = Array("RFB 003.008\n".utf8)

    enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case desktopSize = -223
    }

    /// VNC authentication: DES-encrypt the 16-byte challenge with the password as
    /// the key — and with every key byte's bits reversed, a quirk of the original
    /// implementation that every server still expects. Only the first eight
    /// characters count.
    static func vncAuthResponse(challenge: [UInt8], password: String) -> [UInt8] {
        var key = Array(password.utf8.prefix(8))
        key += [UInt8](repeating: 0, count: 8 - key.count)
        key = key.map { byte in
            (0..<8).reduce(UInt8(0)) { reversed, bit in
                byte & (1 << bit) != 0 ? reversed | (1 << (7 - bit)) : reversed
            }
        }
        var out = [UInt8](repeating: 0, count: challenge.count)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
            key, 8, nil, challenge, challenge.count, &out, out.count, &moved
        )
        precondition(status == kCCSuccess, "DES with a fixed-size key cannot fail")
        return out
    }

    /// 32 bits per pixel, little-endian BGRX — exactly what `CGImage` reads with
    /// `byteOrder32Little | noneSkipFirst`, so pixels are never converted.
    static let setPixelFormat: [UInt8] =
        [0, 0, 0, 0] + [32, 24, 0, 1] + be16(255) + be16(255) + be16(255) + [16, 8, 0] + [0, 0, 0]

    static let setEncodings: [UInt8] = {
        let encodings: [Encoding] = [.copyRect, .raw, .desktopSize]
        return [2, 0] + be16(encodings.count) + encodings.flatMap { be32(UInt32(bitPattern: $0.rawValue)) }
    }()

    static func updateRequest(incremental: Bool, width: Int, height: Int) -> [UInt8] {
        [3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(width) + be16(height)
    }

    static func keyEvent(keysym: UInt32, down: Bool) -> [UInt8] {
        [4, down ? 1 : 0, 0, 0] + be32(keysym)
    }

    /// `buttons` is a mask: bit 0 left, 1 middle, 2 right, 3/4 wheel up/down.
    static func pointerEvent(buttons: UInt8, x: Int, y: Int) -> [UInt8] {
        [5, buttons] + be16(max(0, x)) + be16(max(0, y))
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }
    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

/// The remote screen, 4 bytes per pixel in the format `RFB.setPixelFormat` asks for.
///
/// Rectangles that reach outside the buffer are clipped rather than trusted: a
/// server that sends a bad rectangle should cost a garbled frame, not a crash.
struct RFBFramebuffer {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    mutating func resize(width: Int, height: Int) {
        self = RFBFramebuffer(width: width, height: height)
    }

    /// `data` is `w * h * 4` bytes, row by row.
    mutating func applyRaw(x: Int, y: Int, w: Int, h: Int, data: [UInt8]) {
        guard data.count >= w * h * 4 else { return }
        let cols = min(w, width - x)
        guard x >= 0, y >= 0, cols > 0 else { return }
        for row in 0..<min(h, height - y) {
            let src = row * w * 4
            let dst = ((y + row) * width + x) * 4
            pixels.replaceSubrange(dst ..< dst + cols * 4, with: data[src ..< src + cols * 4])
        }
    }

    mutating func copyRect(fromX sx: Int, fromY sy: Int, x: Int, y: Int, w: Int, h: Int) {
        guard sx >= 0, sy >= 0, x >= 0, y >= 0,
              sx + w <= width, sy + h <= height, x + w <= width, y + h <= height else { return }
        let source = pixels
        // Rows are copied from a snapshot, so overlapping source and target are safe.
        for row in 0..<h {
            let src = ((sy + row) * width + sx) * 4
            let dst = ((y + row) * width + x) * 4
            pixels.replaceSubrange(dst ..< dst + w * 4, with: source[src ..< src + w * 4])
        }
    }

    func makeImage() -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
