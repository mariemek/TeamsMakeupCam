import Foundation
import AppKit

/// Launches the MediaPipe helper sidecar on app startup and stops it on quit.
///
/// Lookup order:
///   1. Bundled binary:  YourApp.app/Contents/MacOS/mediapipe_helper
///      with model at:   YourApp.app/Contents/Resources/face_landmarker.task
///   2. Dev binary:      ~/mediapipe-helper/dist/mediapipe_helper
///      with model at:   ~/mediapipe-helper/face_landmarker.task
///   3. Dev script:      ~/mediapipe-helper/mediapipe_helper.py via python3
final class SidecarLauncher {

    static let shared = SidecarLauncher()

    private var process: Process?
    private let port = 9001

    // Change this if your python3 is elsewhere.
    private let python3Path = "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"

    private init() {}

    // MARK: - Public

    func start() {
        guard process == nil else {
            print("SidecarLauncher: already started.")
            return
        }

        if isPortInUse(port) {
            print("SidecarLauncher: port \(port) already in use — assuming helper is already running.")
            return
        }

        guard let launchConfig = findSidecar() else {
            print("SidecarLauncher: ⚠️ mediapipe_helper not found.")
            print("SidecarLauncher: expected one of:")
            print("  - bundled app executable in Contents/MacOS/mediapipe_helper")
            print("  - dev binary at ~/mediapipe-helper/dist/mediapipe_helper")
            print("  - dev script at ~/mediapipe-helper/mediapipe_helper.py")
            return
        }

        print("SidecarLauncher: launching executable=\(launchConfig.executable.path)")
        print("SidecarLauncher: workingDir=\(launchConfig.workingDirectory.path)")
        print("SidecarLauncher: args=\(launchConfig.arguments)")

        let proc = Process()
        proc.executableURL = launchConfig.executable
        proc.arguments = launchConfig.arguments
        proc.currentDirectoryURL = launchConfig.workingDirectory

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

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
            print("SidecarLauncher: ✅ launched pid=\(proc.processIdentifier)")

            waitForServerStartup(timeout: 5.0) { [weak self] started in
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

    @objc private func appWillTerminate() {
        stop()
    }

    // MARK: - Launch config

    private struct LaunchConfig {
        let executable: URL
        let workingDirectory: URL
        let arguments: [String]
    }

    private func findSidecar() -> LaunchConfig? {
        let devRoot = home("mediapipe-helper")

        let pyScript = devRoot.appendingPathComponent("mediapipe_helper.py")
        let model = devRoot.appendingPathComponent("face_landmarker.task")
        let python3 = URL(fileURLWithPath: python3Path)

        print("SidecarLauncher: forcing python mode")
        print("Script:", pyScript.path)
        print("Model:", model.path)

        if FileManager.default.fileExists(atPath: pyScript.path),
           FileManager.default.fileExists(atPath: model.path),
           FileManager.default.fileExists(atPath: python3.path) {

            return LaunchConfig(
                executable: python3,
                workingDirectory: devRoot,
                arguments: [pyScript.path]
            )
        }

        return nil
    }

    private func home(_ relativePath: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)
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
