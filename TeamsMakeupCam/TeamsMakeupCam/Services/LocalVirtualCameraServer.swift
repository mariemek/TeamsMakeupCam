import Foundation
import Network

/// Minimal HTTP server on port 9010 that exposes composited camera frames.
///
/// Endpoints:
///   GET /stream      → MJPEG stream (multipart/x-mixed-replace)
///   GET /latest.jpg  → single JPEG snapshot
///   GET /             → simple status page
///
/// No external dependencies — uses Apple's Network framework (`NWListener`).
final class LocalVirtualCameraServer {

    static let shared = LocalVirtualCameraServer()

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "VirtualCameraServer.queue")

    /// Active MJPEG streaming connections.
    private var mjpegClients: [ObjectIdentifier: NWConnection] = [:]
    private let clientLock = NSLock()

    /// Observation token for new-frame notifications.
    private var frameObserver: NSObjectProtocol?

    private let port: UInt16 = 9010
    private let boundary = "frame"

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else {
            print("VirtualCameraServer: already running on port \(port)")
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("VirtualCameraServer: invalid port \(port)")
            return
        }

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            print("VirtualCameraServer: failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("VirtualCameraServer: listening on http://127.0.0.1:\(self.port)/stream")
            case .failed(let error):
                print("VirtualCameraServer: listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: serverQueue)

        // Subscribe to new frames and push to MJPEG clients.
        frameObserver = NotificationCenter.default.addObserver(
            forName: SharedFrameProvider.newFrameNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let jpeg = notification.object as? Data else { return }
            self?.pushMJPEGFrame(jpeg)
        }

        print("VirtualCameraServer: starting on port \(port)")
    }

    func stop() {
        if let obs = frameObserver {
            NotificationCenter.default.removeObserver(obs)
            frameObserver = nil
        }

        clientLock.lock()
        for (_, conn) in mjpegClients {
            conn.cancel()
        }
        mjpegClients.removeAll()
        clientLock.unlock()

        listener?.cancel()
        listener = nil
        print("VirtualCameraServer: stopped")
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)

        // Read the HTTP request (first chunk is enough).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            if request.hasPrefix("GET /stream") {
                self.startMJPEGStream(connection)
            } else if request.hasPrefix("GET /latest.jpg") || request.hasPrefix("GET /latest") {
                self.serveLatestJPEG(connection)
            } else {
                self.serveStatusPage(connection)
            }
        }
    }

    // MARK: - Single JPEG

    private func serveLatestJPEG(_ connection: NWConnection) {
        guard let jpeg = SharedFrameProvider.shared.latestJPEG else {
            let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n"
            sendAndClose(connection, data: Data(response.utf8))
            return
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: image/jpeg\r\n"
        header += "Content-Length: \(jpeg.count)\r\n"
        header += "Cache-Control: no-cache, no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var payload = Data(header.utf8)
        payload.append(jpeg)

        sendAndClose(connection, data: payload)
    }

    // MARK: - MJPEG stream

    private func startMJPEGStream(_ connection: NWConnection) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n"
        header += "Cache-Control: no-cache, no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: keep-alive\r\n"
        header += "\r\n"

        let headerData = Data(header.utf8)
        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }

            let id = ObjectIdentifier(connection)
            self.clientLock.lock()
            self.mjpegClients[id] = connection
            self.clientLock.unlock()
            print("VirtualCameraServer: MJPEG client connected (\(self.mjpegClients.count) total)")

            // Monitor for disconnection.
            self.monitorDisconnection(connection, id: id)

            // Send the current frame immediately so client doesn't stare at blank.
            if let jpeg = SharedFrameProvider.shared.latestJPEG {
                self.sendMJPEGPart(to: connection, jpeg: jpeg, id: id)
            }
        })
    }

    /// Push a new JPEG frame to all connected MJPEG clients.
    private func pushMJPEGFrame(_ jpeg: Data) {
        clientLock.lock()
        let clients = mjpegClients
        clientLock.unlock()

        for (id, conn) in clients {
            sendMJPEGPart(to: conn, jpeg: jpeg, id: id)
        }
    }

    private func sendMJPEGPart(to connection: NWConnection, jpeg: Data, id: ObjectIdentifier) {
        var part = "--\(boundary)\r\n"
        part += "Content-Type: image/jpeg\r\n"
        part += "Content-Length: \(jpeg.count)\r\n"
        part += "\r\n"

        var payload = Data(part.utf8)
        payload.append(jpeg)
        payload.append(Data("\r\n".utf8))

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.removeClient(id: id)
                connection.cancel()
            }
        })
    }

    private func monitorDisconnection(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.viabilityUpdateHandler = { [weak self] viable in
            if !viable {
                self?.removeClient(id: id)
                connection.cancel()
            }
        }
    }

    private func removeClient(id: ObjectIdentifier) {
        clientLock.lock()
        mjpegClients.removeValue(forKey: id)
        let remaining = mjpegClients.count
        clientLock.unlock()
        print("VirtualCameraServer: MJPEG client disconnected (\(remaining) remaining)")
    }

    // MARK: - Status page

    private func serveStatusPage(_ connection: NWConnection) {
        let hasFrame = SharedFrameProvider.shared.latestJPEG != nil
        let frameNum = SharedFrameProvider.shared.frameNumber

        clientLock.lock()
        let clientCount = mjpegClients.count
        clientLock.unlock()

        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>TeamsMakeupCam Virtual Camera</title></head>
        <body style="background:#111;color:#eee;font-family:system-ui;padding:2em">
        <h1>TeamsMakeupCam Virtual Camera</h1>
        <p>Status: \(hasFrame ? "Streaming" : "Waiting for frames...")</p>
        <p>Frame #\(frameNum) | MJPEG clients: \(clientCount)</p>
        <h2>Endpoints</h2>
        <ul>
        <li><a href="/stream" style="color:#4af">/stream</a> — MJPEG live stream (use in OBS Browser Source)</li>
        <li><a href="/latest.jpg" style="color:#4af">/latest.jpg</a> — Latest JPEG snapshot</li>
        </ul>
        <h2>Live Preview</h2>
        <img src="/stream" style="max-width:640px;border:1px solid #333" />
        </body>
        </html>
        """

        let body = Data(html.utf8)
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/html; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var payload = Data(header.utf8)
        payload.append(body)

        sendAndClose(connection, data: payload)
    }

    // MARK: - Helpers

    private func sendAndClose(_ connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
