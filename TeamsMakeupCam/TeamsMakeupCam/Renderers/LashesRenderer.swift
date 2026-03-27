import AVFoundation
import AppKit

/// Renders realistic individual lash strands along the upper eyelid.
///
/// Each strand is a quad-bezier curve that follows the natural lash growth pattern:
/// longest and fullest at the outer corner, progressively shorter toward the inner
/// corner, with a gentle J-curve that leans slightly outward.
///
/// When `lashesIntensity` is 0 the layer is fully cleared (no ghost effect).
final class LashesRenderer {

    func updateLashesLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = max(0.0, min(settings.lashesIntensity, 1.0))

        guard intensity > 0.0 else { clearLayer(layer); return }

        guard let face = landmarks.first,
              (!face.leftEye.isEmpty || !face.rightEye.isEmpty) else {
            clearLayer(layer); return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.convertProcessedFrameNormalizedToView($0, contentExtent: extent, viewBounds: bounds) }
        } else {
            convert = { Self.convertToLayerSpace($0, in: previewLayer) }
        }

        let path = CGMutablePath()
        if !face.leftEye.isEmpty {
            let eyelid = face.leftUpperEyelid.isEmpty ? nil : face.leftUpperEyelid
            addLashes(eye: face.leftEye, upperEyelid: eyelid, convert: convert, intensity: intensity, to: path)
        }
        if !face.rightEye.isEmpty {
            let eyelid = face.rightUpperEyelid.isEmpty ? nil : face.rightUpperEyelid
            addLashes(eye: face.rightEye, upperEyelid: eyelid, convert: convert, intensity: intensity, to: path)
        }

        layer.path = path

        let alpha     = 0.50 + 0.40 * intensity
        let lineWidth = 0.6  + 0.6  * intensity  // thin individual strands

        layer.strokeColor   = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        layer.fillColor     = nil
        layer.lineWidth     = lineWidth
        layer.lineCap       = .round
        layer.lineJoin      = .round
        layer.shadowColor   = NSColor.labelColor.withAlphaComponent(alpha * 0.25).cgColor
        layer.shadowRadius  = 0.5 + intensity * 0.5
        layer.shadowOffset  = .zero
        layer.shadowOpacity = 1.0
    }

    // MARK: - Layer clearing

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path          = nil
        layer.fillColor     = nil
        layer.strokeColor   = NSColor.clear.cgColor
        layer.shadowColor   = NSColor.clear.cgColor
        layer.shadowOpacity = 0
    }

    // MARK: - Lash construction

    private func addLashes(
        eye: [CGPoint],
        upperEyelid: [CGPoint]?,
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        to path: CGMutablePath
    ) {
        guard eye.count > 3 else { return }

        // Use dedicated upper eyelid points if available, else derive from full contour.
        let rawUpper: [CGPoint]
        if let eyelid = upperEyelid, eyelid.count >= 2 {
            rawUpper = eyelid
        } else {
            let centY = eye.map { $0.y }.reduce(0, +) / CGFloat(eye.count)
            rawUpper = eye.filter { $0.y >= centY }
        }
        guard rawUpper.count >= 2 else { return }

        let sorted = rawUpper.map(convert).sorted { $0.x < $1.x }
        guard sorted.count >= 2 else { return }

        // Eye center in view space — used to orient normals away from the eye.
        let allConverted = eye.map(convert)
        let eyeCenter = CGPoint(
            x: allConverted.map(\.x).reduce(0, +) / CGFloat(allConverted.count),
            y: allConverted.map(\.y).reduce(0, +) / CGFloat(allConverted.count)
        )

        // Densify the upper eyelid curve via Catmull-Rom interpolation.
        let strandCount = 24 + Int(intensity * 16)  // 24–40 base points
        let basePoints = catmullRomResample(sorted, count: strandCount)
        guard basePoints.count >= 2 else { return }

        let span = hypot(basePoints.last!.x - basePoints.first!.x,
                         basePoints.last!.y - basePoints.first!.y)
        guard span > 1 else { return }

        // Determine which end is the outer corner (farther from nose / face center).
        // In a mirrored camera the outer corner is the one farther from the eye center
        // horizontally, but since we don't have full face context we use a heuristic:
        // the end whose upper eyelid points have lower y (higher on screen) is the outer
        // corner because outer lashes lift more. However the simplest robust approach is
        // to make both ends symmetric and just always treat index 0 as "inner" (smaller x)
        // and last as "outer" (larger x). Works for both eyes because they're sorted by x.

        for i in 0..<basePoints.count {
            let t = CGFloat(i) / CGFloat(max(basePoints.count - 1, 1))  // 0=inner, 1=outer

            // Tangent at this point.
            let tangent: CGPoint
            if i == 0 {
                tangent = unitVec(from: basePoints[0], to: basePoints[1])
            } else if i == basePoints.count - 1 {
                tangent = unitVec(from: basePoints[basePoints.count - 2], to: basePoints.last!)
            } else {
                tangent = unitVec(from: basePoints[i - 1], to: basePoints[i + 1])
            }

            // Normal perpendicular to tangent, pointing away from eye center.
            let rawNormal = CGPoint(x: -tangent.y, y: tangent.x)
            let toCenter  = CGPoint(x: eyeCenter.x - basePoints[i].x,
                                    y: eyeCenter.y - basePoints[i].y)
            let dot = rawNormal.x * toCenter.x + rawNormal.y * toCenter.y
            let normal = dot > 0 ? CGPoint(x: -rawNormal.x, y: -rawNormal.y) : rawNormal

            // ── Length envelope: short at inner, long at outer ──────────────
            // Uses a smooth power curve so lashes taper naturally.
            let minRatio: CGFloat = 0.025
            let maxRatio: CGFloat = 0.08 + 0.06 * intensity  // 0.08–0.14
            let envelope = minRatio + (maxRatio - minRatio) * smoothstep(t)
            let baseLen  = span * envelope

            // Seeded deterministic variation per strand.
            let seed = pseudoRandom(index: i)
            let lenVariation = 1.0 + seed * 0.12
            let angVariation = seed * 0.06

            let lashLen = baseLen * lenVariation

            // ── J-curve geometry ────────────────────────────────────────────
            // The strand starts at the base point on the eyelid, curves slightly
            // along the tangent direction (lean) before arcing upward/outward.
            let leanStrength: CGFloat = 0.20 + 0.15 * t  // more lean at outer corner
            let curveLift: CGFloat = 0.50   // how far the control point is along the normal

            // Rotate the tip direction slightly for variation.
            let cosA = cos(angVariation), sinA = sin(angVariation)
            let tipDirX = normal.x * cosA - normal.y * sinA
            let tipDirY = normal.x * sinA + normal.y * cosA

            let base = basePoints[i]
            let tipX = base.x + tipDirX * lashLen
            let tipY = base.y + tipDirY * lashLen
            let ctrlX = base.x + normal.x * lashLen * curveLift + tangent.x * lashLen * leanStrength
            let ctrlY = base.y + normal.y * lashLen * curveLift + tangent.y * lashLen * leanStrength

            path.move(to: base)
            path.addQuadCurve(to: CGPoint(x: tipX, y: tipY),
                              control: CGPoint(x: ctrlX, y: ctrlY))

            // ── Extra strands at the outer 40% for fullness ─────────────────
            if t > 0.6 && intensity > 0.15 {
                let extraCount = t > 0.85 ? 2 : 1
                for j in 1...extraCount {
                    let jf = CGFloat(j)
                    let seed2 = pseudoRandom(index: i * 7 + j * 13)
                    let extraLen = lashLen * (0.65 + 0.25 * seed2)
                    let extraAng = angVariation + jf * 0.09 * (seed2 > 0 ? 1 : -1)
                    let cosB = cos(extraAng), sinB = sin(extraAng)
                    let eDirX = normal.x * cosB - normal.y * sinB
                    let eDirY = normal.x * sinB + normal.y * cosB

                    let eTipX = base.x + eDirX * extraLen
                    let eTipY = base.y + eDirY * extraLen
                    let eCtrlX = base.x + normal.x * extraLen * curveLift * 0.9 + tangent.x * extraLen * leanStrength * 1.1
                    let eCtrlY = base.y + normal.y * extraLen * curveLift * 0.9 + tangent.y * extraLen * leanStrength * 1.1

                    path.move(to: base)
                    path.addQuadCurve(to: CGPoint(x: eTipX, y: eTipY),
                                      control: CGPoint(x: eCtrlX, y: eCtrlY))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Deterministic pseudo-random in [-1, 1] from an integer index.
    private func pseudoRandom(index: Int) -> CGFloat {
        let x = sin(CGFloat(index) * 127.1 + 311.7) * 43758.5453
        let frac = x - x.rounded(.down)  // fractional part in [0, 1)
        return frac * 2.0 - 1.0
    }

    /// Hermite smoothstep for natural taper: 0→0, 1→1, smooth in-between.
    private func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Unit vector from `a` to `b`, or (1,0) if coincident.
    private func unitVec(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: dx / len, y: dy / len)
    }

    /// Catmull-Rom resampling: takes sparse sorted points and returns `count`
    /// evenly-spaced points along the smooth curve through them.
    private func catmullRomResample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count >= 2, count >= 2 else { return points }
        if points.count == 2 {
            return (0..<count).map { i in
                let f = CGFloat(i) / CGFloat(count - 1)
                return CGPoint(x: points[0].x + (points[1].x - points[0].x) * f,
                               y: points[0].y + (points[1].y - points[0].y) * f)
            }
        }

        // Compute cumulative arc-length for parameterisation.
        var arcLen = [CGFloat](repeating: 0, count: points.count)
        for i in 1..<points.count {
            arcLen[i] = arcLen[i - 1] + hypot(points[i].x - points[i - 1].x,
                                               points[i].y - points[i - 1].y)
        }
        let totalLen = arcLen.last!
        guard totalLen > 0 else { return points }

        var result = [CGPoint]()
        result.reserveCapacity(count)

        for i in 0..<count {
            let targetLen = totalLen * CGFloat(i) / CGFloat(count - 1)

            // Find segment.
            var seg = 0
            for s in 1..<points.count {
                if arcLen[s] >= targetLen { seg = s - 1; break }
                if s == points.count - 1 { seg = s - 1 }
            }

            let segLen = arcLen[seg + 1] - arcLen[seg]
            let localT = segLen > 0 ? (targetLen - arcLen[seg]) / segLen : 0

            // Catmull-Rom with phantom end-points.
            let p0 = seg > 0 ? points[seg - 1] : CGPoint(x: 2 * points[0].x - points[1].x,
                                                           y: 2 * points[0].y - points[1].y)
            let p1 = points[seg]
            let p2 = points[seg + 1]
            let p3 = seg + 2 < points.count ? points[seg + 2] : CGPoint(x: 2 * p2.x - p1.x,
                                                                          y: 2 * p2.y - p1.y)

            let t2 = localT * localT
            let t3 = t2 * localT

            let x = 0.5 * ((2 * p1.x) +
                            (-p0.x + p2.x) * localT +
                            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
            let y = 0.5 * ((2 * p1.y) +
                            (-p0.y + p2.y) * localT +
                            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)

            result.append(CGPoint(x: x, y: y))
        }
        return result
    }

    // MARK: - Coordinate conversion

    private static func convertToLayerSpace(_ p: CGPoint,
                                            in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func convertProcessedFrameNormalizedToView(
        _ normalized: CGPoint, contentExtent: CGRect, viewBounds: CGRect
    ) -> CGPoint {
        let w = contentExtent.width, h = contentExtent.height
        guard w > 0, h > 0 else { return .zero }
        let scale = max(viewBounds.width / w, viewBounds.height / h)
        let drawW = w * scale, drawH = h * scale
        let ox    = viewBounds.midX - drawW / 2
        let oy    = viewBounds.midY - drawH / 2
        return CGPoint(x: ox + normalized.x * drawW, y: oy + normalized.y * drawH)
    }
}
