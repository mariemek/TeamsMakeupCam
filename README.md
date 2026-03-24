# TeamsMakeupCam 💄

A real-time virtual makeup application for macOS using face tracking.

---

## ✨ Features
- Real-time face landmark detection
- Eyeliner, lashes, lipstick filters
- Smooth tracking and rendering
- macOS native app (built with Swift + AVFoundation)

---

## 📦 Installation (Recommended)

### Download the App

1. Go to **Releases**
2. Download `TeamsMakeupCam.dmg`
3. Open the `.dmg`
4. Drag **TeamsMakeupCam.app** into **Applications**

## 1. Clone the repo
git clone https://github.com/mariemek/TeamsMakeupCam.git
cd TeamsMakeupCam
## 2. Build the app (no Xcode needed)
xcodebuild -project TeamsMakeupCam/TeamsMakeupCam.xcodeproj \
-scheme TeamsMakeupCam \
-configuration Release \
-build
## 3. Find the built app
find ~/Library/Developer/Xcode/DerivedData -path "*Release/TeamsMakeupCam.app"

Copy the path it returns.

## 4. Run the app

Replace PASTE_PATH_HERE with the path you got:

open "PASTE_PATH_HERE"
## ⚠️ First time only (macOS security)

If it gets blocked:

xattr -dr com.apple.quarantine "PASTE_PATH_HERE"
open "PASTE_PATH_HERE"
## ⚠️ IMPORTANT (your app setup)

Right now your app may still need:

mediapipe helper running
model file present

If so, users also need to run:

python3 mediapipe_helper.py

(or wherever your helper is)

## 🧠 One-line version (advanced users)
git clone https://github.com/mariemek/TeamsMakeupCam.git && cd TeamsMakeupCam && xcodebuild -project TeamsMakeupCam/TeamsMakeupCam.xcodeproj -scheme TeamsMakeupCam -configuration Release -build && open "$(find ~/Library/Developer/Xcode/DerivedData -path "*Release/TeamsMakeupCam.app" | head -n 1)"

---

### ⚠️ First Launch (Important)

macOS may block the app because it’s not signed yet.

#### Option 1 (recommended)
- Right-click the app
- Click **Open**
- Click **Open** again

#### Option 2 (Terminal fix)
Run:

```bash
xattr -dr com.apple.quarantine /Applications/TeamsMakeupCam.app

