import AVFoundation
import AppKit

/// Renders a smooth filled eyeliner on the upper lash line with a short upward wing.
///
/// Tuned for Apple Vision landmarks:
///   - Vision returns ~6-16 points per eye (fewer than MediaPipe)
///   - Vision leftEye  = subject's left  = RIGHT side of screen → outerOnRight = true
///   - Vision rightEye = subject's right = LEFT  side of screen → outerOnRight = false
///   - Points are in normalised [0,1] bottom-left space relative to face bbox,
///     remapped to full-image space in FaceLandmarkService
///
/// y increases DOWNWARD in view/layer space after coordinate conversion.
/// "Below lash line" = y + thickness. "Wing lifts up" = y - lift.
final class EyelinerRenderer {

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
        guard intensity > 0.0 else { clearLayer(layer); return }

        guard let face = landmarks.first,
              !face.leftEye.isEmpty || !face.rightEye.isEmpty else {
            clearLayer(layer); return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.convertProcessedFrameNormalizedToView($0, contentExtent: extent, viewBounds: bounds) }
        } else {
            convert = { Self.convertToLayerSpace($0, in: previewLayer) }
        }

        let path = CGMutablePath()

        // Vision convention:
        //   leftEye  = subject's left eye = appears on RIGHT of screen → outer corner at max-x
        //   rightEye = subject's right eye = appears on LEFT of screen → outer corner at min-x
        if !face.leftEye.isEmpty {
            addEyeliner(eye: face.leftEye,  outerOnRight: true,  convert: convert, intensity: intensity, to: path)
        }
        if !face.rightEye.isEmpty {
            addEyeliner(eye: face.rightEye, outerOnRight: false, convert: convert, intensity: intensity, to: path)
        }

        layer.path        = path
        layer.fillColor   = NSColor.labelColor.withAlphaComponent(intensity).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth   = 0
        layer.lineCap     = .round
        layer.lineJoin    = .round
        layer.fillRule    = .nonZero
        layer.shadowColor   = NSColor.labelColor.withAlphaComponent(0.12 * intensity).cgColor
        layer.shadowRadius  = 0.8
        layer.shadowOpacity = 1.0
        layer.shadowOffset  = .zero
    }

    // MARK: - Per-eye

    private func addEyeliner(
        eye: [CGPoint],
        outerOnRight: Bool,
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        to path: CGMutablePath
    ) {
        // Vision returns as few as 6 points per eye — lower guard to 3
        guard eye.count >= 3 else { return }

        // 1. Upper lid in normalised space (larger y = higher = upper lid)
        let centY     = eye.map(\.y).reduce(0, +) / CGFloat(eye.count)
        var upperNorm = eye.filter { $0.y >= centY }

        // If filter leaves too few, use all points (Vision sometimes returns
        // only upper-lid points already)
        if upperNorm.count < 3 { upperNorm = eye }
        guard upperNorm.count >= 2 else { return }

        // 2. Convert to view space
        var pts = upperNorm.map(convert)

        // 3. Sort inner → outer
        pts.sort { outerOnRight ? $0.x < $1.x : $0.x > $1.x }

        // 4. Deduplicate near-identical x values
        pts = deduplicate(pts, minSpacing: 1.0)
        guard pts.count >= 2 else { return }

        let lidSpan = abs(pts.last!.x - pts.first!.x)
        guard lidSpan > 2 else { return }

        // 5. Smooth spine — fewer passes needed for Vision (cleaner points)
        var spine = pts
        for _ in 0..<3 {
            spine = movingAverage(spine, window: 3)
        }
        guard spine.count >= 2 else { return }

        // 6. Build liner band edges
        //    y + thickness = below lash line (downward in view space)
        let maxThick = max(2.5, min(lidSpan * (0.045 + 0.025 * intensity), 7.0))

        var upperEdge = [CGPoint]()
        var lowerEdge = [CGPoint]()
        upperEdge.reserveCapacity(spine.count)
        lowerEdge.reserveCapacity(spine.count)

        for (i, p) in spine.enumerated() {
            let t     = CGFloat(i) / CGFloat(max(spine.count - 1, 1))
            let taper = smoothStep(0.0, 0.30, t)
            let boost = 1.0 + 0.50 * smoothStep(0.55, 1.0, t)
            let thick = maxThick * taper * boost
            upperEdge.append(p)
            lowerEdge.append(CGPoint(x: p.x, y: p.y + thick))
        }

        let outerU = upperEdge.last!
        let outerL = lowerEdge.last!

        // 7. Wing tangent from last segment
        let refPt = spine[max(0, spine.count - min(3, spine.count))]
        var tx    = outerU.x - refPt.x
        var ty    = outerU.y - refPt.y
        let tLen  = max(1, hypot(tx, ty))
        tx /= tLen; ty /= tLen

        // Force outward direction
        if  outerOnRight && tx < 0 { tx = -tx; ty = -ty }
        if !outerOnRight && tx > 0 { tx = -tx; ty = -ty }

        // Wing size: proportional to lid span
        let wLen  = lidSpan * (0.18 + 0.08 * intensity)
        let wLift = lidSpan * (0.10 + 0.05 * intensity)   // upward = -y in view space

        // Perpendicular upward: rotate tangent 90° → (-ty, tx)
        // In view space y-down: upward = -y, so lift component is -py
        let px = -ty
        let py =  tx
        // py is positive when tangent goes left→right, which = downward in view space
        // We want upward so we negate: wing lifts by -py * wLift
        let wingTip = CGPoint(
            x: outerU.x + tx * wLen + px * wLift,
            y: outerU.y + ty * wLen - py * wLift   // -py = upward
        )

        // 8. Closed polygon
        let band = CGMutablePath()

        // Upper edge: inner → outer
        band.move(to: upperEdge[0])
        var prev = upperEdge[0]
        for pt in upperEdge.dropFirst() {
            let mid = CGPoint(x: (prev.x + pt.x) / 2, y: (prev.y + pt.y) / 2)
            band.addQuadCurve(to: mid, control: prev)
            prev = pt
        }
        band.addLine(to: outerU)

        // Wing
        let wingCtrl = CGPoint(
            x: outerU.x + tx * wLen * 0.5 + px * wLift * 0.3,
            y: outerU.y + ty * wLen * 0.5 - py * wLift * 0.3
        )
        band.addQuadCurve(to: wingTip, control: wingCtrl)

        // Back down to outer-lower
        band.addLine(to: outerL)

        // Lower edge: outer → inner (skip outerL)
        let lowerReturn = Array(lowerEdge.dropLast().reversed())
        prev = outerL
        for pt in lowerReturn {
            let mid = CGPoint(x: (prev.x + pt.x) / 2, y: (prev.y + pt.y) / 2)
            band.addQuadCurve(to: mid, control: prev)
            prev = pt
        }
        band.addLine(to: lowerEdge[0])
        band.closeSubpath()

        path.addPath(band)
    }

    // MARK: - Spine helpers

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
            let lo    = max(0, i - window / 2)
            let hi    = min(pts.count - 1, i + window / 2)
            let slice = pts[lo...hi]
            let cx    = slice.map(\.x).reduce(0, +) / CGFloat(slice.count)
            let cy    = slice.map(\.y).reduce(0, +) / CGFloat(slice.count)
            return CGPoint(x: cx, y: cy)
        }
    }

    private func smoothStep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - edge0) / max(edge1 - edge0, 0.0001)))
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

    private static func convertToLayerSpace(_ p: CGPoint, in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func convertProcessedFrameNormalizedToView(
        _ normalized: CGPoint,
        contentExtent: CGRect,
        viewBounds: CGRect
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
