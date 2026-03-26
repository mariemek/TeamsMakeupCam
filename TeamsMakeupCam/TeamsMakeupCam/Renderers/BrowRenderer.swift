import AVFoundation
import AppKit

/// Renders natural-looking filled eyebrows from 10 MediaPipe landmarks.
///
/// ## Why we sort by x
/// MediaPipe landmark indices follow the 3-D mesh topology, NOT left→right
/// screen order. Without sorting, adjacent points zig-zag in screen space
/// and Catmull-Rom creates self-intersecting "X" shapes.
/// Sorting each arc by screen-x puts them in spatial order along the brow axis.
///
/// ## How the brow shape is determined
/// pts[0..4] = upper arc (top edge of brow)
/// pts[5..9] = lower arc (bottom edge of brow)
/// Both arcs come from MediaPipe and trace the user's ACTUAL brow boundary.
/// We do NOT invent a fake thickness — we use the real lower arc y positions
/// and only blend them toward the upper arc at the head and tail tips so the
/// shape closes cleanly.
///
/// Controls: intensity + color only.
final class BrowRenderer {

    // MARK: - Temporal state

    private struct BrowState {
        var upper: [CGPoint] = []   // EMA-smoothed upper arc, head→tail
        var lower: [CGPoint] = []   // EMA-smoothed lower arc, head→tail
        var valid = false
    }
    private var leftState  = BrowState()
    private var rightState = BrowState()

    /// EMA alpha — lower = smoother/more lag, higher = snappier/more jitter.
    private let ema: CGFloat = 0.35

    // MARK: - Entry point

    func updateBrowLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = CGFloat(settings.browIntensity).clamped(0, 1)

        guard intensity > 0.001, let face = landmarks.first else {
            clearLayer(layer); return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let ext = contentExtent, let b = viewBounds {
            convert = { Self.normToView($0, extent: ext, bounds: b) }
        } else {
            convert = { self.toLayer($0, in: previewLayer) }
        }

        let leftPts  = face.leftEyebrow.map(convert)
        let rightPts = face.rightEyebrow.map(convert)

        let path = CGMutablePath()

        if leftPts.count >= 10 {
            drawBrow(leftPts,  isLeftBrow: true,  state: &leftState,  to: path)
        }
        if rightPts.count >= 10 {
            drawBrow(rightPts, isLeftBrow: false, state: &rightState, to: path)
        }

        layer.path = path

        // Keep alpha modest — CIMultiplyBlendMode already darkens the skin
        // naturally, so we don't need a heavy fill.
        let alpha = 0.03 + 0.22 * intensity
        let color  = settings.browNSColor

        layer.fillColor   = color.withAlphaComponent(alpha).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth   = 0
        layer.fillRule    = .nonZero

        // Tiny shadow = soft hair-edge fringe, not extra thickness.
        layer.shadowColor   = color.withAlphaComponent(alpha * 0.45).cgColor
        layer.shadowOpacity = 1.0
        layer.shadowRadius  = 0.6 + 0.9 * intensity
        layer.shadowOffset  = .zero

        layer.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
    }

    // MARK: - Shape

    private func drawBrow(
        _ rawPoints: [CGPoint],
        isLeftBrow: Bool,
        state: inout BrowState,
        to path: CGMutablePath
    ) {
        // ── 1. Split into upper arc (top edge) and lower arc (bottom edge) ────
        var upper = Array(rawPoints.prefix(5))
        var lower = Array(rawPoints.suffix(5))

        // ── 2. Sort each arc by screen-x (left → right) ───────────────────────
        // MediaPipe indices are mesh-topology order, not screen-spatial order.
        // Sorting by x puts them in correct left→right sequence so Catmull-Rom
        // draws smooth curves rather than self-intersecting zigzags.
        upper.sort { $0.x < $1.x }
        lower.sort { $0.x < $1.x }

        // ── 3. Orient both arcs head (inner corner) → tail (outer corner) ─────
        // The subject's LEFT brow is on the camera's right side → larger x in
        // layer space. After sort: [0]=inner/nasal (smaller x), [4]=outer/temple
        // (larger x) → tail at high x, no reversal needed.
        //
        // The subject's RIGHT brow is on the camera's left side → smaller x.
        // After sort: [0]=outer/temple (smallest x), [4]=inner/nasal (larger x)
        // → reverse so [0]=inner, [4]=outer/tail.
        //
        // Using isLeftBrow (fixed side) is more robust than a dynamic faceCentreX
        // which can shift when the head tilts and cause the tail to flip mid-frame.
        let tailAtHighX = isLeftBrow
        if !tailAtHighX {
            upper.reverse()
            lower.reverse()
        }
        // After this: [0] = inner head corner, [4] = outer tail corner ✓

        // ── 4. EMA temporal smoothing ─────────────────────────────────────────
        if state.valid,
           state.upper.count == upper.count,
           state.lower.count == lower.count {
            upper = zip(upper, state.upper).map { lerp($1, $0, ema) }
            lower = zip(lower, state.lower).map { lerp($1, $0, ema) }
        }
        state.upper = upper
        state.lower = lower
        state.valid = true

        // ── 5. Shape the lower arc ────────────────────────────────────────────
        // Use the REAL MediaPipe lower-arc y positions (they trace the user's
        // actual brow bottom edge). Only blend toward the upper arc at the
        // very head and tail tips so the shape closes to a point at each end.
        let shaped = shapeLower(lower, against: upper)

        // ── 6. Catmull-Rom subdivision ─────────────────────────────────────────
        let upperCurve = catmullRom(upper,  steps: 14)
        let lowerCurve = catmullRom(shaped, steps: 14)
        guard !upperCurve.isEmpty, !lowerCurve.isEmpty else { return }

        // ── 7. Pointed tail tip ────────────────────────────────────────────────
        // shapeLower no longer converges at the tail, so tailLower is the actual
        // lower-arc outer endpoint — meaningfully different from tailUpper.
        // We use straight lines to avoid the degenerate quad-curve spike that
        // occurred when tailLower ≈ tailUpper (the old shapeLower forced them
        // together, making the quad curves collapse into a tiny self-intersecting
        // loop visible as a sharp spike).
        let tailUpper = upperCurve.last!
        let tailLower = lowerCurve.last!
        let outDir: CGFloat = tailAtHighX ? 1 : -1
        let ext = abs(upper.last!.x - upper.first!.x) * 0.08
        let tailTip = CGPoint(
            x: (tailUpper.x + tailLower.x) / 2 + outDir * ext,
            y: tailUpper.y * 0.70 + tailLower.y * 0.30
        )

        // ── 8. Trace closed outline ────────────────────────────────────────────
        path.move(to: upperCurve[0])
        for pt in upperCurve.dropFirst() { path.addLine(to: pt) }

        // Sharp pointed tail — simple lines, no quad curves
        path.addLine(to: tailTip)
        path.addLine(to: tailLower)

        for pt in lowerCurve.dropLast().reversed() { path.addLine(to: pt) }

        let headCtrl = CGPoint(
            x: (lowerCurve.first!.x + upperCurve.first!.x) / 2,
            y: (lowerCurve.first!.y + upperCurve.first!.y) / 2
        )
        path.addQuadCurve(to: upperCurve.first!, control: headCtrl)
        path.closeSubpath()
    }

