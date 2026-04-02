import CoreImage
import AppKit

/// Composites all makeup (lipstick, lip liner, eyeliner) into the camera frame
/// as actual pixels, producing a CGImage suitable for JPEG encoding and HTTP streaming.
///
/// This is the **offscreen** counterpart of the CAShapeLayer-based renderers used
/// for the live preview. It runs on the VideoFrameProcessor's background queue —
/// never on the main thread.
final class OffscreenMakeupCompositor {

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public API

    /// Composites makeup onto the base image and returns JPEG data.
    /// - Parameters:
    ///   - baseImage: The skin-smoothed CIImage from VideoFrameProcessor.
    ///   - landmarks: Detected face landmarks (may be empty → no makeup drawn).
    ///   - settings: Current makeup settings (intensities, colors).
    /// - Returns: JPEG data of the composited frame, or nil on failure.
    func composite(
        baseImage: CIImage,
        landmarks: [FaceLandmarks],
        settings: MakeupSettings
    ) -> Data? {
        let extent = baseImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        guard let cgBase = ciContext.createCGImage(baseImage, from: extent) else { return nil }

        let w = cgBase.width
        let h = cgBase.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw the base camera frame (skin smoothing already applied).
        ctx.draw(cgBase, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Draw makeup for each detected face.
        let fw = CGFloat(w)
        let fh = CGFloat(h)
        for face in landmarks {
            drawLipstick(face: face, settings: settings, ctx: ctx, w: fw, h: fh)
            drawLipLiner(face: face, settings: settings, ctx: ctx, w: fw, h: fh)
            drawEyeliner(face: face, settings: settings, ctx: ctx, w: fw, h: fh)
        }

        // Encode to JPEG.
        guard let result = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: result)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    // MARK: - Coordinate conversion

    /// Normalized [0,1] (bottom-left origin) → pixel coordinates.
    private func px(_ p: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        CGPoint(x: p.x * w, y: p.y * h)
    }

    // MARK: - Lipstick

    private func drawLipstick(face: FaceLandmarks, settings: MakeupSettings,
                              ctx: CGContext, w: CGFloat, h: CGFloat) {
        let alpha = max(0, min(settings.lipstickOpacity, 1))
        guard alpha > 0, !face.lips.isEmpty else { return }

        let outer = face.lips.map { px($0, w, h) }
        let inner = face.innerLips.map { px($0, w, h) }

        let path = CGMutablePath()
        addSmoothClosedPath(outer, to: path)
        if !inner.isEmpty { addSmoothClosedPath(inner, to: path) }

        let nsColor = settings.lipstickNSColor
        let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        let fillAlpha = alpha * 0.65

        ctx.saveGState()
        ctx.setBlendMode(.normal)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(
            srgbRed: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent,
            alpha: fillAlpha
        ))
        // Even-odd rule: outer filled, inner cut out.
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // MARK: - Lip Liner

    private func drawLipLiner(face: FaceLandmarks, settings: MakeupSettings,
                              ctx: CGContext, w: CGFloat, h: CGFloat) {
        let intensity = max(0, min(settings.lipLinerIntensity, 1))
        guard intensity > 0, !face.lips.isEmpty else { return }

        let outer = face.lips.map { px($0, w, h) }
        let path = CGMutablePath()
        addSmoothClosedPath(outer, to: path)

        let base = settings.lipLinerNSColor
        let srgb = (base.usingColorSpace(.sRGB) ?? base)
        // Darken by blending 35% with black.
        let r = srgb.redComponent * 0.65
        let g = srgb.greenComponent * 0.65
        let b = srgb.blueComponent * 0.65
        let alpha = 0.10 + 0.30 * intensity
        let lineWidth = 2.7 + 0.5 * intensity

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: r, green: g, blue: b, alpha: alpha))
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Eyeliner

    private func drawEyeliner(face: FaceLandmarks, settings: MakeupSettings,
                              ctx: CGContext, w: CGFloat, h: CGFloat) {
        let intensity = max(0, min(settings.eyelinerIntensity, 1))
        guard intensity > 0 else { return }

        if !face.leftEye.isEmpty {
            if let path = buildEyelinerPath(
                fullEye: face.leftEye,
                upperLid: face.leftUpperEyelidRaw.isEmpty ? nil : face.leftUpperEyelidRaw,
                wingGoesRight: true, w: w, h: h
            ) {
                fillEyelinerPath(path, intensity: intensity, ctx: ctx)
            }
        }

        if !face.rightEye.isEmpty {
            if let path = buildEyelinerPath(
                fullEye: face.rightEye,
                upperLid: face.rightUpperEyelidRaw.isEmpty ? nil : face.rightUpperEyelidRaw,
                wingGoesRight: false, w: w, h: h
            ) {
                fillEyelinerPath(path, intensity: intensity, ctx: ctx)
            }
        }
    }

