# TeamsMakeupCam — Full Engineering Audit & Ship Plan

> Generated March 2026 | Based on live repo inspection

---

## 1. REPO AUDIT

### Architecture Overview

```
Camera Feed (AVCaptureSession)
  └── VideoFrameProcessor (processingQueue)
        ├── JPEG → HTTP POST → Python sidecar (MediaPipe, port 9001)
        │     └── FaceLandmarks JSON → back to Swift
        └── SkinSmoothingRenderer (CIFilter on CIImage)
              └── Processed CIImage + FaceLandmarks → CameraPreviewView
                    ├── BrowRenderer     (CAShapeLayer)
                    ├── EyelinerRenderer (CAShapeLayer)
                    ├── LashesRenderer   (CAShapeLayer)
                    ├── LipstickRenderer (CAShapeLayer)
                    └── LipLinerRenderer (CAShapeLayer)
```

All overlay rendering happens via CoreAnimation `CAShapeLayer` drawn on top of an `AVCaptureVideoPreviewLayer`. Landmark detection is fully offloaded to a Python sidecar via HTTP.

---

## 2. CRITICAL BUGS (Fix Before Anything Else)

### 🔴 BUG 1 — Unresolved Git Merge Conflict in MediaPipeHelperClient.swift

`Services/MediaPipeHelperClient.swift` has literal `<<<<<<< HEAD` / `=======` / `>>>>>>> 980b9c8` markers inside the Swift source. **The app does not compile in its current state.**

**Lines affected:** the `Configuration` struct and `init` are split across both sides of the conflict. You need to pick one version and delete the conflict markers.

**Fix:** Keep the `HEAD` version (the simple one with hardcoded endpoint) and delete the conflict block. The `Configuration` struct from the other branch was incomplete. Here is the resolved file:

```swift
// MediaPipeHelperClient.swift — RESOLVED (keep this entire file)
import AVFoundation
import Foundation
import AppKit
import CoreGraphics
import CoreImage

final class MediaPipeHelperClient {
    private let session: URLSession
    private let endpoint = URL(string: "http://127.0.0.1:9001/v1/face_landmarks")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum ClientError: Error {
        case imageBufferMissing
        case jpegEncodingFailed
        case invalidResponse
        case serverError(String)
        case decodingFailed
    }

    func fetchLandmarks(
        sampleBuffer: CMSampleBuffer,
        completion: @escaping (Result<FaceLandmarks, Error>) -> Void
    ) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            completion(.failure(ClientError.imageBufferMissing))
            return
        }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            completion(.failure(ClientError.jpegEncodingFailed))
            return
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else {
            completion(.failure(ClientError.jpegEncodingFailed))
            return
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 1.0)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpegData

        session.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(ClientError.invalidResponse))
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMessage = json["error"] as? String {
                    completion(.failure(ClientError.serverError(errorMessage)))
                    return
                }
                let decoded = try JSONDecoder().decode(FaceLandmarks.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(ClientError.decodingFailed))
            }
        }.resume()
    }
}
```

---

### 🔴 BUG 2 — Sidecar Sends No Upper Eyelid or Head Pose Data

`FaceLandmarks` has `leftUpperEyelidRaw` and `rightUpperEyelidRaw` fields, and `roll/yaw/pitch` — but the Python sidecar never populates them. Every renderer falls back to a Y-centroid split to guess the upper lid, which is fragile and wrong when the face tilts.

**Fix in mediapipe_helper.py** — see Phase 1, Step 2.

---

### 🟡 BUG 3 — Eye Contour Arrays Have Duplicate Endpoints

In `mediapipe_helper.py`:
```python
LEFT_EYE = [263, 249, 390, 373, 374, 380, 381, 382, 362,  # lower
             398, 384, 385, 386, 387, 388, 466, 263]        # upper ← 263 repeated
RIGHT_EYE = [33, 7, 163, 144, 145, 153, 154, 155, 133,     # lower
              173, 157, 158, 159, 160, 161, 246, 33]         # upper ← 33 repeated
```

The first and last point are the same. This creates a "closed loop" in the array. When `LashesRenderer` and `EyelinerRenderer` split by Y-centroid, they get unequal halves with the inner corner counted twice, causing the wrong arc to be chosen.

---

### 🟡 BUG 4 — BrowRenderer Has Zero Temporal Smoothing

Each frame's brow shape is computed fresh from raw landmarks. MediaPipe landmarks jitter 1–3px per frame even on a still face. With no per-frame EMA (exponential moving average), the brow edge oscillates every frame → visible shimmer.

---

### 🟡 BUG 5 — EyelinerRenderer Wing Direction Relies on Raw dx/dy

The wing tangent is computed directly from the outer spine point. If the face tilts or the outer landmark jitters, `dx` flips sign, and the wing jumps to the wrong side. The `wingGoesRight` flag partially compensates but doesn't account for head roll.

---

### 🟡 BUG 6 — LashesRenderer Uses Stroke Not Fill

Lashes are rendered as open stroked paths (`strokeColor`, `lineWidth`). Real lashes are filled tapered shapes. Strokes look like a marker drawn over the lid, not hair. They also don't antialias the same way as filled paths at retina scale.

---

## 3. WHAT CURRENTLY WORKS

- Camera capture pipeline is solid (AVCaptureSession + CMSampleBuffer → CIImage)
- Skin smoothing (CIGaussianBlur masked to face contour) works well
- Lipstick + lip liner renderers work acceptably
- Preset system (save/load) is correctly implemented
- The sidecar launch mechanism is in place (SidecarLauncher.swift)
- The coordinate transform (`convertProcessedFrameNormalizedToView`) is correct and consistent across all renderers

---

## 4. WHAT IS RISKY / FRAGILE

| Component | Risk | Notes |
|-----------|------|-------|
| Python sidecar | HIGH | App requires a running Python process; if it crashes, all landmark rendering stops silently |
| HTTP latency | MEDIUM | At 1s timeout + 30fps, you're sending ~30 HTTP requests/sec; the sidecar is `threaded=False` → single-threaded Flask = sequential |
| Virtual camera | HIGH | CoreMediaIO DAL plugin approach is fragile on macOS 13+; Camera Extension (DriverKit) is the correct modern path |
| App Store | HIGH | Virtual camera via DAL plugin = not sandbox-compatible = direct sale only |

---

## 5. IMPLEMENTATION PLAN

---

### PHASE 1 — RENDERING FIXES (Do First)

**Goal:** Eyebrows look clean, eyeliner follows blinking, lashes look real.

---

#### Step 1 — Fix the Merge Conflict (30 min)

