import AVFoundation
import AppKit
import CoreGraphics

final class BlushRenderer {

    private var previousLeftCenter: CGPoint?
    private var previousRightCenter: CGPoint?
    private var previousLeftSize: CGSize = .zero
    private var previousRightSize: CGSize = .zero
    private var previousLeftAngle: CGFloat = 0
    private var previousRightAngle: CGFloat = 0

    func updateBlushLayers(
        leftLayer: CALayer,
        rightLayer: CALayer,
        with landmarks: [FaceLandmarks],
        in previewLayer: AVCaptureVideoPreviewLayer,
        settings: MakeupSettings,
        useProcessedFrameCoordinates: Bool = false,
        contentExtent: CGRect? = nil,
        viewBounds: CGRect? = nil
    ) {
        let intensity = max(0.0, min(settings.blushIntensity, 1.0))

        guard intensity > 0.001,
              let face = landmarks.first,
              !face.leftEye.isEmpty,
              !face.rightEye.isEmpty,
              !face.faceContour.isEmpty else {
            clear(leftLayer: leftLayer, rightLayer: rightLayer)
            return
        }

        let bounds = viewBounds ?? previewLayer.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            clear(leftLayer: leftLayer, rightLayer: rightLayer)
            return
        }

        let convert: (CGPoint) -> CGPoint = { point in
            if useProcessedFrameCoordinates,
               let extent = contentExtent,
               extent.width > 0,
               extent.height > 0 {
                return convertProcessedFrameNormalizedToView(
                    point,
                    contentExtent: extent,
                    viewBounds: bounds
                )
            } else {
                let capturePoint = CGPoint(x: point.x, y: 1.0 - point.y)
                return previewLayer.layerPointConverted(fromCaptureDevicePoint: capturePoint)
            }
        }

        let leftEyePoints = face.leftEye.map(convert)
        let rightEyePoints = face.rightEye.map(convert)
        let contourPoints = face.faceContour.map(convert)

        guard !leftEyePoints.isEmpty,
              !rightEyePoints.isEmpty,
              contourPoints.count >= 6 else {
            clear(leftLayer: leftLayer, rightLayer: rightLayer)
            return
        }

        let leftEyeCenter = average(leftEyePoints)
        let rightEyeCenter = average(rightEyePoints)
        let contourBounds = boundingRect(contourPoints)

        guard contourBounds.width > 0, contourBounds.height > 0 else {
            clear(leftLayer: leftLayer, rightLayer: rightLayer)
            return
        }

        let faceWidth = contourBounds.width
        let faceHeight = contourBounds.height
        let meanEyeWidth = max(10, (horizontalSpan(leftEyePoints) + horizontalSpan(rightEyePoints)) * 0.5)

        // Inspired by cheek-region approaches:
        // place blush under each eye, slightly outward, inside a cheek-safe box.
        let baseHorizontalOffset = faceWidth * 0.12
        let baseVerticalOffset = faceHeight * 0.22

        var leftCenter = CGPoint(
            x: leftEyeCenter.x - baseHorizontalOffset + faceWidth * settings.blushPlacementX * 0.20,
            y: leftEyeCenter.y + baseVerticalOffset + faceHeight * settings.blushPlacementY * 0.18
        )

        var rightCenter = CGPoint(
            x: rightEyeCenter.x + baseHorizontalOffset + faceWidth * settings.blushPlacementX * 0.20,
            y: rightEyeCenter.y + baseVerticalOffset + faceHeight * settings.blushPlacementY * 0.18
        )

        // Constrain to realistic cheek band.
        let minY = contourBounds.minY + faceHeight * 0.45
        let maxY = contourBounds.minY + faceHeight * 0.72

        leftCenter.y = min(max(leftCenter.y, minY), maxY)
        rightCenter.y = min(max(rightCenter.y, minY), maxY)

        let leftMinX = contourBounds.minX + faceWidth * 0.10
        let leftMaxX = contourBounds.midX - faceWidth * 0.10
        let rightMinX = contourBounds.midX + faceWidth * 0.10
        let rightMaxX = contourBounds.maxX - faceWidth * 0.10

        leftCenter.x = min(max(leftCenter.x, leftMinX), leftMaxX)
        rightCenter.x = min(max(rightCenter.x, rightMinX), rightMaxX)

        // More realistic blush footprint: wider than tall, cheek-sized.
        let blushWidth = max(faceWidth * 0.18, meanEyeWidth * 1.55) * max(0.7, settings.blushWidth)
        let blushHeight = max(faceHeight * 0.14, meanEyeWidth * 1.05) * max(0.7, settings.blushHeight)

        let leftSize = CGSize(width: blushWidth, height: blushHeight)
        let rightSize = CGSize(width: blushWidth, height: blushHeight)

        let rollRadians = CGFloat(face.roll * .pi / 180.0)
        let leftAngle = rollRadians - CGFloat(8.0 * .pi / 180.0)
        let rightAngle = rollRadians + CGFloat(8.0 * .pi / 180.0)

        let finalLeftCenter = smooth(point: leftCenter, previous: &previousLeftCenter, alpha: 0.20)
        let finalRightCenter = smooth(point: rightCenter, previous: &previousRightCenter, alpha: 0.20)

