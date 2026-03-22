import AVFoundation
import AppKit

/// Renders a subtle lip liner along the outer lip contour.
///
/// When `lipLinerIntensity` is 0 the layer is fully cleared (no ghost effect).
final class LipLinerRenderer {

    func updateLipLinerLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = max(0.0, min(settings.lipLinerIntensity, 1.0))

        // ── Zero guard ────────────────────────────────────────────────────────
        guard intensity > 0.0 else { clearLayer(layer); return }

        guard let face = landmarks.first, !face.lips.isEmpty else {
            clearLayer(layer); return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.convertProcessedFrameNormalizedToView($0, contentExtent: extent, viewBounds: bounds) }
        } else {
            convert = { Self.convertToLayerSpace($0, in: previewLayer) }
        }

        let outerPoints = face.lips.map(convert)
        let path = CGMutablePath()
        addSmoothClosedPath(outerPoints, to: path)
        layer.path = path

        let baseColor  = settings.lipLinerNSColor
        let darker     = baseColor.blended(withFraction: 0.35, of: .black) ?? baseColor
        let alpha      = 0.10 + 0.30 * intensity   // ~0.10 – 0.40

        layer.strokeColor   = darker.withAlphaComponent(alpha).cgColor
        layer.fillColor     = nil
        layer.lineWidth     = 0.7 + 0.5 * intensity
        layer.lineCap       = .round
        layer.lineJoin      = .round
        layer.shadowOpacity = 0          // ensure no leftover shadow
    }

    // MARK: - Layer clearing

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path          = nil
        layer.fillColor     = nil
        layer.strokeColor   = NSColor.clear.cgColor
        layer.shadowColor   = NSColor.clear.cgColor
        layer.shadowOpacity = 0
    }

    // MARK: - Path helpers

    private func addSmoothClosedPath(_ points: [CGPoint], to path: CGMutablePath) {
        guard points.count > 2 else {
            guard let first = points.first else { return }
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
            return
        }

        var prev = points[0]
        path.move(to: prev)

        for i in 1..<points.count {
            let cur = points[i]
            let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            prev = cur
        }

        let closingMid = CGPoint(x: (prev.x + points[0].x) / 2,
                                  y: (prev.y + points[0].y) / 2)
        path.addQuadCurve(to: closingMid, control: prev)
        path.closeSubpath()
    }

    // MARK: - Coordinate conversion

    private static func convertToLayerSpace(_ p: CGPoint,
                                            in previewLayer: AVCaptureVideoPreviewLayer) -> CGPoint {
        previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
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
