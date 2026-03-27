import AVFoundation
import AppKit

/// Renders natural-looking filled eyebrows from a 10-point ordered contour.
///
/// ## Contour format (from Python sidecar)
/// pts[0..4] = upper arc, inner-corner → outer-corner  (top edge of brow)
/// pts[5..9] = lower arc, outer-corner → inner-corner  (bottom edge of brow, reversed)
///
/// Together the 10 points form a closed brow outline. We draw it directly as
/// a closed Catmull-Rom spline — the same technique used for lips — so no
/// sorting, splitting, or geometric shaping is needed. The shape comes
/// entirely from the real MediaPipe landmarks.
final class BrowRenderer {

    // MARK: - Temporal state

    private struct BrowState {
        var contour: [CGPoint] = []
        var valid = false
    }
    private var leftState  = BrowState()
    private var rightState = BrowState()

    /// EMA alpha — lower = smoother/more lag, higher = snappier/more jitter.
    private let ema: CGFloat = 0.30

    // MARK: - Entry point

    func updateBrowLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = CGFloat(settings.browIntensity).clamped(0, 1)

        guard intensity > 0.001, let face = landmarks.first else {
            clearLayer(layer); return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let ext = contentExtent, let b = viewBounds {
            convert = { Self.normToView($0, extent: ext, bounds: b) }
        } else {
            convert = { self.toLayer($0, in: previewLayer) }
        }

        let leftPts  = face.leftEyebrow.map(convert)
        let rightPts = face.rightEyebrow.map(convert)

        let path = CGMutablePath()

        if leftPts.count >= 6 {
            drawBrow(leftPts,  state: &leftState,  to: path)
        }
        if rightPts.count >= 6 {
            drawBrow(rightPts, state: &rightState, to: path)
        }

        layer.path = path

        // Modest alpha — CIMultiplyBlendMode darkens naturally, so keep fill subtle.
        let alpha = 0.05 + 0.20 * intensity
        let color  = settings.browNSColor

        layer.fillColor   = color.withAlphaComponent(alpha).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth   = 0
        layer.fillRule    = .nonZero

        // Soft shadow gives a hair-edge fringe without adding artificial thickness.
        layer.shadowColor   = color.withAlphaComponent(alpha * 0.40).cgColor
        layer.shadowOpacity = 1.0
        layer.shadowRadius  = 0.5 + 1.0 * intensity
        layer.shadowOffset  = .zero

        layer.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
    }

    // MARK: - Shape

    private func drawBrow(
        _ rawPoints: [CGPoint],
        state: inout BrowState,
        to path: CGMutablePath
    ) {
        // EMA temporal smoothing
        var pts = rawPoints
        if state.valid && state.contour.count == pts.count {
            pts = zip(pts, state.contour).map { lerp($1, $0, ema) }
        }
        state.contour = pts
        state.valid   = true

        // Draw the ordered contour as a closed Catmull-Rom curve.
        // The 10 landmarks already trace the brow outline (upper arc then
        // reversed lower arc), so no geometric shaping is needed.
        let curve = catmullRomClosed(pts, steps: 12)
        guard curve.count >= 3 else { return }

        path.move(to: curve[0])
        for pt in curve.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
    }

    // MARK: - Closed Catmull-Rom spline

    private func catmullRomClosed(_ pts: [CGPoint], steps: Int = 12) -> [CGPoint] {
        let n = pts.count
        guard n >= 3 else { return pts }
        var result: [CGPoint] = []
        result.reserveCapacity(n * steps)
        for i in 0..<n {
            let p0 = pts[(i + n - 1) % n]
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[(i + 2) % n]
            for j in 0..<steps {
                let t  = CGFloat(j) / CGFloat(steps)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2*p1.x) + (-p0.x+p2.x)*t
                    + (2*p0.x-5*p1.x+4*p2.x-p3.x)*t2
                    + (-p0.x+3*p1.x-3*p2.x+p3.x)*t3)
                let y = 0.5 * ((2*p1.y) + (-p0.y+p2.y)*t
                    + (2*p0.y-5*p1.y+4*p2.y-p3.y)*t2
                    + (-p0.y+3*p1.y-3*p2.y+p3.y)*t3)
                result.append(CGPoint(x: x, y: y))
            }
        }
        return result
    }

    // MARK: - Helpers

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path              = nil
        layer.fillColor         = NSColor.clear.cgColor
        layer.strokeColor       = NSColor.clear.cgColor
        layer.shadowColor       = NSColor.clear.cgColor
        layer.shadowOpacity     = 0
        layer.shadowRadius      = 0
        layer.compositingFilter = nil
    }

    // MARK: - Coordinate conversion

    private func toLayer(_ p: CGPoint, in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func normToView(_ p: CGPoint, extent: CGRect, bounds: CGRect) -> CGPoint {
        let scale = max(bounds.width / extent.width, bounds.height / extent.height)
        let dw = extent.width * scale, dh = extent.height * scale
        return CGPoint(
            x: bounds.midX - dw / 2 + p.x * dw,
            y: bounds.midY - dh / 2 + p.y * dh
        )
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, self))
    }
}
