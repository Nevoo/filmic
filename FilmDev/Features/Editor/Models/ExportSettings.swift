import Foundation
import CoreGraphics

struct ExportSettings: Sendable {
    var format: ExportFormat = .jpeg
    var quality: Double = 0.92
    var resizeEnabled: Bool = false
    var maxLongEdge: Int = 2048
    var colorProfile: ColorProfile = .sRGB
    /// Composites the orange quartz date-back stamp onto the export. Off by
    /// default; export output is unchanged from before when false. Export-only —
    /// this never touches EditState or the sidecar.
    var dateStampEnabled: Bool = false

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

    enum ColorProfile: String, CaseIterable, Identifiable, Sendable {
        case sRGB = "sRGB"
        case displayP3 = "Display P3"

        var id: String { rawValue }

        var cgColorSpace: CGColorSpace? {
            switch self {
            case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
            case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
            }
        }
    }
}
