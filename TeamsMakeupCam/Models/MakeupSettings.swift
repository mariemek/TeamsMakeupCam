import SwiftUI
import AppKit

struct MakeupSettings {
    // MARK: - Lipstick
    var lipstickNSColor: NSColor = .systemRed
    var lipstickOpacity: Double = 0.18

    // MARK: - Lip Liner
    var lipLinerNSColor: NSColor = .systemRed
    var lipLinerIntensity: Double = 0.16

    // MARK: - Brows
    var browNSColor: NSColor = NSColor(red: 0.30, green: 0.20, blue: 0.12, alpha: 1)
    var browIntensity: Double = 0.18

    /// 0...1, changes the overall brow fill thickness.
    var browThickness: Double = 0.45

    /// -1...1, raises or lowers the arch around the middle/outer-middle of the brow.
    var browArchAmount: Double = 0.0

    /// -1...1, lifts or drops the outer tail.
    var browTailLift: Double = 0.0

    /// -1...1, moves the whole brow up/down.
    var browHeightOffset: Double = 0.0

    /// 0.75...1.25, narrows or widens the brow around its center.
    var browHorizontalScale: Double = 1.0

    // MARK: - Eyes / Skin
    var smoothingStrength: Double = 0.12
    var eyelinerIntensity: Double = 0.14
    var lashesIntensity: Double = 0.10

    // MARK: - SwiftUI Color bindings

    var lipstickColor: Color {
        get { Color(nsColor: lipstickNSColor) }
        set { lipstickNSColor = NSColor(newValue) }
    }

    var lipLinerColor: Color {
        get { Color(nsColor: lipLinerNSColor) }
        set { lipLinerNSColor = NSColor(newValue) }
    }

    var browColor: Color {
        get { Color(nsColor: browNSColor) }
        set { browNSColor = NSColor(newValue) }
    }

    // MARK: - Beauty SDK parameter mapping

    struct BeautySdkParameters {
        var lipstickRGBA: (r: Float, g: Float, b: Float, a: Float)
        var lipLinerRGBA: (r: Float, g: Float, b: Float, a: Float)
        var browRGBA: (r: Float, g: Float, b: Float, a: Float)
        var browIntensity: Float
        var eyelinerIntensity: Float
        var lashesIntensity: Float
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
            browRGBA: rgba(browNSColor, alpha: min(max(browIntensity, 0), 1) * 0.8),
            browIntensity: Float(max(0, min(browIntensity, 1))),
            eyelinerIntensity: Float(max(0, min(eyelinerIntensity, 1))),
            lashesIntensity: Float(max(0, min(lashesIntensity, 1))),
            smoothingStrength: Float(max(0, min(smoothingStrength, 1)))
        )
    }

    // MARK: - Presets

    static let naturalPreset = MakeupSettings(
        lipstickNSColor: .systemRed,
        lipstickOpacity: 0.10,
        lipLinerNSColor: .systemRed,
        lipLinerIntensity: 0.08,

        browNSColor: NSColor(red: 0.28, green: 0.18, blue: 0.10, alpha: 1),
        browIntensity: 0.10,
        browThickness: 0.38,
        browArchAmount: 0.05,
        browTailLift: 0.04,
        browHeightOffset: 0.0,
        browHorizontalScale: 1.0,

        smoothingStrength: 0.08,
        eyelinerIntensity: 0.06,
        lashesIntensity: 0.06
    )

    static let softGlamPreset = MakeupSettings(
        lipstickNSColor: .systemPink,
        lipstickOpacity: 0.18,
        lipLinerNSColor: .systemPink,
        lipLinerIntensity: 0.16,

        browNSColor: NSColor(red: 0.32, green: 0.20, blue: 0.12, alpha: 1),
        browIntensity: 0.16,
        browThickness: 0.48,
        browArchAmount: 0.12,
        browTailLift: 0.10,
        browHeightOffset: 0.02,
        browHorizontalScale: 1.03,

        smoothingStrength: 0.12,
        eyelinerIntensity: 0.14,
        lashesIntensity: 0.12
    )

    static let polishedPreset = MakeupSettings(
        lipstickNSColor: .systemRed,
        lipstickOpacity: 0.24,
        lipLinerNSColor: .systemRed,
        lipLinerIntensity: 0.22,

        browNSColor: NSColor(red: 0.22, green: 0.13, blue: 0.08, alpha: 1),
        browIntensity: 0.22,
        browThickness: 0.56,
        browArchAmount: 0.18,
        browTailLift: 0.16,
        browHeightOffset: 0.03,
        browHorizontalScale: 1.05,

        smoothingStrength: 0.16,
        eyelinerIntensity: 0.20,
        lashesIntensity: 0.16
    )
}
