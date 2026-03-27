import AVFoundation
import AppKit
import CoreImage

// MARK: - Lash Style

enum LashStyle: String, CaseIterable, Codable {
    case natural
    case wispy
    case dramatic
}

// MARK: - PNGLashesRenderer
//
// Renders realistic eyelashes using procedurally-generated textures on CALayers.
// Architecture:
//   containerLayer (full-screen, receives the mirror transform from PreviewContainerView)
//     ├── leftLashLayer   (sized to left eye, repositioned each frame)
//     └── rightLashLayer  (sized to right eye, repositioned each frame)
//
// No layers are created or destroyed at runtime — only transforms and bounds update.

final class PNGLashesRenderer {

    // MARK: - Public container
    // Add to rootLayer in PreviewContainerView and include in allLayers so it
    // receives autoresizingMask + the horizontal mirror transform automatically.
    let containerLayer = CALayer()

    // MARK: - Private layers
    private let leftLashLayer  = CALayer()
    private let rightLashLayer = CALayer()

    // MARK: - Texture cache  (style → CGImage, generated once, reused every frame)
    private var textureCache: [LashStyle: CGImage] = [:]
    private var currentStyle: LashStyle = .wispy

    // MARK: - Temporal smoothing state (one per eye)
    private var leftSmooth  = EyeSmoothState()
    private var rightSmooth = EyeSmoothState()

    // MARK: - Init

    init() {
        containerLayer.backgroundColor = NSColor.clear.cgColor
        containerLayer.masksToBounds   = false

        for lashLayer in [leftLashLayer, rightLashLayer] {
            lashLayer.contentsGravity = .resize
            lashLayer.masksToBounds   = false
            lashLayer.isHidden        = true
            // anchorPoint (0.5, 0.85): the lash ROOT sits 85 % up from the layer bottom.
            // Setting layer.position = eyeCenter therefore places the root on the lid.
            // macOS CALayer has y = 0 at bottom, consistent with Quartz.
            lashLayer.anchorPoint = CGPoint(x: 0.5, y: 0.85)
            containerLayer.addSublayer(lashLayer)
        }
    }

    // MARK: - Public update  (call every frame from updateOverlay)

    func update(
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        style: LashStyle = .wispy,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = max(0.0, min(settings.lashesIntensity, 1.0))

        guard intensity > 0, let face = landmarks.first else { hide(); return }

        // Invalidate texture cache when style changes.
        if style != currentStyle {
            currentStyle = style
            textureCache.removeAll()
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates,
           let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.fromProcessedFrame($0, extent: extent, viewBounds: bounds) }
        } else {
            convert = { Self.fromPreviewLayer($0, in: previewLayer) }
        }

        // Prefer dedicated upper-eyelid points; fall back to full eye contour.
        let leftEyelid  = face.leftUpperEyelid.isEmpty  ? face.leftEye  : face.leftUpperEyelid
        let rightEyelid = face.rightUpperEyelid.isEmpty ? face.rightEye : face.rightUpperEyelid

        updateEye(layer: leftLashLayer,  state: &leftSmooth,
                  eyelid: leftEyelid,   convert: convert,
                  intensity: intensity, style: style)

