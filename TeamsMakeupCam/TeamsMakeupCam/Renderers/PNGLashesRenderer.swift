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
// Draws individual eyelash strands from the actual upper-eyelid landmark curve.
// Each lash originates on the eyelid contour and grows perpendicular to it, so
// the strip naturally follows the eye's arch and tracks every movement.
//
// Architecture
// ─────────────
//   containerLayer  (full-screen CALayer — receives the horizontal mirror
//                    transform from PreviewContainerView like every other layer)
//     ├── leftLashLayer   CAShapeLayer — rebuilt each frame for the left eye
//     └── rightLashLayer  CAShapeLayer — rebuilt each frame for the right eye
//
// Per-frame work: sort + smooth points → Catmull-Rom expand → fill wedge path.
// No allocations beyond the CGMutablePath; CAShapeLayer is reused.

final class PNGLashesRenderer {

    // MARK: - Public
    let containerLayer = CALayer()

    // MARK: - Private
    private let leftLashLayer  = CAShapeLayer()
    private let rightLashLayer = CAShapeLayer()
    private var leftSmooth  = EyelidSmoothing()
    private var rightSmooth = EyelidSmoothing()

    // MARK: - Init

    init() {
        containerLayer.backgroundColor = NSColor.clear.cgColor
        containerLayer.masksToBounds   = false

        for layer in [leftLashLayer, rightLashLayer] {
            // Filled wedge shapes — no stroke needed.
            layer.fillColor     = NSColor(calibratedRed: 0.05, green: 0.04,
                                          blue: 0.06, alpha: 1.0).cgColor
            layer.strokeColor   = nil
            layer.isHidden      = true
            layer.masksToBounds = false
            // Shadow softens the lash edges and adds depth so they blend into skin.
            layer.shadowColor   = NSColor.black.cgColor
            layer.shadowOffset  = .zero
            layer.shadowRadius  = 2.5
            layer.shadowOpacity = 0   // set per-frame proportional to intensity
            containerLayer.addSublayer(layer)
        }
    }