    private func fillEyelinerPath(_ path: CGPath, intensity: Double, ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        // Eyeliner is dark (labelColor equivalent = black in sRGB).
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: intensity))
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
    }

    /// Builds the eyeliner band + wing path in pixel coordinates.
    /// This is a stateless, per-frame version of EyelinerRenderer's logic
    /// (no temporal smoothing needed for the HTTP output).
    private func buildEyelinerPath(
        fullEye: [CGPoint],
        upperLid: [CGPoint]?,
        wingGoesRight: Bool,
        w: CGFloat, h: CGFloat
    ) -> CGPath? {
        guard fullEye.count >= 5 else { return nil }

        // Extract upper lid arc.
        let arc: [CGPoint]
        if let lid = upperLid, lid.count >= 3 {
            arc = lid
        } else {
            arc = upperArc(from: fullEye)
            guard arc.count >= 3 else { return nil }
        }

        // Convert to pixel coords.
        var pts = arc.map { px($0, w, h) }
        pts = deduplicate(pts, minGap: 1.0)
        guard pts.count >= 3 else { return nil }

        // Ensure inner → outer direction.
        let shouldReverse = wingGoesRight
            ? (pts.first!.x > pts.last!.x)
            : (pts.first!.x < pts.last!.x)
        if shouldReverse { pts.reverse() }

        let spine = movingAverage(pts, window: 3)
        let n = spine.count
        guard n >= 3 else { return nil }

        let lidSpan = hypot(spine.last!.x - spine.first!.x,
                            spine.last!.y - spine.first!.y)
        guard lidSpan > 2 else { return nil }

        // Eye centre for normal orientation.
        let eyeCenter = centroid(fullEye.map { px($0, w, h) })

        // Per-point tangent & normal.
        var tangents = [CGPoint](repeating: .zero, count: n)
        var normals  = [CGPoint](repeating: .zero, count: n)

        for i in 0..<n {
            let prev = i > 0     ? spine[i - 1] : spine[i]
            let next = i < n - 1 ? spine[i + 1] : spine[i]
            var tx = next.x - prev.x
            var ty = next.y - prev.y
            let len = max(0.001, hypot(tx, ty))
            tx /= len; ty /= len
            tangents[i] = CGPoint(x: tx, y: ty)

            var nx = -ty, ny = tx
            let toCX = eyeCenter.x - spine[i].x
            let toCY = eyeCenter.y - spine[i].y
            if nx * toCX + ny * toCY < 0 { nx = -nx; ny = -ny }
            normals[i] = CGPoint(x: nx, y: ny)
        }

        // Upper / lower edges.
        let maxThick = max(2.5, min(lidSpan * 0.065, 7.0))
        var upper = [CGPoint](repeating: .zero, count: n)
        var lower = [CGPoint](repeating: .zero, count: n)

        for i in 0..<n {
            let t     = CGFloat(i) / CGFloat(max(n - 1, 1))
            let taper = smoothStep(0.30, 0.55, t)
            let boost = 1.0 + 0.5 * smoothStep(0.55, 1.0, t)
            let thick = maxThick * taper * boost

            let p  = spine[i]
            let nm = normals[i]
            upper[i] = CGPoint(x: p.x - nm.x * thick, y: p.y - nm.y * thick)
            lower[i] = p
        }

        // Wing.
        let outerT  = tangents[n - 1]
        let outerN  = normals[n - 1]
        let outerU  = upper[n - 1]
        let outerL  = lower[n - 1]
        let outerMid = CGPoint(x: (outerU.x + outerL.x) / 2,
                               y: (outerU.y + outerL.y) / 2)
        let wingLen  = lidSpan * 0.18
        let wingLift = lidSpan * 0.07
        let wingTip = CGPoint(
            x: outerMid.x + outerT.x * wingLen - outerN.x * wingLift,
            y: outerMid.y + outerT.y * wingLen - outerN.y * wingLift
        )

        // Trace closed path.
        let result = CGMutablePath()
        let startIdx = max(0, Int(CGFloat(n) * 0.28))

        result.move(to: upper[startIdx])
        var prev = upper[startIdx]
        for i in (startIdx + 1)..<n {
            let mid = CGPoint(x: (prev.x + upper[i].x) / 2,
                              y: (prev.y + upper[i].y) / 2)
            result.addQuadCurve(to: mid, control: prev)
            prev = upper[i]
        }
        result.addLine(to: outerU)

        let ctrl1 = CGPoint(
            x: outerU.x + outerT.x * wingLen * 0.65,
            y: outerU.y + outerT.y * wingLen * 0.65
        )
        result.addQuadCurve(to: wingTip, control: ctrl1)

        let ctrl2 = CGPoint(
            x: outerL.x + outerT.x * wingLen * 0.35,
            y: outerL.y + outerT.y * wingLen * 0.35
        )
        result.addQuadCurve(to: outerL, control: ctrl2)

        prev = outerL
        for i in stride(from: n - 2, through: startIdx, by: -1) {
            let mid = CGPoint(x: (prev.x + lower[i].x) / 2,
                              y: (prev.y + lower[i].y) / 2)
            result.addQuadCurve(to: mid, control: prev)
            prev = lower[i]
        }
        result.addLine(to: lower[startIdx])
        result.closeSubpath()

        return result
    }

    // MARK: - Geometry helpers (ported from EyelinerRenderer)

    private func upperArc(from eye: [CGPoint]) -> [CGPoint] {
        guard eye.count >= 8 else { return eye }
        let half = eye.count / 2
        let a1 = Array(eye[0..<half])
        let a2 = Array(eye[half..<eye.count])
        let avg1 = a1.map(\.y).reduce(0, +) / CGFloat(max(a1.count, 1))
        let avg2 = a2.map(\.y).reduce(0, +) / CGFloat(max(a2.count, 1))
        return avg1 > avg2 ? a1 : a2
    }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(pts.count, 1))
        return CGPoint(
            x: pts.map(\.x).reduce(0, +) / n,
            y: pts.map(\.y).reduce(0, +) / n
        )
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

    private func smoothStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - e0) / max(e1 - e0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Path helpers (shared with lipstick/liner)

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
}
