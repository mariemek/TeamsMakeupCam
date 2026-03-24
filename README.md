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

#### 🧑‍💻 Run from Source (Developers)
1. Clone the repo
git clone https://github.com/mariemek/TeamsMakeupCam.git
cd TeamsMakeupCam/TeamsMakeupCam
2. Open in Xcode
open TeamsMakeupCam.xcodeproj
3. Run
Select My Mac
Click ▶️ Run
⚙️ Requirements
macOS
Xcode (for development)
Camera access enabled
📸 Permissions

Make sure camera access is enabled:

System Settings → Privacy & Security → Camera

🚀 Future Improvements
App signing + notarization
Remove Python dependency
Improved filter realism
Better UI/UX
