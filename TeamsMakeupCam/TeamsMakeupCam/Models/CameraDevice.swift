import AVFoundation

struct CameraDevice: Identifiable, Equatable {
    let id: String
    let localizedName: String
    let position: AVCaptureDevice.Position
    let device: AVCaptureDevice

    init(device: AVCaptureDevice) {
        self.id = device.uniqueID
        self.localizedName = device.localizedName
        self.position = device.position
        self.device = device
    }

    static func == (lhs: CameraDevice, rhs: CameraDevice) -> Bool {
        lhs.id == rhs.id
    }
}
