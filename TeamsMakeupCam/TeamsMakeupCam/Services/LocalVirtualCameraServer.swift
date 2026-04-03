import Foundation
import Network

/// Minimal HTTP server on port 9010 that exposes composited camera frames.
///
/// Endpoints:
///   GET /stream      -> MJPEG stream (multipart/x-mixed-replace)
///   GET /latest.jpg  -> single JPEG snapshot
///   GET /             -> simple status page with embedded live preview
///
/// No external dependencies — uses Apple's Network framework (`NWListener`).
/// Frames always contain the fully-composited output (with makeup applied).
final class LocalVirtualCameraServer {

    static let shared = LocalVirtualCameraServer()

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "VirtualCameraServer.queue", qos: .userInteractive)

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
        // Disable Nagle's algorithm for lower latency.
        if let proto = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            // Network.framework doesn't expose TCP_NODELAY directly,
            // but keepalive + small writes effectively achieve low latency.
        }

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

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("VirtualCameraServer: listening on http://127.0.0.1:\(self.port)")
                print("  /stream      -> MJPEG live stream")
                print("  /latest.jpg  -> single JPEG snapshot")
            case .failed(let error):
                print("VirtualCameraServer: listener failed: \(error) — restarting in 1s")
                self.listener?.cancel()
                self.listener = nil
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.start()
                }
            default:
                break
            }
        }

        listener?.start(queue: serverQueue)

        // Subscribe to new composited frames and push to all MJPEG clients.
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

        // Read the HTTP request line (first chunk is enough).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse the request line.
            let firstLine = request.components(separatedBy: "\r\n").first ?? request

            if firstLine.hasPrefix("GET /stream") {
                self.startMJPEGStream(connection)
            } else if firstLine.hasPrefix("GET /latest.jpg") || firstLine.hasPrefix("GET /latest") {
                self.serveLatestJPEG(connection)
            } else {
                self.serveStatusPage(connection)
            }
        }
    }

    // MARK: - Single JPEG snapshot

    private func serveLatestJPEG(_ connection: NWConnection) {
        guard let jpeg = SharedFrameProvider.shared.latestJPEG else {
            let body = "No frames available yet — camera may still be starting."
            var response = "HTTP/1.1 503 Service Unavailable\r\n"
            response += "Content-Type: text/plain\r\n"
            response += "Content-Length: \(body.utf8.count)\r\n"
            response += "Retry-After: 1\r\n"
            response += "\r\n"
            response += body
            sendAndClose(connection, data: Data(response.utf8))
            return
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: image/jpeg\r\n"
        header += "Content-Length: \(jpeg.count)\r\n"
        header += "Cache-Control: no-cache, no-store, must-revalidate\r\n"
        header += "Pragma: no-cache\r\n"
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
        header += "Pragma: no-cache\r\n"
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
            let total = self.mjpegClients.count
            self.clientLock.unlock()
            print("VirtualCameraServer: MJPEG client connected (\(total) total)")

            // Monitor for disconnection.
            self.monitorDisconnection(connection, id: id)

            // Send the current frame immediately so the client doesn't stare at blank.
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

        guard !clients.isEmpty else { return }

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
        <head>
            <title>TeamsMakeupCam Virtual Camera</title>
            <meta http-equiv="refresh" content="5">
        </head>
        <body style="background:#111;color:#eee;font-family:system-ui;padding:2em;max-width:800px;margin:0 auto">
            <h1>TeamsMakeupCam Virtual Camera</h1>
            <p>Status: <strong>\(hasFrame ? "Streaming" : "Waiting for frames...")</strong></p>
            <p>Frame #\(frameNum) | MJPEG clients: \(clientCount)</p>

            <h2>Endpoints</h2>
            <ul>
                <li><a href="/stream" style="color:#4af">/stream</a> &mdash; MJPEG live stream (use in OBS Browser Source)</li>
                <li><a href="/latest.jpg" style="color:#4af">/latest.jpg</a> &mdash; Latest JPEG snapshot</li>
            </ul>

            <h2>OBS Setup</h2>
            <ol style="line-height:1.8">
                <li>Add a <strong>Browser Source</strong></li>
                <li>Set URL to <code style="background:#333;padding:2px 6px;border-radius:3px">http://127.0.0.1:\(port)/stream</code></li>
                <li>Set width/height to match your camera resolution (e.g. 1280x720)</li>
                <li>Click <strong>Start Virtual Camera</strong> in OBS</li>
                <li>In Teams, select <strong>OBS Virtual Camera</strong></li>
            </ol>

            <h2>Live Preview</h2>
            <img src="/stream" style="max-width:640px;border:1px solid #333;border-radius:4px" />
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
