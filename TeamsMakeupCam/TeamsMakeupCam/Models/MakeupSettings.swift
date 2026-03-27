import SwiftUI
import AppKit

struct MakeupSettings: Codable, Equatable {
    // MARK: - Lipstick
    var lipstickNSColor: NSColor = NSColor(
        calibratedRed: 0.55,
        green: 0.20,
        blue: 0.23,
        alpha: 1.0
    )
    var lipstickOpacity: Double = 0.0

    // MARK: - Lip Liner
    var lipLinerNSColor: NSColor = NSColor(
        calibratedRed: 0.55,
        green: 0.20,
        blue: 1.23,
        alpha: 1.0
    )
    var lipLinerIntensity: Double = 0.0

    // MARK: - Eyes / Skin
    var smoothingStrength: Double = 0.0
    var eyelinerIntensity: Double = 0.0
    var lashesIntensity: Double = 0.0

    // MARK: - SwiftUI Color bindings

    var lipstickColor: Color {
        get { Color(nsColor: lipstickNSColor) }
        set { lipstickNSColor = NSColor(newValue) }
    }

    var lipLinerColor: Color {
        get { Color(nsColor: lipLinerNSColor) }
        set { lipLinerNSColor = NSColor(newValue) }
    }

    // MARK: - Codable (manual, because NSColor isn't Codable)

    enum CodingKeys: String, CodingKey {
        case lipstickNSColor, lipstickOpacity
        case lipLinerNSColor, lipLinerIntensity
        case smoothingStrength, eyelinerIntensity, lashesIntensity
    }

    init(
        lipstickNSColor: NSColor = .systemRed,
        lipstickOpacity: Double = 0.18,
        lipLinerNSColor: NSColor = .systemRed,
        lipLinerIntensity: Double = 0.16,
        smoothingStrength: Double = 0.0,
        eyelinerIntensity: Double = 0.5,
        lashesIntensity: Double = 0.0
    ) {
        self.lipstickNSColor = lipstickNSColor
        self.lipstickOpacity = lipstickOpacity
        self.lipLinerNSColor = lipLinerNSColor
        self.lipLinerIntensity = lipLinerIntensity
        self.smoothingStrength = smoothingStrength
        self.eyelinerIntensity = eyelinerIntensity
        self.lashesIntensity = lashesIntensity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lipstickOpacity    = try c.decode(Double.self, forKey: .lipstickOpacity)
        lipLinerIntensity  = try c.decode(Double.self, forKey: .lipLinerIntensity)
        smoothingStrength  = try c.decode(Double.self, forKey: .smoothingStrength)
        eyelinerIntensity  = try c.decode(Double.self, forKey: .eyelinerIntensity)
        lashesIntensity    = try c.decode(Double.self, forKey: .lashesIntensity)

        // NSColor decoded from archived Data
        let lipstickData  = try c.decode(Data.self, forKey: .lipstickNSColor)
        let lipLinerData  = try c.decode(Data.self, forKey: .lipLinerNSColor)
        lipstickNSColor = NSColor.from(data: lipstickData) ?? .systemRed
        lipLinerNSColor = NSColor.from(data: lipLinerData) ?? .systemRed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lipstickOpacity,     forKey: .lipstickOpacity)
        try c.encode(lipLinerIntensity,   forKey: .lipLinerIntensity)
        try c.encode(smoothingStrength,   forKey: .smoothingStrength)
        try c.encode(eyelinerIntensity,   forKey: .eyelinerIntensity)
        try c.encode(lashesIntensity,     forKey: .lashesIntensity)

        // NSColor encoded as archived Data
        try c.encode(lipstickNSColor.toData() ?? Data(), forKey: .lipstickNSColor)
        try c.encode(lipLinerNSColor.toData() ?? Data(), forKey: .lipLinerNSColor)
    }

    // MARK: - Beauty SDK parameter mapping

    struct BeautySdkParameters {
        var lipstickRGBA: (r: Float, g: Float, b: Float, a: Float)
        var lipLinerRGBA: (r: Float, g: Float, b: Float, a: Float)
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
            eyelinerIntensity: Float(max(0, min(eyelinerIntensity, 1))),
            lashesIntensity:   Float(max(0, min(lashesIntensity, 1))),
            smoothingStrength: Float(max(0, min(smoothingStrength, 1)))
        )
    }
}

// MARK: - NSColor + Codable helper

extension NSColor {
    func toData() -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: true)
    }
    static func from(data: Data) -> NSColor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }
}

// MARK: - Equatable (NSColor doesn't auto-synthesize)

extension MakeupSettings {
    static func == (lhs: MakeupSettings, rhs: MakeupSettings) -> Bool {
        lhs.lipstickNSColor    == rhs.lipstickNSColor &&
        lhs.lipstickOpacity    == rhs.lipstickOpacity &&
        lhs.lipLinerNSColor    == rhs.lipLinerNSColor &&
        lhs.lipLinerIntensity  == rhs.lipLinerIntensity &&
        lhs.smoothingStrength  == rhs.smoothingStrength &&
        lhs.eyelinerIntensity  == rhs.eyelinerIntensity &&
        lhs.lashesIntensity    == rhs.lashesIntensity
    }
}