Replace `Services/MediaPipeHelperClient.swift` with the resolved version above. Build and confirm it compiles.

---

#### Step 2 — Upgrade the Python Sidecar (1 hour)

Replace `mediapipe_helper/mediapipe_helper.py` with this:

```python
#!/usr/bin/env python3
"""
mediapipe_helper.py — v2
Upper eyelid landmarks + head pose added.
"""

import sys, os
import numpy as np
import cv2
from flask import Flask, request, jsonify

try:
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision as mp_vision
except ImportError:
    print("ERROR: mediapipe not installed."); sys.exit(1)

if getattr(sys, "frozen", False):
    _base = sys._MEIPASS
else:
    _base = os.path.dirname(os.path.abspath(__file__))

MODEL_PATH = os.path.join(_base, "face_landmarker.task")
if not os.path.exists(MODEL_PATH):
    print(f"ERROR: Model not found: {MODEL_PATH}"); sys.exit(1)

_options = mp_vision.FaceLandmarkerOptions(
    base_options=mp_python.BaseOptions(model_asset_path=MODEL_PATH),
    num_faces=1,
    min_face_detection_confidence=0.5,
    min_face_presence_confidence=0.5,
    min_tracking_confidence=0.5,
    output_face_blendshapes=True,           # needed for blink detection
    output_facial_transformation_matrixes=True,  # head pose
)
detector = mp_vision.FaceLandmarker.create_from_options(_options)
print("✅ Face Landmarker v2 loaded.")

# Outer lip
OUTER_LIPS = [61,185,40,39,37,0,267,269,270,409,291,375,321,405,314,17,84,181,91,146]
# Inner lip
INNER_LIPS = [78,191,80,81,82,13,312,311,310,415,308,324,318,402,317,14,87,178,88,95]

# Full eye contours — NO duplicate endpoints
LEFT_EYE  = [263,249,390,373,374,380,381,382,362,398,384,385,386,387,388,466]
RIGHT_EYE = [33,7,163,144,145,153,154,155,133,173,157,158,159,160,161,246]

# Upper eyelid ONLY — dedicated arcs for eyeliner/lash anchoring
# These indices specifically trace the upper lid from inner to outer corner
LEFT_UPPER_EYELID  = [362, 398, 384, 385, 386, 387, 388, 466, 263]
RIGHT_UPPER_EYELID = [133, 173, 157, 158, 159, 160, 161, 246, 33]

# Eyebrows — 10 points each (upper arch + lower edge)
LEFT_EYEBROW  = [276,283,282,295,285,300,293,334,296,336]
RIGHT_EYEBROW = [46,53,52,65,55,70,63,105,66,107]

# Face oval
FACE_CONTOUR = [
    10,338,297,332,284,251,389,356,454,323,
    361,288,397,365,379,378,400,377,152,148,
    176,149,150,136,172,58,132,93,234,127,
    162,21,54,103,67,109
]

def extract_points(lms, indices, flip_y=True):
    n = len(lms)
    out = []
    for idx in indices:
        if 0 <= idx < n:
            lm = lms[idx]
            y = (1.0 - lm.y) if flip_y else lm.y
            out.append([round(float(lm.x), 5), round(float(y), 5)])
    return out

import math

def rotation_matrix_to_euler(mat):
    """Convert 4x4 rotation matrix to roll/yaw/pitch in degrees."""
    # mat is a flat 16-element list (column-major from mediapipe)
    m = mat
    # Extract rotation sub-matrix (3x3, row-major):
    # mediapipe gives column-major 4x4
    r00 = m[0]; r10 = m[1]; r20 = m[2]
    r01 = m[4]; r11 = m[5]; r21 = m[6]
    r02 = m[8]; r12 = m[9]; r22 = m[10]

    pitch = math.atan2(-r20, math.sqrt(r00**2 + r10**2))
    yaw   = math.atan2(r10, r00)
    roll  = math.atan2(r21, r22)

    return (
        round(math.degrees(roll), 2),
        round(math.degrees(yaw), 2),
        round(math.degrees(pitch), 2)
    )

app = Flask(__name__)

@app.route("/v1/face_landmarks", methods=["POST"])
def face_landmarks_endpoint():
    jpeg_bytes = request.get_data()
    if not jpeg_bytes:
        return jsonify({"error": "empty_body"}), 400

    nparr   = np.frombuffer(jpeg_bytes, np.uint8)
    img_bgr = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    if img_bgr is None:
        return jsonify({"error": "decode_failed"}), 400

    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=img_rgb)
    result = detector.detect(mp_image)

    if not result.face_landmarks:
        return jsonify({"error": "no_face"})

    face = result.face_landmarks[0]

    # Head pose
    roll, yaw, pitch = 0.0, 0.0, 0.0
    if result.facial_transformation_matrixes:
        mat = result.facial_transformation_matrixes[0].data.flatten().tolist()
        roll, yaw, pitch = rotation_matrix_to_euler(mat)

    # Blink scores from blendshapes
    left_blink = 0.0
    right_blink = 0.0
    if result.face_blendshapes:
        for bs in result.face_blendshapes[0]:
            if bs.category_name == "eyeBlinkLeft":
                left_blink = round(float(bs.score), 3)
            elif bs.category_name == "eyeBlinkRight":
                right_blink = round(float(bs.score), 3)

    response = {
        "outerLips":           extract_points(face, OUTER_LIPS),
        "innerLips":           extract_points(face, INNER_LIPS),
        "leftEye":             extract_points(face, LEFT_EYE),
        "rightEye":            extract_points(face, RIGHT_EYE),
        "leftUpperEyelidRaw":  extract_points(face, LEFT_UPPER_EYELID),
        "rightUpperEyelidRaw": extract_points(face, RIGHT_UPPER_EYELID),
        "leftEyebrow":         extract_points(face, LEFT_EYEBROW),
        "rightEyebrow":        extract_points(face, RIGHT_EYEBROW),
        "faceContour":         extract_points(face, FACE_CONTOUR),
        "roll":   roll,
        "yaw":    yaw,
        "pitch":  pitch,
        "leftBlink":  left_blink,
        "rightBlink": right_blink,
    }
    return jsonify(response)

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})

if __name__ == "__main__":
    print("MediaPipe Face Landmarker v2 running on http://127.0.0.1:9001")
    app.run(host="127.0.0.1", port=9001, threaded=False)
```

**Also add to `FaceLandmarks.swift`:**

