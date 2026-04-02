import AVFoundation
import CoreImage
import CoreMedia

/// Delegate that receives updated landmarks and the processed preview frame
/// (with skin smoothing applied when a face is detected).
protocol VideoFrameProcessorDelegate: AnyObject {
    func videoFrameProcessor(_ processor: VideoFrameProcessor, didUpdate landmarks: [FaceLandmarks], processedFrame: CIImage?)
}

/// Simple protocol for a video frame processing pipeline.
protocol VideoFrameProcessorProtocol: AnyObject {
    func process(sampleBuffer: CMSampleBuffer)
}

/// Receives sample buffers from CameraManager, runs MediaPipe-based face landmark
/// detection via a local helper, composites makeup into actual pixels for the HTTP
/// virtual camera, and publishes landmarks + processed frames for the live preview.
///
/// ## Pipeline guarantee
///
/// Every camera frame that enters `process(sampleBuffer:)` is composited with the
/// most-recent detected landmarks and pushed to `SharedFrameProvider`.  Raw /
/// un-makeup'd frames **never** reach the HTTP server once a face has been detected.
///
/// ```
/// Camera Frame
///   -> Skin Smoothing (cached contour)
///   -> OffscreenMakeupCompositor (cached landmarks + current settings)
///   -> SharedFrameProvider -> HTTP Server
///
/// Async (non-blocking):
///   Camera Frame -> MediaPipe -> update cached landmarks
/// ```
final class VideoFrameProcessor: NSObject, VideoFrameProcessorProtocol, CameraManagerSampleBufferDelegate {

    weak var delegate: VideoFrameProcessorDelegate?

    /// Current makeup settings.  Thread-safe — protected by `settingsLock`.
    /// Written from the main thread (Combine sink in StudioViewModel),
    /// read on the processing queue.
    var currentMakeupSettings: MakeupSettings {
        get { settingsLock.withLock { _settings } }
        set { settingsLock.withLock { _settings = newValue } }
    }

    // MARK: - Private state

    private let processingQueue = DispatchQueue(label: "TeamsMakeupCam.VideoProcessingQueue", qos: .userInitiated)
    private let faceLandmarkService: FaceLandmarkServiceProtocol
    private let skinSmoothingRenderer = SkinSmoothingRenderer()
    private let compositor = OffscreenMakeupCompositor()

    /// Thread-safe settings storage.
    private var _settings = MakeupSettings()
    private let settingsLock = NSLock()

    /// Most-recent successfully-detected landmarks.
    /// Accessed ONLY on `processingQueue` — no lock needed.
    private var cachedLandmarks: [FaceLandmarks] = []

    /// Gate: only one landmark request in flight at a time.
    /// Accessed ONLY on `processingQueue`.
    private var isDetectingLandmarks = false

    private var frameCount: Int = 0

    // MARK: - Init

    init(faceLandmarkService: FaceLandmarkServiceProtocol? = nil) {
        // Use a dedicated background queue for landmark callbacks so we never
        // block the main thread with compositing work.
        let cbQueue = DispatchQueue(label: "TeamsMakeupCam.LandmarkCallback", qos: .userInitiated)
        self.faceLandmarkService = faceLandmarkService
            ?? FaceLandmarkService(callbackQueue: cbQueue)
        super.init()
    }

    // MARK: - CameraManagerSampleBufferDelegate

    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        process(sampleBuffer: sampleBuffer)
    }

    // MARK: - VideoFrameProcessorProtocol

    func process(sampleBuffer: CMSampleBuffer) {
        processingQueue.async { [weak self] in
            guard let self else { return }

            self.frameCount += 1
            if self.frameCount % 90 == 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                print("VideoFrameProcessor: frame #\(self.frameCount) pts=\(CMTimeGetSeconds(pts))s  landmarks=\(self.cachedLandmarks.count)")
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let settings = self.currentMakeupSettings
            let landmarks = self.cachedLandmarks

            // ── 1. Skin smoothing (using cached face contour) ──────────────
            let smoothed: CIImage
            if let contour = landmarks.first?.faceContour, !contour.isEmpty {
                smoothed = self.skinSmoothingRenderer.smoothImage(
                    sourceImage,
                    faceContour: contour,
                    strength: settings.smoothingStrength
                )
            } else {
                smoothed = sourceImage
            }

            // ── 2. Composite makeup → push to HTTP server ─────────────────
            // This runs on EVERY frame using cached landmarks, so the HTTP
            // stream always shows makeup (never raw camera).
            if let jpegData = self.compositor.composite(
                baseImage: smoothed,
                landmarks: landmarks,
                settings: settings
            ) {
                SharedFrameProvider.shared.update(jpegData)
            }

            // ── 3. Kick off async landmark detection (non-blocking) ───────
            // The preview delegate is notified only when fresh landmarks
            // arrive (not on every frame) to avoid flooding the main thread.
            // The preview's AVCaptureVideoPreviewLayer provides live video
            // independently; only the CAShapeLayer overlays need landmarks.
            if !self.isDetectingLandmarks {
                self.isDetectingLandmarks = true

                // Capture the smoothed frame for the delegate callback.
                let frameForPreview = smoothed

                self.faceLandmarkService.process(sampleBuffer: sampleBuffer) { [weak self] face in
                    guard let self else { return }
                    self.processingQueue.async {
                        // Only update cache when we get a real detection.
                        // On failure (nil), keep last good landmarks so
                        // makeup doesn't vanish between detections.
                        if let face {
                            self.cachedLandmarks = [face]
                        }
                        self.isDetectingLandmarks = false

                        // Notify preview delegate with latest landmarks.
                        self.delegate?.videoFrameProcessor(
                            self,
                            didUpdate: self.cachedLandmarks,
                            processedFrame: frameForPreview
                        )
                    }
                }
            }
        }
    }
}