        updateEye(layer: rightLashLayer, state: &rightSmooth,
                  eyelid: rightEyelid,  convert: convert,
                  intensity: intensity, style: style)
    }

    func hide() {
        leftLashLayer.isHidden  = true
        rightLashLayer.isHidden = true
        // Reset smoothing so the next appearance doesn't lerp from stale state.
        leftSmooth  = EyeSmoothState()
        rightSmooth = EyeSmoothState()
    }

    // MARK: - Per-eye update

    private func updateEye(
        layer: CALayer,
        state: inout EyeSmoothState,
        eyelid: [CGPoint],
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        style: LashStyle
    ) {
        guard eyelid.count >= 2 else { layer.isHidden = true; return }

        // Convert to view space (macOS CALayer, y = 0 at bottom).
        let pts = eyelid.map(convert)

        // ── Eye geometry ──────────────────────────────────────────────────────
        //
        // Center: centroid of all upper-eyelid points.
        let rawCenter = CGPoint(
            x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
            y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        )

        // Corners: leftmost and rightmost x in view space (pre-mirror).
        // After the container mirror flip, "leftmost in view space" becomes the
        // visual right side — this is correct for a mirrored (selfie) camera.
        let byX   = pts.sorted { $0.x < $1.x }
        let inner = byX.first!
        let outer = byX.last!

        // Width: Euclidean distance between the two corner points.
        let rawWidth = hypot(outer.x - inner.x, outer.y - inner.y)
        guard rawWidth > 4 else { layer.isHidden = true; return }

        // Angle: direction inner → outer in view space.
        // The container's mirror (scale -1 in x) will negate this angle visually,
        // which is exactly what we want for a mirrored camera feed.
        let rawAngle = atan2(outer.y - inner.y, outer.x - inner.x)

        // ── Temporal smoothing (EMA) ──────────────────────────────────────────
        state.update(center: rawCenter, angle: rawAngle, width: rawWidth)

        // ── Lash layer sizing ─────────────────────────────────────────────────
        // Width = eyeWidth × 1.12  (slight overhang at corners looks natural)
        // Height preserves the texture aspect ratio (512 : 128 = 4 : 1).
        let layerW = state.width * 1.12
        let layerH = layerW * (128.0 / 512.0)   // = layerW * 0.25

        // ── Vertical lift ─────────────────────────────────────────────────────
        // Shift the lash root upward along the perpendicular to the eye axis so
        // lashes sit just above the eyelid line rather than on the centroid.
        //
        // In macOS view space (y = 0 bottom, y = height top):
        //   eye direction: (cos θ,  sin θ)
        //   CCW perpendicular (points toward top of eye): (−sin θ, cos θ)
        //
        // lift > 0 → move toward top of screen.
        let lift = state.width * 0.09
        let liftX = -sin(state.angle) * lift
        let liftY =  cos(state.angle) * lift

        // ── Apply to layer (no implicit animations) ───────────────────────────
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer.isHidden = false
        layer.contents = texture(for: style)
        layer.bounds   = CGRect(x: 0, y: 0, width: layerW, height: layerH)

        // position is in the PARENT (containerLayer) coordinate space.
        // anchorPoint (0.5, 0.85) maps this position to the lash root.
        layer.position = CGPoint(
            x: state.center.x + liftX,
            y: state.center.y + liftY
        )

        // Rotation-only transform.  Scale is encoded in bounds; translation in position.
        layer.transform = CATransform3DMakeRotation(state.angle, 0, 0, 1)

        // Opacity: 0.82 at full intensity, fades in proportionally below that.
        layer.opacity   = Float(0.82 * intensity)

        CATransaction.commit()
    }

    // MARK: - Texture cache

    private func texture(for style: LashStyle) -> CGImage? {
        if let cached = textureCache[style] { return cached }
        let img = generateTexture(style: style)
        textureCache[style] = img
        return img
    }

    // MARK: - Procedural texture generation
    //
    // Draws a 512 × 128 lash strip using Core Graphics.
    // y = 0 at bottom in CGContext on macOS.
    // Root line at y ≈ 109  (85 % up), tips toward y = 128 (top).
    // After generation a very subtle Gaussian blur softens the edges so the
    // lashes blend rather than looking like a hard-edged sticker.

    private func generateTexture(style: LashStyle) -> CGImage? {
        let W = 512, H = 128

        guard let ctx = CGContext(
            data: nil, width: W, height: H,
            bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setLineCap(.round)

        let rootY  = CGFloat(H) * 0.85          // lash root y in CGContext space
        let params = LashParams(style: style, canvasW: CGFloat(W), rootY: rootY)

        var rng = SeededRNG(seed: style.rawValue.hashValue)

        // ── Primary lash layer ────────────────────────────────────────────────
        drawLashLayer(ctx: ctx, params: params, rng: &rng, scale: 1.0)

        // ── Wispy accent layer: sparse, longer, thinner secondary lashes ──────
        if style == .wispy {
            var rng2 = SeededRNG(seed: style.rawValue.hashValue &+ 9999)
            drawAccentLashes(ctx: ctx, params: params, rng: &rng2)
        }

        guard let rawImage = ctx.makeImage() else { return nil }

        // Subtle Gaussian blur (radius 0.9) removes pixel-sharp edges.
        let ciImage  = CIImage(cgImage: rawImage)
        let blurred  = ciImage.applyingFilter("CIGaussianBlur",
                                              parameters: ["inputRadius": 0.9])
        let ciCtx    = CIContext(options: [.useSoftwareRenderer: false])
        let srcRect  = CGRect(x: 0, y: 0, width: W, height: H)
        return ciCtx.createCGImage(blurred, from: srcRect) ?? rawImage
    }

    // MARK: - Primary lash pass

    private func drawLashLayer(
        ctx: CGContext, params: LashParams,
        rng: inout SeededRNG, scale: CGFloat
    ) {
        let spacing = params.canvasW / CGFloat(params.lashCount)

        for i in 0..<params.lashCount {
            let t     = CGFloat(i) / CGFloat(max(params.lashCount - 1, 1))
            let baseX = spacing * (CGFloat(i) + 0.5)
                      + rng.float(in: -spacing * 0.12 ... spacing * 0.12)

            // Length: envelope peaks near the outer third (t ≈ 0.6).
            // Wispy adds cluster-based variation.
            let lengthNorm = params.lashLength(at: t, rng: &rng)
            let length     = lengthNorm * params.canvasW * params.maxLengthRatio * scale
            guard length > 2 else { continue }

            // Lean: lashes angle outward at the corners, straight up in center.
            let lean = (t - 0.5) * params.leanStrength
            let tipX = baseX + lean * length
            let tipY = params.rootY + length      // upward = +y in CGContext (macOS)

            // Quadratic bezier control point for a gentle S-curve.
            let ctrlX = baseX + lean * length * 0.35
            let ctrlY = params.rootY + length * 0.55

            let thick = params.baseThickness(at: t, rng: &rng)
            drawTaperedLash(ctx: ctx,
                            from: CGPoint(x: baseX, y: params.rootY),
                            ctrl: CGPoint(x: ctrlX, y: ctrlY),
                            to:   CGPoint(x: tipX,  y: tipY),
                            baseThickness: thick,
                            color: params.lashColor,
                            steps: 9)
        }
    }

    // MARK: - Wispy accent pass

    private func drawAccentLashes(
        ctx: CGContext, params: LashParams, rng: inout SeededRNG
    ) {
        let accentCount = params.lashCount / 3
        for i in 0..<accentCount {
            let t     = CGFloat(i) / CGFloat(max(accentCount - 1, 1))
            let baseX = params.canvasW * (0.12 + t * 0.76)
                      + rng.float(in: -10 ... 10)
            let len   = params.canvasW * 0.175
                      * (0.65 + rng.float(in: 0 ... 0.70))
            let lean  = (t - 0.5) * params.leanStrength * 1.4
            let tipX  = baseX + lean * len
            let tipY  = params.rootY + len
            let ctrlX = baseX + lean * len * 0.25
            let ctrlY = params.rootY + len * 0.50

            drawTaperedLash(ctx: ctx,
                            from: CGPoint(x: baseX, y: params.rootY),
                            ctrl: CGPoint(x: ctrlX, y: ctrlY),
                            to:   CGPoint(x: tipX,  y: tipY),
                            baseThickness: 0.6 + rng.float(in: 0 ... 0.45),
                            color: params.lashColor,
                            steps: 7)
        }
    }

    // MARK: - Tapered lash primitive
    //
    // Approximates the bezier curve in `steps` linear segments.
    // Stroke width decreases linearly from baseThickness → 0 at the tip.
    // Alpha fades in the final 20 % to avoid a hard tip termination.

    private func drawTaperedLash(
        ctx: CGContext,
        from start: CGPoint, ctrl: CGPoint, to end: CGPoint,
        baseThickness: CGFloat, color: CGColor, steps: Int
    ) {
        var prev = start
        for s in 1...steps {
            let t0   = CGFloat(s - 1) / CGFloat(steps)
            let t1   = CGFloat(s)     / CGFloat(steps)
            let next = quadBezier(t: t1, p0: start, p1: ctrl, p2: end)

            let thick = baseThickness * (1.0 - t0)
            guard thick > 0.04 else { break }

            // Fade alpha in the last 20 % so tips dissolve naturally.
            let alpha: CGFloat = t0 < 0.80 ? 1.0 : (1.0 - t0) / 0.20
            ctx.setStrokeColor(color.copy(alpha: alpha) ?? color)
            ctx.setLineWidth(thick)

            ctx.beginPath()
            ctx.move(to: prev)
            ctx.addLine(to: next)
            ctx.strokePath()

            prev = next
        }
    }

    // MARK: - Math helpers

    /// Quadratic bezier evaluation.
    private func quadBezier(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u*u*p0.x + 2*u*t*p1.x + t*t*p2.x,
                       y: u*u*p0.y + 2*u*t*p1.y + t*t*p2.y)
    }

    // MARK: - Coordinate conversion (mirrors LashesRenderer helpers exactly)

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

