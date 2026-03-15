import Foundation
import CoreGraphics

struct FilmPreset: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let category: PresetCategory
    let fileName: String  // .cube file name without extension
    var thumbnail: CGImage?
    var lutData: Data?
    var lutSize: Int?

    enum PresetCategory: String, CaseIterable, Identifiable {
        case fuji = "Fuji"
        case kodak = "Kodak"
        case ilford = "Ilford"
        case custom = "Custom"

        var id: String { rawValue }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FilmPreset, rhs: FilmPreset) -> Bool {
        lhs.id == rhs.id
    }
}