```swift
// Add these fields to FaceLandmarks struct
var leftBlink: Double = 0      // 0=open, 1=fully closed
var rightBlink: Double = 0

// Add to CodingKeys
case leftBlink
case rightBlink

// Add to init(from decoder:)
self.leftBlink  = try container.decodeIfPresent(Double.self, forKey: .leftBlink) ?? 0
self.rightBlink = try container.decodeIfPresent(Double.self, forKey: .rightBlink) ?? 0
```

---

#### Step 3 — Rewrite BrowRenderer with Temporal Smoothing

**Why it fails today:**
- No per-frame smoothing → visible shimmer
- The 10 MediaPipe brow points are sparse; `smooth()` only runs a 3-point window once → not enough
- The shape looks broken at the ends because the head+tail taper abruptly terminates at the first/last raw landmark

**The fix:** Add an EMA (exponential moving average) state object to BrowRenderer, same pattern used in EyelinerRenderer. Additionally run the Catmull-Rom spline (not just quadratic approximation) for a cleaner arch.

Replace `BrowRenderer.swift`:

```swift
import AVFoundation
import AppKit

final class BrowRenderer {

    // MARK: - Per-eye temporal state
    private struct BrowState {
        var smoothedPoints: [CGPoint] = []
        var hasValidShape = false
    }
    private var leftState  = BrowState()
    private var rightState = BrowState()

    /// EMA alpha: lower = more lag but smoother. 0.25 is a good default.
    private let emaAlpha: CGFloat = 0.25

    func updateBrowLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = CGFloat(settings.browIntensity.clamped(to: 0...1))
        guard intensity > 0.001, let face = landmarks.first else {
            clearLayer(layer); return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let extent = contentExtent, let bounds = viewBounds {
            convert = { Self.convertProcessedFrameNormalized($0, extent: extent, bounds: bounds) }
        } else {
            convert = { self.convertToLayer($0, in: previewLayer) }
        }

        let path = CGMutablePath()
        if !face.leftEyebrow.isEmpty {
            let pts = face.leftEyebrow.map(convert)
            let stable = applyEMA(pts, state: &leftState)
            addBrowShape(for: stable, settings: settings, intensity: intensity, to: path, preferIncreasingX: true)
        }
        if !face.rightEyebrow.isEmpty {
            let pts = face.rightEyebrow.map(convert)
            let stable = applyEMA(pts, state: &rightState)
            addBrowShape(for: stable, settings: settings, intensity: intensity, to: path, preferIncreasingX: false)
        }

        layer.path = path

        // Soft fill: low base opacity, scaled by intensity
        let fillAlpha = 0.08 + 0.28 * intensity
        let color = settings.browNSColor
        layer.fillColor   = color.withAlphaComponent(fillAlpha).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth   = 0
        layer.fillRule    = .nonZero
        layer.shadowColor   = color.withAlphaComponent(fillAlpha * 0.15).cgColor
        layer.shadowOpacity = 1.0
        layer.shadowRadius  = 1.2 + 1.0 * intensity
        layer.shadowOffset  = .zero
    }

    // MARK: - EMA temporal smoothing

    private func applyEMA(_ current: [CGPoint], state: inout BrowState) -> [CGPoint] {
        guard !current.isEmpty else { return current }
        // If count changes (face tracking re-acquired), reset
        if state.smoothedPoints.count != current.count || !state.hasValidShape {
            state.smoothedPoints = current
            state.hasValidShape  = true
            return current
        }
        state.smoothedPoints = zip(current, state.smoothedPoints).map { cur, prev in
            CGPoint(
                x: prev.x + (cur.x - prev.x) * emaAlpha,
                y: prev.y + (cur.y - prev.y) * emaAlpha
            )
        }
        return state.smoothedPoints
    }

    // MARK: - Shape construction

    private func addBrowShape(
        for rawPoints: [CGPoint],
        settings: MakeupSettings,
        intensity: CGFloat,
        to path: CGMutablePath,
        preferIncreasingX: Bool
    ) {
        guard rawPoints.count >= 4 else { return }

        let ordered = normalizeDirection(rawPoints, preferIncreasingX: preferIncreasingX)
        let spine    = adjustedSpine(catmullRom(ordered, subdivisions: 12), settings: settings)
        guard spine.count >= 4 else { return }

        let span = max(abs(spine.last!.x - spine.first!.x), 1.0)

        let thickMult    = 0.55 + CGFloat(settings.browThickness.clamped(to: 0...1)) * 1.1
        let baseThickness = (span * 0.07 * thickMult).clamped(to: 3...14)

        var upper: [CGPoint] = []
        var lower: [CGPoint] = []

        for i in spine.indices {
            let t       = CGFloat(i) / CGFloat(max(spine.count - 1, 1))
            let profile = thicknessProfile(t)
            let thick   = baseThickness * profile

            upper.append(CGPoint(x: spine[i].x, y: spine[i].y + thick * 0.30))
            lower.append(CGPoint(x: spine[i].x, y: spine[i].y - thick * 0.70))
        }

        let uSmooth = catmullRomSmooth(upper)
        let lSmooth = catmullRomSmooth(lower)

        guard let fu = uSmooth.first, let lu = uSmooth.last,
              let fl = lSmooth.first, let ll = lSmooth.last else { return }

        path.move(to: fu)
        addCatmullPath(uSmooth.dropFirst().dropLast(), to: path)
        path.addLine(to: lu)

        let tailCtrl = CGPoint(x: (lu.x + ll.x) / 2, y: (lu.y + ll.y) / 2)
        path.addQuadCurve(to: ll, control: tailCtrl)

        addCatmullPath(lSmooth.dropFirst().dropLast().reversed(), to: path)
        path.addLine(to: fl)

        let headCtrl = CGPoint(x: (fl.x + fu.x) / 2, y: (fl.y + fu.y) / 2)
        path.addQuadCurve(to: fu, control: headCtrl)
        path.closeSubpath()
    }

    // MARK: - Catmull-Rom spline helpers

    /// Subdivides a polyline into smooth curve points using Catmull-Rom
    private func catmullRom(_ pts: [CGPoint], subdivisions: Int = 8) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        // Pad endpoints
        let p = [pts[0]] + pts + [pts[pts.count - 1]]
        var result: [CGPoint] = []
        for i in 1..<p.count - 2 {
            let p0 = p[i-1], p1 = p[i], p2 = p[i+1], p3 = p[i+2]
            for j in 0...subdivisions {
                let t = CGFloat(j) / CGFloat(subdivisions)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2*p1.x) + (-p0.x + p2.x)*t +
                               (2*p0.x - 5*p1.x + 4*p2.x - p3.x)*t2 +
                               (-p0.x + 3*p1.x - 3*p2.x + p3.x)*t3)
                let y = 0.5 * ((2*p1.y) + (-p0.y + p2.y)*t +
                               (2*p0.y - 5*p1.y + 4*p2.y - p3.y)*t2 +
                               (-p0.y + 3*p1.y - 3*p2.y + p3.y)*t3)
                result.append(CGPoint(x: x, y: y))
            }
        }
        return result
    }

    private func catmullRomSmooth(_ pts: [CGPoint]) -> [CGPoint] {
        return catmullRom(pts, subdivisions: 4)
    }

    private func addCatmullPath<C: Collection>(_ pts: C, to path: CGMutablePath)
        where C.Element == CGPoint
    {
        var prev = path.currentPoint
        for pt in pts {
            let mid = CGPoint(x: (prev.x + pt.x) / 2, y: (prev.y + pt.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            prev = pt
        }
        if let last = pts.last {
            path.addLine(to: last)
        }
    }

    // MARK: - Spine adjustment

    private func adjustedSpine(from points: [CGPoint], settings: MakeupSettings) -> [CGPoint] {
        adjustedSpine(points, settings: settings)
    }

    private func adjustedSpine(_ points: [CGPoint], settings: MakeupSettings) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let centerX = (minX + maxX) / 2
        let archAmount  = CGFloat(settings.browArchAmount.clamped(to: -1...1))
        let tailLift    = CGFloat(settings.browTailLift.clamped(to: -1...1))
        let heightOffset = CGFloat(settings.browHeightOffset.clamped(to: -1...1))

        return points.enumerated().map { index, point in
            let t = CGFloat(index) / CGFloat(max(points.count - 1, 1))
            var y = point.y - heightOffset * 14.0
            let archCenter: CGFloat = 0.55
            let archFalloff = exp(-pow((t - archCenter) / 0.22, 2.0))
            y -= archAmount * 10.0 * archFalloff
            let tailWeight = smoothStep(0.60, 1.0, t)
            y -= tailLift * 9.0 * tailWeight
            return CGPoint(x: centerX + (point.x - centerX), y: y)
        }
    }

    private func normalizeDirection(_ points: [CGPoint], preferIncreasingX: Bool) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return points }
        let isIncreasing = last.x > first.x
        return (preferIncreasingX == isIncreasing) ? points : points.reversed()
    }

    private func thicknessProfile(_ t: CGFloat) -> CGFloat {
        let base      = 0.38
        let archBoost = 0.62 * exp(-pow((t - 0.56) / 0.22, 2.0))
        let headTaper = 0.30 + 0.70 * smoothStep(0.00, 0.20, t)
        let tailTaper = 1.0 - 0.62 * smoothStep(0.78, 1.00, t)
        return max(0.18, (base + archBoost) * headTaper * tailTaper)
    }

    // MARK: - Utilities

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path = nil
        layer.fillColor = NSColor.clear.cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.shadowColor = NSColor.clear.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
    }

    private func smoothStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - e0) / max(e1 - e0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    private func convertToLayer(_ p: CGPoint, in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func convertProcessedFrameNormalized(
        _ normalized: CGPoint, extent: CGRect, bounds: CGRect
    ) -> CGPoint {
        let scale = max(bounds.width / extent.width, bounds.height / extent.height)
        let drawW = extent.width * scale, drawH = extent.height * scale
        let ox = bounds.midX - drawW / 2, oy = bounds.midY - drawH / 2
        return CGPoint(x: ox + normalized.x * drawW, y: oy + normalized.y * drawH)
    }
}

// MARK: - Extensions
extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        max(range.lowerBound, min(range.upperBound, self))
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        max(range.lowerBound, min(range.upperBound, self))
    }
}
```

