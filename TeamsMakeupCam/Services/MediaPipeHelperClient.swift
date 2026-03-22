import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// Client for a local MediaPipe helper/sidecar process.
///
/// Design goal:
/// - Keep the macOS SwiftUI app native and lightweight.
/// - Offload MediaPipe (Python/C++/anything) into a localhost helper that returns JSON landmarks.
///
/// Expected helper contract (placeholder; implement your helper to match):
/// - Request: HTTP POST `http://127.0.0.1:8765/v1/face_landmarks`
///   - Headers: `Content-Type: image/jpeg`
///   - Body: JPEG bytes for the current frame (RGB/BGR is fine; helper decides)
/// - Response: JSON with normalized points in [0,1], origin bottom-left:
///   {
///     "outerLips": [[x,y], ...],
///     "innerLips": [[x,y], ...],
///     "leftEye": [[x,y], ...],
///     "rightEye": [[x,y], ...],
///     "leftEyebrow": [[x,y], ...],
///     "rightEyebrow": [[x,y], ...],
///     "faceContour": [[x,y], ...]
///   }
final class MediaPipeHelperClient {

    struct Configuration {
        var endpoint: URL = URL(string: "http://127.0.0.1:9001/v1/face_landmarks")!
        /// JPEG quality 0...1. Lower reduces latency.
        var jpegQuality: CGFloat = 0.65
        /// Optional request timeout.
        var timeout: TimeInterval = 0.25
    }

    enum ClientError: Error {
        case jpegEncodingFailed
        case invalidResponse
        case httpError(status: Int, body: Data?)
        case decodeFailed
    }

    private let config: Configuration
    private let session: URLSession
    private let ciContext: CIContext

    init(config: Configuration = Configuration()) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.timeout
        configuration.timeoutIntervalForResource = config.timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }

    func fetchLandmarks(
        sampleBuffer: CMSampleBuffer,
        completion: @escaping (Result<FaceLandmarks?, Error>) -> Void
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            completion(.success(nil))
            return
        }

        guard let jpeg = makeJPEG(from: pixelBuffer, quality: config.jpegQuality) else {
            completion(.failure(ClientError.jpegEncodingFailed))
            return
        }

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.httpBody = jpeg
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(ClientError.invalidResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(ClientError.httpError(status: http.statusCode, body: data)))
                return
            }

            guard let data else {
                completion(.success(nil))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)
                completion(.success(decoded.toFaceLandmarks()))
            } catch {
                completion(.failure(ClientError.decodeFailed))
            }
        }
        task.resume()
    }

    // MARK: - JPEG encoding

    private func makeJPEG(from pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return nil }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        let props: [NSBitmapImageRep.PropertyKey: Any] = [
            .compressionFactor: max(0.0, min(quality, 1.0))
        ]
        return rep.representation(using: .jpeg, properties: props)
    }
}

// MARK: - Helper JSON schema

private struct HelperResponse: Decodable {
    var outerLips: [[CGFloat]]?
    var innerLips: [[CGFloat]]?
    var leftEye: [[CGFloat]]?
    var rightEye: [[CGFloat]]?
    var leftEyebrow: [[CGFloat]]?
    var rightEyebrow: [[CGFloat]]?
    var faceContour: [[CGFloat]]?

    func toFaceLandmarks() -> FaceLandmarks? {
        // If helper returns no face, it can respond with empty arrays or nulls.
        let anyNonEmpty =
            (outerLips?.isEmpty == false) ||
            (innerLips?.isEmpty == false) ||
            (leftEye?.isEmpty == false) ||
            (rightEye?.isEmpty == false) ||
            (leftEyebrow?.isEmpty == false) ||
            (rightEyebrow?.isEmpty == false) ||
            (faceContour?.isEmpty == false)

        guard anyNonEmpty else { return nil }

        var result = FaceLandmarks()
        result.outerLips = points(from: outerLips)
        result.innerLips = points(from: innerLips)
        result.leftEye = points(from: leftEye)
        result.rightEye = points(from: rightEye)
        result.leftEyebrow = points(from: leftEyebrow)
        result.rightEyebrow = points(from: rightEyebrow)
        result.faceContour = points(from: faceContour)

        // Compute a coarse bounding box from available points (normalized).
        let all = result.outerLips
            + result.innerLips
            + result.leftEye
            + result.rightEye
            + result.leftEyebrow
            + result.rightEyebrow
            + result.faceContour
        if let first = all.first {
            var minX = first.x, maxX = first.x
            var minY = first.y, maxY = first.y
            for p in all.dropFirst() {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            result.boundingBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        return result
    }

    private func points(from array: [[CGFloat]]?) -> [CGPoint] {
        guard let array else { return [] }
        return array.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            let x = max(0.0, min(pair[0], 1.0))
            let y = max(0.0, min(pair[1], 1.0))
            return CGPoint(x: x, y: y)
        }
    }
}

