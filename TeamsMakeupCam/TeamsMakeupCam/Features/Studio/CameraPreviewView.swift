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

    // MARK: - Layers

    let previewLayer = AVCaptureVideoPreviewLayer()
    private let contentLayer = CALayer()

    private let leftBlushLayer = CALayer()
    private let rightBlushLayer = CALayer()

    private let lipstickLayer = CAShapeLayer()
    private let lipLinerLayer = CAShapeLayer()
    private let eyelinerLayer = CAShapeLayer()
    private let leftLashLayer = CALayer()
    private let rightLashLayer = CALayer()
    private let debugOverlayLayer = CAShapeLayer()

    /// Layers whose frame fills the view and receive the mirror transform.
    private var fullFrameLayers: [CALayer] {
        [
            previewLayer,
            contentLayer,
            leftBlushLayer,
            rightBlushLayer,
            leftLashLayer,
            rightLashLayer,
            eyelinerLayer,
            lipstickLayer,
            lipLinerLayer,
            debugOverlayLayer
        ]
    }

    // MARK: - Renderers

    private let lipstickRenderer = LipstickRenderer()
    private let lipLinerRenderer = LipLinerRenderer()
    private let eyelinerRenderer = EyelinerRenderer()
    private let lashesRenderer = LashesRenderer()
    private let blushRenderer = BlushRenderer()

    // MARK: - State

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastRenderedExtent: CGRect?

    var landmarks: [FaceLandmarks] = [] { didSet { updateOverlay() } }
    var makeupSettings: MakeupSettings = .naturalPreset { didSet { updateOverlay() } }
    var showDebugLandmarks: Bool = false { didSet { updateOverlay() } }

    // MARK: - Init

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
        contentLayer.contentsGravity = .resizeAspectFill
        contentLayer.masksToBounds = true

        leftBlushLayer.backgroundColor = NSColor.clear.cgColor
        leftBlushLayer.masksToBounds = false
        leftBlushLayer.compositingFilter = "screenBlendMode"

        rightBlushLayer.backgroundColor = NSColor.clear.cgColor
        rightBlushLayer.masksToBounds = false
        rightBlushLayer.compositingFilter = "screenBlendMode"

        debugOverlayLayer.strokeColor = NSColor.systemGreen.cgColor
        debugOverlayLayer.fillColor = NSColor.clear.cgColor
        debugOverlayLayer.lineWidth = 1.5

        let fill: CAAutoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        for layer in fullFrameLayers {
            layer.autoresizingMask = fill
            layer.frame = bounds
        }

        leftLashLayer.backgroundColor = NSColor.clear.cgColor
        leftLashLayer.masksToBounds = false
        rightLashLayer.backgroundColor = NSColor.clear.cgColor
        rightLashLayer.masksToBounds = false

        rootLayer.addSublayer(previewLayer)
        rootLayer.addSublayer(contentLayer)
        rootLayer.addSublayer(leftBlushLayer)
        rootLayer.addSublayer(rightBlushLayer)
        rootLayer.addSublayer(leftLashLayer)
        rootLayer.addSublayer(rightLashLayer)
        rootLayer.addSublayer(eyelinerLayer)
        rootLayer.addSublayer(lipstickLayer)
        rootLayer.addSublayer(lipLinerLayer)
        rootLayer.addSublayer(debugOverlayLayer)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layer?.frame = bounds
        for layer in fullFrameLayers {
            layer.frame = bounds
        }

        let mirror = CATransform3DMakeScale(-1, 1, 1)
        for layer in fullFrameLayers {
            layer.transform = mirror
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
        for layer in fullFrameLayers {
            layer.frame = bounds
        }
        CATransaction.commit()
    }

    // MARK: - Processed frame

    func updateProcessedFrame(_ image: CIImage?) {
        if let image = image {
            let extent = image.extent
            guard extent.width > 0,
                  extent.height > 0,
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

    // MARK: - Overlay

    private func updateOverlay() {
        guard bounds.width > 0, bounds.height > 0 else {
            clearAllLayers()
            return
        }

        let useProcessed = lastRenderedExtent != nil

        blushRenderer.updateBlushLayers(
            leftLayer: leftBlushLayer,
            rightLayer: rightBlushLayer,
            with: landmarks,
            in: previewLayer,
            settings: makeupSettings,
            useProcessedFrameCoordinates: useProcessed,
            contentExtent: lastRenderedExtent,
            viewBounds: bounds
        )

        lipstickRenderer.updateLipstickLayer(
            lipstickLayer,
            with: landmarks,
            in: previewLayer,
            settings: makeupSettings,
            useProcessedFrameCoordinates: useProcessed,
            contentExtent: lastRenderedExtent,
            viewBounds: bounds
        )

        lipLinerRenderer.updateLipLinerLayer(
            lipLinerLayer,
            with: landmarks,
            in: previewLayer,
            settings: makeupSettings,
            useProcessedFrameCoordinates: useProcessed,
            contentExtent: lastRenderedExtent,
            viewBounds: bounds
        )

        eyelinerRenderer.updateEyelinerLayer(
            eyelinerLayer,
            with: landmarks,
            in: previewLayer,
            settings: makeupSettings,
            useProcessedFrameCoordinates: useProcessed,
            contentExtent: lastRenderedExtent,
            viewBounds: bounds
        )

        lashesRenderer.updateLashLayers(
            leftLayer: leftLashLayer,
            rightLayer: rightLashLayer,
            with: landmarks,
            in: previewLayer,
            settings: makeupSettings,
            useProcessedFrameCoordinates: useProcessed,
            contentExtent: lastRenderedExtent,
            viewBounds: bounds
        )

        if showDebugLandmarks {
            let path = CGMutablePath()
            for face in landmarks {
                addPolyline(face.outerLips, to: path, closed: true)
                addPolyline(face.innerLips, to: path, closed: true)
                addPolyline(face.leftEye, to: path, closed: true)
                addPolyline(face.rightEye, to: path, closed: true)
                addPolyline(face.faceContour, to: path, closed: false)
            }
            debugOverlayLayer.path = path
        } else {
            debugOverlayLayer.path = nil
        }
    }

    private func clearAllLayers() {
        leftBlushLayer.contents = nil
        rightBlushLayer.contents = nil
        leftBlushLayer.opacity = 0
        rightBlushLayer.opacity = 0
        leftLashLayer.contents = nil
        rightLashLayer.contents = nil
        leftLashLayer.opacity = 0
        rightLashLayer.opacity = 0
        lipstickLayer.path = nil
        lipLinerLayer.path = nil
        eyelinerLayer.path = nil
        debugOverlayLayer.path = nil
    }

    // MARK: - Helpers

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
                normalizedPoint,
                contentExtent: extent,
                viewBounds: bounds
            )
        }

        let capturePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: capturePoint)
    }
}

// MARK: - Coordinate conversion

private func convertProcessedFrameNormalizedToView(
    _ normalized: CGPoint,
    contentExtent: CGRect,
    viewBounds: CGRect
) -> CGPoint {
    let w = contentExtent.width
    let h = contentExtent.height
    guard w > 0, h > 0 else { return .zero }

    let scale = max(viewBounds.width / w, viewBounds.height / h)
    let drawW = w * scale
    let drawH = h * scale
    let originX = viewBounds.midX - drawW / 2
    let originY = viewBounds.midY - drawH / 2

    return CGPoint(
        x: originX + normalized.x * drawW,
        y: originY + normalized.y * drawH
    )
}
