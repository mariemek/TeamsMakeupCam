#!/usr/bin/env python3
"""
mediapipe_helper.py
────────────────────────────────────────────────────────────
Localhost Face Landmarker helper using the MediaPipe Tasks API.
Significantly more accurate eye/lip contours than the old Face Mesh API.

Requirements:
    pip install mediapipe flask opencv-python

Model download (run once):
    curl -o face_landmarker.task \
      https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task

Run:
    python mediapipe_helper.py

Listens on http://127.0.0.1:9001
────────────────────────────────────────────────────────────

POST /v1/face_landmarks
  Content-Type: image/jpeg
  Body: raw JPEG bytes

Response (face found):
  {
    "outerLips":    [[x, y], ...],   // normalised 0-1, origin bottom-left
    "innerLips":    [[x, y], ...],
    "leftEye":      [[x, y], ...],
    "rightEye":     [[x, y], ...],
    "leftEyebrow":  [[x, y], ...],
    "rightEyebrow": [[x, y], ...],
    "faceContour":  [[x, y], ...]
  }

Response (no face):
  {"error": "no_face"}

────────────────────────────────────────────────────────────
Landmark indices — same 468-point map as Face Mesh.
The Tasks API face_landmarker.task uses the identical indices
for points 0-467, so all mappings below are correct for both APIs.

Coordinate convention:
  MediaPipe returns x,y normalised to [0,1] with origin TOP-LEFT.
  We flip y → bottom-left origin so Swift renderers receive (0,0)=bottom-left.
────────────────────────────────────────────────────────────
"""

import sys
import os
import numpy as np
import cv2
from flask import Flask, request, jsonify

# ── MediaPipe Tasks API ────────────────────────────────────────────────────────
try:
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision as mp_vision
except ImportError:
    print("ERROR: mediapipe not installed. Run:  pip install mediapipe flask opencv-python")
    sys.exit(1)

# ── Model path ─────────────────────────────────────────────────────────────────
# When bundled with PyInstaller (--onefile), data files are extracted to a
# temporary directory referenced by sys._MEIPASS. Fall back to the script's
# own directory for normal dev use.
if getattr(sys, "frozen", False):
    _base = sys._MEIPASS  # type: ignore[attr-defined]
else:
    _base = os.path.dirname(os.path.abspath(__file__))

MODEL_PATH = os.path.join(_base, "face_landmarker.task")
if not os.path.exists(MODEL_PATH):
    print(f"ERROR: Model file not found at: {MODEL_PATH}")
    print("Download it with:")
    print("  curl -o face_landmarker.task \\")
    print("    https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task")
    sys.exit(1)

# ── Initialise detector (once at startup) ──────────────────────────────────────
_base_options = mp_python.BaseOptions(model_asset_path=MODEL_PATH)
_options = mp_vision.FaceLandmarkerOptions(
    base_options=_base_options,
    num_faces=1,
    min_face_detection_confidence=0.5,
    min_face_presence_confidence=0.5,
    min_tracking_confidence=0.5,
    output_face_blendshapes=False,
    output_facial_transformation_matrixes=False,
)
detector = mp_vision.FaceLandmarker.create_from_options(_options)
print("✅ Face Landmarker model loaded.")

# ── Landmark index groups ──────────────────────────────────────────────────────
# All indices are for the 468-point canonical Face Mesh / Face Landmarker model.

# Outer lip contour (20 points, closed loop)
OUTER_LIPS = [
    61, 185, 40, 39, 37, 0, 267, 269, 270, 409,
    291, 375, 321, 405, 314, 17, 84, 181, 91, 146,
]

# Inner lip / mouth-opening ring (20 points, closed loop)
INNER_LIPS = [
    78, 191, 80, 81, 82, 13, 312, 311, 310, 415,
    308, 324, 318, 402, 317, 14, 87, 178, 88, 95,
]

# Left eye contour — subject's LEFT eye (appears on RIGHT side of a mirrored frame).
# Uses the refined eyelid contour for better upper-lid accuracy.
LEFT_EYE = [
    263, 249, 390, 373, 374, 380, 381, 382, 362,  # lower lid
    398, 384, 385, 386, 387, 388, 466, 263          # upper lid
]

# Right eye contour — subject's RIGHT eye (appears on LEFT side of a mirrored frame).
RIGHT_EYE = [
    33, 7, 163, 144, 145, 153, 154, 155, 133,   # lower lid
    173, 157, 158, 159, 160, 161, 246, 33         # upper lid
]

# Left eyebrow (subject's left; screen-right in mirrored feed)
LEFT_EYEBROW = [
    276, 283, 282, 295, 285,   # upper arch
    300, 293, 334, 296, 336    # lower edge
]

# Right eyebrow (subject's right; screen-left in mirrored feed)
RIGHT_EYEBROW = [
    46, 53, 52, 65, 55,    # upper arch
    70, 63, 105, 66, 107   # lower edge
]

# Face oval — 36-point jaw + hairline contour
FACE_CONTOUR = [
    10,  338, 297, 332, 284, 251, 389, 356, 454, 323,
    361, 288, 397, 365, 379, 378, 400, 377, 152, 148,
    176, 149, 150, 136, 172, 58,  132, 93,  234, 127,
    162, 21,  54,  103, 67,  109
]

# ── Helpers ────────────────────────────────────────────────────────────────────

def extract_points(face_landmarks, indices, flip_y=True):
    """
    Extract normalised [0,1] coordinates for a list of landmark indices.

    face_landmarks : list of NormalizedLandmark from the Tasks API result
    indices        : list[int]
    flip_y         : True  → output origin bottom-left  (Swift convention)
                     False → output origin top-left     (MediaPipe native)
    """
    n = len(face_landmarks)
    result = []
    for idx in indices:
        if idx < 0 or idx >= n:
            continue
        lm = face_landmarks[idx]
        y = (1.0 - lm.y) if flip_y else lm.y
        result.append([round(float(lm.x), 5), round(float(y), 5)])
    return result

# ── Flask app ──────────────────────────────────────────────────────────────────
app = Flask(__name__)

@app.route("/v1/face_landmarks", methods=["POST"])
def face_landmarks_endpoint():
    # 1. Decode JPEG
    jpeg_bytes = request.get_data()
    if not jpeg_bytes:
        return jsonify({"error": "empty_body"}), 400

    nparr   = np.frombuffer(jpeg_bytes, np.uint8)
    img_bgr = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    if img_bgr is None:
        return jsonify({"error": "decode_failed"}), 400

    # 2. Convert to MediaPipe Image (RGB)
    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=img_rgb)

    # 3. Run Tasks API detector
    result = detector.detect(mp_image)

    if not result.face_landmarks:
        return jsonify({"error": "no_face"})

    # 4. Extract from the first detected face
    face = result.face_landmarks[0]   # list of NormalizedLandmark

    response = {
        "outerLips":    extract_points(face, OUTER_LIPS),
        "innerLips":    extract_points(face, INNER_LIPS),
        "leftEye":      extract_points(face, LEFT_EYE),
        "rightEye":     extract_points(face, RIGHT_EYE),
        "leftEyebrow":  extract_points(face, LEFT_EYEBROW),
        "rightEyebrow": extract_points(face, RIGHT_EYEBROW),
        "faceContour":  extract_points(face, FACE_CONTOUR),
    }

    return jsonify(response)


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


# ── Entry point ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("MediaPipe Face Landmarker helper running on http://127.0.0.1:9001")
    print("  POST /v1/face_landmarks  — send JPEG, get landmark JSON")
    print("  GET  /health             — liveness check")
    app.run(host="127.0.0.1", port=9001, threaded=False)
