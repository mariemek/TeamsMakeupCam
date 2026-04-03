import Foundation
import CoreMediaIO

/// Top-level CMIOExtension provider that owns a single virtual camera device.
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {

    let provider: CMIOExtensionProvider
    private let deviceSource: CameraDeviceSource

    init(clientQueue: DispatchQueue?) {
        provider = CMIOExtensionProvider(source: nil, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource()
        super.init()
        provider.source = self
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("CameraProviderSource: failed to add device: \(error)")
        }
    }

    // MARK: - CMIOExtensionProviderSource

    func connect(to client: CMIOExtensionClient) throws {
        // Accept all clients (Teams, Zoom, FaceTime, etc.)
    }

    func disconnect(from client: CMIOExtensionClient) {
        // No-op
    }

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

    func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {
        // Read-only
    }
}
