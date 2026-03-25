# mediapipe_helper.spec
# ─────────────────────────────────────────────────────────────────────────────
# PyInstaller spec for building a standalone macOS binary of mediapipe_helper.
#
# Usage (run from inside the mediapipe_helper/ directory):
#
#   pip install pyinstaller
#   pyinstaller mediapipe_helper.spec
#
# Output binary: dist/mediapipe_helper
# ─────────────────────────────────────────────────────────────────────────────

import os
import sys

# Locate the installed mediapipe package so we can collect its data files
# (native extensions, protobuf descriptors, etc.)
try:
    import mediapipe as _mp
    _mp_pkg_dir = os.path.dirname(_mp.__file__)
except ImportError:
    raise SystemExit("mediapipe is not installed in the active Python environment.\n"
                     "Run:  pip install mediapipe flask opencv-python")

block_cipher = None

a = Analysis(
    ["mediapipe_helper.py"],
    pathex=["."],
    binaries=[],
    datas=[
        # Bundle the face landmarker model next to the script
        ("face_landmarker.task", "."),
        # Include all mediapipe data files (models, graphs, etc.)
        (_mp_pkg_dir, "mediapipe"),
    ],
    hiddenimports=[
        "mediapipe",
        "mediapipe.python",
        "mediapipe.python._framework_bindings",
        "mediapipe.tasks",
        "mediapipe.tasks.python",
        "mediapipe.tasks.python.core",
        "mediapipe.tasks.python.vision",
        "mediapipe.tasks.python.components",
        "mediapipe.tasks.python.components.containers",
        "google.protobuf",
        "google.protobuf.descriptor",
        "google.protobuf.descriptor_pool",
        "google.protobuf.message_factory",
        "flask",
        "flask.json",
        "cv2",
        "numpy",
    ],
    hookspath=[],
    runtime_hooks=[],
    excludes=[
        # Trim unused heavy packages to keep binary smaller
        "matplotlib",
        "pandas",
        "scipy",
        "sklearn",
        "IPython",
        "PIL",
        "tensorflow",
        "torch",
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="mediapipe_helper",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,          # UPX can break native extensions; keep off
    console=True,       # Keep stdout/stderr visible for SidecarLauncher logs
    disable_windowed_traceback=False,
    target_arch=None,   # Use None to match the host arch (arm64 on Apple Silicon)
    codesign_identity=None,
    entitlements_file=None,
    onefile=True,
)
