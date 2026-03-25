import Foundation
import AppKit

final class SidecarLauncher {
    static let shared = SidecarLauncher()

    private var process: Process?
    private let port = 9001

    private init() {}

    func start() {
        guard process == nil else {
            print("SidecarLauncher: already started.")
            return
        }

        if isPortInUse(port) {
            print("SidecarLauncher: port \(port) already in use — assuming helper is already running.")
            return
        }

        guard let helperURL = Bundle.main.url(forResource: "mediapipe_helper", withExtension: nil) else {
            print("SidecarLauncher: bundled mediapipe_helper not found.")
            return
        }

        let proc = Process()
        proc.executableURL = helperURL
        proc.currentDirectoryURL = helperURL.deletingLastPathComponent()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                print("[sidecar] \(text)", terminator: "")
            }
        }

        proc.terminationHandler = { [weak self] p in
            print("SidecarLauncher: sidecar exited with status \(p.terminationStatus)")
            self?.process = nil
        }

        do {
            try proc.run()
            process = proc
<<<<<<< HEAD
            print("SidecarLauncher: launched pid=\(proc.processIdentifier)")
=======
            print("SidecarLauncher: ✅ launched pid=\(proc.processIdentifier)")

            // PyInstaller --onefile binaries decompress themselves on first run (120 MB),
            // which can take 15–30 s. Give the server generous time to come up.
            waitForServerStartup(timeout: 30.0) { [weak self] started in
                guard let self else { return }
                if started {
                    print("SidecarLauncher: ✅ helper is listening on port \(self.port)")
                } else {
                    print("SidecarLauncher: ❌ helper did not start listening on port \(self.port) within timeout")
                    if let proc = self.process, proc.isRunning {
                        print("SidecarLauncher: process is still running but server is not reachable yet")
                    } else {
                        print("SidecarLauncher: process is no longer running")
                    }
                }
            }
>>>>>>> 980b9c8 (Fix automatic sidecar launch so app works without Terminal)
        } catch {
            print("SidecarLauncher: failed to launch helper: \(error)")
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
    }

    @objc private func appWillTerminate() {
        stop()
    }

<<<<<<< HEAD
=======
    // MARK: - Launch config

    private struct LaunchConfig {
        let executable: URL
        let workingDirectory: URL
        let arguments: [String]
    }

    private func findSidecar() -> LaunchConfig? {

        // ── 1. Bundled binary inside the .app (Release distribution) ──────────
        //       Build: PyInstaller --onefile → place binary at
        //              YourApp.app/Contents/MacOS/mediapipe_helper
        let macOSDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
        let bundledBinary = macOSDir.appendingPathComponent("mediapipe_helper")

        if FileManager.default.fileExists(atPath: bundledBinary.path) {
            print("SidecarLauncher: found bundled binary at \(bundledBinary.path)")
            return LaunchConfig(
                executable: bundledBinary,
                workingDirectory: macOSDir,
                arguments: []
            )
        }

        // ── 2. Dev binary (PyInstaller output in local dev folder) ─────────────
        //       ~/mediapipe-helper/dist/mediapipe_helper
        let devDist = home("mediapipe-helper/dist/mediapipe_helper")
        if FileManager.default.fileExists(atPath: devDist.path) {
            print("SidecarLauncher: found dev binary at \(devDist.path)")
            return LaunchConfig(
                executable: devDist,
                workingDirectory: devDist.deletingLastPathComponent(),
                arguments: []
            )
        }

        // ── 3. Dev Python script (no build needed, requires python3 + deps) ────
        let devRoot = home("mediapipe-helper")
        let pyScript = devRoot.appendingPathComponent("mediapipe_helper.py")
        let model    = devRoot.appendingPathComponent("face_landmarker.task")
        let python3  = URL(fileURLWithPath: python3Path)

        if FileManager.default.fileExists(atPath: pyScript.path),
           FileManager.default.fileExists(atPath: model.path),
           FileManager.default.fileExists(atPath: python3.path) {

            print("SidecarLauncher: found dev script at \(pyScript.path)")
            return LaunchConfig(
                executable: python3,
                workingDirectory: devRoot,
                arguments: [pyScript.path]
            )
        }

        return nil
    }

    private func home(_ relativePath: String) -> URL {
        // NSHomeDirectory() returns the sandbox container in sandboxed apps,
        // NOT the real user home (/Users/username). Use getpwuid to get the
        // actual home directory regardless of sandbox state.
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = String(validatingUTF8: pw.pointee.pw_dir) {
            realHome = dir
        } else {
            realHome = "/Users/\(NSUserName())"
        }
        return URL(fileURLWithPath: realHome).appendingPathComponent(relativePath)
    }

    // MARK: - Startup wait

    private func waitForServerStartup(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if isPortInUse(port) {
                completion(true)
                return
            }

            if Date() >= deadline {
                completion(false)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                poll()
            }
        }

        DispatchQueue.global().async {
            poll()
        }
    }

    // MARK: - Port check

>>>>>>> 980b9c8 (Fix automatic sidecar launch so app works without Terminal)
    private func isPortInUse(_ port: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-i", ":\(port)", "-sTCP:LISTEN", "-t"]

        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return !data.isEmpty
        } catch {
            return false
        }
    }
}
