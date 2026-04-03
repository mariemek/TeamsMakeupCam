import Foundation

/// Writes composited JPEG frames to the App Group shared container
/// so the Camera Extension (running as a separate process) can read them.
///
/// Files written:
///   <AppGroupContainer>/CameraFrame/latest.jpg   — current frame JPEG
///   <AppGroupContainer>/CameraFrame/counter       — monotonic uint64 counter
final class SharedFrameWriter {

    static let shared = SharedFrameWriter()

    /// Must match SharedFrameReader.appGroupID in the extension.
    private static let appGroupID = "group.com.teamsmakeupcam.shared"

    private let frameDir: URL?
    private var counter: UInt64 = 0

    private init() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            NSLog("SharedFrameWriter: App Group container not available.")
            frameDir = nil
            return
        }

        let dir = container.appendingPathComponent("CameraFrame")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        frameDir = dir
    }

    /// Write a JPEG frame to the shared container for the extension to pick up.
    func writeFrame(_ jpegData: Data) {
        guard let dir = frameDir else { return }

        let jpegURL = dir.appendingPathComponent("latest.jpg")
        let counterURL = dir.appendingPathComponent("counter")

        // Write JPEG atomically (temp file + rename) to avoid torn reads
        try? jpegData.write(to: jpegURL, options: .atomic)

        // Update counter
        counter += 1
        var value = counter
        let counterData = Data(bytes: &value, count: MemoryLayout<UInt64>.size)
        try? counterData.write(to: counterURL, options: .atomic)
    }
}
