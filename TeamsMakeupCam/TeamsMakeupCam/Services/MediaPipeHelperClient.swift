import AVFoundation
import Foundation
import AppKit
import CoreGraphics
import CoreImage

final class MediaPipeHelperClient {
    private let session: URLSession
    private let endpoint = URL(string: "http://127.0.0.1:9001/v1/face_landmarks")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum ClientError: Error, LocalizedError {
        case imageBufferMissing
        case jpegEncodingFailed
        case invalidResponse
        case serverError(String)
        case decodingFailed
        case helperUnavailable

        var errorDescription: String? {
            switch self {
            case .imageBufferMissing:
                return "image buffer missing"
            case .jpegEncodingFailed:
                return "jpeg encoding failed"
            case .invalidResponse:
                return "invalid response"
            case .serverError(let message):
                return "server error: \(message)"
            case .decodingFailed:
                return "decoding failed"
            case .helperUnavailable:
                return "mediapipe helper unavailable"
            }
        }
    }

    func fetchLandmarks(
        sampleBuffer: CMSampleBuffer,
        completion: @escaping (Result<FaceLandmarks, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            SidecarLauncher.shared.start()

            guard SidecarLauncher.shared.waitUntilHealthy(timeout: 5.0) else {
                completion(.failure(ClientError.helperUnavailable))
                return
            }

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
            guard let jpegData = bitmapRep.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.65]
            ) else {
                completion(.failure(ClientError.jpegEncodingFailed))
                return
            }

            self.sendRequest(jpegData: jpegData, remainingAttempts: 2, completion: completion)
        }
    }

    private func sendRequest(
        jpegData: Data,
        remainingAttempts: Int,
        completion: @escaping (Result<FaceLandmarks, Error>) -> Void
    ) {
        var request = URLRequest(url: endpoint, timeoutInterval: 1.5)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegData

        session.dataTask(with: request) { data, _, error in
            if let error {
                if remainingAttempts > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                        self.sendRequest(
                            jpegData: jpegData,
                            remainingAttempts: remainingAttempts - 1,
                            completion: completion
                        )
                    }
                } else {
                    completion(.failure(error))
                }
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