        let finalLeftSize = smooth(size: leftSize, previous: &previousLeftSize, alpha: 0.18)
        let finalRightSize = smooth(size: rightSize, previous: &previousRightSize, alpha: 0.18)

        let finalLeftAngle = smooth(angle: leftAngle, previous: &previousLeftAngle, alpha: 0.18)
        let finalRightAngle = smooth(angle: rightAngle, previous: &previousRightAngle, alpha: 0.18)

        let finalOpacity = Float(0.10 + intensity * 0.26)

        updateSingleBlushLayer(
            leftLayer,
            center: finalLeftCenter,
            size: finalLeftSize,
            angle: finalLeftAngle,
            color: settings.blushNSColor,
            feather: settings.blushFeather,
            opacity: finalOpacity
        )

        updateSingleBlushLayer(
            rightLayer,
            center: finalRightCenter,
            size: finalRightSize,
            angle: finalRightAngle,
            color: settings.blushNSColor,
            feather: settings.blushFeather,
            opacity: finalOpacity
        )
    }

    func clear(leftLayer: CALayer, rightLayer: CALayer) {
        leftLayer.contents = nil
        rightLayer.contents = nil
        leftLayer.opacity = 0
        rightLayer.opacity = 0
        previousLeftCenter = nil
        previousRightCenter = nil
        previousLeftSize = .zero
        previousRightSize = .zero
        previousLeftAngle = 0
        previousRightAngle = 0
    }

    private func updateSingleBlushLayer(
        _ layer: CALayer,
        center: CGPoint,
        size: CGSize,
        angle: CGFloat,
        color: NSColor,
        feather: Double,
        opacity: Float
    ) {
        guard size.width > 8, size.height > 8 else {
            layer.contents = nil
            layer.opacity = 0
            return
        }

        let imageSize = CGSize(
            width: max(96, round(size.width)),
            height: max(96, round(size.height))
        )

        layer.bounds = CGRect(origin: .zero, size: imageSize)
        layer.position = center
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.opacity = opacity
        layer.contentsGravity = .resizeAspectFill
        layer.contents = makeSoftBlushImage(
            color: color,
            size: imageSize,
            feather: feather
        )
        layer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
    }

    // Draw directly into a transparent bitmap so we get a true cheek patch,
    // not a tinted full rectangle.
    private func makeSoftBlushImage(
        color: NSColor,
        size: CGSize,
        feather: Double
    ) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: size))

        let srgb = color.usingColorSpace(.sRGB) ?? color
        let red = srgb.redComponent
        let green = srgb.greenComponent
        let blue = srgb.blueComponent

        let rect = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: rect.midX, y: rect.midY)

        // Realistic cheek blush:
        // stack several soft ellipses with fading alpha.
        let layers = 18
        let softness = max(0.0, min(feather, 1.0))

        for i in 0..<layers {
            let t = CGFloat(i) / CGFloat(max(layers - 1, 1))

            let widthScale = 1.0 - t * 0.78
            let heightScale = 1.0 - t * 0.72

            let ellipseWidth = size.width * widthScale
            let ellipseHeight = size.height * heightScale

            let ellipseRect = CGRect(
                x: center.x - ellipseWidth / 2,
                y: center.y - ellipseHeight / 2,
                width: ellipseWidth,
                height: ellipseHeight
            )

            // Stronger center, very soft outer edge.
            let alpha = (0.010 + (1.0 - t) * 0.060) * (0.75 + softness * 0.50)

            context.setFillColor(
                red: red,
                green: green,
                blue: blue,
                alpha: alpha
            )
            context.fillEllipse(in: ellipseRect)
        }

        // Add a slightly offset inner oval to mimic natural cheek diffusion.
        let innerRect = CGRect(
            x: center.x - size.width * 0.26,
            y: center.y - size.height * 0.22,
            width: size.width * 0.52,
            height: size.height * 0.44
        )

        context.setFillColor(
            red: red,
            green: green,
            blue: blue,
            alpha: 0.045 * (0.7 + softness * 0.4)
        )
        context.fillEllipse(in: innerRect)

        return context.makeImage()
    }

    private func average(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(
            x: sum.x / CGFloat(points.count),
            y: sum.y / CGFloat(points.count)
        )
    }

    private func horizontalSpan(_ points: [CGPoint]) -> CGFloat {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max() else {
            return 0
        }
        return maxX - minX
    }

    private func boundingRect(_ points: [CGPoint]) -> CGRect {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else {
            return .zero
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private func smooth(point: CGPoint, previous: inout CGPoint?, alpha: CGFloat) -> CGPoint {
        guard let old = previous else {
            previous = point
            return point
        }

        let result = CGPoint(
            x: old.x + (point.x - old.x) * alpha,
            y: old.y + (point.y - old.y) * alpha
        )
        previous = result
        return result
    }

    private func smooth(size: CGSize, previous: inout CGSize, alpha: CGFloat) -> CGSize {
        guard previous != .zero else {
            previous = size
            return size
        }

        let result = CGSize(
            width: previous.width + (size.width - previous.width) * alpha,
            height: previous.height + (size.height - previous.height) * alpha
        )
        previous = result
        return result
    }

    private func smooth(angle: CGFloat, previous: inout CGFloat, alpha: CGFloat) -> CGFloat {
        let result = previous + (angle - previous) * alpha
        previous = result
        return result
    }
}

// MARK: - Local coordinate conversion helper

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
