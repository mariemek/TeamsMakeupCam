import AVFoundation

protocol FaceLandmarkServiceProtocol: AnyObject {
    func process(sampleBuffer: CMSampleBuffer, completion: @escaping (FaceLandmarks?) -> Void)
}

final class FaceLandmarkService: FaceLandmarkServiceProtocol {

    private let client: MediaPipeHelperClient
    private let callbackQueue: DispatchQueue

    init(
        client: MediaPipeHelperClient = MediaPipeHelperClient(),
        callbackQueue: DispatchQueue = .main
    ) {
        self.client = client
        self.callbackQueue = callbackQueue
    }

    func process(sampleBuffer: CMSampleBuffer, completion: @escaping (FaceLandmarks?) -> Void) {
        client.fetchLandmarks(sampleBuffer: sampleBuffer) { [callbackQueue] result in
            callbackQueue.async {
                switch result {
                case .success(let landmarks):
                    completion(landmarks)
                case .failure(let error):
                    print("FaceLandmarkService: \(error)")
                    completion(nil)
                }
            }
        }
    }
}
