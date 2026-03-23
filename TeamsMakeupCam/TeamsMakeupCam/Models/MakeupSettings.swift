import SwiftUI
import AppKit

struct MakeupSettings: Codable, Equatable {
    // MARK: - Lipstick
    var lipstickNSColor: NSColor = .systemRed
    var lipstickOpacity: Double = 0.0

    // MARK: - Lip Liner
    var lipLinerNSColor: NSColor = .systemRed
    var lipLinerIntensity: Double = 0.0

    // MARK: - Brows
    var browNSColor: NSColor = NSColor(red: 0.30, green: 0.20, blue: 0.12, alpha: 1)
    var browIntensity: Double = 0.0

    var browThickness: Double = 0.0
    var browArchAmount: Double = 0.0
    var browTailLift: Double = 0.0
    var browHeightOffset: Double = 0.0
    var browHorizontalScale: Double = 0.0

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

    var browColor: Color {
        get { Color(nsColor: browNSColor) }
        set { browNSColor = NSColor(newValue) }
    }

    // MARK: - Codable (manual, because NSColor isn't Codable)

    enum CodingKeys: String, CodingKey {
        case lipstickNSColor, lipstickOpacity
        case lipLinerNSColor, lipLinerIntensity
        case browNSColor, browIntensity
        case browThickness, browArchAmount, browTailLift, browHeightOffset, browHorizontalScale
        case smoothingStrength, eyelinerIntensity, lashesIntensity
    }

    init(
        lipstickNSColor: NSColor = .systemRed,
        lipstickOpacity: Double = 0.18,
        lipLinerNSColor: NSColor = .systemRed,
        lipLinerIntensity: Double = 0.16,
        browNSColor: NSColor = NSColor(red: 0.30, green: 0.20, blue: 0.12, alpha: 1),
        browIntensity: Double = 0.0,
        browThickness: Double = 0.0,
        browArchAmount: Double = 0.0,
        browTailLift: Double = 0.0,
        browHeightOffset: Double = 0.0,
        browHorizontalScale: Double = 0.0,
        smoothingStrength: Double = 0.0,
        eyelinerIntensity: Double = 0.5,
        lashesIntensity: Double = 0.0
    ) {
        self.lipstickNSColor = lipstickNSColor
        self.lipstickOpacity = lipstickOpacity
        self.lipLinerNSColor = lipLinerNSColor
        self.lipLinerIntensity = lipLinerIntensity
        self.browNSColor = browNSColor
        self.browIntensity = browIntensity
        self.browThickness = browThickness
        self.browArchAmount = browArchAmount
        self.browTailLift = browTailLift
        self.browHeightOffset = browHeightOffset
        self.browHorizontalScale = browHorizontalScale
        self.smoothingStrength = smoothingStrength
        self.eyelinerIntensity = eyelinerIntensity
        self.lashesIntensity = lashesIntensity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lipstickOpacity    = try c.decode(Double.self, forKey: .lipstickOpacity)
        lipLinerIntensity  = try c.decode(Double.self, forKey: .lipLinerIntensity)
        browIntensity      = try c.decode(Double.self, forKey: .browIntensity)
        browThickness      = try c.decode(Double.self, forKey: .browThickness)
        browArchAmount     = try c.decode(Double.self, forKey: .browArchAmount)
        browTailLift       = try c.decode(Double.self, forKey: .browTailLift)
        browHeightOffset   = try c.decode(Double.self, forKey: .browHeightOffset)
        browHorizontalScale = try c.decode(Double.self, forKey: .browHorizontalScale)
        smoothingStrength  = try c.decode(Double.self, forKey: .smoothingStrength)
        eyelinerIntensity  = try c.decode(Double.self, forKey: .eyelinerIntensity)
        lashesIntensity    = try c.decode(Double.self, forKey: .lashesIntensity)

        // NSColor decoded from archived Data
        let lipstickData  = try c.decode(Data.self, forKey: .lipstickNSColor)
        let lipLinerData  = try c.decode(Data.self, forKey: .lipLinerNSColor)
        let browData      = try c.decode(Data.self, forKey: .browNSColor)
        lipstickNSColor = NSColor.from(data: lipstickData) ?? .systemRed
        lipLinerNSColor = NSColor.from(data: lipLinerData) ?? .systemRed
        browNSColor     = NSColor.from(data: browData) ?? NSColor(red: 0.30, green: 0.20, blue: 0.12, alpha: 1)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lipstickOpacity,     forKey: .lipstickOpacity)
        try c.encode(lipLinerIntensity,   forKey: .lipLinerIntensity)
        try c.encode(browIntensity,       forKey: .browIntensity)
        try c.encode(browThickness,       forKey: .browThickness)
        try c.encode(browArchAmount,      forKey: .browArchAmount)
        try c.encode(browTailLift,        forKey: .browTailLift)
        try c.encode(browHeightOffset,    forKey: .browHeightOffset)
        try c.encode(browHorizontalScale, forKey: .browHorizontalScale)
        try c.encode(smoothingStrength,   forKey: .smoothingStrength)
        try c.encode(eyelinerIntensity,   forKey: .eyelinerIntensity)
        try c.encode(lashesIntensity,     forKey: .lashesIntensity)

        // NSColor encoded as archived Data
        try c.encode(lipstickNSColor.toData() ?? Data(), forKey: .lipstickNSColor)
        try c.encode(lipLinerNSColor.toData() ?? Data(), forKey: .lipLinerNSColor)
        try c.encode(browNSColor.toData()     ?? Data(), forKey: .browNSColor)
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
            browRGBA:     rgba(browNSColor,     alpha: min(max(browIntensity, 0), 1) * 0.8),
            browIntensity:     Float(max(0, min(browIntensity, 1))),
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
        lhs.browNSColor        == rhs.browNSColor &&
        lhs.browIntensity      == rhs.browIntensity &&
        lhs.browThickness      == rhs.browThickness &&
        lhs.browArchAmount     == rhs.browArchAmount &&
        lhs.browTailLift       == rhs.browTailLift &&
        lhs.browHeightOffset   == rhs.browHeightOffset &&
        lhs.browHorizontalScale == rhs.browHorizontalScale &&
        lhs.smoothingStrength  == rhs.smoothingStrength &&
        lhs.eyelinerIntensity  == rhs.eyelinerIntensity &&
        lhs.lashesIntensity    == rhs.lashesIntensity
    }
}
