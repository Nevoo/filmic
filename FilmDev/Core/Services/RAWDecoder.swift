import CoreImage

struct RAWDecoder: @unchecked Sendable {
    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    func decode(url: URL, temperature: Double = 6500, tint: Double = 0) throws -> CIImage {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw AppError.rawDecodeFailed(url: url)
        }
        // Use neutral settings - adjustments come later in pipeline
        filter.exposure = 0
        filter.baselineExposure = 0
        filter.shadowBias = 0
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = true
        filter.isLensCorrectionEnabled = true
        filter.neutralTemperature = Float(temperature)
        filter.neutralTint = Float(tint)

        guard let output = filter.outputImage else {
            throw AppError.rawDecodeFailed(url: url)
        }
        return output
    }
}
