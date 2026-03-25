#!/usr/bin/env bash
# =============================================================================
# build_sidecar.sh
# =============================================================================
# Builds the mediapipe_helper standalone binary with PyInstaller and copies
# it into the Xcode-built .app bundle so the app can launch it automatically.
#
# Usage:
#   chmod +x scripts/build_sidecar.sh
#   ./scripts/build_sidecar.sh
#
# Optional: pass the path to your .app bundle as the first argument:
#   ./scripts/build_sidecar.sh "/path/to/TeamsMakeupCam.app"
#
# If no argument is supplied the script searches DerivedData automatically.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_DIR="$REPO_ROOT/mediapipe_helper"
BINARY_NAME="mediapipe_helper"

# ── 1. Make sure we're running inside the virtual environment ─────────────────
VENV="$REPO_ROOT/venv"
if [ ! -f "$VENV/bin/python3" ]; then
    echo "❌  venv not found at $VENV"
    echo "    Create it with:  python3 -m venv venv && source venv/bin/activate"
    echo "    Then install:    pip install mediapipe flask opencv-python pyinstaller"
    exit 1
fi

PYTHON="$VENV/bin/python3"
PIP="$VENV/bin/pip"

# ── 2. Install PyInstaller if missing ─────────────────────────────────────────
if ! "$VENV/bin/pyinstaller" --version &>/dev/null 2>&1; then
    echo "📦  Installing PyInstaller…"
    "$PIP" install --quiet pyinstaller
fi

# ── 3. Build the binary ───────────────────────────────────────────────────────
echo "🔨  Building $BINARY_NAME with PyInstaller…"
cd "$HELPER_DIR"
"$VENV/bin/pyinstaller" mediapipe_helper.spec --noconfirm

BUILT_BINARY="$HELPER_DIR/dist/$BINARY_NAME"
if [ ! -f "$BUILT_BINARY" ]; then
    echo "❌  Build failed — binary not found at $BUILT_BINARY"
    exit 1
fi
echo "✅  Binary built: $BUILT_BINARY"

# ── 4. Locate the .app bundle ─────────────────────────────────────────────────
if [ -n "${1:-}" ]; then
    APP_BUNDLE="$1"
else
    # Search DerivedData for the most recently built Release app
    APP_BUNDLE=$(find ~/Library/Developer/Xcode/DerivedData \
        -name "TeamsMakeupCam.app" \
        -path "*/Release/*" \
        2>/dev/null | sort -t/ -k1,1 | tail -n1 || true)
fi

if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    echo ""
    echo "⚠️   Could not find TeamsMakeupCam.app automatically."
    echo "    Build the app first in Xcode (Product → Archive or Build), then run:"
    echo "    $0 \"/path/to/TeamsMakeupCam.app\""
    echo ""
    echo "    The binary is ready at:"
    echo "    $BUILT_BINARY"
    echo ""
    echo "    Copy it manually with:"
    echo "    cp \"$BUILT_BINARY\" \"/path/to/TeamsMakeupCam.app/Contents/MacOS/$BINARY_NAME\""
    echo "    chmod +x \"/path/to/TeamsMakeupCam.app/Contents/MacOS/$BINARY_NAME\""
    exit 0
fi

# ── 5. Copy binary into the bundle ────────────────────────────────────────────
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
DEST="$MACOS_DIR/$BINARY_NAME"

echo "📋  Copying to $DEST"
cp "$BUILT_BINARY" "$DEST"
chmod +x "$DEST"

echo ""
echo "✅  Done!  $BINARY_NAME is bundled inside:"
echo "    $APP_BUNDLE"
echo ""
echo "You can now open the app and the Python helper will start automatically."
