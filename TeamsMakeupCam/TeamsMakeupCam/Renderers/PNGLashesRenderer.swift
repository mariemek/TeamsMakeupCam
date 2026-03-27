import AVFoundation
import AppKit

// MARK: - LashStyle

enum LashStyle: String, CaseIterable, Codable {
    case natural
    case wispy
    case dramatic
}

// MARK: - PNGLashesRenderer
//
// Overlays a procedurally-generated lash-strip image on each eye.
//
// The strip is rendered once at init into a CGImage (transparent background,
// dark lash strands, fuller at the outer corner, tapering toward the inner).
// Each frame the renderer measures the upper eyelid from landmarks, smooths it
// via EMA, and maps the image onto the eye with an affine transform (position,
// scale, rotation).  The right eye uses a horizontally-flipped copy.
//
// This approach is inherently stable: the image shape never changes, only its
// placement does, and placement is smoothed.  Intensity controls opacity.
//
// Architecture
// ─────────────
//   containerLayer  (full-screen CALayer, receives the mirror transform)
//     ├── leftLashLayer   CALayer — image overlay for the left eye
//     └── rightLashLayer  CALayer — image overlay for the right eye

final class PNGLashesRenderer {

    // MARK: - Public
    let containerLayer = CALayer()

    // MARK: - Private
    private let leftLashLayer  = CALayer()
    private let rightLashLayer = CALayer()
    private var leftSmooth  = TransformSmoothing()
    private var rightSmooth = TransformSmoothing()

    /// The generated lash-strip image (outer-corner-right orientation).
    private let lashImage: CGImage
    /// Image size in points for layer bounds.
    private let imageSize: CGSize

    // Strip generation constants.
    private static let stripWidth:  CGFloat = 512
    private static let stripHeight: CGFloat = 180

    // MARK: - Init

    init() {
        let img = Self.generateLashStrip(
            width: Self.stripWidth, height: Self.stripHeight, style: .wispy)
        self.lashImage = img
        self.imageSize = CGSize(width: Self.stripWidth, height: Self.stripHeight)

        containerLayer.backgroundColor = NSColor.clear.cgColor
        containerLayer.masksToBounds   = false

        for lashLayer in [leftLashLayer, rightLashLayer] {
            lashLayer.contents        = img
            lashLayer.contentsGravity = .resizeAspect
            lashLayer.isHidden        = true
            lashLayer.masksToBounds   = false
            lashLayer.anchorPoint     = CGPoint(x: 0.5, y: 1.0)  // bottom-center anchor
            containerLayer.addSublayer(lashLayer)
        }
    }

    // MARK: - Public update (called every frame)

