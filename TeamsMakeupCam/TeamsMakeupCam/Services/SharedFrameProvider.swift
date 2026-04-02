import Foundation

/// Thread-safe singleton that holds the latest composited JPEG frame.
///
/// Written by `VideoFrameProcessor` on its background processing queue,
/// read by `LocalVirtualCameraServer` on network threads.
///
/// ## Invariant
///
/// The stored frame is **always** the fully-composited output (skin smoothing +
/// makeup applied).  Raw / un-processed frames are never stored here.
final class SharedFrameProvider {

    static let shared = SharedFrameProvider()

    /// Posted (on a global queue) every time a new frame is stored.
    /// The notification `object` is the JPEG `Data` payload.
    static let newFrameNotification = Notification.Name("SharedFrameProvider.newFrame")

    private let queue = DispatchQueue(label: "SharedFrameProvider.queue", qos: .userInteractive)
    private var _jpegData: Data?
    private var _frameNumber: UInt64 = 0

    private init() {}

    // MARK: - Read access (called from server / UI threads)

    /// The latest composited JPEG frame, or `nil` if no frame has been produced yet.
    var latestJPEG: Data? {
        queue.sync { _jpegData }
    }

    /// Monotonically increasing frame counter.
    var frameNumber: UInt64 {
        queue.sync { _frameNumber }
    }

    // MARK: - Write access (called from VideoFrameProcessor's processing queue)

    /// Store a new composited frame and notify all MJPEG clients.
    ///
    /// - Parameter jpegData: The JPEG-encoded composited frame.  Must already
    ///   contain all makeup overlays burned into the pixels.
    func update(_ jpegData: Data) {
        let frameNum: UInt64 = queue.sync {
            _jpegData = jpegData
            _frameNumber &+= 1
            return _frameNumber
        }
        // Post on a global queue so we never block the caller (VideoFrameProcessor).
        DispatchQueue.global(qos: .userInteractive).async {
            NotificationCenter.default.post(
                name: Self.newFrameNotification,
                object: jpegData,
                userInfo: ["frameNumber": frameNum]
            )
        }
    }
}
