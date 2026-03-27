#!/usr/bin/env python3
"""
mediapipe_helper.py
────────────────────────────────────────────────────────────
Localhost Face Landmarker helper using the MediaPipe Tasks API.

POST /v1/face_landmarks
  Content-Type: image/jpeg
  Body: raw JPEG bytes

Response:
  {
    "outerLips": [[x, y], ...],
    "innerLips": [[x, y], ...],
    "leftEye": [[x, y], ...],
    "rightEye": [[x, y], ...],
    "leftUpperEyelidRaw": [[x, y], ...],
    "rightUpperEyelidRaw": [[x, y], ...],
    "faceContour": [[x, y], ...],
    "leftCheekPoint": [x, y],
    "rightCheekPoint": [x, y],
    "roll": 0.0,
    "yaw": 0.0,
    "pitch": 0.0
  }

Coordinate convention:
  MediaPipe returns x,y normalized to [0,1] with origin TOP-LEFT.
  We flip y so Swift renderers receive bottom-left origin.
"""

import sys
import os
import math
import numpy as np
import cv2
from flask import Flask, request, jsonify

try:
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision as mp_vision
except ImportError:
    print("ERROR: mediapipe not installed. Run: pip install mediapipe flask opencv-python")
    sys.exit(1)

if getattr(sys, "frozen", False):
    _base = sys._MEIPASS  # type: ignore[attr-defined]
else:
    _base = os.path.dirname(os.path.abspath(__file__))

MODEL_PATH = os.path.join(_base, "face_landmarker.task")
if not os.path.exists(MODEL_PATH):
    print(f"ERROR: Model file not found at: {MODEL_PATH}")
    sys.exit(1)

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

OUTER_LIPS = [
    61, 185, 40, 39, 37, 0, 267, 269, 270, 409,
    291, 375, 321, 405, 314, 17, 84, 181, 91, 146,
]

INNER_LIPS = [
    78, 191, 80, 81, 82, 13, 312, 311, 310, 415,
    308, 324, 318, 402, 317, 14, 87, 178, 88, 95,
]

LEFT_EYE = [
    263, 249, 390, 373, 374, 380, 381, 382, 362,
    398, 384, 385, 386, 387, 388, 466, 263
]

RIGHT_EYE = [
    33, 7, 163, 144, 145, 153, 154, 155, 133,
    173, 157, 158, 159, 160, 161, 246, 33
]

LEFT_UPPER_EYELID = [263, 466, 388, 387, 386, 385, 384, 398, 362]
RIGHT_UPPER_EYELID = [33, 246, 161, 160, 159, 158, 157, 173, 133]

FACE_CONTOUR = [
    10, 338, 297, 332, 284, 251, 389, 356, 454, 323,
    361, 288, 397, 365, 379, 378, 400, 377, 152, 148,
    176, 149, 150, 136, 172, 58, 132, 93, 234, 127,
    162, 21, 54, 103, 67, 109
]

# Canonical mesh cheek anchors used in many virtual makeup examples.
LEFT_CHEEK_CENTER = 425
RIGHT_CHEEK_CENTER = 205

# Optional extra cheek contour support if you want it later.
LEFT_CHEEK_RING = [280, 352, 346, 347, 348, 349, 350, 357, 425]
RIGHT_CHEEK_RING = [50, 123, 117, 118, 119, 120, 121, 128, 205]


def extract_points(face_landmarks, indices, flip_y=True):
    n = len(face_landmarks)
    result = []
    for idx in indices:
        if idx < 0 or idx >= n:
            continue
        lm = face_landmarks[idx]
        y = (1.0 - lm.y) if flip_y else lm.y
        result.append([round(float(lm.x), 5), round(float(y), 5)])
    return result


def extract_point(face_landmarks, index, flip_y=True):
    n = len(face_landmarks)
    if index < 0 or index >= n:
        return None
    lm = face_landmarks[index]
    y = (1.0 - lm.y) if flip_y else lm.y
    return [round(float(lm.x), 5), round(float(y), 5)]


def estimate_head_pose(face_landmarks):
    # Lightweight approximation from landmark geometry.
    # Good enough for renderer tilt, even if not full 3D pose.
    left_eye_outer = face_landmarks[263]
    right_eye_outer = face_landmarks[33]
    nose_tip = face_landmarks[1]
    chin = face_landmarks[152]

    dx = left_eye_outer.x - right_eye_outer.x
    dy = left_eye_outer.y - right_eye_outer.y
    roll = math.degrees(math.atan2(dy, dx))

    eye_mid_x = (left_eye_outer.x + right_eye_outer.x) * 0.5
    eye_mid_y = (left_eye_outer.y + right_eye_outer.y) * 0.5

    yaw = (nose_tip.x - eye_mid_x) * 120.0
    pitch = ((chin.y - nose_tip.y) - (nose_tip.y - eye_mid_y)) * 120.0

    return {
        "roll": round(float(roll), 4),
        "yaw": round(float(yaw), 4),
        "pitch": round(float(pitch), 4),
    }


app = Flask(__name__)


@app.route("/v1/face_landmarks", methods=["POST"])
def face_landmarks_endpoint():
    jpeg_bytes = request.get_data()
    if not jpeg_bytes:
        return jsonify({"error": "empty_body"}), 400

    nparr = np.frombuffer(jpeg_bytes, np.uint8)
    img_bgr = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    if img_bgr is None:
        return jsonify({"error": "decode_failed"}), 400

    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=img_rgb)

    result = detector.detect(mp_image)

    if not result.face_landmarks:
        return jsonify({"error": "no_face"})

    face = result.face_landmarks[0]
    pose = estimate_head_pose(face)

    response = {
        "outerLips": extract_points(face, OUTER_LIPS),
        "innerLips": extract_points(face, INNER_LIPS),
        "leftEye": extract_points(face, LEFT_EYE),
        "rightEye": extract_points(face, RIGHT_EYE),
        "leftUpperEyelidRaw": extract_points(face, LEFT_UPPER_EYELID),
        "rightUpperEyelidRaw": extract_points(face, RIGHT_UPPER_EYELID),
        "faceContour": extract_points(face, FACE_CONTOUR),
        "leftCheekPoint": extract_point(face, LEFT_CHEEK_CENTER),
        "rightCheekPoint": extract_point(face, RIGHT_CHEEK_CENTER),
        "roll": pose["roll"],
        "yaw": pose["yaw"],
        "pitch": pose["pitch"],
    }

    return jsonify(response)


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    print("MediaPipe Face Landmarker helper running on http://127.0.0.1:9001")
    print("  POST /v1/face_landmarks  — send JPEG, get landmark JSON")
    print("  GET  /health             — liveness check")
    app.run(host="127.0.0.1", port=9001, threaded=False)