---

#### Step 4 — Rewrite EyelinerRenderer (Blink-aware, Wing-stable)

**Why it fails today:**
- Wing direction computed from raw dx/dy — flips on tilt
- Band starts at t=0.50 (`smoothStep(0.5, 0.70, t)`) — inner half of eye has NO eyeliner
- During blink, it freezes the last frame's *screen* shape — but if the head has moved, the frozen shape is in the wrong position
- `wingGoesRight` is determined at call site, but the renderer trusts it without checking actual eye geometry

**The critical fix: anchor everything to the outer corner landmark directly, and use the dedicated `leftUpperEyelid`/`rightUpperEyelid` arc instead of guessing from Y-centroid.**

```swift
// EyelinerRenderer.swift — full replacement

import AVFoundation
import AppKit

final class EyelinerRenderer {

    private struct EyeState {
        var smoothedLid: [CGPoint] = []
        var emaOuterCorner: CGPoint = .zero
        var emaInnerCorner: CGPoint = .zero
        var hasValid = false
    }

    private var leftState  = EyeState()
    private var rightState = EyeState()
    private let emaAlpha: CGFloat = 0.30

    func updateEyelinerLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = CGFloat(settings.eyelinerIntensity.clamped(to: 0...1))
        guard intensity > 0, let face = landmarks.first else {
            clearLayer(layer)
            leftState  = EyeState()
            rightState = EyeState()
            return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let ext = contentExtent, let b = viewBounds {
            convert = { Self.normToView($0, extent: ext, bounds: b) }
        } else {
            convert = { Self.toLayer($0, layer: previewLayer) }
        }

        let path = CGMutablePath()

        // Use dedicated upper eyelid arc if available
        let leftLid  = face.leftUpperEyelid.isEmpty  ? [] : face.leftUpperEyelid
        let rightLid = face.rightUpperEyelid.isEmpty ? [] : face.rightUpperEyelid

        let leftBlink  = face.leftBlink
        let rightBlink = face.rightBlink

        if !leftLid.isEmpty {
            drawEyeliner(lid: leftLid, convert: convert, intensity: intensity,
                         blink: leftBlink, isLeft: true, state: &leftState, into: path)
        }
        if !rightLid.isEmpty {
            drawEyeliner(lid: rightLid, convert: convert, intensity: intensity,
                         blink: rightBlink, isLeft: false, state: &rightState, into: path)
        }

        let eyelinerColor = settings.eyelinerNSColor   // see MakeupSettings update below
        layer.path        = path
        layer.fillColor   = eyelinerColor.withAlphaComponent(0.82 * intensity + 0.08).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth   = 0
        layer.fillRule    = .nonZero
        layer.shadowColor   = eyelinerColor.withAlphaComponent(0.12).cgColor
        layer.shadowRadius  = 0.8
        layer.shadowOpacity = 1.0
        layer.shadowOffset  = .zero
    }

    // MARK: - Draw one eye

    private func drawEyeliner(
        lid: [CGPoint],
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        blink: Double,
        isLeft: Bool,
        state: inout EyeState,
        into path: CGMutablePath
    ) {
        // Convert and EMA-smooth the lid arc
        var pts = lid.map(convert)

        // Sort inner → outer (increasing x for left eye on screen, decreasing for right)
        // "isLeft" in our context means the left eye as seen by the user (appears on right of screen in mirrored view)
        // Sort consistently by x-coordinate:
        pts.sort { isLeft ? $0.x > $1.x : $0.x < $1.x }

        // Deduplicate
        pts = pts.reduce(into: [CGPoint]()) { acc, pt in
            if let last = acc.last, abs(last.x - pt.x) < 0.5 { return }
            acc.append(pt)
        }
        guard pts.count >= 3 else { return }

        // EMA smooth
        if state.smoothedLid.count == pts.count && state.hasValid {
            pts = zip(pts, state.smoothedLid).map { cur, prev in
                CGPoint(x: prev.x + (cur.x - prev.x) * emaAlpha,
                        y: prev.y + (cur.y - prev.y) * emaAlpha)
            }
        }
        state.smoothedLid = pts
        state.hasValid = true

        // Blink compression: scale y toward the lid center when eye is closing
        let blinkFactor = CGFloat(max(0, 1.0 - blink * 0.85))
        let lidCenterY  = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        if blinkFactor < 1.0 {
            pts = pts.map { pt in
                CGPoint(x: pt.x, y: lidCenterY + (pt.y - lidCenterY) * blinkFactor)
            }
        }

        let innerCorner = pts.first!
        let outerCorner = pts.last!

        // EMA-smooth the corner anchors independently (more stable than smoothing all pts together)
        let smoothOuter: CGPoint
        let smoothInner: CGPoint
        if state.hasValid && state.emaOuterCorner != .zero {
            smoothOuter = lerp(state.emaOuterCorner, outerCorner, emaAlpha)
            smoothInner = lerp(state.emaInnerCorner, innerCorner, emaAlpha)
        } else {
            smoothOuter = outerCorner
            smoothInner = innerCorner
        }
        state.emaOuterCorner = smoothOuter
        state.emaInnerCorner = smoothInner

        // Lid span
        let span = hypot(smoothOuter.x - smoothInner.x, smoothOuter.y - smoothInner.y)
        guard span > 4 else { return }

        // Band thickness: tapers from inner to outer, then flares at outer corner
        let maxThick = (span * (0.032 + 0.018 * intensity)).clamped(to: 1.5...6.5)
        let blinkThickScale = 0.4 + 0.6 * blinkFactor  // thin during blink

        var upper: [CGPoint] = []
        var lower: [CGPoint] = []

        for (i, p) in pts.enumerated() {
            let t = CGFloat(i) / CGFloat(max(pts.count - 1, 1))
            // Liner starts thin at inner corner, grows through outer
            let taper = smoothStep(0.0, 0.45, t)          // full coverage from inner corner
            let flare = 1.0 + 0.5 * smoothStep(0.75, 1.0, t)
            let thick = maxThick * taper * flare * blinkThickScale
            let drop  = span * 0.015 * (1.2 - 0.4 * t)   // drop below the lid

            let base = CGPoint(x: p.x, y: p.y + drop)
            upper.append(base)
            lower.append(CGPoint(x: base.x, y: base.y + thick))
        }

        // Wing — anchored to smoothOuter, direction from the last 3 points of the lid
        let refIdx = max(0, pts.count - 3)
        let ref    = pts[refIdx]
        var dx = smoothOuter.x - ref.x
        var dy = smoothOuter.y - ref.y
        let dLen = max(1, hypot(dx, dy))
        dx /= dLen; dy /= dLen

        // Ensure wing goes in the correct direction for each eye
        if isLeft && dx < 0 { dx = -dx; dy = -dy }
        if !isLeft && dx > 0 { dx = -dx; dy = -dy }

        let wLen   = span * (0.08 + 0.13 * intensity)
        let wLift  = span * 0.045
        let wDepth = max(2.5, span * (0.060 + 0.025 * intensity))

        // Wing tip — lifted slightly upward
        let wingTip = CGPoint(
            x: smoothOuter.x + dx * wLen,
            y: smoothOuter.y - wLift         // lift = negative y (up on screen)
        )

        // Wedge base — anchor of the lower wing edge
        let wedgeBase = CGPoint(
            x: smoothOuter.x + dx * wLen * 0.25,
            y: smoothOuter.y + wDepth
        )

        // Draw filled shape: upper band → wing tip → wedge → lower band reverse
        guard !upper.isEmpty, !lower.isEmpty else { return }

        path.move(to: upper[0])
        catmullPath(upper.dropFirst(), to: path)
        path.addLine(to: wingTip)
        path.addLine(to: wedgeBase)
        catmullPath(lower.reversed().dropFirst(), to: path)
        path.addLine(to: upper[0])
        path.closeSubpath()
    }

    // MARK: - Helpers

    private func catmullPath<C: Collection>(_ pts: C, to path: CGMutablePath)
        where C.Element == CGPoint
    {
        var prev = path.currentPoint
        for pt in pts {
            let mid = CGPoint(x: (prev.x + pt.x) / 2, y: (prev.y + pt.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            prev = pt
        }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func smoothStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - e0) / max(e1 - e0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path = nil
        [layer.fillColor, layer.strokeColor, layer.shadowColor].forEach { _ in }
        layer.fillColor   = NSColor.clear.cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.shadowColor = NSColor.clear.cgColor
        layer.shadowOpacity = 0
    }

    private static func toLayer(_ p: CGPoint, layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func normToView(_ p: CGPoint, extent: CGRect, bounds: CGRect) -> CGPoint {
        let scale = max(bounds.width / extent.width, bounds.height / extent.height)
        let dw = extent.width * scale, dh = extent.height * scale
        let ox = bounds.midX - dw / 2, oy = bounds.midY - dh / 2
        return CGPoint(x: ox + p.x * dw, y: oy + p.y * dh)
    }
}
```

