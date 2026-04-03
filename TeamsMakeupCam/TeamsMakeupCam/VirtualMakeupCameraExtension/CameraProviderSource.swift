import Foundation
import CoreMediaIO

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {

    var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()

        deviceSource = CameraDeviceSource()

        provider = CMIOExtensionProvider(
            source: self,
            clientQueue: clientQueue
        )

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("CameraProviderSource: failed to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties
    {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            props.manufacturer = "TeamsMakeupCam"
        }
        return props
    }

    func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}
}
