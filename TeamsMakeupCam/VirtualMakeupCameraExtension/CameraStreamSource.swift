import Foundation
import CoreMediaIO
import CoreVideo
import IOKit.audio

/// Output stream that delivers video frames to consuming apps.
///
/// Frames are read from a memory-mapped file written by the host app via App Group.
/// When no host frame is available, a solid-color placeholder is generated.
final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {

    let stream: CMIOExtensionStream

    private let frameWidth: Int32 = 1920
    private let frameHeight: Int32 = 1080
    private let frameRate: Float64 = 30.0

    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "CameraStream.timer", qos: .userInteractive)

    private var sequenceNumber: UInt64 = 0
    private let formatDescription: CMFormatDescription

    /// Shared frame reader for IPC with host app.
    private let frameReader = SharedFrameReader()

    override init() {
        // Create format description for 32BGRA
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: frameWidth,
            height: frameHeight,
            extensions: nil,
            formatDescriptionOut: &desc
        )
        formatDescription = desc!

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            validFrameDurations: nil
        )

        stream = CMIOExtensionStream(
            localizedName: "TeamsMakeupCam",
            streamID: UUID(),
            direction: .source,
            clockType: .hostTimeClock,
            source: nil
        )

        super.init()
        stream.source = self
    }

    // MARK: - CMIOExtensionStreamSource

    var formats: [CMIOExtensionStreamFormat] {
        let fmt = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            validFrameDurations: nil
        )
        return [fmt]
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        }
        return props
    }

    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        // Read-only
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        guard timer == nil else { return }

        let interval = 1.0 / frameRate
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            self?.emitFrame()
        }
        t.resume()
        timer = t
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Frame emission

    private func emitFrame() {
        var pixelBuffer: CVPixelBuffer?

        // Try to read a frame from the host app via shared memory
        if let hostFrame = frameReader.readLatestFrame(width: Int(frameWidth), height: Int(frameHeight)) {
            pixelBuffer = hostFrame
        }

        // Fallback: generate a solid dark-gray placeholder
        if pixelBuffer == nil {
            pixelBuffer = createPlaceholderBuffer()
        }

        guard let buffer = pixelBuffer else { return }

        var sbuf: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sbuf
        )

        guard let sampleBuffer = sbuf else { return }

        stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * 1_000_000_000)
        )

        sequenceNumber += 1
    }

    private func createPlaceholderBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(frameWidth),
            Int(frameHeight),
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let baseAddress = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // Fill with dark gray (BGRA: 40, 40, 40, 255)
        for y in 0..<Int(frameHeight) {
            let row = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<Int(frameWidth) {
                let pixel = row.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = 40   // B
                pixel[1] = 40   // G
                pixel[2] = 40   // R
                pixel[3] = 255  // A
            }
        }

        return buffer
    }
}
