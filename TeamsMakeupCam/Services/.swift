import Foundation

final class MediaPipeHelperProcessManager: ObservableObject {
    private var process: Process?

    func startIfNeeded() {
        guard process == nil || process?.isRunning == false else { return }

        guard let helperURL = Bundle.main.url(forResource: "mediapipe_helper", withExtension: nil) else {
            print("❌ Could not find bundled mediapipe_helper in app bundle")
            return
        }

        let process = Process()
        process.executableURL = helperURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            self.process = process
            print("✅ mediapipe_helper started at \(helperURL.path)")
        } catch {
            print("❌ Failed to start mediapipe_helper: \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    deinit {
        stop()
    }
}//
//  MediaPipeHelperProcessManager.swift
//  TeamsMakeupCam
//
//  Created by ideas on 2026-03-21.
//

