import SwiftUI
import AppKit

struct MakeupSettings {
    // MARK: - Lipstick
    var lipstickNSColor: NSColor = .systemRed
    var lipstickOpacity: Double = 0.18

    // MARK: - Lip Liner
    var lipLinerNSColor: NSColor = .systemRed
    var lipLinerIntensity: Double = 0.16

    // MARK: - Eyes / Skin
    var smoothingStrength: Double = 0.12
    var eyelinerIntensity: Double = 0.14

    

   
    // MARK: - Beauty SDK parameter mapping

    struct BeautySdkParameters {
        var lipstickRGBA: (r: Float, g: Float, b: Float, a: Float)
        var lipLinerRGBA: (r: Float, g: Float, b: Float, a: Float)
        var eyelinerIntensity: Float
        var smoothingStrength: Float
    }

    func asBeautySdkParameters() -> BeautySdkParameters {
        func rgba(_ color: NSColor, alpha: Double) -> (Float, Float, Float, Float) {
            let srgb = color.usingColorSpace(.sRGB) ?? color
            return (
                Float(srgb.redComponent),
                Float(srgb.greenComponent),
                Float(srgb.blueComponent),
                Float(max(0.0, min(alpha, 1.0)))
            )
        }

        return BeautySdkParameters(
            lipstickRGBA: rgba(lipstickNSColor, alpha: lipstickOpacity),
            lipLinerRGBA: rgba(lipLinerNSColor, alpha: min(max(lipLinerIntensity, 0), 1) * 0.8),
            eyelinerIntensity: Float(max(0, min(eyelinerIntensity, 1))),
            smoothingStrength: Float(max(0, min(smoothingStrength, 1)))
        )
    }

    // MARK: - Presets

    static let naturalPreset = MakeupSettings(
        lipstickNSColor: .systemRed,
        lipstickOpacity: 0.10,
        lipLinerNSColor: .systemRed,
        lipLinerIntensity: 0.08,
        smoothingStrength: 0.08,
        eyelinerIntensity: 0.06,
    )

    static let softGlamPreset = MakeupSettings(
        lipstickNSColor: .systemPink,
        lipstickOpacity: 0.18,
        lipLinerNSColor: .systemPink,
        lipLinerIntensity: 0.16,
        smoothingStrength: 0.12,
        eyelinerIntensity: 0.14,
    )

    static let polishedPreset = MakeupSettings(
        lipstickNSColor: .systemRed,
        lipstickOpacity: 0.24,
        lipLinerNSColor: .systemRed,
        lipLinerIntensity: 0.22,
        smoothingStrength: 0.16,
        eyelinerIntensity: 0.20,
    )
}
