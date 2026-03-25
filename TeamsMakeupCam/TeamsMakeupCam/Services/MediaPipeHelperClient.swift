import AVFoundation
import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation


<<<<<<< HEAD
final class MediaPipeHelperClient {
    private let session: URLSession
    private let endpoint = URL(string: "http://127.0.0.1:9001/v1/face_landmarks")!

    init(session: URLSession = .shared) {
        self.session = session
=======
    struct Configuration {
        var endpoint: URL = URL(string: "http://127.0.0.1:9001/v1/face_landmarks")!
        /// JPEG quality 0...1. Lower reduces latency.
        var jpegQuality: CGFloat = 0.65
        /// Optional request timeout. 1 s gives the sidecar room to respond
        /// without causing visible lag on the 30-fps camera feed.
        var timeout: TimeInterval = 1.0
>>>>>>> 980b9c8 (Fix automatic sidecar launch so app works without Terminal)
    }

    enum ClientError: Error {
        case imageBufferMissing
        case jpegEncodingFailed
        case invalidResponse
        case serverError(String)
        case decodingFailed
    }

    func fetchLandmarks(
        sampleBuffer: CMSampleBuffer,
        completion: @escaping (Result<FaceLandmarks, Error>) -> Void
    ) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            completion(.failure(ClientError.imageBufferMissing))
            return
        }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            completion(.failure(ClientError.jpegEncodingFailed))
            return
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [:]) else {
            completion(.failure(ClientError.jpegEncodingFailed))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegData

        session.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let data else {
                completion(.failure(ClientError.invalidResponse))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMessage = json["error"] as? String {
                    completion(.failure(ClientError.serverError(errorMessage)))
                    return
                }

                let decoded = try JSONDecoder().decode(FaceLandmarks.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(ClientError.decodingFailed))
            }
        }.resume()
    }
}
