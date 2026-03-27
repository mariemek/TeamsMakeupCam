import AVFoundation
import AppKit

/// Renders lash overlays by positioning a transparent PNG lash-strip image onto
/// the detected upper eyelid curve for each eye.
///
/// Each eye gets its own `CALayer`.  The lash image band (bottom arc) is aligned
/// to the upper-lid lash line using position, scale, and rotation derived from
/// the inner and outer eye corners.
///
/// ## Realism techniques
/// - **Temporal smoothing** on position, scale, and angle to prevent jitter.
/// - **Blink hold**: Retains last-good placement during blinks.
/// - **Opacity** controlled by `lashesIntensity * lashesOpacity`.
final class LashesRenderer {

    // MARK: - Per-eye tracking state

    private struct EyeState {
        var smoothedInner: CGPoint?
        var smoothedOuter: CGPoint?
        var smoothedMidY: CGFloat?
        var smoothedAngle: CGFloat?
        var smoothedSpan: CGFloat?
        var hasValidPlacement = false
    }

    private var leftState  = EyeState()
    private var rightState = EyeState()

    private let posAlpha: CGFloat   = 0.35
    private let angleAlpha: CGFloat = 0.30
    private let sizeAlpha: CGFloat  = 0.30
    private let blinkThreshold: CGFloat = 0.10

    /// Width multiplier: the lash strip occupies ~70% of the image width,
    /// so we need ~1.45× to make the actual lash strip match the eye span.
    private let widthOvershoot: CGFloat = 1.45

    /// Nudge toward eye center so band sits ON the lash line (fraction of eye span).
    private let verticalNudge: CGFloat = 0.06

    /// Fraction from top of image where the lash band sits (per-style).
    /// Measured from the PNG bounding box bottom (where the band curve is).
    private func bandYFraction(for style: MakeupSettings.LashStyle) -> CGFloat {
        switch style {
        case .natural:  return 0.55   // band at 55% from top
        case .wispy:    return 0.68   // band at 68% from top
        case .dramatic: return 0.58   // band at 58% from top
        }
    }

    // MARK: - Cached image per style

    private var cachedStyle: MakeupSettings.LashStyle?
    private var cachedImage: CGImage?

    // MARK: - Public entry point

    func updateLashLayers(
        leftLayer: CALayer,
        rightLayer: CALayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = max(0.0, min(settings.lashesIntensity, 1.0))
        let opacity   = max(0.0, min(settings.lashesOpacity, 1.0))

        guard intensity > 0.0, opacity > 0.0 else {
            clearLayer(leftLayer)
            clearLayer(rightLayer)
            leftState  = EyeState()
            rightState = EyeState()
            return
        }

        guard let face = landmarks.first,
              (!face.leftEye.isEmpty || !face.rightEye.isEmpty) else {
            clearLayer(leftLayer)
            clearLayer(rightLayer)
            return
        }

        let image = lashImage(for: settings.lashStyle)
        guard let image else {
            clearLayer(leftLayer)
            clearLayer(rightLayer)
            return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.normToView($0, extent: extent, bounds: bounds) }
        } else {
            convert = { Self.toLayer($0, in: previewLayer) }
        }

        let finalOpacity = Float(intensity * opacity)
        let bandY = bandYFraction(for: settings.lashStyle)

        if !face.leftEye.isEmpty {
            updateSingleEye(
                layer: leftLayer,
                eye: face.leftEye,
                upperLid: face.leftUpperEyelidRaw.isEmpty ? nil : face.leftUpperEyelidRaw,
                convert: convert,
                image: image,
                flipHorizontally: false,
                opacity: finalOpacity,
                bandY: bandY,
                state: &leftState
            )
        } else {
            clearLayer(leftLayer)
        }

