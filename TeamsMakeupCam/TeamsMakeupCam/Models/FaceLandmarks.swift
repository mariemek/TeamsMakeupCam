import CoreGraphics

struct FaceLandmarks {
    // MARK: - Lips
    var lips: [CGPoint] = []
    var outerLips: [CGPoint] {
        get { lips }
        set { lips = newValue }
    }
    var innerLips: [CGPoint] = []

    // MARK: - Brows
    var leftEyebrow: [CGPoint] = []
    var rightEyebrow: [CGPoint] = []

    // MARK: - Eyes
    var leftEye: [CGPoint] = []
    var rightEye: [CGPoint] = []

    // Upper eyelid points from sidecar (dedicated, more accurate than derived)
    // Falls back to derived version if sidecar doesn't send them yet.
    var leftUpperEyelidRaw:  [CGPoint] = []
    var rightUpperEyelidRaw: [CGPoint] = []

    var leftUpperEyelid: [CGPoint] {
        leftUpperEyelidRaw.isEmpty ? upperEyelid(fromClosedContour: leftEye) : leftUpperEyelidRaw
    }
    var rightUpperEyelid: [CGPoint] {
        rightUpperEyelidRaw.isEmpty ? upperEyelid(fromClosedContour: rightEye) : rightUpperEyelidRaw
    }

    // MARK: - Head pose (radians, from MediaPipe)
    /// Roll: head tilt left/right. Positive = tilted right in image space.
    var roll:  Double = 0
    /// Yaw: head turn left/right.
    var yaw:   Double = 0
    /// Pitch: head nod up/down.
    var pitch: Double = 0

    // MARK: - Face outline
    var faceContour: [CGPoint] = []
    var boundingBox: CGRect = .zero

    // MARK: - Helpers
    private func upperEyelid(fromClosedContour contour: [CGPoint]) -> [CGPoint] {
        guard contour.count > 2 else { return [] }
        let centerY = contour.map { $0.y }.reduce(0, +) / CGFloat(contour.count)
        return contour.filter { $0.y >= centerY }
    }
}
