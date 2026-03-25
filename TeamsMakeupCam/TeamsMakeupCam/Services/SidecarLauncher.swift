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
            print("SidecarLauncher: launched pid=\(proc.processIdentifier)")
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
