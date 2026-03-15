import CoreImage

extension CIImage {
    func applying(_ filterName: String, parameters: [String: Any] = [:]) -> CIImage {
        applyingFilter(filterName, parameters: parameters)
    }
}