// MARK: - Eye smooth state
//
// Exponential moving average (EMA) applied independently to center, angle, and
// width. Chosen alphas keep tracking tight while absorbing per-frame landmark jitter.

private struct EyeSmoothState {
    var center       = CGPoint.zero
    var angle:  CGFloat = 0
    var width:  CGFloat = 0
    var initialized  = false

    // Higher α → faster but jitterier.  Lower α → smoother but laggier.
    private static let αPos:   CGFloat = 0.45
    private static let αAngle: CGFloat = 0.35
    private static let αWidth: CGFloat = 0.40

    mutating func update(center c: CGPoint, angle a: CGFloat, width w: CGFloat) {
        guard initialized else {
            center = c; angle = a; width = w; initialized = true; return
        }
        center = CGPoint(
            x: center.x + Self.αPos * (c.x - center.x),
            y: center.y + Self.αPos * (c.y - center.y)
        )
        width  = width + Self.αWidth * (w - width)

        // Wrap angle delta into (−π, π] to prevent spinning through 360°.
        var Δ = a - angle
        if Δ >  .pi { Δ -= 2 * .pi }
        if Δ < -.pi { Δ += 2 * .pi }
        angle = angle + Self.αAngle * Δ
    }
}

// MARK: - Lash style parameters

private struct LashParams {
    let style:   LashStyle
    let canvasW: CGFloat
    let rootY:   CGFloat