        if !face.rightEye.isEmpty {
            updateSingleEye(
                layer: rightLayer,
                eye: face.rightEye,
                upperLid: face.rightUpperEyelidRaw.isEmpty ? nil : face.rightUpperEyelidRaw,
                convert: convert,
                image: image,
                flipHorizontally: true,
                opacity: finalOpacity,
                bandY: bandY,
                state: &rightState
            )
        } else {
            clearLayer(rightLayer)
        }
    }

    // MARK: - Single-eye update

    private func updateSingleEye(
        layer: CALayer,
        eye: [CGPoint],
        upperLid: [CGPoint]?,
        convert: (CGPoint) -> CGPoint,
        image: CGImage,
        flipHorizontally: Bool,
        opacity: Float,
        bandY: CGFloat,
        state: inout EyeState
    ) {
        guard eye.count > 3 else { holdOrClear(layer, state: state); return }

        if eyeOpenness(eye) < blinkThreshold {
            holdOrClear(layer, state: state)
            return
        }

        let spineSource = upperLid ?? eye
        guard let spine = buildSpine(points: spineSource, convert: convert) else {
            holdOrClear(layer, state: state)
            return
        }
        guard spine.count >= 3 else { holdOrClear(layer, state: state); return }

        let innerPt = spine.first!
        let outerPt = spine.last!
        let span    = hypot(outerPt.x - innerPt.x, outerPt.y - innerPt.y)
        guard span > 4 else { holdOrClear(layer, state: state); return }

        let midIdx = spine.count / 2
        let midY   = spine[midIdx].y
        let angle  = atan2(outerPt.y - innerPt.y, outerPt.x - innerPt.x)

        // Temporal smoothing.
        let sInner = smoothPt(innerPt, prev: state.smoothedInner, alpha: posAlpha)
        let sOuter = smoothPt(outerPt, prev: state.smoothedOuter, alpha: posAlpha)
        let sMidY  = smoothVal(midY, prev: state.smoothedMidY, alpha: posAlpha)
        let sAngle = smoothVal(angle, prev: state.smoothedAngle, alpha: angleAlpha)
        let sSpan  = smoothVal(span, prev: state.smoothedSpan, alpha: sizeAlpha)

        state.smoothedInner = sInner
        state.smoothedOuter = sOuter
        state.smoothedMidY  = sMidY
        state.smoothedAngle = sAngle
        state.smoothedSpan  = sSpan

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0 else { return }

        // Scale image to match eye span.
        let targetW = sSpan * widthOvershoot
        let scale   = targetW / imgW

        // Band target: midpoint of the lid line, nudged toward eye center.
        let midX  = (sInner.x + sOuter.x) / 2
        let nudge = sSpan * verticalNudge

        let nx = -sin(sAngle)
        let ny =  cos(sAngle)
        let eyeCenter = centroid(eye.map(convert))
        let toC = CGPoint(x: eyeCenter.x - midX, y: eyeCenter.y - sMidY)
        let dot = nx * toC.x + ny * toC.y
        let s: CGFloat = dot > 0 ? 1 : -1

        let targetX = midX + s * nx * nudge
        let targetY = sMidY + s * ny * nudge

        let layerW = imgW * scale
        let layerH = imgH * scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer.contents = image
        layer.contentsGravity = .resize
        layer.bounds = CGRect(x: 0, y: 0, width: layerW, height: layerH)

        // Anchor at band center: horizontally centered, vertically at the band.
        layer.anchorPoint = CGPoint(x: 0.5, y: bandY)
        layer.position = CGPoint(x: targetX, y: targetY)

        // Rotation + optional horizontal flip for the other eye.
        var xform = CATransform3DMakeRotation(sAngle, 0, 0, 1)
        if flipHorizontally {
            xform = CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), xform)
        }
        layer.transform = xform

        layer.opacity = opacity

        CATransaction.commit()

        state.hasValidPlacement = true
    }

    // MARK: - Spine building

    private func buildSpine(
        points: [CGPoint],
        convert: (CGPoint) -> CGPoint
    ) -> [CGPoint]? {
        guard points.count >= 5 else { return nil }

        let centY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let upper = points.filter { $0.y >= centY }
        guard upper.count >= 3 else { return nil }

        var pts = upper.map(convert)
        pts = deduplicate(pts, minGap: 1.0)
        guard pts.count >= 3 else { return nil }
        pts.sort { $0.x < $1.x }

        return movingAverage(pts, window: 3)
    }

    // MARK: - Image loading

    private func lashImage(for style: MakeupSettings.LashStyle) -> CGImage? {
        if style == cachedStyle, let img = cachedImage { return img }

        let names: [String]
        switch style {
        case .natural:  names = ["lash_natural", "lashes"]
        case .wispy:    names = ["lash_wispy", "lashes"]
        case .dramatic: names = ["lash_dramatic", "lashes"]
        }

        for name in names {
            if let nsImage = NSImage(named: name),
               let tiff = nsImage.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let cg = rep.cgImage {
                cachedStyle = style
                cachedImage = cg
                return cg
            }
        }

        return nil
    }

    // MARK: - Layer helpers

    private func clearLayer(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        layer.opacity = 0
        CATransaction.commit()
    }

    private func holdOrClear(_ layer: CALayer, state: EyeState) {
        guard !state.hasValidPlacement else { return }
        clearLayer(layer)
    }

    // MARK: - Geometry helpers

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

    private func smoothPt(_ cur: CGPoint, prev: CGPoint?, alpha: CGFloat) -> CGPoint {
        guard let prev else { return cur }
        return CGPoint(
            x: prev.x + (cur.x - prev.x) * alpha,
            y: prev.y + (cur.y - prev.y) * alpha
        )
    }

    private func smoothVal(_ cur: CGFloat, prev: CGFloat?, alpha: CGFloat) -> CGFloat {
        guard let prev else { return cur }
        return prev + (cur - prev) * alpha
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