**Add to `MakeupSettings`:**

```swift
// In MakeupSettings struct
var eyelinerNSColor: NSColor = NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)

var eyelinerColor: Color {
    get { Color(nsColor: eyelinerNSColor) }
    set { eyelinerNSColor = NSColor(newValue) }
}
```

---

#### Step 5 — Rewrite LashesRenderer (Wispy Tapered Fills)

**Why it fails today:**
- Uses stroked open paths (lines) not filled tapered shapes
- Only 3–5 flicks at the outer corner; inner/middle lashes are absent
- No variation in length, spacing, or angle — looks like a rubber stamp
- No temporal smoothing
- No blink behavior (lashes float when eye closes)

**The fix: render each lash as a tiny filled teardrop path — thick at base (on the liner), tapering to a point at tip, with slight curve.**

```swift
// LashesRenderer.swift — full replacement

import AVFoundation
import AppKit

final class LashesRenderer {

    private struct LashState {
        var smoothedLid: [CGPoint] = []
        var hasValid = false
    }
    private var leftState  = LashState()
    private var rightState = LashState()
    private let emaAlpha: CGFloat = 0.28

    // Seeded RNG for deterministic variation (same lash layout every frame)
    private let rng = SeededRandom(seed: 42)

    func updateLashesLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = CGFloat(settings.lashesIntensity.clamped(to: 0...1))
        guard intensity > 0, let face = landmarks.first else { clearLayer(layer); return }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let ext = contentExtent, let b = viewBounds {
            convert = { Self.normToView($0, extent: ext, bounds: b) }
        } else {
            convert = { Self.toLayer($0, layer: previewLayer) }
        }

        let path = CGMutablePath()
        let leftLid  = face.leftUpperEyelid
        let rightLid = face.rightUpperEyelid
        let leftBlink  = face.leftBlink
        let rightBlink = face.rightBlink

        if !leftLid.isEmpty {
            addLashSet(lid: leftLid, convert: convert, intensity: intensity,
                       blink: leftBlink, isLeft: true, state: &leftState, to: path)
        }
        if !rightLid.isEmpty {
            addLashSet(lid: rightLid, convert: convert, intensity: intensity,
                       blink: rightBlink, isLeft: false, state: &rightState, to: path)
        }

        layer.path        = path
        layer.fillColor   = NSColor.labelColor.withAlphaComponent(0.78 * intensity + 0.10).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.lineWidth   = 0
        layer.shadowColor   = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        layer.shadowRadius  = 0.5 + 0.5 * intensity
        layer.shadowOpacity = 1.0
        layer.shadowOffset  = .zero
    }

    private func addLashSet(
        lid: [CGPoint],
        convert: (CGPoint) -> CGPoint,
        intensity: CGFloat,
        blink: Double,
        isLeft: Bool,
        state: inout LashState,
        to path: CGMutablePath
    ) {
        var pts = lid.map(convert)
        pts.sort { isLeft ? $0.x > $1.x : $0.x < $1.x }
        pts = deduplicate(pts, minDist: 1.0)
        guard pts.count >= 3 else { return }

        // EMA
        if state.smoothedLid.count == pts.count && state.hasValid {
            pts = zip(pts, state.smoothedLid).map { cur, prev in
                CGPoint(x: prev.x + (cur.x - prev.x) * emaAlpha,
                        y: prev.y + (cur.y - prev.y) * emaAlpha)
            }
        }
        state.smoothedLid = pts
        state.hasValid = true

        // Blink: compress lashes toward lid
        let openness = CGFloat(max(0.05, 1.0 - blink * 0.90))
        let lidCenterY = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)

        let span = hypot(pts.last!.x - pts.first!.x, pts.last!.y - pts.first!.y)
        guard span > 4 else { return }

        // Lash density: roughly 1 lash per 3-4px along the lid
        let count = max(8, Int(span / 3.5 * (0.6 + 0.4 * intensity)))

        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(max(count - 1, 1))

            // Position along lid via linear interpolation between sorted points
            let base = interpolateLid(pts, at: t)

            // Blink compression
            let compressed = CGPoint(
                x: base.x,
                y: lidCenterY + (base.y - lidCenterY) * openness
            )

            // Lash tangent from lid curve
            let t0 = max(0, t - 0.05)
            let t1 = min(1, t + 0.05)
            let p0 = interpolateLid(pts, at: t0)
            let p1 = interpolateLid(pts, at: t1)
            let tangentX = p1.x - p0.x
            let tangentY = p1.y - p0.y
            let tLen = max(1, hypot(tangentX, tangentY))
            let tx = tangentX / tLen, ty = tangentY / tLen
            // Normal (perpendicular, pointing "up" = away from lid)
            let nx = -ty, ny = tx

            // Deterministic pseudo-random variation per lash
            let seed = Float(i) * 0.618 + 0.1
            let lengthJitter  = 0.75 + 0.50 * pseudoRand(seed)
            let curveJitter   = 0.85 + 0.30 * pseudoRand(seed + 1.1)
            let angleJitter   = (pseudoRand(seed + 2.3) - 0.5) * 0.20  // ±~11°
            let widthJitter   = 0.8 + 0.4 * pseudoRand(seed + 3.7)

            // Outer lashes are longer and more lifted
            let outerBoost = 0.6 + 0.8 * smoothStep(0.55, 1.0, t)   // if isLeft, outer is at high t
            let baseLen    = span * (0.045 + 0.040 * intensity) * outerBoost * lengthJitter * openness
            let baseWidth  = max(0.8, span * 0.008 * widthJitter)

            // Angle: slightly outward from normal, varies per lash
            let cos_a = cos(angleJitter), sin_a = sin(angleJitter)
            let lashDX = nx * cos_a - ny * sin_a
            let lashDY = nx * sin_a + ny * cos_a

            // Control point for the lash curve
            let curveFactor = baseLen * 0.35 * curveJitter
            let ctrlX = compressed.x + lashDX * baseLen * 0.5 + tx * curveFactor
            let ctrlY = compressed.y + lashDY * baseLen * 0.5 + ty * curveFactor

            let tipX = compressed.x + lashDX * baseLen
            let tipY = compressed.y + lashDY * baseLen

            // Draw tapered filled lash (teardrop shape)
            addTaperedLash(
                from: compressed,
                control: CGPoint(x: ctrlX, y: ctrlY),
                to: CGPoint(x: tipX, y: tipY),
                baseWidth: baseWidth,
                tangent: CGPoint(x: tx, y: ty),
                to: path
            )
        }
    }

    private func addTaperedLash(
        from base: CGPoint,
        control ctrl: CGPoint,
        to tip: CGPoint,
        baseWidth: CGFloat,
        tangent: CGPoint,
        to path: CGMutablePath
    ) {
        // Draw a filled teardrop: wide at base, converging to a point at tip
        let perp = CGPoint(x: -tangent.y, y: tangent.x)
        let halfW = baseWidth * 0.5

        let baseLeft  = CGPoint(x: base.x - perp.x * halfW, y: base.y - perp.y * halfW)
        let baseRight = CGPoint(x: base.x + perp.x * halfW, y: base.y + perp.y * halfW)

        path.move(to: baseLeft)
        path.addQuadCurve(to: tip, control: ctrl)
        path.addLine(to: baseRight)
        path.addLine(to: baseLeft)
        path.closeSubpath()
    }

    // MARK: - Helpers

    private func interpolateLid(_ pts: [CGPoint], at t: CGFloat) -> CGPoint {
        guard pts.count >= 2 else { return pts.first ?? .zero }
        let ft = t * CGFloat(pts.count - 1)
        let lo = Int(ft)
        let hi = min(lo + 1, pts.count - 1)
        let frac = ft - CGFloat(lo)
        let a = pts[lo], b = pts[hi]
        return CGPoint(x: a.x + (b.x - a.x) * frac, y: a.y + (b.y - a.y) * frac)
    }

    private func deduplicate(_ pts: [CGPoint], minDist: CGFloat) -> [CGPoint] {
        guard !pts.isEmpty else { return [] }
        var out = [pts[0]]
        for pt in pts.dropFirst() {
            let last = out.last!
            if hypot(pt.x - last.x, pt.y - last.y) >= minDist { out.append(pt) }
        }
        return out
    }

    private func pseudoRand(_ x: Float) -> CGFloat {
        let s = sin(x * 127.1 + 311.7) * 43758.5453
        return CGFloat(s - floor(s))
    }

    private func smoothStep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - e0) / max(e1 - e0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path = nil
        layer.fillColor   = NSColor.clear.cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.shadowColor = NSColor.clear.cgColor
        layer.shadowOpacity = 0
    }

    private static func toLayer(_ p: CGPoint, layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func normToView(_ p: CGPoint, extent: CGRect, bounds: CGRect) -> CGPoint {
        let scale = max(bounds.width / extent.width, bounds.height / extent.height)
        let dw = extent.width * scale, dh = extent.height * scale
        return CGPoint(x: bounds.midX - dw / 2 + p.x * dw,
                       y: bounds.midY - dh / 2 + p.y * dh)
    }
}

// MARK: - Seeded RNG (deterministic per frame — same lash layout)
private struct SeededRandom {
    var seed: UInt64
    init(seed: Int) { self.seed = UInt64(seed) }
    mutating func next() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
}
```

