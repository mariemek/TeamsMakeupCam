import AVFoundation
import CoreImage
import AppKit

/// Applies subtle, image-based skin smoothing inside the detected face contour
/// using Core Image (masked Gaussian blur). Not a translucent overlay—actual
/// pixel smoothing for a meeting-appropriate look.
final class SkinSmoothingRenderer {

    /// Returns a new CIImage with subtle smoothing applied only inside the
    /// face contour. Uses smoothingStrength (0–1) to control blur radius.
    /// If contour is empty or strength is negligible, returns the original image.
    func smoothImage(
        _ image: CIImage,
        faceContour: [CGPoint],
        strength: Double
    ) -> CIImage {
        let clampedStrength = max(0.0, min(strength, 1.0))
        guard !faceContour.isEmpty, clampedStrength > 0.01 else {
            return image
        }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }

        // Build a grayscale mask: white = inside face (apply blur), black = outside (keep original).
        guard let maskImage = makeFaceMaskImage(
            faceContour: faceContour,
            imageWidth: CGFloat(width),
            imageHeight: CGFloat(height)
        ) else { return image }

        // Very subtle blur radius so the face doesn't look fake.
        let radius = 0.5 + 2.0 * clampedStrength

        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(image, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)

        guard let blurred = blurFilter.outputImage?.cropped(to: extent) else { return image }

        // CIBlendWithMask: background = original, foreground = blurred, mask = our mask (white = foreground).
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return image }
        blendFilter.setValue(blurred, forKey: kCIInputImageKey)
        blendFilter.setValue(image, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)

        return blendFilter.outputImage ?? image
    }

    /// Creates a CIImage mask (grayscale) with white inside the face polygon, black outside.
    /// Face contour points are in normalized [0,1] with origin bottom-left.
    private func makeFaceMaskImage(
        faceContour: [CGPoint],
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CIImage? {
        let width = Int(imageWidth)
        let height = Int(imageHeight)
        guard width > 0, height > 0, faceContour.count >= 3 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Black background (outside face).
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Polygon in image coordinates; normalized [0,1] bottom-left → same for CGContext (bottom-left).
        let path = CGMutablePath()
        let first = faceContour[0]
        let px = first.x * imageWidth
        let py = first.y * imageHeight
        path.move(to: CGPoint(x: px, y: py))
        for point in faceContour.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * imageWidth, y: point.y * imageHeight))
        }
        path.closeSubpath()

        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath()

        guard let cgMask = context.makeImage() else { return nil }
        let maskCIImage = CIImage(cgImage: cgMask)
        // Align mask to image extent in case of non-zero origin.
        return maskCIImage.transformed(by: CGAffineTransform(translationX: 0, y: 0))
    }
}