    // Near-black with a hint of warmth — looks more biological than pure black.
    let lashColor = NSColor(calibratedRed: 0.04, green: 0.03, blue: 0.04, alpha: 1.0).cgColor

    var lashCount: Int {
        switch style {
        case .natural:  return 28
        case .wispy:    return 22
        case .dramatic: return 40
        }
    }

    // Fraction of canvasW that the longest lash spans vertically.
    var maxLengthRatio: CGFloat {
        switch style {
        case .natural:  return 0.135
        case .wispy:    return 0.170
        case .dramatic: return 0.210
        }
    }

    // How much lashes lean toward the corners (0 = straight up).
    var leanStrength: CGFloat {
        switch style {
        case .natural:  return 0.22
        case .wispy:    return 0.32
        case .dramatic: return 0.18
        }
    }

    // Normalised length [0,1] at horizontal position t ∈ [0,1].
    // Wispy uses a clustered, irregular pattern; others use a smooth bell envelope.
    func lashLength(at t: CGFloat, rng: inout SeededRNG) -> CGFloat {
        // Envelope: rises from both ends, peaks near the outer third.
        let env = sin(t * .pi) * (0.55 + 0.45 * smoothStep(0.30, 0.70, t))
        switch style {
        case .natural:
            return env * (0.65 + rng.float(in: 0 ... 0.35))

        case .wispy:
            // sin at 7× frequency creates ~7 length clusters across the strip.
            let cluster = sin(t * .pi * 7.0) * 0.32
            return max(0.06, env * (0.45 + 0.55 * abs(cluster))
                           + rng.float(in: 0 ... 0.18))

        case .dramatic:
            return env * (0.80 + rng.float(in: 0 ... 0.20))
        }
    }

    func baseThickness(at t: CGFloat, rng: inout SeededRNG) -> CGFloat {
        let jitter = rng.float(in: 0 ... 0.30)
        switch style {
        case .natural:  return 1.0 + jitter
        case .wispy:    return 0.7 + jitter
        case .dramatic: return 1.9 + jitter
        }
    }

    // Hermite smoothstep (C¹ continuous).
    private func smoothStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min((x - e0) / (e1 - e0), 1))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Seeded RNG
//
// Linear congruential generator with Knuth parameters.
// Seeded deterministically so the same style always produces identical textures.

private struct SeededRNG {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed &+ 0x9e3779b9))
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// Returns a CGFloat uniformly in [lo, hi].
    mutating func float(in range: ClosedRange<CGFloat>) -> CGFloat {
        let norm = CGFloat(next() >> 11) / CGFloat(1 << 53)
        return range.lowerBound + norm * (range.upperBound - range.lowerBound)
    }
}
