import AVFoundation
import AppKit

/// Renders lash overlays by warping a PNG lash-strip image onto the detected
/// upper eyelid curve for each eye.
///
/// Each eye gets its own `CALayer` so that position, rotation, and scale can be
/// computed independently.  The lash image band (bottom arc) is aligned to the
/// upper-lid lash line using an affine transform derived from the inner and
/// outer eye corners.
///
/// ## Realism techniques
/// - **Multiply blend mode** so the lash texture blends with skin/eye.
/// - **Slight Gaussian blur** to soften edges and match camera focus.
/// - **Temporal smoothing** on position, scale, and angle to prevent jitter.
/// - **Blink hold**: Retains last-good placement during blinks.
final class LashesRenderer {

    // MARK: - Per-eye tracking state (temporal smoothing + blink hold)

    private struct EyeState {
        var smoothedInner: CGPoint?
        var smoothedOuter: CGPoint?
        var smoothedMidY: CGFloat?
        var smoothedAngle: CGFloat?
        var smoothedSpan: CGFloat?
        var lastGoodTransform: CATransform3D?
        var lastGoodBounds: CGRect?
    }

    private var leftState  = EyeState()
    private var rightState = EyeState()

    private let posAlpha: CGFloat   = 0.30   // position smoothing (lower = smoother)
    private let angleAlpha: CGFloat = 0.25
    private let sizeAlpha: CGFloat  = 0.25
    private let blinkThreshold: CGFloat = 0.10

    /// Fraction from top of image where the band center sits.
    /// The lash PNGs have the band (strip base) at the bottom of the arc;
    /// the hairs extend upward.  We want to align the band, not the hair tips.
    /// ~0.78 means the band center is at 78% down from the top of the image.
    private let bandYFraction: CGFloat = 0.78

    /// Extra width multiplier so the strip slightly overshoots the corners.
    private let widthOvershoot: CGFloat = 1.12

    /// How far above the lash line (toward forehead) to nudge the image
    /// so the band sits exactly on the lid edge.  Expressed as a fraction
    /// of the eye span.
    private let verticalNudge: CGFloat = 0.04

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

        // Load / cache lash image for the current style.
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
        let blur = settings.lashesBlurRadius

        // Left eye — image used as-is (the strip curves as a left-eye lash).
        if !face.leftEye.isEmpty {
            updateSingleEye(
                layer: leftLayer,
                eye: face.leftEye,
                upperLid: face.leftUpperEyelidRaw.isEmpty ? nil : face.leftUpperEyelidRaw,
                convert: convert,
                image: image,
                flipHorizontally: false,
                opacity: finalOpacity,
                blur: blur,
                state: &leftState
            )
        } else {
            clearLayer(leftLayer)
        }

