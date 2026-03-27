import AVFoundation
import AppKit

/// Renders a filled eyeliner shape along the upper lid with a smooth wing.
///
/// ## Key design decisions
/// - **Band perpendicular to spine**: Thickness offsets are applied along the
///   normal perpendicular to the lid curve at each point, so the shape follows
///   the eye on head tilt instead of using absolute vertical offsets.
/// - **Wing follows actual tangent**: The flick direction comes from the spine's
///   outer-end tangent. No forced left/right override — this means the wing
///   naturally tilts with the head.
/// - **Intensity = opacity only**: Geometry (wing length, band thickness) is fixed.
///   The `intensity` slider only controls the fill alpha.
final class EyelinerRenderer {

    // MARK: - State

    private struct EyeTrackState {
        var smoothedEye: [CGPoint] = []
        var lastGoodSpine: [CGPoint] = []
        var lastGoodPath: CGPath?
        var hasValidShape = false
    }

    private var leftState  = EyeTrackState()
    private var rightState = EyeTrackState()

    private let pointAlpha: CGFloat = 0.35
    private let shapeAlpha: CGFloat = 0.40
    private let blinkThreshold: CGFloat = 0.10

    // MARK: - Public entry point

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
            leftState  = EyeTrackState()
            rightState = EyeTrackState()
            return
        }

        guard let face = landmarks.first,
              !face.leftEye.isEmpty || !face.rightEye.isEmpty else {
            clearLayer(layer)
            return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates,
           let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.normToView($0, extent: extent, bounds: bounds) }
        } else {
            convert = { Self.toLayer($0, in: previewLayer) }
        }

        let path = CGMutablePath()

        if !face.leftEye.isEmpty {
            drawEye(
                fullEye: face.leftEye,
                upperLid: face.leftUpperEyelidRaw.isEmpty ? nil : face.leftUpperEyelidRaw,
                convert: convert,
                wingGoesRight: true,
                state: &leftState,
                into: path
            )
        }

        if !face.rightEye.isEmpty {
            drawEye(
                fullEye: face.rightEye,
                upperLid: face.rightUpperEyelidRaw.isEmpty ? nil : face.rightUpperEyelidRaw,
                convert: convert,
                wingGoesRight: false,
                state: &rightState,
                into: path
            )
        }

        // Intensity only controls opacity, not geometry.
        layer.path        = path
        layer.fillColor   = NSColor.labelColor.withAlphaComponent(intensity).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth   = 0
        layer.fillRule    = .nonZero

        layer.shadowColor   = NSColor.labelColor.withAlphaComponent(0.10 * intensity).cgColor
        layer.shadowRadius  = 0.8
        layer.shadowOpacity = 1.0
        layer.shadowOffset  = .zero
    }

    // MARK: - Per-eye draw

    private func drawEye(
        fullEye: [CGPoint],
        upperLid: [CGPoint]?,
        convert: (CGPoint) -> CGPoint,
        wingGoesRight: Bool,
        state: inout EyeTrackState,
        into path: CGMutablePath
    ) {
        // Smooth the full-eye contour (needed for blink detection).
        let stableEye = smooth(fullEye, prev: state.smoothedEye, alpha: pointAlpha)
        state.smoothedEye = stableEye

        // Blink → hold last shape.
        if eyeOpenness(stableEye) < blinkThreshold {
            if let p = state.lastGoodPath { path.addPath(p) }
            return
        }

        // Build spine from upper lid when available; otherwise derive from full eye.
        let hasUpperLid = upperLid != nil
        let spineSource = upperLid ?? stableEye
        guard let rawSpine = buildSpine(
            eye: spineSource,
            convert: convert,
            wingGoesRight: wingGoesRight,
            isUpperLidOnly: hasUpperLid
        ) else {
            if let p = state.lastGoodPath { path.addPath(p) }
            return
        }

        let spine = smooth(rawSpine, prev: state.lastGoodSpine, alpha: shapeAlpha)
        state.lastGoodSpine = spine

        let lidSpan = hypot(spine.last!.x - spine.first!.x,
                            spine.last!.y - spine.first!.y)
        guard lidSpan > 2 else { return }

        // Eye centre in screen coords — used to orient per-point normals
        // so the band always sits between the lid and the iris.
        let eyeCenterNorm = centroid(stableEye)
        let eyeCenter = convert(eyeCenterNorm)

        let result = buildEyelinerPath(spine: spine, lidSpan: lidSpan,
                                       eyeCenter: eyeCenter)

        state.lastGoodPath   = result
        state.hasValidShape  = true
        path.addPath(result)
    }

    // MARK: - Build spine (inner → outer, screen coords)

    private func buildSpine(
        eye: [CGPoint],
        convert: (CGPoint) -> CGPoint,
        wingGoesRight: Bool,
        isUpperLidOnly: Bool = false
    ) -> [CGPoint]? {
        guard eye.count >= 5 else { return nil }

        // Pre-extracted upper lid → use directly; full eye → extract upper arc.
        let arc = isUpperLidOnly ? eye : upperArc(from: eye)
        guard arc.count >= 3 else { return nil }

        var pts = arc.map(convert)
        pts = deduplicate(pts, minGap: 1.0)
        guard pts.count >= 3 else { return nil }

        // Ensure spine runs inner-corner → outer-corner.
        let shouldReverse = wingGoesRight
            ? (pts.first!.x > pts.last!.x)
            : (pts.first!.x < pts.last!.x)
        if shouldReverse { pts.reverse() }

        return movingAverage(pts, window: 3)
    }

    private func upperArc(from eye: [CGPoint]) -> [CGPoint] {
        // Full eye contour (≥ 8 pts) → split in half, pick the upper arc.
        // Smaller counts (e.g. Vision fallback with few points) → return as-is.
        guard eye.count >= 8 else { return eye }

        let half = eye.count / 2
        let a1 = Array(eye[0..<half])
        let a2 = Array(eye[half..<eye.count])
        let avg1 = a1.map(\.y).reduce(0, +) / CGFloat(max(a1.count, 1))
        let avg2 = a2.map(\.y).reduce(0, +) / CGFloat(max(a2.count, 1))
        return avg1 > avg2 ? a1 : a2
    }

    // MARK: - Eyeliner path (band + wing)

    private func buildEyelinerPath(
        spine: [CGPoint],
        lidSpan: CGFloat,
        eyeCenter: CGPoint
    ) -> CGPath {
        let n = spine.count

        // ── 1. Per-point tangent & normal ────────────────────────────────────
        var tangents = [CGPoint](repeating: .zero, count: n)
        var normals  = [CGPoint](repeating: .zero, count: n)

        for i in 0..<n {
            let prev = i > 0     ? spine[i - 1] : spine[i]
            let next = i < n - 1 ? spine[i + 1] : spine[i]
            var tx = next.x - prev.x
            var ty = next.y - prev.y
            let len = max(0.001, hypot(tx, ty))
            tx /= len; ty /= len
            tangents[i] = CGPoint(x: tx, y: ty)

            // Pick the perpendicular that points toward the eye centre.
            var nx = -ty, ny = tx
            let toCX = eyeCenter.x - spine[i].x
            let toCY = eyeCenter.y - spine[i].y
            if nx * toCX + ny * toCY < 0 { nx = -nx; ny = -ny }
            normals[i] = CGPoint(x: nx, y: ny)
        }

        // ── 2. Upper / lower edges (perpendicular to spine) ─────────────────
        // Geometry is fixed — intensity does NOT affect it.
        // The band straddles the lash line: upper edge on the eyelid (AWAY
        // from eye centre), lower edge at the lash line (spine).
        // Normal points toward eye centre, so −normal points onto the lid.
        let maxThick = max(2.5, min(lidSpan * 0.065, 7.0))

        var upper = [CGPoint](repeating: .zero, count: n)
        var lower = [CGPoint](repeating: .zero, count: n)

        for i in 0..<n {
            let t     = CGFloat(i) / CGFloat(max(n - 1, 1))
            // Cat-eye taper: invisible inner third, appears ~35%, full at ~55%.
            let taper = smoothStep(0.30, 0.55, t)
            let boost = 1.0 + 0.5 * smoothStep(0.55, 1.0, t)
            let thick = maxThick * taper * boost

            let p  = spine[i]
            let nm = normals[i]

            // Upper edge = offset onto the eyelid (away from eye centre).
            upper[i] = CGPoint(x: p.x - nm.x * thick,
                               y: p.y - nm.y * thick)
            // Lower edge = the spine itself (lash line).
            lower[i] = p
        }

        // ── 3. Wing ─────────────────────────────────────────────────────────
        let outerT  = tangents[n - 1]
        let outerN  = normals[n - 1]
        let outerU  = upper[n - 1]
        let outerL  = lower[n - 1]
        let outerMid = CGPoint(x: (outerU.x + outerL.x) / 2,
                               y: (outerU.y + outerL.y) / 2)

        let wingLen  = lidSpan * 0.18
        let wingLift = lidSpan * 0.07

        // Wing tip: extend along tangent, lift AWAY from eye (−normal).
        let wingTip = CGPoint(
            x: outerMid.x + outerT.x * wingLen - outerN.x * wingLift,
            y: outerMid.y + outerT.y * wingLen - outerN.y * wingLift
        )

        // ── 4. Trace closed path ────────────────────────────────────────────
        let result = CGMutablePath()

        // Skip the invisible inner portion (thickness ≈ 0 before taper kicks in).
        let startIdx = max(0, Int(CGFloat(n) * 0.28))

        // Upper edge  inner → outer
        result.move(to: upper[startIdx])
        var prev = upper[startIdx]
        for i in (startIdx + 1)..<n {
            let mid = CGPoint(x: (prev.x + upper[i].x) / 2,
                              y: (prev.y + upper[i].y) / 2)
            result.addQuadCurve(to: mid, control: prev)
            prev = upper[i]
        }
        result.addLine(to: outerU)

        // Smooth wing:  outerU → wingTip → outerL
        let ctrl1 = CGPoint(
            x: outerU.x + outerT.x * wingLen * 0.65,
            y: outerU.y + outerT.y * wingLen * 0.65
        )
        result.addQuadCurve(to: wingTip, control: ctrl1)

        let ctrl2 = CGPoint(
            x: outerL.x + outerT.x * wingLen * 0.35,
            y: outerL.y + outerT.y * wingLen * 0.35
        )
        result.addQuadCurve(to: outerL, control: ctrl2)

        // Lower edge  outer → inner
        prev = outerL
        for i in stride(from: n - 2, through: startIdx, by: -1) {
            let mid = CGPoint(x: (prev.x + lower[i].x) / 2,
                              y: (prev.y + lower[i].y) / 2)
            result.addQuadCurve(to: mid, control: prev)
            prev = lower[i]
        }
        result.addLine(to: lower[startIdx])

        result.closeSubpath()
        return result
    }

    // MARK: - Geometry helpers

    private func smooth(_ cur: [CGPoint], prev: [CGPoint], alpha: CGFloat) -> [CGPoint] {
        guard cur.count == prev.count, !prev.isEmpty else { return cur }
        return zip(cur, prev).map { c, p in
            CGPoint(x: p.x + (c.x - p.x) * alpha,
                    y: p.y + (c.y - p.y) * alpha)
        }
    }

    private func eyeOpenness(_ eye: [CGPoint]) -> CGFloat {
        guard eye.count >= 6 else { return 1.0 }
        let xs = eye.map(\.x), ys = eye.map(\.y)
        let w = max((xs.max() ?? 1) - (xs.min() ?? 0), 0.0001)
        let h = max((ys.max() ?? 1) - (ys.min() ?? 0), 0.0001)
        return h / w
    }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(pts.count, 1))
        return CGPoint(
            x: pts.map(\.x).reduce(0, +) / n,
            y: pts.map(\.y).reduce(0, +) / n
        )
    }

    private func deduplicate(_ pts: [CGPoint], minGap: CGFloat) -> [CGPoint] {
        guard !pts.isEmpty else { return pts }
        var out = [pts[0]]
        for pt in pts.dropFirst() {
            if hypot(pt.x - out.last!.x, pt.y - out.last!.y) >= minGap {
                out.append(pt)
            }
        }
        return out
    }

    private func movingAverage(_ pts: [CGPoint], window: Int) -> [CGPoint] {
        guard pts.count > window else { return pts }
        return pts.indices.map { i in
            let lo = max(0, i - window / 2)
            let hi = min(pts.count - 1, i + window / 2)
            let s  = pts[lo...hi]
            return CGPoint(
                x: s.map(\.x).reduce(0, +) / CGFloat(s.count),
                y: s.map(\.y).reduce(0, +) / CGFloat(s.count)
            )
        }
    }

    private func smoothStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - e0) / max(e1 - e0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Layer clearing

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path          = nil
        layer.fillColor     = NSColor.clear.cgColor
        layer.strokeColor   = NSColor.clear.cgColor
        layer.shadowColor   = NSColor.clear.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius  = 0
        layer.lineWidth     = 0
    }

    // MARK: - Coordinate conversion

    private static func toLayer(_ p: CGPoint,
                                in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func normToView(_ p: CGPoint,
                                   extent: CGRect, bounds: CGRect) -> CGPoint {
        let w = extent.width, h = extent.height
        guard w > 0, h > 0 else { return .zero }
        let scale = max(bounds.width / w, bounds.height / h)
        let dw = w * scale, dh = h * scale
        return CGPoint(
            x: bounds.midX - dw / 2 + p.x * dw,
            y: bounds.midY - dh / 2 + p.y * dh
        )
    }
}
