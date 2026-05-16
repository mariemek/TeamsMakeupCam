import Foundation
import AppKit

final class SidecarLauncher {
    static let shared = SidecarLauncher()

    private var process: Process?
    private let port = 9001
    private let startLock = NSLock()

    private lazy var healthURL = URL(string: "http://127.0.0.1:\(port)/health")!

    private init() {}

    func start() {
        startLock.lock()
        defer { startLock.unlock() }

        if isHealthy(timeout: 0.5) {
            print("SidecarLauncher: helper already healthy on port \(port)")
            installTerminationObserver()
            return
        }

        if let process, process.isRunning {
            print("SidecarLauncher: process already running, waiting for health.")
            waitForHealthyStartup(timeout: 30.0) { started in
                print(started
                    ? "SidecarLauncher: ✅ helper became healthy"
                    : "SidecarLauncher: ❌ helper still not healthy")
            }
            installTerminationObserver()
            return
        }

        let resourcesURL = Bundle.main.resourceURL
        let taskPath = resourcesURL?.appendingPathComponent("face_landmarker.task").path

        let candidates = helperLaunchCandidates()

        guard !candidates.isEmpty else {
            print("SidecarLauncher: no helper launch candidates found in app bundle.")
            return
        }

        for candidate in candidates {
            if launch(candidate: candidate, taskPath: taskPath) {
                installTerminationObserver()
                return
            }
        }

        print("SidecarLauncher: failed to launch any helper candidate.")
    }

    func stop() {
        startLock.lock()
        defer { startLock.unlock() }

        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
    }

    func waitUntilHealthy(timeout: TimeInterval) -> Bool {
        if isHealthy(timeout: 0.5) { return true }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isHealthy(timeout: 0.5) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    @objc private func appWillTerminate() {
        stop()
    }

    // MARK: - Launch

    private enum HelperCandidate {
        case executable(URL)
        case pythonScript(python: URL, script: URL)
    }

    private func helperLaunchCandidates() -> [HelperCandidate] {
        var result: [HelperCandidate] = []

        if let bundledExec = Bundle.main.url(forAuxiliaryExecutable: "mediapipe_helper") {
            result.append(.executable(bundledExec))
        }

        if let resourcesURL = Bundle.main.resourceURL {
            let distExec = resourcesURL.appendingPathComponent("dist/mediapipe_helper")
            if FileManager.default.fileExists(atPath: distExec.path) {
                result.append(.executable(distExec))
            }

            let script = resourcesURL.appendingPathComponent("mediapipe_helper.py")
            let python = URL(fileURLWithPath: "/usr/bin/python3")
            if FileManager.default.fileExists(atPath: script.path),
               FileManager.default.fileExists(atPath: python.path) {
                result.append(.pythonScript(python: python, script: script))
            }
        }

        return result
    }

    private func launch(candidate: HelperCandidate, taskPath: String?) -> Bool {
        let proc = Process()

        switch candidate {
        case .executable(let url):
            proc.executableURL = url
            proc.currentDirectoryURL = url.deletingLastPathComponent()
            print("SidecarLauncher: trying bundled helper \(url.path)")
        case .pythonScript(let python, let script):
            proc.executableURL = python
            proc.arguments = [script.path]
            proc.currentDirectoryURL = script.deletingLastPathComponent()
            print("SidecarLauncher: trying python helper \(script.path)")
        }

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["TEAMSMAKEUPCAM_PORT"] = "\(port)"
        if let taskPath {
            env["TEAMSMAKEUPCAM_TASK_PATH"] = taskPath
        }
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
            if self?.process === p {
                self?.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
            print("SidecarLauncher: ✅ launched pid=\(proc.processIdentifier)")
        } catch {
            print("SidecarLauncher: failed to launch helper: \(error)")
            return false
        }

        let started = waitUntilHealthy(timeout: 90.0)
        if started {
            print("SidecarLauncher: ✅ helper is healthy on port \(port)")
            return true
        }

        print("SidecarLauncher: helper did not become healthy after launch attempt")
        if proc.isRunning {
            proc.terminate()
        }
        if process === proc {
            process = nil
        }
        return false
    }

    // MARK: - Health

    private func waitForHealthyStartup(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(self.waitUntilHealthy(timeout: timeout))
        }
    }

    private func isHealthy(timeout: TimeInterval) -> Bool {
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var ok = false

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                ok = true
            }
            semaphore.signal()
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.2)
        return ok
    }

    private func installTerminationObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }
}