        // Right eye — horizontally flipped.
        if !face.rightEye.isEmpty {
            updateSingleEye(
                layer: rightLayer,
                eye: face.rightEye,
                upperLid: face.rightUpperEyelidRaw.isEmpty ? nil : face.rightUpperEyelidRaw,
                convert: convert,
                image: image,
                flipHorizontally: true,
                opacity: finalOpacity,
                blur: blur,
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
        blur: Double,
        state: inout EyeState
    ) {
        guard eye.count > 3 else { holdOrClear(layer, state: state); return }

        // Blink detection.
        if eyeOpenness(eye) < blinkThreshold {
            holdOrClear(layer, state: state)
            return
        }

        // Build upper lid spine (inner → outer in screen coords).
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

        // Compute the midpoint Y of the spine (where the band should sit).
        let midIdx = spine.count / 2
        let midY   = spine[midIdx].y

        // Angle of the line from inner to outer corner.
        let angle = atan2(outerPt.y - innerPt.y, outerPt.x - innerPt.x)

        // Temporal smoothing.
        let sInner = smoothPoint(innerPt, prev: state.smoothedInner, alpha: posAlpha)
        let sOuter = smoothPoint(outerPt, prev: state.smoothedOuter, alpha: posAlpha)
        let sMidY  = smoothScalar(midY, prev: state.smoothedMidY, alpha: posAlpha)
        let sAngle = smoothScalar(angle, prev: state.smoothedAngle, alpha: angleAlpha)
        let sSpan  = smoothScalar(span, prev: state.smoothedSpan, alpha: sizeAlpha)

        state.smoothedInner = sInner
        state.smoothedOuter = sOuter
        state.smoothedMidY  = sMidY
        state.smoothedAngle = sAngle
        state.smoothedSpan  = sSpan

        // Image natural dimensions.
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0 else { return }

        // Target width: eye span * overshoot.
        let targetW = sSpan * widthOvershoot
        let scaleX  = targetW / imgW
        let scaleY  = scaleX   // uniform scale to maintain aspect ratio

        // Position: center of the band should sit on the lash line.
        // The band center is at (imgW/2, imgH * bandYFraction) in image space.
        // After scaling, that point should map to the midpoint of the lid line,
        // nudged slightly upward so the band sits ON the lash line.
        let midX = (sInner.x + sOuter.x) / 2
        let nudge = sSpan * verticalNudge

        // Nudge the band toward the eye center (perpendicular to lash line)
        // so it sits ON the upper lid edge rather than floating above.
        let nx = -sin(sAngle)
        let ny =  cos(sAngle)
        let eyeCenter = centroid(eye.map(convert))
        let toCenter = CGPoint(x: eyeCenter.x - midX, y: eyeCenter.y - sMidY)
        let dot = nx * toCenter.x + ny * toCenter.y
        let sign: CGFloat = dot > 0 ? 1 : -1

        let bandTargetX = midX + sign * nx * nudge
        let bandTargetY = sMidY + sign * ny * nudge

        // Layer bounds = scaled image size.
        let layerBounds = CGRect(x: 0, y: 0, width: imgW * scaleX, height: imgH * scaleY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer.contents = image
        layer.contentsGravity = .resize
        layer.bounds = layerBounds
        layer.masksToBounds = false

        // Anchor at band center: horizontally centered, vertically at the band line.
        // position maps this anchor point to the target in the superlayer.
        layer.anchorPoint = CGPoint(x: 0.5, y: bandYFraction)
        layer.position = CGPoint(x: bandTargetX, y: bandTargetY)

        // Rotation around the anchor (band center) + optional horizontal flip.
        var transform3D = CATransform3DMakeAffineTransform(
            CGAffineTransform(rotationAngle: sAngle)
        )
        if flipHorizontally {
            transform3D = CATransform3DConcat(
                CATransform3DMakeScale(-1, 1, 1),
                transform3D
            )
        }
        layer.transform = transform3D

        layer.opacity = opacity
        layer.compositingFilter = "multiplyBlendMode"

        // Gaussian blur for edge softness.
        if blur > 0.01 {
            if let existing = layer.filters?.first as? CIFilter, existing.name == "CIGaussianBlur" {
                existing.setValue(blur, forKey: kCIInputRadiusKey)
            } else {
                let blurFilter = CIFilter(name: "CIGaussianBlur")!
                blurFilter.setValue(blur, forKey: kCIInputRadiusKey)
                layer.filters = [blurFilter]
            }
        } else {
            layer.filters = nil
        }

        CATransaction.commit()

        state.lastGoodTransform = layer.transform
        state.lastGoodBounds = layerBounds
    }

    // MARK: - Spine building

    /// Extracts and sorts the upper-lid points inner→outer in screen coords.
    private func buildSpine(
        points: [CGPoint],
        convert: (CGPoint) -> CGPoint
    ) -> [CGPoint]? {
        guard points.count >= 5 else { return nil }

        let centY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        // In normalized coords (bottom-left origin), upper lid has HIGHER y.
        let upper = points.filter { $0.y >= centY }
        guard upper.count >= 3 else { return nil }

        var pts = upper.map(convert)
        pts = deduplicate(pts, minGap: 1.0)
        guard pts.count >= 3 else { return nil }

        // Sort left-to-right in screen coords.
        pts.sort { $0.x < $1.x }

        return movingAverage(pts, window: 3)
    }

    // MARK: - Image loading

    private func lashImage(for style: MakeupSettings.LashStyle) -> CGImage? {
        if style == cachedStyle, let img = cachedImage { return img }

        let name: String
        switch style {
        case .natural:  name = "lash_natural"
        case .wispy:    name = "lash_wispy"
        case .dramatic: name = "lash_dramatic"
        }

        guard let nsImage = NSImage(named: name),
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage else {
            // Fallback: try the old single "lashes" asset.
            if let fallback = NSImage(named: "lashes"),
               let tiff = fallback.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let cg = rep.cgImage {
                cachedStyle = style
                cachedImage = cg
                return cg
            }
            return nil
        }

        cachedStyle = style
        cachedImage = cgImage
        return cgImage
    }

    // MARK: - Layer helpers

    private func clearLayer(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        layer.opacity = 0
        layer.filters = nil
        CATransaction.commit()
    }

    private func holdOrClear(_ layer: CALayer, state: EyeState) {
        if state.lastGoodTransform != nil {
            // Keep showing the last good frame during blink.
            return
        }
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

    private func smoothPoint(_ cur: CGPoint, prev: CGPoint?, alpha: CGFloat) -> CGPoint {
        guard let prev else { return cur }
        return CGPoint(
            x: prev.x + (cur.x - prev.x) * alpha,
            y: prev.y + (cur.y - prev.y) * alpha
        )
    }

    private func smoothScalar(_ cur: CGFloat, prev: CGFloat?, alpha: CGFloat) -> CGFloat {
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