---

#### Step 6 — Add Blush Renderer

Add `BlushRenderer.swift`:

```swift
import AVFoundation
import AppKit

final class BlushRenderer {

    private struct BlushState {
        var smoothedLeft:  CGPoint = .zero
        var smoothedRight: CGPoint = .zero
        var hasValid = false
    }
    private var state = BlushState()
    private let alpha: CGFloat = 0.18

    func updateBlushLayer(
        _ layer: CAShapeLayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = CGFloat(settings.blushIntensity.clamped(to: 0...1))
        guard intensity > 0, let face = landmarks.first,
              !face.leftEye.isEmpty, !face.rightEye.isEmpty else {
            clearLayer(layer); return
        }

        let convert: (CGPoint) -> CGPoint
        if useProcessedFrameCoordinates, let ext = contentExtent, let b = viewBounds {
            convert = { Self.normToView($0, extent: ext, bounds: b) }
        } else {
            convert = { Self.toLayer($0, layer: previewLayer) }
        }

        // Estimate cheek center from eye + jaw landmarks
        // Left cheek: between left eye outer corner and jawline
        let leftEyeOuter  = convert(face.leftEye.min(by: { $0.x < $1.x }) ?? face.leftEye[0])
        let rightEyeOuter = convert(face.rightEye.max(by: { $0.x < $1.x }) ?? face.rightEye[0])

        // Cheek center = below-and-outside each eye outer corner
        let faceH: CGFloat = 80  // estimated pixel offset downward

        let rawLeft  = CGPoint(x: leftEyeOuter.x  - 14, y: leftEyeOuter.y  + faceH)
        let rawRight = CGPoint(x: rightEyeOuter.x + 14, y: rightEyeOuter.y + faceH)

        // EMA smooth cheek centers
        if state.hasValid {
            state.smoothedLeft  = lerp(state.smoothedLeft, rawLeft, alpha)
            state.smoothedRight = lerp(state.smoothedRight, rawRight, alpha)
        } else {
            state.smoothedLeft  = rawLeft
            state.smoothedRight = rawRight
            state.hasValid = true
        }

        let path = CGMutablePath()
        let rx: CGFloat = 24 + 18 * intensity
        let ry: CGFloat = 14 + 10 * intensity

        path.addEllipse(in: CGRect(
            x: state.smoothedLeft.x  - rx, y: state.smoothedLeft.y  - ry,
            width: rx * 2, height: ry * 2
        ))
        path.addEllipse(in: CGRect(
            x: state.smoothedRight.x - rx, y: state.smoothedRight.y - ry,
            width: rx * 2, height: ry * 2
        ))

        layer.path        = path
        layer.fillColor   = settings.blushNSColor.withAlphaComponent(0.10 + 0.18 * intensity).cgColor
        layer.strokeColor = NSColor.clear.cgColor
        layer.shadowColor = settings.blushNSColor.withAlphaComponent(0.08).cgColor
        layer.shadowRadius  = 10 + 6 * intensity
        layer.shadowOpacity = 1.0
        layer.shadowOffset  = .zero
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func clearLayer(_ layer: CAShapeLayer) {
        layer.path = nil
        layer.fillColor = NSColor.clear.cgColor
        layer.shadowColor = NSColor.clear.cgColor
        layer.shadowOpacity = 0
    }

    private static func toLayer(_ p: CGPoint, layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: p.x, y: 1 - p.y))
    }

    private static func normToView(_ p: CGPoint, extent: CGRect, bounds: CGRect) -> CGPoint {
        let scale = max(bounds.width / extent.width, bounds.height / extent.height)
        let dw = extent.width * scale, dh = extent.height * scale
        return CGPoint(x: bounds.midX - dw / 2 + p.x * dw,
                       y: bounds.midY - dh / 2 + p.y * dh)
    }
}
```

