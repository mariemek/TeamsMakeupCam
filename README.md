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
