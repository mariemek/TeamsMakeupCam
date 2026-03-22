import AVFoundation

protocol CameraManagerDelegate: AnyObject {
    func cameraManagerDidStartSession(_ manager: CameraManager)
    func cameraManagerDidStopSession(_ manager: CameraManager)
    func cameraManager(_ manager: CameraManager, didFailWith error: Error)
}

protocol CameraManagerSampleBufferDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer)
}

final class CameraManager: NSObject {
    enum CameraError: Error {
        case configurationFailed
        case noInputDevice
    }

    weak var delegate: CameraManagerDelegate?
    weak var sampleBufferDelegate: CameraManagerSampleBufferDelegate?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "TeamsMakeupCam.CameraSessionQueue")
    private let videoOutputQueue = DispatchQueue(label: "TeamsMakeupCam.VideoOutputQueue")
    private let videoOutput = AVCaptureVideoDataOutput()

    var captureSession: AVCaptureSession {
        session
    }

    override init() {
        super.init()
        session.sessionPreset = .high
    }

    func configureSession(with cameraDevice: CameraDevice?, completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            for input in self.session.inputs {
                self.session.removeInput(input)
            }

            for output in self.session.outputs {
                self.session.removeOutput(output)
            }

            guard let device = cameraDevice?.device else {
                DispatchQueue.main.async {
                    self.delegate?.cameraManager(self, didFailWith: CameraError.noInputDevice)
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    throw CameraError.configurationFailed
                }
                self.session.addInput(input)
                self.configureVideoOutput()
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.cameraManager(self, didFailWith: error)
                }
                return
            }

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    private func configureVideoOutput() {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }

            self.session.startRunning()
            DispatchQueue.main.async {
                self.delegate?.cameraManagerDidStartSession(self)
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }

            self.session.stopRunning()
            DispatchQueue.main.async {
                self.delegate?.cameraManagerDidStopSession(self)
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sampleBufferDelegate?.cameraManager(self, didOutput: sampleBuffer)
    }
}
