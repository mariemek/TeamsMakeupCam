import Foundation
import AVFoundation
import CoreImage
import SwiftUI
import Combine

@MainActor
final class StudioViewModel: ObservableObject {
    @Published var availableCameras: [CameraDevice] = []
    @Published var selectedCamera: CameraDevice?
    @Published var isSessionRunning: Bool = false
    @Published var errorMessage: String?

    @Published var makeupSettings: MakeupSettings = .naturalPreset
    @Published var debugLandmarks: [FaceLandmarks] = []
    @Published var processedFrame: CIImage?

    private let deviceDiscoveryService: DeviceDiscoveryServiceProtocol
    private let cameraManager: CameraManager
    private let frameProcessor: VideoFrameProcessor

    var captureSession: AVCaptureSession {
        cameraManager.captureSession
    }

    init(
        deviceDiscoveryService: DeviceDiscoveryServiceProtocol = DeviceDiscoveryService(),
        cameraManager: CameraManager = CameraManager(),
        frameProcessor: VideoFrameProcessor = VideoFrameProcessor()
    ) {
        self.deviceDiscoveryService = deviceDiscoveryService
        self.cameraManager = cameraManager
        self.frameProcessor = frameProcessor

        self.cameraManager.delegate = self
        self.cameraManager.sampleBufferDelegate = frameProcessor
        self.frameProcessor.delegate = self
        self.frameProcessor.currentMakeupSettings = makeupSettings

        requestCameraAccessAndLoadDevices()
    }

    func requestCameraAccessAndLoadDevices() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            refreshCameras()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        self.refreshCameras()
                    } else {
                        self.errorMessage = "Camera access was denied."
                    }
                }
            }

        case .denied:
            errorMessage = "Camera access is denied. Please enable it in System Settings > Privacy & Security > Camera."

        case .restricted:
            errorMessage = "Camera access is restricted on this Mac."

        @unknown default:
            errorMessage = "Unknown camera authorization state."
        }
    }

    func refreshCameras() {
        let devices = deviceDiscoveryService.discoverVideoDevices()
        availableCameras = devices

        guard !devices.isEmpty else {
            selectedCamera = nil
            errorMessage = "No camera devices were found."
            return
        }

        if selectedCamera == nil || !devices.contains(where: { $0.id == selectedCamera?.id }) {
            selectedCamera = devices.first
        }

        configureSession()
    }

    func configureSession() {
        guard selectedCamera != nil else {
            errorMessage = "No camera selected."
            return
        }

        cameraManager.configureSession(with: selectedCamera) { [weak self] in
            guard let self else { return }
            self.startSession()
        }
    }

    func startSession() {
        cameraManager.startSession()
    }

    func stopSession() {
        cameraManager.stopSession()
    }

    func selectCamera(_ camera: CameraDevice) {
        selectedCamera = camera
        configureSession()
    }

    func applyNaturalPreset() {
        makeupSettings = .naturalPreset
        syncMakeupSettingsToProcessor()
    }

    func applySoftGlamPreset() {
        makeupSettings = .softGlamPreset
        syncMakeupSettingsToProcessor()
    }

    func applyPolishedPreset() {
        makeupSettings = .polishedPreset
        syncMakeupSettingsToProcessor()
    }

    func syncMakeupSettingsToProcessor() {
        frameProcessor.currentMakeupSettings = makeupSettings
    }
}

extension StudioViewModel: CameraManagerDelegate {
    nonisolated func cameraManagerDidStartSession(_ manager: CameraManager) {
        Task { @MainActor in
            self.isSessionRunning = true
        }
    }

    nonisolated func cameraManagerDidStopSession(_ manager: CameraManager) {
        Task { @MainActor in
            self.isSessionRunning = false
        }
    }

    nonisolated func cameraManager(_ manager: CameraManager, didFailWith error: Error) {
        Task { @MainActor in
            self.errorMessage = error.localizedDescription
        }
    }
}

extension StudioViewModel: VideoFrameProcessorDelegate {
    nonisolated func videoFrameProcessor(_ processor: VideoFrameProcessor, didUpdate landmarks: [FaceLandmarks], processedFrame: CIImage?) {
        Task { @MainActor in
            print("Landmarks array count:", landmarks.count)
            if let first = landmarks.first {
                print("outerLips:", first.outerLips.count)
                print("innerLips:", first.innerLips.count)
                print("leftEye:", first.leftEye.count)
                print("rightEye:", first.rightEye.count)
                print("leftEyebrow:", first.leftEyebrow.count)
                print("rightEyebrow:", first.rightEyebrow.count)
                print("faceContour:", first.faceContour.count)
            }
            self.debugLandmarks = landmarks
            self.processedFrame = processedFrame
        }
    
    }
}

