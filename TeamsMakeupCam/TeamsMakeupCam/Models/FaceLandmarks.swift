import CoreGraphics
import Foundation

struct FaceLandmarks: Decodable {
    // MARK: - Lips

    var lips: [CGPoint] = []

    var outerLips: [CGPoint] {
        get { lips }
        set { lips = newValue }
    }

    var innerLips: [CGPoint] = []

    // MARK: - Eyes

    var leftEye: [CGPoint] = []
    var rightEye: [CGPoint] = []

    // Dedicated upper-eyelid points from the helper.
    var leftUpperEyelidRaw: [CGPoint] = []
    var rightUpperEyelidRaw: [CGPoint] = []

    var leftUpperEyelid: [CGPoint] {
        leftUpperEyelidRaw.isEmpty ? upperEyelid(fromClosedContour: leftEye) : leftUpperEyelidRaw
    }

    var rightUpperEyelid: [CGPoint] {
        rightUpperEyelidRaw.isEmpty ? upperEyelid(fromClosedContour: rightEye) : rightUpperEyelidRaw
    }

    // MARK: - Head pose

    var roll: Double = 0
    var yaw: Double = 0
    var pitch: Double = 0

    // MARK: - Face outline

    var faceContour: [CGPoint] = []
    var boundingBox: CGRect = .zero

    // MARK: - Cheek anchors

    var leftCheekPoint: CGPoint?
    var rightCheekPoint: CGPoint?

    enum CodingKeys: String, CodingKey {
        case lips
        case outerLips
        case innerLips
        case leftEye
        case rightEye
        case leftUpperEyelidRaw
        case rightUpperEyelidRaw
        case roll
        case yaw
        case pitch
        case faceContour
        case boundingBox
        case leftCheekPoint
        case rightCheekPoint
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let outer = try container.decodeIfPresent([[CGFloat]].self, forKey: .outerLips) {
            self.lips = Self.decodePoints(outer)
        } else if let lips = try container.decodeIfPresent([[CGFloat]].self, forKey: .lips) {
            self.lips = Self.decodePoints(lips)
        } else {
            self.lips = []
        }

        self.innerLips = Self.decodePoints(
            try container.decodeIfPresent([[CGFloat]].self, forKey: .innerLips) ?? []
        )

        self.leftEye = Self.decodePoints(
            try container.decodeIfPresent([[CGFloat]].self, forKey: .leftEye) ?? []
        )

        self.rightEye = Self.decodePoints(
            try container.decodeIfPresent([[CGFloat]].self, forKey: .rightEye) ?? []
        )

        self.leftUpperEyelidRaw = Self.decodePoints(
            try container.decodeIfPresent([[CGFloat]].self, forKey: .leftUpperEyelidRaw) ?? []
        )

        self.rightUpperEyelidRaw = Self.decodePoints(
            try container.decodeIfPresent([[CGFloat]].self, forKey: .rightUpperEyelidRaw) ?? []
        )

        self.roll = try container.decodeIfPresent(Double.self, forKey: .roll) ?? 0
        self.yaw = try container.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
        self.pitch = try container.decodeIfPresent(Double.self, forKey: .pitch) ?? 0

        self.faceContour = Self.decodePoints(
            try container.decodeIfPresent([[CGFloat]].self, forKey: .faceContour) ?? []
        )

        if let rectArray = try container.decodeIfPresent([CGFloat].self, forKey: .boundingBox),
           rectArray.count == 4 {
            self.boundingBox = CGRect(
                x: rectArray[0],
                y: rectArray[1],
                width: rectArray[2],
                height: rectArray[3]
            )
        } else {
            self.boundingBox = .zero
        }

        self.leftCheekPoint = Self.decodeOptionalPoint(
            try container.decodeIfPresent([CGFloat].self, forKey: .leftCheekPoint)
        )

        self.rightCheekPoint = Self.decodeOptionalPoint(
            try container.decodeIfPresent([CGFloat].self, forKey: .rightCheekPoint)
        )
    }

    // MARK: - Helpers

    private func upperEyelid(fromClosedContour contour: [CGPoint]) -> [CGPoint] {
        guard contour.count > 2 else { return [] }
        let centerY = contour.map(\.y).reduce(0, +) / CGFloat(contour.count)
        return contour.filter { $0.y >= centerY }
    }

    private static func decodePoints(_ raw: [[CGFloat]]) -> [CGPoint] {
        raw.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
    }

    private static func decodeOptionalPoint(_ raw: [CGFloat]?) -> CGPoint? {
        guard let raw, raw.count >= 2 else { return nil }
        return CGPoint(x: raw[0], y: raw[1])
    }
}
