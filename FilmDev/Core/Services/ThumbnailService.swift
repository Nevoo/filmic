import CoreImage
import CoreGraphics

actor ThumbnailService {
    private let context: CIContext
    private let processor: ImageProcessor
    private let maxThumbnailSize: CGFloat = 200

    init(context: CIContext) {
        self.context = context
        self.processor = ImageProcessor(context: context)
    }

    func generateThumbnail(for image: CIImage, withEditState editState: EditState? = nil) -> CGImage? {
        var img = image
        if let editState {
            img = processor.process(image: image, editState: editState)
        }

        let extent = img.extent
        guard !extent.isInfinite && !extent.isEmpty else { return nil }
        let scale = min(maxThumbnailSize / extent.width, maxThumbnailSize / extent.height, 1.0)
        if scale < 1.0 {
            img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return context.createCGImage(img, from: img.extent)
    }
}
