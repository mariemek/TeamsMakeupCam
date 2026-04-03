import Foundation
import CoreVideo

/// Reads composited JPEG frames from the App Group shared container,
/// decodes them into CVPixelBuffers for the camera stream.
///
/// The host app writes frames as raw JPEG files to:
///   <AppGroupContainer>/CameraFrame/latest.jpg
///
/// A monotonic counter file tracks freshness:
///   <AppGroupContainer>/CameraFrame/counter
final class SharedFrameReader {

    private let containerURL: URL?
    private var lastCounter: UInt64 = 0
    private var cachedPixelBuffer: CVPixelBuffer?

    /// App Group identifier — must match host app and extension entitlements.
    static let appGroupID = "group.com.teamsmakeupcam.shared"

    init() {
        containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        )
        if containerURL == nil {
            NSLog("SharedFrameReader: App Group container not available. Frames will not be received.")
        }
    }

    /// Read the latest JPEG frame and decode it to a CVPixelBuffer.
    /// Returns nil if no new frame is available or the App Group is inaccessible.
    func readLatestFrame(width: Int, height: Int) -> CVPixelBuffer? {
        guard let container = containerURL else { return nil }

        let frameDir = container.appendingPathComponent("CameraFrame")
        let counterURL = frameDir.appendingPathComponent("counter")
        let jpegURL = frameDir.appendingPathComponent("latest.jpg")

        // Check counter for freshness
        if let counterData = try? Data(contentsOf: counterURL),
           counterData.count >= 8
        {
            let counter = counterData.withUnsafeBytes { $0.load(as: UInt64.self) }
            if counter == lastCounter, let cached = cachedPixelBuffer {
                return cached
            }
            lastCounter = counter
        }

        // Read JPEG
        guard let jpegData = try? Data(contentsOf: jpegURL) else { return nil }

        // Decode JPEG → CGImage → CVPixelBuffer
        guard let provider = CGDataProvider(data: jpegData as CFData),
              let cgImage = CGImage(
                  jpegDataProviderSource: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }

        let pixelBuffer = createPixelBuffer(from: cgImage, width: width, height: height)
        cachedPixelBuffer = pixelBuffer
        return pixelBuffer
    }

    private func createPixelBuffer(from cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                        CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