    // MARK: - Lower arc shaping

    /// Tapers the lower arc toward the upper arc only at the inner (head) corner
    /// so the brow starts thin at the nose-bridge end.
    ///
    /// The outer (tail) end is NOT converged here — the tail tip is handled
    /// explicitly in drawBrow with a proper pointed extension. Converging the
    /// lower arc at the tail as well caused tailLower ≈ tailUpper, which made
    /// the quad-curve tail construction degenerate into a spike.
    ///
    /// blend = 0.0 at head → lower arc converges to upper (thin inner corner)
    /// blend = 1.0 past 30% → full brow thickness preserved to the outer end
    private func shapeLower(_ lower: [CGPoint], against upper: [CGPoint]) -> [CGPoint] {
        guard lower.count == upper.count else { return lower }

        return zip(lower, upper).enumerated().map { i, pair in
            let (lo, up) = pair
            let t = CGFloat(i) / CGFloat(max(lower.count - 1, 1))
            let blend = smoothStep(0.0, 0.30, t)
            return CGPoint(
                x: up.x + (lo.x - up.x) * blend,
                y: up.y + (lo.y - up.y) * blend
            )
        }
    }

    // MARK: - Catmull-Rom spline

    private func catmullRom(_ pts: [CGPoint], steps: Int = 14) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        let p = [pts[0]] + pts + [pts[pts.count - 1]]
        var result: [CGPoint] = []
        result.reserveCapacity((p.count - 3) * steps + 1)
        for i in 1..<(p.count - 2) {
            let p0 = p[i-1], p1 = p[i], p2 = p[i+1], p3 = p[i+2]
            for j in 0..<steps {
                let t  = CGFloat(j) / CGFloat(steps)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2*p1.x) + (-p0.x+p2.x)*t
                    + (2*p0.x-5*p1.x+4*p2.x-p3.x)*t2
                    + (-p0.x+3*p1.x-3*p2.x+p3.x)*t3)
                let y = 0.5 * ((2*p1.y) + (-p0.y+p2.y)*t
                    + (2*p0.y-5*p1.y+4*p2.y-p3.y)*t2
                    + (-p0.y+3*p1.y-3*p2.y+p3.y)*t3)
                result.append(CGPoint(x: x, y: y))
            }
        }
        if let last = pts.last { result.append(last) }
        return result
    }

    // MARK: - Helpers

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func smoothStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - e0) / max(e1 - e0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path              = nil
        layer.fillColor         = NSColor.clear.cgColor
        layer.strokeColor       = NSColor.clear.cgColor
        layer.shadowColor       = NSColor.clear.cgColor
        layer.shadowOpacity     = 0
        layer.shadowRadius      = 0
        layer.compositingFilter = nil
    }

    // MARK: - Coordinate conversion

    private func toLayer(_ p: CGPoint, in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func normToView(_ p: CGPoint, extent: CGRect, bounds: CGRect) -> CGPoint {
        let scale = max(bounds.width / extent.width, bounds.height / extent.height)
        let dw = extent.width * scale, dh = extent.height * scale
        return CGPoint(
            x: bounds.midX - dw / 2 + p.x * dw,
            y: bounds.midY - dh / 2 + p.y * dh
        )
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, self))
    }
}
