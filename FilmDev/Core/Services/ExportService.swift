import CoreImage
import UniformTypeIdentifiers

struct ExportService: @unchecked Sendable {
    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    func export(image: CIImage, to url: URL, settings: ExportSettings) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw AppError.exportFailed(description: "Failed to create sRGB color space")
        }

        switch settings.format {
        case .jpeg:
            try context.writeJPEGRepresentation(
                of: image,
                to: url,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: settings.quality]
            )
        case .png:
            try context.writePNGRepresentation(
                of: image,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        case .tiff:
            try context.writeTIFFRepresentation(
                of: image,
                to: url,
                format: .RGBA16,
                colorSpace: colorSpace
            )
        case .heif:
            try context.writeHEIFRepresentation(
                of: image,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: settings.quality]
            )
        }
    }
}
