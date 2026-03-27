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
// Overlays a lash-strip PNG image on each eye using multiply blend mode.
//
// The strip is loaded from the asset catalog ("lashes").  Multiply compositing
// makes the white background invisible (white × anything = anything) while dark
// lash strands darken the underlying skin naturally.  No pixel manipulation needed.
//
// Each frame the renderer measures the upper eyelid from smoothed landmarks and
// maps the image onto the eye with position / scale / rotation.  The left eye
// uses a horizontally-flipped copy so the outer-corner fullness lands on the
// correct side for both eyes.  Intensity controls layer opacity.
//
// Architecture
// ─────────────
//   containerLayer  (full-screen CALayer, receives the global mirror transform)
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

    /// The lash-strip image (outer corner on the LEFT side of the image).
    private let lashImage: CGImage
    /// Image size in POINTS for layer bounds (matches NSImage.size).
    private let imageSize: CGSize

    // MARK: - Init

    init() {
        // Try loading the bundled PNG from the asset catalog.
        if let nsImage = NSImage(named: "lashes"),
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            self.lashImage = cg
            self.imageSize = nsImage.size  // points — DPI-independent
        } else {
            // Fallback: procedurally generate a lash strip.
            let w: CGFloat = 512, h: CGFloat = 180
            self.lashImage = Self.generateLashStrip(width: w, height: h)
            self.imageSize = CGSize(width: w, height: h)
        }

        containerLayer.backgroundColor = NSColor.clear.cgColor
        containerLayer.masksToBounds   = false

        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0

        for lashLayer in [leftLashLayer, rightLashLayer] {
            lashLayer.contents        = lashImage
            lashLayer.contentsGravity = .resizeAspect
            lashLayer.contentsScale   = scaleFactor
            lashLayer.isHidden        = true
            lashLayer.masksToBounds   = false

            // Multiply blend: white → invisible, dark lash strands → darken skin.
            // This handles the white PNG background without any pixel manipulation.
            lashLayer.compositingFilter = "multiplyBlendMode"

            // Anchor at the top-center of the layer.
            // On macOS (y-up), CGImage contents render with the image's top row
            // at the top of the visual area.  The lash PNG has roots at the top
            // of the image → roots appear at the top of the layer (high y).
            // anchorPoint (0.5, 1.0) = top-center → roots sit at the position point.
            lashLayer.anchorPoint = CGPoint(x: 0.5, y: 1.0)

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

        // flipImage: true for the left eye so the outer corner (fuller end)
        // lands on the lateral side of each eye after the container mirror.
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

        let rawPts = eyelid.map(convert).sorted { $0.x < $1.x }
        guard rawPts.count >= 2 else { layer.isHidden = true; return }

        let leftPt  = rawPts.first!
        let rightPt = rawPts.last!

        let eyeWidth = hypot(rightPt.x - leftPt.x, rightPt.y - leftPt.y)
        guard eyeWidth > 4 else { layer.isHidden = true; return }

        // Midpoint of the upper eyelid.
        let midX = (leftPt.x + rightPt.x) / 2
        let midY = (leftPt.y + rightPt.y) / 2

        // Angle of the lash line.
        let angle = atan2(rightPt.y - leftPt.y, rightPt.x - leftPt.x)

        // Eye center — used to nudge lashes toward the eyelid and away from pupil.
        let allPts = fullEye.map(convert)
        let eyeCenterY: CGFloat
        if allPts.count >= 3 {
            eyeCenterY = allPts.map(\.y).reduce(0, +) / CGFloat(allPts.count)
        } else {
            eyeCenterY = midY
        }

        // Perpendicular to the lash line, pointing away from eye center.
        let perpX = -sin(angle)
        let perpY =  cos(angle)
        let testPtY = midY + perpY * 5
        let awaySign: CGFloat = (testPtY < eyeCenterY) ? 1 : -1
        // Small offset so the lash roots sit right on the lash line.
        let verticalOffset = eyeWidth * 0.02 * awaySign

        let posX = midX + perpX * verticalOffset
        let posY = midY + perpY * verticalOffset

        let smoothed = state.update(x: posX, y: posY, width: eyeWidth, angle: angle)

        // Scale: image width → eye width with slight overshoot for full coverage.
        let scaleX = smoothed.width * 1.10 / imageSize.width
        let scaleY = scaleX
        let flipScaleX = flipImage ? -scaleX : scaleX

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer.isHidden = false
        layer.opacity  = Float(intensity)
        layer.bounds   = CGRect(origin: .zero, size: imageSize)
        layer.position = CGPoint(x: smoothed.x, y: smoothed.y)

        var t = CATransform3DIdentity
        t = CATransform3DRotate(t, smoothed.angle, 0, 0, 1)
        t = CATransform3DScale(t, flipScaleX, scaleY, 1)
        layer.transform = t

        CATransaction.commit()
    }

    // MARK: - Procedural fallback
    //
    // Generates a lash strip if the asset catalog image is missing.
    // Dark strands on transparent background — no white-to-alpha needed.

    private static func generateLashStrip(width: CGFloat, height: CGFloat) -> CGImage {
        let w = Int(width), h = Int(height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(NSColor(calibratedRed: 0.06, green: 0.04,
                                    blue: 0.05, alpha: 0.92).cgColor)

        let baseline: CGFloat = 10
        let strandCount = 60
        let maxLenFrac:  CGFloat = 0.82
        let baseWidth:   CGFloat = 1.2
        let curlAmount:  CGFloat = 0.30

        var rng = SeededRNG(seed: 0xBEEF)

        for i in 0..<strandCount {
            let t = CGFloat(i) / CGFloat(strandCount - 1)
            let jitter = rng.next(-4, 4)
            let x = 12 + t * (width - 24) + jitter

            let envelope = 0.15 + 0.85 * smoothstepStatic(t)
            let lenVar = rng.next(0.82, 1.08)
            let lashLen = height * maxLenFrac * envelope * lenVar
            guard lashLen > 4 else { continue }

            let baseAngle: CGFloat = .pi / 2
            let fanAngle = (t - 0.4) * 0.35
            let angleVar = rng.next(-0.06, 0.06)
            let angle = baseAngle + fanAngle + angleVar

            let cosA = cos(angle), sinA = sin(angle)
            let tipX = x + cosA * lashLen
            let tipY = baseline + sinA * lashLen

            let curlOffset = lashLen * curlAmount * (0.6 + 0.4 * t)
            let ctrlX = x + cosA * lashLen * 0.55 - sinA * curlOffset * 0.3
            let ctrlY = baseline + sinA * lashLen * 0.55 + cosA * curlOffset

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

        // Extra wispy accents.
        ctx.setLineWidth(0.8)
        for _ in 0..<12 {
            let t = rng.next(0.35, 1.0)
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

private struct TransformSmoothing {
    private var smoothX:     CGFloat?
    private var smoothY:     CGFloat?
    private var smoothWidth: CGFloat?
    private var smoothAngle: CGFloat?
    private let alpha: CGFloat = 0.38

    struct Values {
        let x, y, width, angle: CGFloat
    }

    mutating func update(x: CGFloat, y: CGFloat, width: CGFloat, angle: CGFloat) -> Values {
        if let sx = smoothX {
            smoothX     = sx + alpha * (x - sx)
            smoothY     = smoothY! + alpha * (y - smoothY!)
            smoothWidth = smoothWidth! + alpha * (width - smoothWidth!)
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
