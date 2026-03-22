import CoreGraphics

/// Normalized face landmark data for a single detected face.
/// Points are in the range [0, 1] in both x and y, where
/// (0, 0) is the bottom-left of the image and (1, 1) is the top-right.
struct FaceLandmarks {
    // MARK: - Lips
    /// Outer lip contour in normalized coordinates.
    /// Backwards-compatible alias for renderers that expect `lips`.
    var lips: [CGPoint] = []
    var outerLips: [CGPoint] {
        get { lips }
        set { lips = newValue }
    }

    /// Inner mouth / inner lip contour, used to subtract teeth/inner mouth
    /// from the filled lipstick region.
    var innerLips: [CGPoint] = []

    // MARK: - Brows
    /// Full left eyebrow shape.
    var leftEyebrow: [CGPoint] = []
    /// Full right eyebrow shape.
    var rightEyebrow: [CGPoint] = []

    // MARK: - Eyes
    /// Closed left eye contour (upper + lower lid).
    var leftEye: [CGPoint] = []
    /// Closed right eye contour (upper + lower lid).
    var rightEye: [CGPoint] = []

    /// Convenience: samples along the upper eyelid / lash line for the left eye,
    /// derived from the full closed contour when available.
    var leftUpperEyelid: [CGPoint] {
        upperEyelid(fromClosedContour: leftEye)
    }

    /// Convenience: samples along the upper eyelid / lash line for the right eye,
    /// derived from the full closed contour when available.
    var rightUpperEyelid: [CGPoint] {
        upperEyelid(fromClosedContour: rightEye)
    }

    // MARK: - Face outline
    var faceContour: [CGPoint] = []

    /// Normalized face bounding box (Vision/MediaPipe coordinate space).
    var boundingBox: CGRect = .zero

    // MARK: - Helpers

    /// Derive an approximate upper-eyelid / lash-line polyline from a closed
    /// eye contour by taking the half of points with greater y (upper side).
    private func upperEyelid(fromClosedContour contour: [CGPoint]) -> [CGPoint] {
        guard contour.count > 2 else { return [] }
        let centerY = contour.map { $0.y }.reduce(0, +) / CGFloat(contour.count)
        let upper = contour.filter { $0.y >= centerY }
        return upper
    }
}

