import Foundation
import CoreMediaIO

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {

    var device: CMIOExtensionDevice!
    var streamSource: CameraStreamSource!

    override init() {
        super.init()

        let localizedName = "TeamsMakeupCam"
        streamSource = CameraStreamSource()

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: UUID(),
            legacyDeviceID: nil,
            source: self
        )

        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("CameraDeviceSource: failed to add stream: \(error)")
        }
    }

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

    func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
}
