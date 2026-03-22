import AVFoundation
import AppKit

/// Renders a softly filled eyebrow shape with manual shape controls:
/// - color
/// - intensity
/// - thickness
/// - arch amount
/// - tail lift
/// - height offset
/// - horizontal scale
///
/// When intensity is 0, the layer is fully cleared.
final class BrowRenderer {

    func updateBrowLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = clamped(settings.browIntensity, 0, 1)
        guard intensity > 0.001 else {
            clearLayer(layer)
            return
        }

        guard let face = landmarks.first else {
            clearLayer(layer)
            return
        }

        let left = face.leftEyebrow
        let right = face.rightEyebrow
        guard !left.isEmpty || !right.isEmpty else {
            clearLayer(layer)
            return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.convertProcessedFrameNormalizedToView($0, contentExtent: extent, viewBounds: bounds) }
        } else {
            convert = { self.convertToLayerSpace($0, in: previewLayer) }
        }

        let path = CGMutablePath()

        if !left.isEmpty {
            let converted = left.map(convert)
            addBrowShape(for: converted, settings: settings, to: path, preferIncreasingX: true)
        }

        if !right.isEmpty {
            let converted = right.map(convert)
            addBrowShape(for: converted, settings: settings, to: path, preferIncreasingX: false)
        }

        layer.path = path

        let fillAlpha = 0.10 + 0.22 * intensity
        let browColor = settings.browNSColor

        layer.fillColor = browColor.withAlphaComponent(fillAlpha).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth = 0
        layer.fillRule = .nonZero
        layer.lineCap = .round
        layer.lineJoin = .round

        // Small feather only; enough to soften edges without duplicating the shape.
        layer.shadowColor = browColor.withAlphaComponent(fillAlpha * 0.20).cgColor
        layer.shadowOpacity = 1.0
        layer.shadowRadius = 0.4 + 0.8 * intensity
        layer.shadowOffset = .zero
    }

    // MARK: - Shape construction

    private func addBrowShape(
        for points: [CGPoint],
        settings: MakeupSettings,
        to path: CGMutablePath,
        preferIncreasingX: Bool
    ) {
        guard points.count >= 4 else { return }

        let normalizedPoints = normalizedDirection(points, preferIncreasingX: preferIncreasingX)
        let spine = adjustedSpine(from: smooth(normalizedPoints), settings: settings)

        guard spine.count >= 4 else { return }

        let span = max(abs(spine.last!.x - spine.first!.x), 1.0)

        // Thickness is now controlled by browThickness.
        let thicknessMultiplier = 0.60 + CGFloat(clamped(settings.browThickness, 0, 1)) * 1.0
        let baseThickness = max(3.0, min(span * 0.060 * thicknessMultiplier, 10.0))

        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        upper.reserveCapacity(spine.count)
        lower.reserveCapacity(spine.count)

        for i in spine.indices {
            let t = CGFloat(i) / CGFloat(max(spine.count - 1, 1))

            // More compact profile: fuller at arch, still tapered at ends.
            let profile = thicknessProfile(t)
            let thickness = baseThickness * profile

            // Use a compact split around the spine.
            // Small upper offset, stronger lower offset gives a realistic filled brow.
            let upperOffset = thickness * 0.28
            let lowerOffset = thickness * 0.72

            // Tiny extra fullness at the front/head of the brow.
            let headBoost = (1.0 - smoothStep(0.10, 0.35, t)) * thickness * 0.10

            upper.append(
                CGPoint(
                    x: spine[i].x,
                    y: spine[i].y + upperOffset + headBoost * 0.25
                )
            )

            lower.append(
                CGPoint(
                    x: spine[i].x,
                    y: spine[i].y - lowerOffset - headBoost
                )
            )
        }

        let upperSmoothed = smooth(upper)
        let lowerSmoothed = smooth(lower)

        guard let firstUpper = upperSmoothed.first,
              let lastUpper = upperSmoothed.last,
              let firstLower = lowerSmoothed.first,
              let lastLower = lowerSmoothed.last else {
            return
        }

        path.move(to: firstUpper)
        addSmoothPath(points: Array(upperSmoothed.dropFirst()), to: path)

        let tailControl = CGPoint(
            x: (lastUpper.x + lastLower.x) / 2,
            y: (lastUpper.y + lastLower.y) / 2
        )
        path.addQuadCurve(to: lastLower, control: tailControl)

        addSmoothPath(points: Array(lowerSmoothed.dropLast().reversed()), to: path)

        let headControl = CGPoint(
            x: (firstLower.x + firstUpper.x) / 2,
            y: (firstLower.y + firstUpper.y) / 2
        )
        path.addQuadCurve(to: firstUpper, control: headControl)

        path.closeSubpath()
    }

    /// Apply manual brow shaping to the brow spine.
    private func adjustedSpine(from points: [CGPoint], settings: MakeupSettings) -> [CGPoint] {
        guard points.count >= 2 else { return points }

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let centerX = (minX + maxX) / 2

        let horizontalScale = CGFloat(clamped(settings.browHorizontalScale, 0.75, 1.25))
        let archAmount = CGFloat(clamped(settings.browArchAmount, -1, 1))
        let tailLift = CGFloat(clamped(settings.browTailLift, -1, 1))
        let heightOffset = CGFloat(clamped(settings.browHeightOffset, -1, 1))

        return points.enumerated().map { index, point in
            let t = CGFloat(index) / CGFloat(max(points.count - 1, 1))

            // Width scaling around the brow center.
            let scaledX = centerX + (point.x - centerX) * horizontalScale

            // Move whole brow up/down.
            var y = point.y - heightOffset * 12.0

            // Raise/lower the arch mostly in the middle / outer-middle.
            let archCenter: CGFloat = 0.58
            let archFalloff = exp(-pow((t - archCenter) / 0.22, 2.0))
            y -= archAmount * 9.0 * archFalloff

            // Lift/drop tail on the outer third.
            let tailWeight = smoothStep(0.62, 1.0, t)
            y -= tailLift * 8.0 * tailWeight

            return CGPoint(x: scaledX, y: y)
        }
    }

    /// Ensure consistent head -> tail ordering so the shape controls act predictably.
    private func normalizedDirection(_ points: [CGPoint], preferIncreasingX: Bool) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return points }

        let isIncreasing = last.x > first.x
        if preferIncreasingX {
            return isIncreasing ? points : points.reversed()
        } else {
            return isIncreasing ? points.reversed() : points
        }
    }

    /// Fuller in the arch, tapered at both ends.
    private func thicknessProfile(_ t: CGFloat) -> CGFloat {
        let base = 0.40
        let archBoost = 0.60 * exp(-pow((t - 0.58) / 0.24, 2.0))
        let headTaper = 0.35 + 0.65 * smoothStep(0.00, 0.22, t)
        let tailTaper = 1.0 - 0.58 * smoothStep(0.80, 1.00, t)
        return max(0.22, (base + archBoost) * headTaper * tailTaper)
    }

    // MARK: - Helpers

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path = nil
        layer.fillColor = NSColor.clear.cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.shadowColor = NSColor.clear.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.lineWidth = 0
    }

    private func smooth(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        return points.indices.map { i in
            let lo = max(0, i - 1)
            let hi = min(points.count - 1, i + 1)
            let slice = points[lo...hi]
            let x = slice.map(\.x).reduce(0, +) / CGFloat(slice.count)
            let y = slice.map(\.y).reduce(0, +) / CGFloat(slice.count)
            return CGPoint(x: x, y: y)
        }
    }

    private func addSmoothPath(points: [CGPoint], to path: CGMutablePath) {
        guard !points.isEmpty else { return }

        var previous = path.currentPoint
        for point in points {
            let mid = CGPoint(
                x: (previous.x + point.x) / 2,
                y: (previous.y + point.y) / 2
            )
            path.addQuadCurve(to: mid, control: previous)
            previous = point
        }
        path.addLine(to: previous)
    }

    private func smoothStep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - edge0) / max(edge1 - edge0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    private func clamped(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        max(minValue, min(maxValue, value))
    }

    // MARK: - Coordinate conversion

    private func convertToLayerSpace(_ p: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) -> CGPoint {
        previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func convertProcessedFrameNormalizedToView(
        _ normalized: CGPoint,
        contentExtent: CGRect,
        viewBounds: CGRect
    ) -> CGPoint {
        let w = contentExtent.width
        let h = contentExtent.height
        guard w > 0, h > 0 else { return .zero }

        let scale = max(viewBounds.width / w, viewBounds.height / h)
        let drawW = w * scale
        let drawH = h * scale
        let ox = viewBounds.midX - drawW / 2
        let oy = viewBounds.midY - drawH / 2

        return CGPoint(
            x: ox + normalized.x * drawW,
            y: oy + normalized.y * drawH
        )
    }
}
