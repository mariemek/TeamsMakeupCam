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
// Overlays a lash-strip PNG image on each eye.
//
// The strip is loaded from the asset catalog ("lashes").  If the PNG has a
// white background it is automatically converted to transparent (white → alpha).
// If the asset is missing, a procedural fallback is generated at init.
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
    /// Image size in points for layer bounds.
    private let imageSize: CGSize

    // MARK: - Init

    init() {
        // Try loading the bundled PNG from the asset catalog.
        if let nsImage = NSImage(named: "lashes"),
           let tiff = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let cg = bitmap.cgImage {
            // The reference image has a white background — convert white → transparent.
            self.lashImage = Self.whiteToAlpha(cg)
            self.imageSize = CGSize(width: cg.width, height: cg.height)
        } else {
            // Fallback: procedurally generate a lash strip.
            let w: CGFloat = 512, h: CGFloat = 180
            self.lashImage = Self.generateLashStrip(width: w, height: h)
            self.imageSize = CGSize(width: w, height: h)
        }

        containerLayer.backgroundColor = NSColor.clear.cgColor
        containerLayer.masksToBounds   = false

        for lashLayer in [leftLashLayer, rightLashLayer] {
            lashLayer.contents        = lashImage
            lashLayer.contentsGravity = .resizeAspect
            lashLayer.isHidden        = true
            lashLayer.masksToBounds   = false
            // Anchor at the bottom-center: the baseline of the lash strip
            // sits on the eyelid, and strands extend upward.
            lashLayer.anchorPoint     = CGPoint(x: 0.5, y: 1.0)
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
        // lands on the lateral side of each eye.
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

        // Angle of the lash line (inner→outer).
        let angle = atan2(rightPt.y - leftPt.y, rightPt.x - leftPt.x)

        // Eye center — used to shift lashes upward (away from pupil).
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
        let verticalOffset = eyeWidth * 0.04 * awaySign

        let posX = midX + perpX * verticalOffset
        let posY = midY + perpY * verticalOffset

        let smoothed = state.update(x: posX, y: posY, width: eyeWidth, angle: angle)

        // Scale image to match eye width (slight overshoot covers the corners).
        let scaleX = smoothed.width * 1.15 / imageSize.width
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

    // MARK: - White-to-alpha conversion
    //
    // Converts a white-background PNG into a transparency-background image.
    // For each pixel: alpha = 1 − luminance.  Dark lash strands stay opaque,
    // white background becomes fully transparent.

    private static func whiteToAlpha(_ source: CGImage) -> CGImage {
        let w = source.width, h = source.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = w * 4
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }

        // Draw the source image into our writable context.
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let data = ctx.data else { return source }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        for i in 0..<(w * h) {
            let offset = i * 4
            let r = CGFloat(pixels[offset])     / 255.0
            let g = CGFloat(pixels[offset + 1]) / 255.0
            let b = CGFloat(pixels[offset + 2]) / 255.0

            // Luminance (perceived brightness).
            let lum = 0.299 * r + 0.587 * g + 0.114 * b

            // New alpha: dark pixels → opaque, light pixels → transparent.
            let newAlpha = max(0, min(1, 1.0 - lum))

            // Premultiplied alpha: RGB values are multiplied by alpha.
            let a = UInt8(newAlpha * 255)
            if newAlpha < 0.01 {
                pixels[offset]     = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 0
            } else {
                // Darken the lash color slightly for richness.
                let darkR = UInt8(min(255, r * 0.15 * newAlpha * 255))
                let darkG = UInt8(min(255, g * 0.12 * newAlpha * 255))
                let darkB = UInt8(min(255, b * 0.14 * newAlpha * 255))
                pixels[offset]     = darkR
                pixels[offset + 1] = darkG
                pixels[offset + 2] = darkB
                pixels[offset + 3] = a
            }
        }

        return ctx.makeImage() ?? source
    }

    // MARK: - Procedural fallback
    //
    // Generates a lash strip if the asset catalog image is missing.
    // Draws curved strands: fuller on the right (outer corner), tapering left.

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
