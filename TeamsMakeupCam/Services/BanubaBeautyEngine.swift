import CoreImage
import CoreMedia
import Foundation

/// Rendering-engine abstraction. The intent is that a commercial beauty SDK
/// (Banuba Face AR SDK) becomes the *renderer* that outputs a processed frame
/// with tracking + makeup + beauty baked in.
///
/// This project intentionally keeps SwiftUI as the UI layer and pushes all
/// makeup realism concerns into this engine.
protocol BeautyRenderingEngine: AnyObject {
    /// Process one frame and return a rendered output frame.
    ///
    /// - Parameters:
    ///   - pixelBuffer: camera frame buffer (BGRA).
    ///   - settings: current UI settings to apply.
    /// - Returns: processed CIImage ready for preview.
    func render(pixelBuffer: CVPixelBuffer, settings: MakeupSettings) -> CIImage?
}

/// Starter implementation for Banuba Face AR SDK integration.
///
/// IMPORTANT:
/// - This file is a scaffold. It will not compile against Banuba until you add
///   the Banuba SDK to the project and replace the placeholder calls below with
///   real Banuba APIs.
/// - The purpose is to make the refactor concrete: the SDK becomes the single
///   rendering engine, and the rest of the app just passes frames + settings.
final class BanubaBeautyEngine: BeautyRenderingEngine {

    // MARK: - Placeholder types
    // Replace these with real Banuba engine/session types.
    private final class _BanubaSession {}

    private let session = _BanubaSession()

    /// Development fallback:
    /// - While Banuba is not yet wired in, we return the raw camera frame so the app
    ///   remains usable during integration.
    /// - Once Banuba output retrieval is implemented, remove/disable this fallback.
    private let usesDevelopmentFallbackRawFrame = true

    init() {
        // TODO(Banuba): initialize Banuba/FaceAR engine here.
        // Example (placeholder):
        // self.session = BanubaSdk.createSession(...)
        _ = session
    }

    func render(pixelBuffer: CVPixelBuffer, settings: MakeupSettings) -> CIImage? {
        let params = settings.asBeautySdkParameters()

        // TODO(Banuba): feed frame into Banuba and get rendered output.
        // Typical flow in AR SDKs:
        // 1) send input frame to engine
        // 2) apply parameters/effects (lipstick, liner, brows, eyeliner, lashes, smoothing)
        // 3) request rendered frame as CVPixelBuffer / CGImage / texture
        // 4) convert to CIImage and return
        //
        _ = params

        // TODO(Banuba): Replace with Banuba rendered output:
        // let renderedPixelBuffer = banubaGetRenderedFrame(...)
        // return CIImage(cvPixelBuffer: renderedPixelBuffer)

        if usesDevelopmentFallbackRawFrame {
            // TEMPORARY FALLBACK (development only): show raw camera frame until Banuba is wired.
            return CIImage(cvPixelBuffer: pixelBuffer)
        }

        return nil
    }
}

