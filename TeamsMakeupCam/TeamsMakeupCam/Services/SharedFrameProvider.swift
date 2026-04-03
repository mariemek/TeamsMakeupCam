import Foundation

/// Thread-safe singleton that holds the latest composited JPEG frame.
///
/// Written by `VideoFrameProcessor` on its background queue,
/// read by `LocalVirtualCameraServer` on network threads.
final class SharedFrameProvider {

    static let shared = SharedFrameProvider()

    /// Posted (on an arbitrary queue) every time a new frame is stored.
    /// The `object` is the `Data` payload.
    static let newFrameNotification = Notification.Name("SharedFrameProvider.newFrame")

    private let queue = DispatchQueue(label: "SharedFrameProvider.queue")
    private var _jpegData: Data?
    private var _frameNumber: UInt64 = 0

    private init() {}

    /// The latest composited JPEG frame, or nil if no frame has been produced yet.
    var latestJPEG: Data? {
        queue.sync { _jpegData }
    }

    /// Monotonically increasing frame counter.  Useful for MJPEG clients to
    /// detect whether a new frame is available without copying the data.
    var frameNumber: UInt64 {
        queue.sync { _frameNumber }
    }

    /// Store a new composited frame, notify MJPEG clients,
    /// and write to App Group for the Camera Extension.
    func update(_ jpegData: Data) {
        queue.sync {
            _jpegData = jpegData
            _frameNumber += 1
        }
        // Notify on a global queue so we never block the caller.
        DispatchQueue.global(qos: .userInteractive).async {
            NotificationCenter.default.post(
                name: Self.newFrameNotification,
                object: jpegData
            )
        }
        // Write to App Group shared container for the Camera Extension process.
        SharedFrameWriter.shared.writeFrame(jpegData)
    }
}
