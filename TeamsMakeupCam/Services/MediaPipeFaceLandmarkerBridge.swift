import AVFoundation
import CoreGraphics
import Vision

/// Abstracts MediaPipe Face Landmarker access away from the UI layer.
/// On macOS there is no first-class Swift MediaPipe Tasks API today, so this
/// bridge is designed to be backed either by:
/// - a local C/C++ wrapper around MediaPipe built as a .xcframework and exposed
///   via a C header, or
/// - a lightweight sidecar process (for example a Python service using
///   `mediapipe-tasks`) that receives frames and returns landmark JSON.
///
/// The rest of the app should depend only on this protocol, not on Vision or
/// MediaPipe directly.
protocol MediaPipeFaceLandmarker {
    /// Performs landmark detection on the given pixel buffer and returns
    /// a single face's landmarks in normalized [0, 1] coordinates, or nil.
    func detect(in pixelBuffer: CVPixelBuffer, completion: @escaping (FaceLandmarks?) -> Void)
}

/// Default implementation used for now: this still uses Apple's Vision under
/// the hood, but conforms to `MediaPipeFaceLandmarker` so we can swap in a
/// real MediaPipe-backed implementation later without touching renderers or
/// view models.
///
/// To integrate MediaPipe natively you would:
/// - Replace the body of `detect(in:completion:)` with a call into your C/C++
///   or Python bridge that runs MediaPipe Face Landmarker and maps its 3D
///   landmarks into this app's `FaceLandmarks` struct.
final class VisionBackedFaceLandmarker: MediaPipeFaceLandmarker {

    private let visionQueue = DispatchQueue(label: "TeamsMakeupCam.VisionBackedFaceLandmarkerQueue")
    private let sequenceHandler = VNSequenceRequestHandler()

    func detect(in pixelBuffer: CVPixelBuffer, completion: @escaping (FaceLandmarks?) -> Void) {
        let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let self else { return }

            if let error {
                print("VisionBackedFaceLandmarker: Vision error: \(error)")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let observations = request.results as? [VNFaceObservation],
                  let face = observations.first else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let landmarks = self.convert(observation: face)
            DispatchQueue.main.async {
                completion(landmarks)
            }
        }

        visionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.sequenceHandler.perform(
                    [request],
                    on: pixelBuffer,
                    orientation: .up
                )
            } catch {
                print("VisionBackedFaceLandmarker: Failed to perform request: \(error)")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Conversion Helpers

    private func convert(observation: VNFaceObservation) -> FaceLandmarks {
        var result = FaceLandmarks()

        let bbox = observation.boundingBox
        result.boundingBox = bbox

        if let lips = observation.landmarks?.outerLips {
            result.outerLips = convert(points: lips.normalizedPoints, in: bbox)
        }

        if let inner = observation.landmarks?.innerLips {
            result.innerLips = convert(points: inner.normalizedPoints, in: bbox)
        }

        if let leftBrow = observation.landmarks?.leftEyebrow {
            result.leftEyebrow = convert(points: leftBrow.normalizedPoints, in: bbox)
        }

        if let rightBrow = observation.landmarks?.rightEyebrow {
            result.rightEyebrow = convert(points: rightBrow.normalizedPoints, in: bbox)
        }

        if let leftEye = observation.landmarks?.leftEye {
            result.leftEye = convert(points: leftEye.normalizedPoints, in: bbox)
        }

        if let rightEye = observation.landmarks?.rightEye {
            result.rightEye = convert(points: rightEye.normalizedPoints, in: bbox)
        }

        if let contour = observation.landmarks?.faceContour {
            result.faceContour = convert(points: contour.normalizedPoints, in: bbox)
        }

        return result
    }

    /// Convert Vision landmark points from face-local normalized coordinates
    /// into full-image normalized coordinates.
    private func convert(points: [CGPoint], in boundingBox: CGRect) -> [CGPoint] {
        return points.map { p in
            let x = boundingBox.origin.x + p.x * boundingBox.size.width
            let y = boundingBox.origin.y + p.y * boundingBox.size.height
            return CGPoint(x: x, y: y)
        }
    }
}

