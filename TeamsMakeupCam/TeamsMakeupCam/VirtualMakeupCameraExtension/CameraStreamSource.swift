import Foundation
import CoreMediaIO
import CoreVideo
import CoreMedia
import IOKit.audio

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {

    var stream: CMIOExtensionStream!

    private let frameWidth: Int32 = 1920
    private let frameHeight: Int32 = 1080
    private let frameRate: Float64 = 30.0

    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "CameraStream.timer")

    private let formatDescription: CMFormatDescription
    private let frameReader = SharedFrameReader()

    override init() {
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

        super.init()

        stream = CMIOExtensionStream(
            localizedName: "TeamsMakeupCam",
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        [
            CMIOExtensionStreamFormat(
                formatDescription: formatDescription,
                maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
                minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
                validFrameDurations: nil
            )
        ]
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

    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {}

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

    private func emitFrame() {
        var pixelBuffer = frameReader.readLatestFrame(
            width: Int(frameWidth),
            height: Int(frameHeight)
        )

        if pixelBuffer == nil {
            pixelBuffer = createPlaceholderBuffer()
        }

        guard let buffer = pixelBuffer else { return }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sbuf: CMSampleBuffer?
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
            hostTimeInNanoseconds: UInt64(
                timingInfo.presentationTimeStamp.seconds * 1_000_000_000
            )
        )
    }

    private func createPlaceholderBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(frameWidth),
            Int(frameHeight),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pb
        )

        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let base = CVPixelBufferGetBaseAddress(buffer)!
        let stride = CVPixelBufferGetBytesPerRow(buffer)

        for y in 0..<Int(frameHeight) {
            let row = base.advanced(by: y * stride)
            for x in 0..<Int(frameWidth) {
                let pixel = row.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = 40
                pixel[1] = 40
                pixel[2] = 40
                pixel[3] = 255
            }
        }

        return buffer
    }
}