    func update(
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        style: LashStyle = .wispy,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = max(0, min(settings.lashesIntensity, 1.0))
        guard intensity > 0, let face = landmarks.first else { hide(); return }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates,
           let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.fromProcessedFrame($0, extent: extent, viewBounds: bounds) }
        } else {
            convert = { Self.fromPreviewLayer($0, in: previewLayer) }
        }

        let leftEyelid  = face.leftUpperEyelid.isEmpty  ? face.leftEye  : face.leftUpperEyelid
        let rightEyelid = face.rightUpperEyelid.isEmpty ? face.rightEye : face.rightUpperEyelid

        updateEye(layer: leftLashLayer,  state: &leftSmooth,
                  eyelid: leftEyelid,  fullEye: face.leftEye,
                  convert: convert, intensity: intensity, flipImage: true)

        updateEye(layer: rightLashLayer, state: &rightSmooth,
                  eyelid: rightEyelid, fullEye: face.rightEye,
                  convert: convert, intensity: intensity, flipImage: false)
    }

    func hide() {
        leftLashLayer.isHidden  = true
        rightLashLayer.isHidden = true
        leftSmooth  = TransformSmoothing()
        rightSmooth = TransformSmoothing()
    }

    // MARK: - Per-eye update

    private func updateEye(
        layer: CALayer,
        state: inout TransformSmoothing,
        eyelid: [CGPoint],
        fullEye: [CGPoint],
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        flipImage: Bool
    ) {
        guard eyelid.count >= 2 else { layer.isHidden = true; return }

        // Convert to view space and sort left→right.
        let rawPts = eyelid.map(convert).sorted { $0.x < $1.x }
        guard rawPts.count >= 2 else { layer.isHidden = true; return }

        // Endpoints of the lash line.
        let leftPt  = rawPts.first!
        let rightPt = rawPts.last!

        let eyeWidth = hypot(rightPt.x - leftPt.x, rightPt.y - leftPt.y)
        guard eyeWidth > 4 else { layer.isHidden = true; return }

        // Midpoint of the lash line.
        let midX = (leftPt.x + rightPt.x) / 2
        let midY = (leftPt.y + rightPt.y) / 2

        // Angle of the lash line.
        let angle = atan2(rightPt.y - leftPt.y, rightPt.x - leftPt.x)

        // Compute eye center to shift lashes slightly upward (away from pupil).
        let allPts = fullEye.map(convert)
        let eyeCenterY: CGFloat
        if allPts.count >= 3 {
            eyeCenterY = allPts.map(\.y).reduce(0, +) / CGFloat(allPts.count)
        } else {
            eyeCenterY = midY
        }
        // Offset along the perpendicular to the lash line, away from eye center.
        let perpX = -sin(angle)
        let perpY =  cos(angle)
        // Determine which direction is "away from eye center."
        let testPtY = midY + perpY * 5
        let awaySign: CGFloat = (testPtY < eyeCenterY) ? 1 : -1  // on macOS, lower y = higher on screen
        let verticalOffset = eyeWidth * 0.04 * awaySign

        let posX = midX + perpX * verticalOffset
        let posY = midY + perpY * verticalOffset

        // Smooth the transform values.
        let smoothed = state.update(x: posX, y: posY, width: eyeWidth, angle: angle)

        // Scale: image width → eye width, with a slight horizontal overshoot
        // so the strip covers the full lash line including corners.
        let scaleX = smoothed.width * 1.15 / imageSize.width
        let scaleY = scaleX  // uniform scale preserves proportions
        let flipScaleX = flipImage ? -scaleX : scaleX

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer.isHidden = false
        layer.opacity  = Float(intensity)
        layer.bounds   = CGRect(origin: .zero, size: imageSize)
        layer.position = CGPoint(x: smoothed.x, y: smoothed.y)

        // Compose: rotate to match lash line angle, scale to match eye width,
        // optionally flip horizontally for the other eye.
        var t = CATransform3DIdentity
        t = CATransform3DRotate(t, smoothed.angle, 0, 0, 1)
        t = CATransform3DScale(t, flipScaleX, scaleY, 1)
        layer.transform = t

        CATransaction.commit()
    }

    // MARK: - Lash strip generation
    //
    // Draws a high-quality lash strip into an offscreen bitmap.
    // The strip has:
    //   - Fuller/longer lashes on the RIGHT side (outer corner)
    //   - Shorter/sparser lashes on the LEFT side (inner corner)
    //   - Natural J-curve shape on each strand
    //   - Subtle per-strand variation for realism
    //   - Dark strands on transparent background

    private static func generateLashStrip(
        width: CGFloat, height: CGFloat, style: LashStyle
    ) -> CGImage {
        let w = Int(width), h = Int(height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Clear background.
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        // Lash color — very dark brown-black.
        ctx.setStrokeColor(NSColor(calibratedRed: 0.06, green: 0.04,
                                    blue: 0.05, alpha: 0.92).cgColor)

        // The baseline sits at the bottom of the image.
        let baseline: CGFloat = 10

        // Number of strands and style parameters.
        let strandCount: Int
        let maxLenFrac:  CGFloat  // max length as fraction of height
        let baseWidth:   CGFloat  // stroke width
        let curlAmount:  CGFloat  // how much J-curl

        switch style {
        case .natural:
            strandCount = 50
            maxLenFrac  = 0.70
            baseWidth   = 1.4
            curlAmount  = 0.25
        case .wispy:
            strandCount = 60
            maxLenFrac  = 0.82
            baseWidth   = 1.2
            curlAmount  = 0.30
        case .dramatic:
            strandCount = 80
            maxLenFrac  = 0.92
            baseWidth   = 1.5
            curlAmount  = 0.22
        }

        var rng = SeededRNG(seed: style.rawValue.hashValue &+ 0xBEEF)

        for i in 0..<strandCount {
            let t = CGFloat(i) / CGFloat(strandCount - 1)  // 0=left(inner), 1=right(outer)

            // ── Position along baseline ─────────────────────────────────
            // Slight jitter so strands aren't perfectly evenly spaced.
            let jitter = rng.next(-4, 4)
            let x = 12 + t * (width - 24) + jitter

            // ── Length: short at inner (left), long at outer (right) ────
            // Smooth envelope with a bit of variation.
            let envelope = 0.15 + 0.85 * smoothstepStatic(t)
            let lenVar = rng.next(0.82, 1.08)
            let lashLen = height * maxLenFrac * envelope * lenVar
            guard lashLen > 4 else { continue }

            // ── Angle: lashes fan outward slightly ──────────────────────
            // Inner lashes point more vertically, outer lashes lean outward.
            let baseAngle: CGFloat = .pi / 2  // straight up
            let fanAngle = (t - 0.4) * 0.35   // lean right for outer lashes
            let angleVar = rng.next(-0.06, 0.06)
            let angle = baseAngle + fanAngle + angleVar

            // ── Curl (J-curve via quadratic bezier) ─────────────────────
            // The control point is offset to create the curl.
            let cosA = cos(angle), sinA = sin(angle)
            let tipX = x + cosA * lashLen
            let tipY = baseline + sinA * lashLen

            // Curl the tip inward (toward the eye) by offsetting the control point.
            // The curl amount increases toward the tip.
            let curlOffset = lashLen * curlAmount * (0.6 + 0.4 * t)
            let ctrlX = x + cosA * lashLen * 0.55 - sinA * curlOffset * 0.3
            let ctrlY = baseline + sinA * lashLen * 0.55 + cosA * curlOffset

            // ── Stroke width: thicker at base, thinner at tip ───────────
            // We approximate this by drawing the curve twice: once thick, once thin.
            let strokeW = baseWidth * (0.7 + 0.6 * rng.next(0.5, 1.0))

            ctx.setLineWidth(strokeW)
            ctx.setLineCap(.round)
            ctx.setAlpha(0.85 + rng.next(0, 0.15))

            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: baseline))
            path.addQuadCurve(
                to: CGPoint(x: tipX, y: tipY),
                control: CGPoint(x: ctrlX, y: ctrlY)
            )
            ctx.addPath(path)
            ctx.strokePath()
        }

        // ── Extra wispy accent strands (longer, thinner) ────────────────
        if style == .wispy {
            ctx.setLineWidth(0.8)
            for _ in 0..<12 {
                let t = rng.next(0.35, 1.0)  // mostly outer half
                let x = 12 + t * (width - 24) + rng.next(-3, 3)
                let envelope = 0.15 + 0.85 * smoothstepStatic(t)
                let lashLen = height * maxLenFrac * envelope * rng.next(1.05, 1.25)
                let angle: CGFloat = .pi / 2 + (t - 0.4) * 0.35 + rng.next(-0.08, 0.08)
                let cosA = cos(angle), sinA = sin(angle)
                let tipX = x + cosA * lashLen
                let tipY = baseline + sinA * lashLen
                let curlOffset = lashLen * curlAmount * 0.9
                let ctrlX = x + cosA * lashLen * 0.5 - sinA * curlOffset * 0.25
                let ctrlY = baseline + sinA * lashLen * 0.5 + cosA * curlOffset

                ctx.setAlpha(0.70 + rng.next(0, 0.20))
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: baseline))
                path.addQuadCurve(
                    to: CGPoint(x: tipX, y: tipY),
                    control: CGPoint(x: ctrlX, y: ctrlY)
                )
                ctx.addPath(path)
                ctx.strokePath()
            }
        }

        return ctx.makeImage()!
    }

    private static func smoothstepStatic(_ t: CGFloat) -> CGFloat {
        let c = max(0, min(1, t))
        return c * c * (3 - 2 * c)
    }

    // MARK: - Coordinate conversion

    private static func fromPreviewLayer(_ p: CGPoint,
                                         in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func fromProcessedFrame(_ p: CGPoint,
                                            extent: CGRect,
                                            viewBounds: CGRect) -> CGPoint {
        let w = extent.width, h = extent.height
        guard w > 0, h > 0 else { return .zero }
        let scale = max(viewBounds.width / w, viewBounds.height / h)
        let drawW = w * scale, drawH = h * scale
        let ox    = viewBounds.midX - drawW / 2
        let oy    = viewBounds.midY - drawH / 2
        return CGPoint(x: ox + p.x * drawW, y: oy + p.y * drawH)
    }
}

