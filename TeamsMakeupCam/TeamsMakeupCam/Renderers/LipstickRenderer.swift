import AVFoundation
import AppKit

/// Renders a filled lipstick overlay using detected lip landmarks.
///
/// When `lipstickOpacity` is 0 the layer is fully cleared (no ghost effect).
final class LipstickRenderer {

    func updateLipstickLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let baseAlpha = max(0.0, min(settings.lipstickOpacity, 1.0))

        // ── Zero guard ────────────────────────────────────────────────────────
        guard baseAlpha > 0.0 else { clearLayer(layer); return }

        guard let face = landmarks.first, !face.lips.isEmpty else {
            clearLayer(layer); return
        }

        let outer = face.lips
        let inner = face.innerLips

        let outerPoints: [CGPoint]
        let innerPoints: [CGPoint]
        if useProcessedFrameCoordinates, let extent = contentExtent, let bounds = viewBounds {
            outerPoints = outer.map { Self.convertProcessedFrameNormalizedToView($0, contentExtent: extent, viewBounds: bounds) }
            innerPoints = inner.map { Self.convertProcessedFrameNormalizedToView($0, contentExtent: extent, viewBounds: bounds) }
        } else {
            outerPoints = outer.map { convertToLayerSpace($0, in: previewLayer) }
            innerPoints = inner.map { convertToLayerSpace($0, in: previewLayer) }
        }

        let path = CGMutablePath()
        addSmoothClosedPath(outerPoints, to: path)
        if !innerPoints.isEmpty { addSmoothClosedPath(innerPoints, to: path) }

        layer.path     = path
        layer.fillRule = .evenOdd

        let nsColor     = settings.lipstickNSColor
        let fillAlpha   = baseAlpha * 0.65
        let strokeAlpha = min(baseAlpha * 0.30, 0.22)

        layer.fillColor     = nsColor.withAlphaComponent(fillAlpha).cgColor
        layer.strokeColor   = nsColor.withAlphaComponent(strokeAlpha).cgColor
        layer.lineWidth     = 0.9
        layer.shadowOpacity = 0    // ensure no leftover shadow
    }

    // MARK: - Layer clearing

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path          = nil
        layer.fillColor     = NSColor.clear.cgColor
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

    private func convertToLayerSpace(_ p: CGPoint,
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
