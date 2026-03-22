import AVFoundation

protocol DeviceDiscoveryServiceProtocol {
    func discoverVideoDevices() -> [CameraDevice]
}

final class DeviceDiscoveryService: DeviceDiscoveryServiceProtocol {
    func discoverVideoDevices() -> [CameraDevice] {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("Camera authorization status:", status.rawValue)

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external
            ],
            mediaType: .video,
            position: .unspecified
        )

        let devices = discoverySession.devices
        print("Discovered video devices:", devices.map { $0.localizedName })

        if let defaultDevice = AVCaptureDevice.default(for: .video) {
            print("Default video device:", defaultDevice.localizedName)
        } else {
            print("Default video device: nil")
        }

        return devices.map { CameraDevice(device: $0) }
    }
}
