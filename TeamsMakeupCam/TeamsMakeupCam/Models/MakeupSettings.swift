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
    var lashesIntensity: Double = 0.10

    // MARK: - Lashes
    enum LashStyle: String, CaseIterable, Codable {
        case natural
        case wispy
        case dramatic

        var displayName: String {
            switch self {
            case .natural: return "Natural"
            case .wispy: return "Wispy"
            case .dramatic: return "Dramatic"
            }
        }
    }

    var lashStyle: LashStyle = .wispy
    var lashesOpacity: Double = 0.85
    var lashesBlurRadius: Double = 0.6

    // MARK: - Blush
    var blushNSColor: NSColor = NSColor(calibratedRed: 0.93, green: 0.55, blue: 0.63, alpha: 1.0)
    var blushIntensity: Double = 0.22

    /// -0.20 ... 0.20
    /// Negative = more inward, positive = more outward
    var blushPlacementX: Double = 0.0

    /// -0.20 ... 0.20
    /// Negative = higher, positive = lower
    var blushPlacementY: Double = 0.0

    /// Scales blush width relative to computed cheek size.
    var blushWidth: Double = 1.0

    /// Scales blush height relative to computed cheek size.
    var blushHeight: Double = 1.0

    /// 0 ... 1 softness amount. Higher = softer/more feathered look.
    var blushFeather: Double = 0.85

    // MARK: - SwiftUI Color bindings

    var lipstickColor: Color {
        get { Color(nsColor: lipstickNSColor) }
        set { lipstickNSColor = NSColor(newValue) }
    }

    var lipLinerColor: Color {
        get { Color(nsColor: lipLinerNSColor) }
        set { lipLinerNSColor = NSColor(newValue) }
    }

    var blushColor: Color {
        get { Color(nsColor: blushNSColor) }
        set { blushNSColor = NSColor(newValue) }
    }

    // MARK: - Beauty SDK parameter mapping

    struct BeautySdkParameters {
        var lipstickRGBA: (r: Float, g: Float, b: Float, a: Float)
        var lipLinerRGBA: (r: Float, g: Float, b: Float, a: Float)
        var blushRGBA: (r: Float, g: Float, b: Float, a: Float)
        var blushIntensity: Float
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
            blushRGBA: rgba(blushNSColor, alpha: min(max(blushIntensity, 0), 1) * 0.75),
            blushIntensity: Float(max(0, min(blushIntensity, 1))),
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
        smoothingStrength: 0.08,
        eyelinerIntensity: 0.06,
        lashesIntensity: 0.06,
        lashStyle: .natural,
        lashesOpacity: 0.82,
        lashesBlurRadius: 0.45,
        blushNSColor: NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.74, alpha: 1.0),
        blushIntensity: 0.12,
        blushPlacementX: -0.01,
        blushPlacementY: -0.02,
        blushWidth: 0.92,
        blushHeight: 0.88,
        blushFeather: 0.90
    )

    static let softGlamPreset = MakeupSettings(
        lipstickNSColor: .systemPink,
        lipstickOpacity: 0.18,
        lipLinerNSColor: .systemPink,
        lipLinerIntensity: 0.16,
        smoothingStrength: 0.12,
        eyelinerIntensity: 0.14,
        lashesIntensity: 0.12,
        lashStyle: .wispy,
        lashesOpacity: 0.85,
        lashesBlurRadius: 0.60,
        blushNSColor: NSColor(calibratedRed: 0.93, green: 0.55, blue: 0.63, alpha: 1.0),
        blushIntensity: 0.22,
        blushPlacementX: 0.0,
        blushPlacementY: -0.01,
        blushWidth: 1.0,
        blushHeight: 0.95,
        blushFeather: 0.86
    )

    static let polishedPreset = MakeupSettings(
        lipstickNSColor: .systemRed,
        lipstickOpacity: 0.24,
        lipLinerNSColor: .systemRed,
        lipLinerIntensity: 0.22,
        smoothingStrength: 0.16,
        eyelinerIntensity: 0.20,
        lashesIntensity: 0.16,
        lashStyle: .dramatic,
        lashesOpacity: 0.88,
        lashesBlurRadius: 0.65,
        blushNSColor: NSColor(calibratedRed: 0.86, green: 0.42, blue: 0.52, alpha: 1.0),
        blushIntensity: 0.28,
        blushPlacementX: 0.02,
        blushPlacementY: -0.01,
        blushWidth: 1.08,
        blushHeight: 0.92,
        blushFeather: 0.82
    )
}
