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

/// Receives sample buffers from CameraManager, runs MediaPipe-based face landmark detection
/// via a local helper, applies lightweight processing (e.g. smoothing), and publishes
/// landmarks + processed frames for Swift renderers to draw overlays.
final class VideoFrameProcessor: NSObject, VideoFrameProcessorProtocol, CameraManagerSampleBufferDelegate {

    weak var delegate: VideoFrameProcessorDelegate?

    /// Current settings (e.g. smoothing strength); set from main thread, read on processing queue.
    var currentMakeupSettings = MakeupSettings()

    private let processingQueue = DispatchQueue(label: "TeamsMakeupCam.VideoProcessingQueue")
    private let faceLandmarkService: FaceLandmarkServiceProtocol
    private let skinSmoothingRenderer = SkinSmoothingRenderer()

    private var frameCount: Int = 0
    /// Only one landmark request at a time to avoid lag, CPU spikes, and stale results.
    private var isProcessingLandmarks = false

    init(faceLandmarkService: FaceLandmarkServiceProtocol = FaceLandmarkService()) {
        self.faceLandmarkService = faceLandmarkService
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
            if self.frameCount % 30 == 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let timeSeconds = CMTimeGetSeconds(pts)
                print("VideoFrameProcessor: frame #\(self.frameCount) at \(timeSeconds)s")
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            guard !self.isProcessingLandmarks else { return }
            self.isProcessingLandmarks = true

            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)

            self.faceLandmarkService.process(sampleBuffer: sampleBuffer) { [weak self] face in
                guard let self else { return }

                let list: [FaceLandmarks] = face.map { [$0] } ?? []
                let settings = self.currentMakeupSettings

                let processed: CIImage
                if let contour = face?.faceContour, !contour.isEmpty {
                    processed = self.skinSmoothingRenderer.smoothImage(
                        sourceImage,
                        faceContour: contour,
                        strength: settings.smoothingStrength
                    )
                } else {
                    processed = sourceImage
                }

                // Reset flag and notify delegate on processingQueue so isProcessingLandmarks is thread-safe.
                self.processingQueue.async {
                    self.isProcessingLandmarks = false
                    self.delegate?.videoFrameProcessor(self, didUpdate: list, processedFrame: processed)
                }
            }
        }
    }
}

