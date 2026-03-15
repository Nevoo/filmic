import CoreImage
import CoreGraphics

struct ImageProcessor: @unchecked Sendable {
    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    func process(image: CIImage, editState: EditState, isDragging: Bool = false) -> CIImage {
        var result = image

        // 1. Exposure
        if editState.exposure != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: editState.exposure
            ])
        }

        // 2. Noise Reduction
        if editState.noiseReduction > 0 {
            result = result.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": editState.noiseReduction * 0.1,
                "inputSharpness": 0.5
            ])
        }

        // 3. Contrast & Saturation (CIColorControls)
        if editState.contrast != 0 || editState.saturation != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + editState.contrast,
                kCIInputSaturationKey: 1.0 + editState.saturation
            ])
        }

        // 4. Hue
        if editState.hue != 0 {
            result = result.applyingFilter("CIHueAdjust", parameters: [
                kCIInputAngleKey: editState.hue
            ])
        }

        // 5. Vibrance
        if editState.vibrance != 0 {
            result = result.applyingFilter("CIVibrance", parameters: [
                "inputAmount": editState.vibrance
            ])
        }

        // 6. Highlights & Shadows
        if editState.highlights != 0 || editState.shadows != 0 {
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0 - editState.highlights,
                "inputShadowAmount": editState.shadows
            ])
        }

        // 7. Whites & Blacks via tone curve endpoint manipulation
        if editState.whites != 0 || editState.blacks != 0 {
            let blackPoint = max(0.0, min(1.0, editState.blacks * 0.1))
            let whitePoint = max(0.0, min(1.0, 1.0 + editState.whites * 0.1))
            result = result.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: CGFloat(blackPoint)),
                "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75),
                "inputPoint4": CIVector(x: 1.0, y: CGFloat(whitePoint))
            ])
        }

        // 8. LUT (Film Simulation)
        if let lutData = editState.activeLUTData,
           let lutSize = editState.activeLUTSize,
           let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
            result = result.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": lutSize,
                "inputCubeData": lutData,
                "inputColorSpace": colorSpace
            ])
        }

        // 9. RGB Curves
        result = applyCurve(editState.rgbCurve, to: result)

        // 10. Per-channel curves
        result = applyPerChannelCurves(editState: editState, to: result)

        // 11. Sharpening
        if editState.sharpening > 0 {
            result = result.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: editState.sharpening
            ])
        }

        // 12. Vignette
        if editState.vignetteIntensity != 0 {
            result = result.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: editState.vignetteIntensity,
                kCIInputRadiusKey: editState.vignetteRadius
            ])
        }

        // 13. Film Grain (skip during drag to avoid flickering — CIRandomGenerator changes per render)
        if editState.grainAmount > 0 && !isDragging {
            result = applyFilmGrain(to: result, amount: editState.grainAmount, size: editState.grainSize)
        }

        // 14. Crop (final step)
        if let crop = editState.cropRect {
            let extent = result.extent
            let cropCGRect = CGRect(
                x: extent.origin.x + crop.x * extent.width,
                y: extent.origin.y + crop.y * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            )
            result = result.cropped(to: cropCGRect)
        }

        return result
    }

    func render(image: CIImage, scale: CGFloat = 1.0) -> CGImage? {
        var renderImage = image
        if scale < 1.0 {
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            renderImage = image.transformed(by: transform)
        }
        let extent = renderImage.extent
        guard !extent.isInfinite && !extent.isEmpty else { return nil }
        return context.createCGImage(renderImage, from: extent)
    }

    // MARK: - Histogram

    func generateHistogram(from image: CIImage) -> CGImage? {
        let extent = image.extent
        guard !extent.isInfinite && !extent.isEmpty else { return nil }

        let histogram = image.applyingFilter("CIAreaHistogram", parameters: [
            "inputScale": 1.0,
            "inputCount": 256,
            "inputExtent": CIVector(cgRect: extent)
        ])

        let display = histogram.applyingFilter("CIHistogramDisplayFilter", parameters: [
            "inputHeight": 60.0
        ])

        return context.createCGImage(display, from: display.extent)
    }

    // MARK: - Film Grain

    private func applyFilmGrain(to image: CIImage, amount: Double, size: Double) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite && !extent.isEmpty else { return image }

        guard let randomGenerator = CIFilter(name: "CIRandomGenerator"),
              let noiseOutput = randomGenerator.outputImage else {
            return image
        }

        // Scale noise by grain size
        let scaleTransform = CGAffineTransform(scaleX: size, y: size)
        let scaledNoise = noiseOutput
            .transformed(by: scaleTransform)
            .cropped(to: extent)

        // Convert to grayscale luminance
        let grayscaleNoise = scaledNoise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.2126, z: 0.2126, w: 0),
            "inputGVector": CIVector(x: 0.7152, y: 0.7152, z: 0.7152, w: 0),
            "inputBVector": CIVector(x: 0.0722, y: 0.0722, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        // Blend grain over the image
        return grayscaleNoise.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: image
        ])
    }

    // MARK: - Curve Helpers

    private func applyCurve(_ curve: [CGPoint], to image: CIImage) -> CIImage {
        guard curve != EditState.defaultCurvePoints, curve.count == 5 else { return image }
        return image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: curve[0].x, y: curve[0].y),
            "inputPoint1": CIVector(x: curve[1].x, y: curve[1].y),
            "inputPoint2": CIVector(x: curve[2].x, y: curve[2].y),
            "inputPoint3": CIVector(x: curve[3].x, y: curve[3].y),
            "inputPoint4": CIVector(x: curve[4].x, y: curve[4].y)
        ])
    }

    private func applyPerChannelCurves(editState: EditState, to image: CIImage) -> CIImage {
        let defaults = EditState.defaultCurvePoints
        let hasRed = editState.redCurve != defaults
        let hasGreen = editState.greenCurve != defaults
        let hasBlue = editState.blueCurve != defaults
        guard hasRed || hasGreen || hasBlue else { return image }

        var result = image

        // Apply per-channel curves by isolating each channel, applying curve, recombining
        if hasRed {
            let redOnly = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let curved = applyCurve(editState.redCurve, to: redOnly)
            let greenBlue = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            result = curved.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: greenBlue
            ])
        }

        if hasGreen {
            let greenOnly = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let curved = applyCurve(editState.greenCurve, to: greenOnly)
            let redBlue = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            result = curved.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: redBlue
            ])
        }

        if hasBlue {
            let blueOnly = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let curved = applyCurve(editState.blueCurve, to: blueOnly)
            let redGreen = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            result = curved.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: redGreen
            ])
        }

        return result
    }
}