// MARK: - TransformSmoothing
//
// EMA smoothing on the 4 transform parameters (x, y, width, angle).
// Much more stable than smoothing individual landmark points because
// there are only 4 values, not dozens.

private struct TransformSmoothing {
    private var smoothX:     CGFloat?
    private var smoothY:     CGFloat?
    private var smoothWidth: CGFloat?
    private var smoothAngle: CGFloat?
    private let alpha: CGFloat = 0.38   // responsiveness (higher = faster, less smooth)

    struct Values {
        let x, y, width, angle: CGFloat
    }

    mutating func update(x: CGFloat, y: CGFloat, width: CGFloat, angle: CGFloat) -> Values {
        if let sx = smoothX {
            smoothX     = sx + alpha * (x - sx)
            smoothY     = smoothY! + alpha * (y - smoothY!)
            smoothWidth = smoothWidth! + alpha * (width - smoothWidth!)
            // Angle needs special handling for wrap-around.
            var da = angle - smoothAngle!
            if da >  .pi { da -= 2 * .pi }
            if da < -.pi { da += 2 * .pi }
            smoothAngle = smoothAngle! + alpha * da
        } else {
            smoothX     = x
            smoothY     = y
            smoothWidth = width
            smoothAngle = angle
        }
        return Values(x: smoothX!, y: smoothY!, width: smoothWidth!, angle: smoothAngle!)
    }
}

// MARK: - SeededRNG

private struct SeededRNG {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed &+ 0x9e37_79b9))
    }

    mutating func nextRaw() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func next(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        let norm = CGFloat(nextRaw() >> 11) / CGFloat(1 << 53)
        return lo + norm * (hi - lo)
    }
}
