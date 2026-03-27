import AVFoundation
import AppKit

/// Renders a lash-line enhancement: a smooth base stroke along the upper lid
/// plus outer-corner flicks that fan upward from the outer third of the lash line.
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

        // ── Zero guard ────────────────────────────────────────────────────────
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
        if !face.leftEye.isEmpty  { addLashes(eye: face.leftEye,  convert: convert, intensity: intensity, to: path) }
        if !face.rightEye.isEmpty { addLashes(eye: face.rightEye, convert: convert, intensity: intensity, to: path) }

        layer.path = path

        let alpha     = 0.30 + 0.45 * intensity      // ~0.30 – 0.75
        let lineWidth = 1.0  + 1.2  * intensity      // ~1.0 – 2.2 pt

        layer.strokeColor   = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        layer.fillColor     = nil
        layer.lineWidth     = lineWidth
        layer.lineCap       = .round
        layer.lineJoin      = .round
        layer.shadowColor   = NSColor.labelColor.withAlphaComponent(alpha * 0.35).cgColor
        layer.shadowRadius  = 1.0 + intensity * 1.0
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
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        to path: CGMutablePath
    ) {
        guard eye.count > 3 else { return }

        let centY  = eye.map { $0.y }.reduce(0, +) / CGFloat(eye.count)
        let upper  = eye.filter { $0.y >= centY }
        guard upper.count >= 2 else { return }

        let sorted = upper.map(convert).sorted { $0.x < $1.x }
        guard sorted.count >= 2 else { return }

        // Pass 1: smooth base lash line.
        path.move(to: sorted[0])
        var prev = sorted[0]
        for pt in sorted.dropFirst() {
            let mid = CGPoint(x: (prev.x + pt.x) / 2, y: (prev.y + pt.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            prev = pt
        }
        path.addLine(to: sorted.last!)

        // Pass 2: outer-corner flicks.
        addOuterFlicks(sorted: sorted, intensity: intensity, to: path)
    }

    /// 3–5 short fanning flicks from the outer third of the lash line.
    private func addOuterFlicks(
        sorted: [CGPoint],
        intensity: CGFloat,
        to path: CGMutablePath
    ) {
        guard sorted.count >= 4 else { return }

        let outerPt  = sorted.last!
        let innerRef = sorted[max(0, sorted.count - 4)]

        let dx  = outerPt.x - innerRef.x
        let dy  = outerPt.y - innerRef.y
        let len = max(1, hypot(dx, dy))
        let tx  = dx / len
        let ty  = dy / len
        let px  = -ty          // perpendicular (lift) direction
        let py  =  tx

        let span       = hypot(sorted.last!.x - sorted.first!.x,
                               sorted.last!.y - sorted.first!.y)
        let flickLen   = span * (0.05 + 0.07 * intensity)
        let flickCount = Int(3 + intensity * 2)

        let spreadRad  = CGFloat(25 + 15 * intensity) * .pi / 180
        let startAng   = -spreadRad * 0.2

        let outerSegStart = sorted.count - Int(CGFloat(sorted.count) * 0.30 + 0.5)
        let segment       = sorted.suffix(from: max(0, outerSegStart))

        for i in 0..<flickCount {
            let frac  = CGFloat(i) / CGFloat(max(flickCount - 1, 1))
            let angle = startAng + frac * spreadRad

            let cos_a = cos(angle), sin_a = sin(angle)
            let fx    = tx * cos_a - ty * sin_a
            let fy    = tx * sin_a + ty * cos_a

            let segIdx = Int(frac * CGFloat(max(segment.count - 1, 0)) + 0.5)
            let base   = segment.dropFirst(segIdx).first ?? outerPt

            let liftFrac: CGFloat = 0.20 + 0.30 * frac
            let tipX  = base.x + fx * flickLen - px * flickLen * liftFrac
            let tipY  = base.y + fy * flickLen + py * flickLen * liftFrac
            let ctrlX = base.x + fx * flickLen * 0.5 - px * flickLen * liftFrac * 0.4
            let ctrlY = base.y + fy * flickLen * 0.5 + py * flickLen * liftFrac * 0.4

            path.move(to: base)
            path.addQuadCurve(to: CGPoint(x: tipX, y: tipY),
                              control: CGPoint(x: ctrlX, y: ctrlY))
        }
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
