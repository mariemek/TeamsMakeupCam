import Foundation
import AppKit

/// Automatically launches the MediaPipe helper sidecar process when the app starts
/// and terminates it when the app quits.
///
/// Lookup order:
///   1. Bundled binary:  YourApp.app/Contents/MacOS/mediapipe_helper
///   2. Dev binary:      ~/mediapipe-helper/dist/mediapipe_helper
///   3. Dev script:      ~/mediapipe-helper/mediapipe_helper.py via python3
final class SidecarLauncher {

    static let shared = SidecarLauncher()

    private var process: Process?
    private let port = 9001

    // Full path to python3 — avoids PATH lookup failures when launched from GUI.
    // Find yours by running `which python3` in Terminal.
    private let python3Path = "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"

    private init() {}

    // MARK: - Public

    func start() {
        guard !isPortInUse(port) else {
            print("SidecarLauncher: port \(port) already in use — skipping.")
            return
        }

        guard let (binary, workingDir, args) = findSidecar() else {
            print("SidecarLauncher: ⚠️ mediapipe_helper not found.")
            print("  Run manually: cd ~/mediapipe-helper && python3 mediapipe_helper.py")
            return
        }

        let proc = Process()
        proc.executableURL       = binary
        proc.arguments           = args
        proc.currentDirectoryURL = workingDir

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                print("[sidecar] \(str)", terminator: "")
            }
        }

        proc.terminationHandler = { [weak self] p in
            print("SidecarLauncher: sidecar exited (status \(p.terminationStatus))")
            self?.process = nil
        }

        do {
            try proc.run()
            self.process = proc
            print("SidecarLauncher: ✅ started (pid \(proc.processIdentifier)) workdir=\(workingDir.path)")
        } catch {
            print("SidecarLauncher: ❌ launch failed: \(error)")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
        print("SidecarLauncher: stopped.")
    }

    @objc private func appWillTerminate() { stop() }

    // MARK: - Find sidecar
    // Returns (executable, workingDirectory, arguments)

    private func findSidecar() -> (URL, URL, [String])? {

        // 1. Bundled binary inside .app — Contents/MacOS/mediapipe_helper
        if let binary = Bundle.main.url(forAuxiliaryExecutable: "mediapipe_helper"),
           FileManager.default.isExecutableFile(atPath: binary.path),
           let resourceDir = Bundle.main.resourceURL {
            print("SidecarLauncher: using bundled binary")
            return (binary, resourceDir, [])
        }

        // 2. Dev pre-built binary — ~/mediapipe-helper/dist/mediapipe_helper
        let devBinary = home("mediapipe-helper/dist/mediapipe_helper")
        if FileManager.default.isExecutableFile(atPath: devBinary.path) {
            print("SidecarLauncher: using dev binary at \(devBinary.path)")
            return (devBinary, home("mediapipe-helper"), [])
        }

        // 3. Dev script — run directly with python3 (no wrapper script needed)
        let pyScript = home("mediapipe-helper/mediapipe_helper.py")
        let python3  = URL(fileURLWithPath: python3Path)
        if FileManager.default.fileExists(atPath: pyScript.path),
           FileManager.default.fileExists(atPath: python3.path) {
            print("SidecarLauncher: using python3 script at \(pyScript.path)")
            // Pass script path as argument to python3 directly — no shell wrapper needed
            return (python3, home("mediapipe-helper"), [pyScript.path])
        }

        return nil
    }

    private func home(_ relative: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative)
    }

    // MARK: - Port check

    private func isPortInUse(_ port: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments     = ["-i", ":\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return !out.fileHandleForReading.readDataToEndOfFile().isEmpty
        } catch {
            return false
        }
    }
}
