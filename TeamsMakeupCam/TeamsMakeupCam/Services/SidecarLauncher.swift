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
            print("SidecarLauncher: ✅ launched pid=\(proc.processIdentifier)")

            // PyInstaller --onefile binaries decompress on first run (can take 15–30 s).
            // Poll until the server is actually listening before declaring success.
            waitForServerStartup(timeout: 30.0) { [weak self] started in
                guard let self else { return }
                if started {
                    print("SidecarLauncher: ✅ helper is listening on port \(self.port)")
                } else {
                    print("SidecarLauncher: ❌ helper did not start on port \(self.port) within timeout")
                    if let proc = self.process, proc.isRunning {
                        print("SidecarLauncher: process still running but server not reachable yet")
                    } else {
                        print("SidecarLauncher: process is no longer running")
                    }
                }
            }
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
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                poll()
            }
        }

        DispatchQueue.global().async { poll() }
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