**Add to `MakeupSettings`:**
```swift
var blushNSColor: NSColor  = NSColor(calibratedRed: 0.85, green: 0.40, blue: 0.45, alpha: 1)
var blushIntensity: Double = 0.0

var blushColor: Color {
    get { Color(nsColor: blushNSColor) }
    set { blushNSColor = NSColor(newValue) }
}
```

---

### PHASE 2 — UI POLISH

#### Improved ControlsSidebarView

The current sidebar is functional but feels like a settings panel, not a beauty app. Key improvements:

1. Group controls into collapsible sections with section icons
2. Add color swatches to eye section (eyeliner color)
3. Show blush section
4. Improve slider visual style
5. Add a header with app name/logo

Key code changes for `ControlsSidebarView`:

```swift
// Add Eyes color pickers:
sectionHeader("Eyes")
colorRow(label: "Eyeliner color", systemImage: "eye", color: $settings.eyelinerColor)
intensityRow(label: "Eyeliner", systemImage: "eye", value: $settings.eyelinerIntensity)
intensityRow(label: "Lashes", systemImage: "eye.fill", value: $settings.lashesIntensity)

// Add Blush section:
Divider().padding(.horizontal, 16)
sectionHeader("Blush")
colorRow(label: "Blush color", systemImage: "heart", color: $settings.blushColor)
intensityRow(label: "Intensity", systemImage: "slider.horizontal.3", value: $settings.blushIntensity)
```

