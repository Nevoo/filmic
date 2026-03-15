import Foundation

struct ExportSettings: Sendable {
    var format: ExportFormat = .jpeg
    var quality: Double = 0.92

    enum ExportFormat: String, CaseIterable, Identifiable {
        case jpeg = "JPEG"
        case png = "PNG"
        case tiff = "TIFF"
        case heif = "HEIF"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .tiff: return "tiff"
            case .heif: return "heic"
            }
        }

        var supportsQuality: Bool {
            self == .jpeg || self == .heif
        }
    }
}
