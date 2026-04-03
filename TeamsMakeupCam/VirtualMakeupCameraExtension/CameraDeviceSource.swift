import Foundation
import CoreMediaIO

/// A single virtual camera device with one output stream.
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {

    let device: CMIOExtensionDevice
    let streamSource: CameraStreamSource

    override init() {
        let localizedName = "TeamsMakeupCam"
        streamSource = CameraStreamSource()

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: UUID(),
            legacyDeviceID: nil,
            source: nil
        )

        super.init()
        device.source = self

        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("CameraDeviceSource: failed to add stream: \(error)")
        }
    }

    // MARK: - CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            props.model = "TeamsMakeupCam Virtual Camera"
        }
        return props
    }

    func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {
        // Read-only
    }
}
