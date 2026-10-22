import CoreImage
import CoreGraphics

enum FilmColorPipeline {
    // sRGB primaries throughout: matches libraw's sRGB output, matches
    // what Fuji-style .cube LUTs are authored against. Cross-primaries
    // conversions (e.g. to/from P3) desaturate the image and shift hue on
    // the way through, so we just don't do them.
    static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func makeContext(highQualityDownsample: Bool = false) -> CIContext {
        var options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: displayColorSpace,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
        ]
        if highQualityDownsample {
            options[.highQualityDownsample] = true
        }
        return CIContext(options: options)
    }

    static func normalizeDecodedImage(_ image: CIImage) -> CIImage {
        if let sourceColorSpace = image.colorSpace {
            return image.matchedToWorkingSpace(from: sourceColorSpace) ?? image
        }
        return image
    }
}
