import Foundation
import SystemExtensions
import os.log

/// Activates (installs) the Camera Extension via OSSystemExtensionManager.
///
/// Call `activate()` once on app launch. The OS will:
/// 1. Prompt the user to allow the extension (first time)
/// 2. Register it as a Camera Extension
/// 3. Make it appear in System Settings → Login Items & Extensions → Camera Extensions
///
/// The extension must be embedded at:
///   TeamsMakeupCam.app/Contents/Library/SystemExtensions/
///       com.teamsmakeupcam.TeamsMakeupCam.camera.systemextension
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {

    static let shared = SystemExtensionActivator()

    /// Bundle identifier of the Camera Extension target.
    /// Must match the extension's PRODUCT_BUNDLE_IDENTIFIER exactly.
    private let extensionBundleID = "com.teamsmakeupcam.TeamsMakeupCam.camera"

    private let logger = Logger(subsystem: "com.teamsmakeupcam.TeamsMakeupCam", category: "SystemExtension")

    private override init() {
        super.init()
    }

    /// Submit an activation request to the OS.
    func activate() {
        logger.info("Requesting activation of camera extension: \(self.extensionBundleID)")

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        logger.info("Replacing existing extension (v\(existing.bundleShortVersion)) with v\(ext.bundleShortVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        logger.info("System extension requires user approval in System Settings.")
        // The OS shows a system dialog directing the user to
        // System Settings → Privacy & Security to approve.
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            logger.info("Camera extension activated successfully.")
        case .willCompleteAfterReboot:
            logger.info("Camera extension will complete activation after reboot.")
        @unknown default:
            logger.warning("Camera extension activation returned unknown result: \(String(describing: result))")
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        logger.error("Camera extension activation failed: \(error.localizedDescription)")

        if let osError = error as? OSSystemExtensionError {
            switch osError.code {
            case .unknown:
                logger.error("Unknown system extension error.")
            case .missingEntitlement:
                logger.error("Missing com.apple.developer.system-extension.install entitlement on host app.")
            case .unsupportedParentBundleLocation:
                logger.error("App must be in /Applications to install system extensions.")
            case .extensionNotFound:
                logger.error("Extension bundle not found in Contents/Library/SystemExtensions/")
            case .extensionMissingIdentifier:
                logger.error("Extension bundle is missing CFBundleIdentifier.")
            case .duplicateExtension:
                logger.error("Another copy of this extension is already installed.")
            case .authorizationRequired:
                logger.error("User authorization required — check System Settings → Privacy & Security.")
            @unknown default:
                logger.error("Unhandled OSSystemExtensionError code: \(osError.code.rawValue)")
            }
        }
    }
}