For the app header, add above the ScrollView:
```swift
// App header
HStack(spacing: 10) {
    Image(systemName: "camera.aperture")  // replace with actual app icon
        .font(.system(size: 20))
        .foregroundStyle(.pink)
    Text("GlowCam")
        .font(.system(size: 14, weight: .semibold))
    Spacer()
}
.padding(.horizontal, 16)
.padding(.vertical, 12)
.background(Color(nsColor: .windowBackgroundColor))
```

---

### PHASE 3 — VIRTUAL CAMERA + RELEASE

#### Virtual Camera Architecture

**Current situation (honest assessment):**

The app currently renders makeup overlays on a `CAShapeLayer` over a camera preview. This is display-only — other apps (Teams, Zoom) cannot see it.

**To make it work as a real camera, you need one of:**

| Approach | Difficulty | App Store | Stability |
|----------|-----------|-----------|-----------|
| CoreMediaIO DAL Plugin | Hard | ❌ No | Fragile (deprecated in macOS 15) |
| DriverKit Camera Extension | Very Hard | ✅ Yes | Stable (Apple-preferred) |
| Companion app (OBS + Virtual Cam) | Medium | N/A | Works today |
| Camo / restream approach (sidecar) | Medium | ❌ Likely no | Good |

**Recommendation for now:**

Use a **CoreMediaIO Camera Extension** (DriverKit) — this is the only approach that is both App Store compatible and stable on macOS 13+. However this requires a separate System Extension target, a separate provisioning profile with a DriverKit entitlement, and Apple must approve the entitlement request (it's not automatic).

**Realistic timeline:** 2–3 weeks of extra work, plus Apple review.

**For shipping fast:** Use the **companion virtual camera approach** — install a lightweight CoreMediaIO DAL plugin (like the open-source `obs-mac-virtualcam` approach) that accepts pixel buffers via a shared memory/mach port, and have your app write rendered frames to it. This works immediately but cannot go on the App Store.

**The honest answer about the App Store:**

> A $13.99 Mac App Store listing for a virtual camera app is possible ONLY if you use DriverKit. Without it, the app cannot inject a camera device system-wide. You could sell a direct (notarized, Gatekeeper-compatible) version from your own website while you pursue the DriverKit path.

---

#### Release Checklist

- [ ] Resolve all merge conflicts (BUG 1)
- [ ] App icon: provide 1024x1024 PNG in Assets.xcassets/AppIcon.appiconset
- [ ] Bundle ID: set a unique reverse-domain ID (e.g. `com.yourname.glowcam`)
- [ ] Info.plist: add `NSCameraUsageDescription`
- [ ] Entitlements: `com.apple.security.device.camera = YES`
- [ ] If sandboxed (App Store): add `com.apple.security.app-sandbox = YES`
- [ ] Notarization: use `xcrun notarytool` with Apple Developer credentials
- [ ] Screenshots: 1280×800 and 1440×900 macOS screenshots for App Store
- [ ] Privacy: no data leaves device (no telemetry, no network except localhost sidecar)
- [ ] Hardened Runtime: enable in target signing settings

---

## 6. EXACT NEXT 3 TASKS

### Task 1 (Do NOW — 30 min)
**Fix the merge conflict in `MediaPipeHelperClient.swift`.**
The app doesn't compile. Replace the entire file with the resolved version in Step 1 above.
File: `TeamsMakeupCam/TeamsMakeupCam/Services/MediaPipeHelperClient.swift`

### Task 2 (Today — 1 hour)
**Upgrade `mediapipe_helper.py` with upper eyelid and blink data.**
The sidecar is the source of truth for all landmark data. Without dedicated upper eyelid points, the eyeliner and lash renderers are guessing. Replace the sidecar script with the v2 version in Step 2, rebuild the binary (`pyinstaller --onefile mediapipe_helper.py`), and copy the new binary to `Services/Resources/mediapipe_helper`.

### Task 3 (This week — 2–3 hours)
**Replace BrowRenderer + EyelinerRenderer + LashesRenderer with the new versions above.**
Do them together because they share the same infrastructure (EMA smoothing, upper eyelid arc, blink data). After applying all three, do a visual test:
- Move your head left/right: eyeliner should not drift
- Blink slowly: eyeliner and lashes should compress, not detach
- Stay still: brows should not shimmer

---

## 7. TESTING CHECKLIST

- [ ] Brows: still on still face (no shimmer)
- [ ] Brows: follow head tilt smoothly
- [ ] Brows: arch/thickness controls work without breaking shape
- [ ] Eyeliner: wing stays attached on head movement
- [ ] Eyeliner: no flip/jump when tilting ±30°
- [ ] Eyeliner: compresses smoothly on blink (not detach)
- [ ] Lashes: distributed along full lid (not just outer corner)
- [ ] Lashes: wispy variation (different lengths per lash)
- [ ] Lashes: compress with blink, no floating
- [ ] Blush: stays on cheeks during head movement
- [ ] Performance: CPU stays below 60% at 30fps

---

## 8. APP ICON DIRECTION

Design brief:
- Color: deep rose / black gradient — premium beauty aesthetic
- Shape: Camera aperture with a subtle lip/eye motif
- Style: Clean, minimal, works at 16px and 1024px
- Tools: Figma or Sketch → export 1024×1024 PNG

Asset sizes needed for macOS:
```
16x16     @1x @2x
32x32     @1x @2x
128x128   @1x @2x
256x256   @1x @2x
512x512   @1x @2x
1024x1024 @1x
```

All go in `Assets.xcassets/AppIcon.appiconset/Contents.json`.

---

*End of audit. Start with Task 1 — the app cannot compile until the merge conflict is resolved.*