    // MARK: - Public update  (called every frame from updateOverlay)

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
        // Reset smoothing so re-appearance doesn't lerp from stale state.
        leftSmooth  = EyelidSmoothing()
        rightSmooth = EyelidSmoothing()
    }

    // MARK: - Per-eye update

    private func updateEye(
        layer: CAShapeLayer,
        state: inout EyelidSmoothing,
        eyelid: [CGPoint],
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        style: LashStyle
    ) {
        guard eyelid.count >= 2 else { layer.isHidden = true; return }

        // 1. Convert to layer space and sort left → right.
        //    Sorting ensures consistent Catmull-Rom interpolation regardless of
        //    the order MediaPipe returns the contour points.
        let rawPts = eyelid.map(convert).sorted { $0.x < $1.x }

        // 2. Per-point EMA smoothing eliminates landmark jitter.
        let smoothPts = state.update(rawPts)

        // 3. Eye width drives all size-dependent parameters.
        let eyeWidth = hypot(smoothPts.last!.x - smoothPts.first!.x,
                             smoothPts.last!.y - smoothPts.first!.y)
        guard eyeWidth > 4 else { layer.isHidden = true; return }

        // 4. Catmull-Rom expand: ~8-16 landmarks → 26-40 dense base points.
        let targetCount: Int
        switch style {
        case .natural:  targetCount = 28
        case .wispy:    targetCount = 22
        case .dramatic: targetCount = 38
        }
        let basePts = catmullRomExpand(smoothPts, targetCount: targetCount)

        // 5. Build filled wedge path.
        let path = buildLashPath(basePts: basePts, eyeWidth: eyeWidth,
                                  style: style)

        // 6. Apply to layer — suppress implicit animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden      = false
        layer.path          = path
        // opacity scales the whole layer: at 100 % intensity lashes are fully opaque.
        layer.opacity       = Float(intensity)
        layer.shadowOpacity = Float(0.40 * intensity)
        CATransaction.commit()
    }

    // MARK: - Lash path construction
    //
    // Each lash is a filled triangular wedge:
    //
    //              tip  ← pointed apex
    //             /   \
    //   leftBase ·─────· rightBase   ← sits on the eyelid curve
    //
    // The wedge width is measured along the eyelid tangent; the height (length)
    // is measured along the outward normal (CCW perpendicular to the tangent).
    //
    // Normal direction:
    //   In macOS CALayer coordinates (y = 0 at bottom), the upper eyelid arches
    //   upward (high y).  For tangent (tx, ty), the CCW perpendicular is (−ty, tx).
    //   This correctly points "above" the arch at every position:
    //     • peak (tx≈1, ty≈0)  → normal (0,  1) = straight up          ✓
    //     • ascending (ty > 0) → normal (−ty, tx) = upper-left         ✓
    //     • descending (ty < 0)→ normal (−ty, tx) = upper-right        ✓
    //
    // Lean:
    //   lean = (t − 0.5) × leanStrength.  After the container mirror (scale −1 in x):
    //     t = 0 (outer corner) → leans away from face center ✓
    //     t = 1 (inner corner) → leans slightly inward ✓ (matches real lashes)

    private func buildLashPath(
        basePts: [CGPoint],
        eyeWidth: CGFloat,
        style: LashStyle
    ) -> CGPath {
        let path   = CGMutablePath()
        let n      = basePts.count
        guard n >= 2 else { return path }

        var rng    = SeededRNG(seed: style.rawValue.hashValue)
        let maxLen = eyeWidth * maxLengthRatio(style)
        let lean0  = leanStrength(style)
        let hw0    = eyeWidth * rootHalfWidthRatio(style)   // half root-width

        for i in 0..<n {
            let t      = CGFloat(i) / CGFloat(n - 1)
            let root   = basePts[i]
            let tan    = tangentAt(i, in: basePts)   // unit tangent along eyelid

            // Outward normal (CCW perpendicular): points above the eyelid arch.
            let nx = -tan.y
            let ny =  tan.x

            // ── Length ────────────────────────────────────────────────────
            // Bell envelope peaks near t ≈ 0.55 (outer-center region).
            let env = sin(t * .pi) * (0.55 + 0.45 * smoothStep(0.30, 0.70, t))
            let lenFrac: CGFloat
            switch style {
            case .natural:
                lenFrac = env * (0.60 + rng.next(0, 0.40))
            case .wispy:
                // Irregular cluster variation — sin at ~6.5× gives 6-7 groups.
                let cluster = abs(sin(t * .pi * 6.5))
                lenFrac = max(0.05, env * (0.40 + 0.60 * cluster) + rng.next(0, 0.20))
            case .dramatic:
                lenFrac = env * (0.78 + rng.next(0, 0.22))
            }
            let lashLen = maxLen * lenFrac
            guard lashLen > 1.5 else { continue }

            // ── Lean ──────────────────────────────────────────────────────
            // Positive lean → lash tilts toward the outer corner (post-mirror).
            let lean = (t - 0.5) * lean0
            let ldx  = nx + lean * tan.x
            let ldy  = ny + lean * tan.y
            let ll   = max(0.001, hypot(ldx, ldy))
            let dirX = ldx / ll
            let dirY = ldy / ll

            // ── Wedge geometry ────────────────────────────────────────────
            let tipX = root.x + dirX * lashLen
            let tipY = root.y + dirY * lashLen

            // Half-width varies slightly per lash for an organic look.
            let hw   = hw0 * (0.80 + rng.next(0, 0.40))
            let lbX  = root.x - tan.x * hw       // left base
            let lbY  = root.y - tan.y * hw
            let rbX  = root.x + tan.x * hw       // right base
            let rbY  = root.y + tan.y * hw

            // Filled triangle: leftBase → tip → rightBase → close.
            path.move(to: CGPoint(x: lbX, y: lbY))
            path.addLine(to: CGPoint(x: tipX, y: tipY))
            path.addLine(to: CGPoint(x: rbX,  y: rbY))
            path.closeSubpath()
        }

        // ── Wispy accent pass ─────────────────────────────────────────────
        // ~10 extra-long, thinner lashes scattered across the lid for that
        // feathery, non-uniform look of the reference image.
        if style == .wispy {
            var rng2 = SeededRNG(seed: style.rawValue.hashValue &+ 0xABCD_EF01)
            for _ in 0..<10 {
                let idx  = Int(rng2.next(0, CGFloat(n - 1)))
                let t    = CGFloat(idx) / CGFloat(n - 1)
                let root = basePts[idx]
                let tan  = tangentAt(idx, in: basePts)
                let nx   = -tan.y, ny = tan.x
                let accentLen = maxLen * (1.10 + rng2.next(0, 0.55))
                let lean = (t - 0.5) * lean0 * 1.30
                let ldx  = nx + lean * tan.x
                let ldy  = ny + lean * tan.y
                let ll   = max(0.001, hypot(ldx, ldy))
                let dX   = ldx / ll, dY = ldy / ll
                let tipX = root.x + dX * accentLen
                let tipY = root.y + dY * accentLen
                let hw   = hw0 * 0.55           // thinner accent lashes
                path.move(to: CGPoint(x: root.x - tan.x * hw, y: root.y - tan.y * hw))
                path.addLine(to: CGPoint(x: tipX, y: tipY))
                path.addLine(to: CGPoint(x: root.x + tan.x * hw, y: root.y + tan.y * hw))
                path.closeSubpath()
            }
        }

        return path
    }

    // MARK: - Catmull-Rom expansion
    //
    // Expands a sparse landmark array (~8-16 pts) to `targetCount` evenly
    // distributed points so every lash has a well-defined base position.

    private func catmullRomExpand(_ pts: [CGPoint], targetCount: Int) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        guard pts.count < targetCount else { return pts }

        let n        = pts.count
        let segments = n - 1
        var result   = [CGPoint]()
        result.reserveCapacity(targetCount)

        for i in 0..<segments {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[min(n - 1, i + 1)]
            let p3 = pts[min(n - 1, i + 2)]

            // Distribute target samples proportionally across segments.
            let segStart = i       * (targetCount - 1) / segments
            let segEnd   = (i + 1) * (targetCount - 1) / segments
            let count    = segEnd - segStart

            for s in 0..<count {
                let t = CGFloat(s) / CGFloat(max(1, count))
                result.append(catmullRomPt(t: t, p0: p0, p1: p1, p2: p2, p3: p3))
            }
        }
        result.append(pts.last!)
        return result
    }

    private func catmullRomPt(t: CGFloat,
                               p0: CGPoint, p1: CGPoint,
                               p2: CGPoint, p3: CGPoint) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        let x  = 0.5 * ((2*p1.x) + (-p0.x+p2.x)*t
                       + (2*p0.x-5*p1.x+4*p2.x-p3.x)*t2
                       + (-p0.x+3*p1.x-3*p2.x+p3.x)*t3)
        let y  = 0.5 * ((2*p1.y) + (-p0.y+p2.y)*t
                       + (2*p0.y-5*p1.y+4*p2.y-p3.y)*t2
                       + (-p0.y+3*p1.y-3*p2.y+p3.y)*t3)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Tangent

    /// Unit tangent at index i along pts (central differences, clamped at ends).
    private func tangentAt(_ i: Int, in pts: [CGPoint]) -> CGPoint {
        let prev = pts[max(0, i - 1)]
        let next = pts[min(pts.count - 1, i + 1)]
        let dx   = next.x - prev.x
        let dy   = next.y - prev.y
        let len  = max(0.001, hypot(dx, dy))
        return CGPoint(x: dx / len, y: dy / len)
    }

    // MARK: - Style parameters

    /// Maximum lash length as a fraction of eye width.
    private func maxLengthRatio(_ s: LashStyle) -> CGFloat {
        switch s {
        case .natural:  return 0.24
        case .wispy:    return 0.30
        case .dramatic: return 0.38
        }
    }

    /// How strongly lashes lean toward the corners (0 = straight up).
    private func leanStrength(_ s: LashStyle) -> CGFloat {
        switch s {
        case .natural:  return 0.40
        case .wispy:    return 0.55
        case .dramatic: return 0.30
        }
    }

    /// Root half-width as a fraction of eye width.
    private func rootHalfWidthRatio(_ s: LashStyle) -> CGFloat {
        switch s {
        case .natural:  return 0.016
        case .wispy:    return 0.012
        case .dramatic: return 0.022
        }
    }

    // MARK: - Math

    private func smoothStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min((x - e0) / (e1 - e0), 1))
        return t * t * (3 - 2 * t)
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

// MARK: - EyelidSmoothing
//
// Exponential moving average applied point-by-point across the eyelid array.
// Resets on count change (landmark dropout / recovery) to avoid erratic jumps.

private struct EyelidSmoothing {
    private var pts:   [CGPoint] = []
    private let alpha: CGFloat   = 0.42   // higher = more responsive, less smooth

    mutating func update(_ newPts: [CGPoint]) -> [CGPoint] {
        guard !newPts.isEmpty else { return pts.isEmpty ? newPts : pts }
        guard pts.count == newPts.count else { pts = newPts; return pts }
        pts = zip(pts, newPts).map { old, new in
            CGPoint(x: old.x + alpha * (new.x - old.x),
                    y: old.y + alpha * (new.y - old.y))
        }
        return pts
    }
}

// MARK: - SeededRNG
//
// Deterministic LCG so every style always produces the same lash pattern.

private struct SeededRNG {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed &+ 0x9e37_79b9))
    }

    mutating func nextRaw() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// Uniform float in [lo, hi].
    mutating func next(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        let norm = CGFloat(nextRaw() >> 11) / CGFloat(1 << 53)
        return lo + norm * (hi - lo)
    }
}
