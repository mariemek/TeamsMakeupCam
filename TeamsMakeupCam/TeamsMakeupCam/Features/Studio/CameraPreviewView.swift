import SwiftUI
import AVFoundation
import CoreImage
import AppKit

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let landmarks: [FaceLandmarks]
    let makeupSettings: MakeupSettings
    let showDebugLandmarks: Bool
    let processedFrame: CIImage?

    init(
        session: AVCaptureSession,
        landmarks: [FaceLandmarks],
        makeupSettings: MakeupSettings,
        showDebugLandmarks: Bool = false,
        processedFrame: CIImage? = nil
    ) {
        self.session = session
        self.landmarks = landmarks
        self.makeupSettings = makeupSettings
        self.showDebugLandmarks = showDebugLandmarks
        self.processedFrame = processedFrame
    }

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        view.makeupSettings = makeupSettings
        view.landmarks = landmarks
        view.showDebugLandmarks = showDebugLandmarks
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        nsView.previewLayer.session = session
        nsView.landmarks = landmarks
        nsView.makeupSettings = makeupSettings
        nsView.showDebugLandmarks = showDebugLandmarks
        nsView.updateProcessedFrame(processedFrame)
    }
}

final class PreviewContainerView: NSView {

    let previewLayer          = AVCaptureVideoPreviewLayer()
    private let contentLayer  = CALayer()
    private let lipstickLayer = CAShapeLayer()
    private let lipLinerLayer = CAShapeLayer()
    private let eyelinerLayer = CAShapeLayer()
    private let debugOverlayLayer = CAShapeLayer()

    private var allLayers: [CALayer] {
        [previewLayer, contentLayer, eyelinerLayer,
         lipstickLayer, lipLinerLayer, debugOverlayLayer]
    }

    private let lipstickRenderer  = LipstickRenderer()
    private let lipLinerRenderer  = LipLinerRenderer()
    private let eyelinerRenderer  = EyelinerRenderer()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastRenderedExtent: CGRect?

    var landmarks: [FaceLandmarks] = [] { didSet { updateOverlay() } }
    var makeupSettings: MakeupSettings = .defaultPreset { didSet { updateOverlay() } }
    var showDebugLandmarks: Bool = false { didSet { updateOverlay() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        layer = rootLayer

        contentLayer.backgroundColor = NSColor.clear.cgColor
        contentLayer.contentsGravity  = .resizeAspectFill
        contentLayer.masksToBounds    = true

        debugOverlayLayer.strokeColor = NSColor.systemGreen.cgColor
        debugOverlayLayer.fillColor   = NSColor.clear.cgColor
        debugOverlayLayer.lineWidth   = 1.5

        let fill: CAAutoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        for l in allLayers {
            l.autoresizingMask = fill
            l.frame = bounds
        }

        rootLayer.addSublayer(previewLayer)
        rootLayer.addSublayer(contentLayer)
        rootLayer.addSublayer(eyelinerLayer)
        rootLayer.addSublayer(lipstickLayer)
        rootLayer.addSublayer(lipLinerLayer)
        rootLayer.addSublayer(debugOverlayLayer)
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer?.frame = bounds
        for l in allLayers {
            l.frame = bounds
        }

        let mirror = CATransform3DMakeScale(-1, 1, 1)
        for l in allLayers {
            l.transform = mirror
        }

        CATransaction.commit()

        updateOverlay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        for l in allLayers { l.frame = bounds }
        CATransaction.commit()
    }

    func updateProcessedFrame(_ image: CIImage?) {
        if let image = image {
            let extent = image.extent
            guard extent.width > 0, extent.height > 0,
                  let cgImage = ciContext.createCGImage(image, from: extent) else {
                contentLayer.contents = nil
                lastRenderedExtent = nil
                updateOverlay()
                return
            }
            contentLayer.contents = cgImage
            lastRenderedExtent = extent
        } else {
            contentLayer.contents = nil
            lastRenderedExtent = nil
        }
        updateOverlay()
    }

    private func updateOverlay() {
        guard bounds.width > 0, bounds.height > 0 else { clearAllLayers(); return }

        let useProcessed = lastRenderedExtent != nil

        lipstickRenderer.updateLipstickLayer(
            lipstickLayer, with: landmarks, in: previewLayer,
            settings: makeupSettings,
            useProcessedFrameCoordinates: useProcessed,
            contentExtent: lastRenderedExtent, viewBounds: bounds)

        lipLinerRenderer.updateLipLinerLayer(
            lipLinerLayer, with: landmarks, in: previewLayer,
            settings: makeupSettings,
            useProcessedFrameCoordinates: useProcessed,
            contentExtent: lastRenderedExtent, viewBounds: bounds)

        eyelinerRenderer.updateEyelinerLayer(
            eyelinerLayer, with: landmarks, in: previewLayer,
            settings: makeupSettings,
            useProcessedFrameCoordinates: useProcessed,
            contentExtent: lastRenderedExtent, viewBounds: bounds)

        if showDebugLandmarks {
            let path = CGMutablePath()
            for face in landmarks {
                addPolyline(face.outerLips,   to: path, closed: true)
                addPolyline(face.innerLips,   to: path, closed: true)
                addPolyline(face.leftEye,     to: path, closed: true)
                addPolyline(face.rightEye,    to: path, closed: true)
                addPolyline(face.faceContour, to: path, closed: false)
            }
            debugOverlayLayer.path = path
        } else {
            debugOverlayLayer.path = nil
        }
    }

    private func clearAllLayers() {
        lipstickLayer.path     = nil
        lipLinerLayer.path     = nil
        eyelinerLayer.path     = nil
        debugOverlayLayer.path = nil
    }

    private func addPolyline(_ points: [CGPoint], to path: CGMutablePath, closed: Bool) {
        guard !points.isEmpty else { return }
        let first = convertToLayerSpace(points[0])
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: convertToLayerSpace(point))
        }
        if closed { path.closeSubpath() }
    }

    private func convertToLayerSpace(_ normalizedPoint: CGPoint) -> CGPoint {
        if let extent = lastRenderedExtent, extent.width > 0, extent.height > 0 {
            return convertProcessedFrameNormalizedToView(
                normalizedPoint, contentExtent: extent, viewBounds: bounds)
        }
        let capturePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: capturePoint)
    }
}

private func convertProcessedFrameNormalizedToView(
    _ normalized: CGPoint,
    contentExtent: CGRect,
    viewBounds: CGRect
) -> CGPoint {
    let w = contentExtent.width, h = contentExtent.height
    guard w > 0, h > 0 else { return .zero }
    let scale   = max(viewBounds.width / w, viewBounds.height / h)
    let drawW   = w * scale
    let drawH   = h * scale
    let originX = viewBounds.midX - drawW / 2
    let originY = viewBounds.midY - drawH / 2
    return CGPoint(x: originX + normalized.x * drawW, y: originY + normalized.y * drawH)
}
