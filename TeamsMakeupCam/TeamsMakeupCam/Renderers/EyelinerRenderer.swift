import AVFoundation
import AppKit

final class EyelinerRenderer {

    private struct EyeTrackState {
        var smoothedEye: [CGPoint] = []
        var lastGoodSpine: [CGPoint] = []
        var lastGoodBand: Band?
        var lastOuterU: CGPoint = .zero
        var lastExtendedOuterU: CGPoint = .zero
        var lastWedgeBase: CGPoint = .zero
        var lastWingTip: CGPoint = .zero
        var hasValidShape = false
        var lastOuterL: CGPoint = .zero
    }

    private struct Band {
        var upperEdge: [CGPoint]
        var lowerEdge: [CGPoint]
    }

    private var leftState = EyeTrackState()
    private var rightState = EyeTrackState()

    private let pointSmoothingAlpha: CGFloat = 0.35
    private let shapeSmoothingAlpha: CGFloat = 0.40
    private let blinkThreshold: CGFloat = 0.10

    func updateEyelinerLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = max(0.0, min(settings.eyelinerIntensity, 1.0))
        guard intensity > 0.0 else {
            clearLayer(layer)
            leftState = EyeTrackState()
            rightState = EyeTrackState()
            return
        }

        guard let face = landmarks.first,
              !face.leftEye.isEmpty || !face.rightEye.isEmpty else {
            clearLayer(layer)
            return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.convertProcessedFrameNormalizedToView($0, contentExtent: extent, viewBounds: bounds) }
        } else {
            convert = { Self.convertToLayerSpace($0, in: previewLayer) }
        }

        let path = CGMutablePath()

        // Prefer the dedicated upper-lid points (9 pts, precise lid crease)
        // over deriving the upper arc from the full eye contour (16 pts).
        let leftEyePts  = face.leftUpperEyelidRaw.isEmpty  ? face.leftEye  : face.leftUpperEyelidRaw
        let rightEyePts = face.rightUpperEyelidRaw.isEmpty ? face.rightEye : face.rightUpperEyelidRaw

        if !leftEyePts.isEmpty {
            drawEye(
                eye: leftEyePts,
                convert: convert,
                intensity: intensity,
                wingGoesRight: true,
                state: &leftState,
                into: path
            )
        }

        if !rightEyePts.isEmpty {
            drawEye(
                eye: rightEyePts,
                convert: convert,
                intensity: intensity,
                wingGoesRight: false,
                state: &rightState,
                into: path
            )
        }

        layer.path = path
        layer.fillColor = NSColor.labelColor.withAlphaComponent(intensity).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth = 0
        layer.fillRule = .nonZero
        layer.shadowColor = NSColor.labelColor.withAlphaComponent(0.10 * intensity).cgColor
        layer.shadowRadius = 0.8
        layer.shadowOpacity = 1.0
        layer.shadowOffset = .zero
    }

    // MARK: - Main eye draw

    private func drawEye(
        eye: [CGPoint],
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        wingGoesRight: Bool,
        state: inout EyeTrackState,
        into path: CGMutablePath
    ) {
        let stableEye = smoothPoints(eye, previous: state.smoothedEye, alpha: pointSmoothingAlpha)
        state.smoothedEye = stableEye

        let openness = eyeOpenness(of: stableEye)
        let isBlinking = openness < blinkThreshold

        if isBlinking, state.hasValidShape, let lastBand = state.lastGoodBand {
            path.addPath(
                closedBand(
                    band: lastBand,
                    outerU: state.lastOuterU,
                    extendedOuterU: state.lastExtendedOuterU,
                    wedgeBase: state.lastWedgeBase,
                    wingTip: state.lastWingTip
                )
            )
            return
        }

        guard let spine = buildSpine(
            eye: stableEye,
            convert: convert,
            wingGoesRight: wingGoesRight
        ) else {
            if state.hasValidShape, let lastBand = state.lastGoodBand {
                path.addPath(
                    closedBand(
                        band: lastBand,
                        outerU: state.lastOuterU,
                        extendedOuterU: state.lastExtendedOuterU,
                        wedgeBase: state.lastWedgeBase,
                        wingTip: state.lastWingTip
                    )
                )
            }
            return
        }

        let smoothedSpine = smoothPolyline(spine, previous: state.lastGoodSpine, alpha: shapeSmoothingAlpha)
        state.lastGoodSpine = smoothedSpine

        let lidSpan = abs(smoothedSpine.last!.x - smoothedSpine.first!.x)
        guard lidSpan > 2 else { return }

        var band = buildBand(spine: smoothedSpine, lidSpan: lidSpan, intensity: intensity)

        let outerU = band.upperEdge.last!
        let outerL = band.lowerEdge.last!

        let ref = smoothedSpine[max(0, smoothedSpine.count - min(3, smoothedSpine.count))]

        // Tangent along the eyeliner body
        var dx = outerU.x - ref.x
        var dy = outerU.y - ref.y
        let dLen = max(1, hypot(dx, dy))
        dx /= dLen
        dy /= dLen

        if wingGoesRight {
            if dx < 0 {
                dx = -dx
                dy = -dy
            }
        } else {
            if dx > 0 {
                dx = -dx
                dy = -dy
            }
        }

        // One consistent normal
        let nx = -dy
        let ny = dx

        // KEEP YOUR CURRENT SHAPE VALUES
        let bodyExtension = lidSpan * (0.18 + 0.04 * intensity)
        let wLen = lidSpan * (0.10 + 0.16 * intensity)
        let wLift = lidSpan * (0.06 + 0.02 * intensity)
        let wedgeDepth = max(3.5, lidSpan * (0.085 + 0.030 * intensity))

        // Move the whole outer piece in one local frame
        var extendedOuterU = CGPoint(
            x: outerU.x + dx * bodyExtension,
            y: outerU.y + dy * bodyExtension * 0.75
        )

        let extendedOuterL = CGPoint(
            x: outerL.x + dx * bodyExtension,
            y: outerL.y + dy * bodyExtension * 0.15
        )

        var wingTip = CGPoint(
            x: extendedOuterU.x + dx * wLen,
            y: extendedOuterU.y + wLift
        )

        var wedgeBase = CGPoint(
            x: extendedOuterL.x - dx * lidSpan * 0.04,
            y: extendedOuterU.y + wedgeDepth
        )

        if state.hasValidShape {
            let a = shapeSmoothingAlpha

            let smoothedOuterU = lerp(state.lastOuterU, outerU, a)
            let smoothedOuterL = lerp(state.lastOuterL, outerL, a)
            extendedOuterU = lerp(state.lastExtendedOuterU, extendedOuterU, a)
            wingTip = lerp(state.lastWingTip, wingTip, a)
            wedgeBase = lerp(state.lastWedgeBase, wedgeBase, a)

            // Shift the band edges by the same delta so the whole outer piece moves together
            let deltaUpper = CGPoint(
                x: smoothedOuterU.x - outerU.x,
                y: smoothedOuterU.y - outerU.y
            )

            let deltaLower = CGPoint(
                x: smoothedOuterL.x - outerL.x,
                y: smoothedOuterL.y - outerL.y
            )

            band.upperEdge = band.upperEdge.enumerated().map { index, pt in
                if index >= max(0, band.upperEdge.count - 3) {
                    return CGPoint(x: pt.x + deltaUpper.x, y: pt.y + deltaUpper.y)
                }
                return pt
            }

            band.lowerEdge = band.lowerEdge.enumerated().map { index, pt in
                if index >= max(0, band.lowerEdge.count - 3) {
                    return CGPoint(x: pt.x + deltaLower.x, y: pt.y + deltaLower.y)
                }
                return pt
            }
        }

        state.lastGoodBand = band
        state.lastOuterU = outerU
        state.lastOuterL = outerL
        state.lastExtendedOuterU = extendedOuterU
        state.lastWingTip = wingTip
        state.lastWedgeBase = wedgeBase
        state.hasValidShape = true

        path.addPath(
            closedBand(
                band: band,
                outerU: outerU,
                extendedOuterU: extendedOuterU,
                wedgeBase: wedgeBase,
                wingTip: wingTip
            )
        )
    }

    // MARK: - Stable spine

    private func buildSpine(
        eye: [CGPoint],
        convert: (CGPoint) -> CGPoint,
        wingGoesRight: Bool
    ) -> [CGPoint]? {
        guard eye.count >= 8 else { return nil }

        let upperNorm = upperArc(from: eye)
        guard upperNorm.count >= 3 else { return nil }

        var pts = upperNorm.map(convert)
        pts = deduplicate(pts, minSpacing: 1.0)
        guard pts.count >= 3 else { return nil }

        let shouldReverse = wingGoesRight ? (pts.first!.x > pts.last!.x) : (pts.first!.x < pts.last!.x)
        if shouldReverse {
            pts.reverse()
        }

        return movingAverage(pts, window: 3)
    }

    private func upperArc(from eye: [CGPoint]) -> [CGPoint] {
        // If we receive fewer than 12 points the caller already passed
        // a pre-extracted upper lid — return it unchanged.
        guard eye.count >= 12 else { return eye }

        let half = eye.count / 2
        let arc1 = Array(eye[0..<half])
        let arc2 = Array(eye[half..<eye.count])

        let avg1 = arc1.map(\.y).reduce(0, +) / CGFloat(max(arc1.count, 1))
        let avg2 = arc2.map(\.y).reduce(0, +) / CGFloat(max(arc2.count, 1))

        return avg1 > avg2 ? arc1 : arc2
    }

    // MARK: - Band construction

    private func buildBand(spine: [CGPoint], lidSpan: CGFloat, intensity: CGFloat) -> Band {
        let maxThick = max(2.5, min(lidSpan * (0.045 + 0.025 * intensity), 7.0))
        let drop = max(1.5, lidSpan * 0.025)

        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        upper.reserveCapacity(spine.count)
        lower.reserveCapacity(spine.count)

        for (i, p) in spine.enumerated() {
            let t = CGFloat(i) / CGFloat(max(spine.count - 1, 1))
            let taper = smoothStep(0.5, 0.70, t)
            let boost = 1.0 + 0.65 * smoothStep(0.62, 1.0, t)
            let thick = maxThick * taper * boost

            let adaptiveDrop = drop * (1.2 - 0.3 * t)
            let base = CGPoint(x: p.x, y: p.y + adaptiveDrop)

            upper.append(base)
            lower.append(CGPoint(x: base.x, y: base.y + thick))
        }

        return Band(upperEdge: upper, lowerEdge: lower)
    }

    // MARK: - Wing shape

    private func closedBand(
        band: Band,
        outerU: CGPoint,
        extendedOuterU: CGPoint,
        wedgeBase: CGPoint,
        wingTip: CGPoint
    ) -> CGPath {
        let path = CGMutablePath()

        let innerTrimCount = max(1, Int(CGFloat(band.upperEdge.count) * 0.18))
        let trimmedUpper = Array(band.upperEdge.dropFirst(innerTrimCount))
        let trimmedLower = Array(band.lowerEdge.dropFirst(innerTrimCount))

        guard !trimmedUpper.isEmpty, !trimmedLower.isEmpty else { return path }

        path.move(to: trimmedUpper[0])

        var prev = trimmedUpper[0]
        for pt in trimmedUpper.dropFirst() {
            let mid = CGPoint(x: (prev.x + pt.x) / 2, y: (prev.y + pt.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            prev = pt
        }

        path.addLine(to: outerU)
        path.addLine(to: extendedOuterU)
        path.addLine(to: wingTip)
        path.addLine(to: wedgeBase)

        let lowerReturn = Array(trimmedLower.dropLast().reversed())
        prev = wedgeBase

        for pt in lowerReturn {
            let mid = CGPoint(x: (prev.x + pt.x) / 2, y: (prev.y + pt.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            prev = pt
        }

        path.addLine(to: trimmedLower[0])
        path.closeSubpath()

        return path
    }

    // MARK: - Stability helpers

    private func smoothPoints(_ current: [CGPoint], previous: [CGPoint], alpha: CGFloat) -> [CGPoint] {
        guard current.count == previous.count, !previous.isEmpty else { return current }
        return zip(current, previous).map { c, p in
            CGPoint(
                x: p.x + (c.x - p.x) * alpha,
                y: p.y + (c.y - p.y) * alpha
            )
        }
    }

    private func smoothPolyline(_ current: [CGPoint], previous: [CGPoint], alpha: CGFloat) -> [CGPoint] {
        guard current.count == previous.count, !previous.isEmpty else { return current }
        return zip(current, previous).map { c, p in
            lerp(p, c, alpha)
        }
    }

    private func eyeOpenness(of eye: [CGPoint]) -> CGFloat {
        guard eye.count >= 6 else { return 1.0 }

        let minX = eye.map(\.x).min() ?? 0
        let maxX = eye.map(\.x).max() ?? 1
        let minY = eye.map(\.y).min() ?? 0
        let maxY = eye.map(\.y).max() ?? 1

        let width = max(maxX - minX, 0.0001)
        let height = max(maxY - minY, 0.0001)
        return height / width
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t
        )
    }

    // MARK: - Geometry helpers

    private func deduplicate(_ pts: [CGPoint], minSpacing: CGFloat) -> [CGPoint] {
        guard !pts.isEmpty else { return pts }
        var result = [pts[0]]
        for pt in pts.dropFirst() {
            if abs(pt.x - result.last!.x) >= minSpacing {
                result.append(pt)
            }
        }
        return result
    }

    private func movingAverage(_ pts: [CGPoint], window: Int) -> [CGPoint] {
        guard pts.count > window else { return pts }
        return pts.indices.map { i in
            let lo = max(0, i - window / 2)
            let hi = min(pts.count - 1, i + window / 2)
            let slice = pts[lo...hi]
            let cx = slice.map(\.x).reduce(0, +) / CGFloat(slice.count)
            let cy = slice.map(\.y).reduce(0, +) / CGFloat(slice.count)
            return CGPoint(x: cx, y: cy)
        }
    }

    private func smoothStep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - edge0) / max(edge1 - edge0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Layer clearing

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path = nil
        layer.fillColor = NSColor.clear.cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.shadowColor = NSColor.clear.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.lineWidth = 0
    }

    // MARK: - Coordinate conversion

    private static func convertToLayerSpace(_ p: CGPoint, in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
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
