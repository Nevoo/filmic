import SwiftUI
import CoreImage

@Observable
@MainActor
final class PresetViewModel {
    var presets: [FilmPreset] = []
    var isLoading = false

    private let thumbnailService: ThumbnailService
    private let ciContext: CIContext

    init() {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        self.ciContext = context
        self.thumbnailService = ThumbnailService(context: context)
    }

    private static let presetCatalog: [(fileName: String, category: FilmPreset.PresetCategory)] = [
        // Fuji - Color
        ("Provia", .fuji),
        ("Velvia", .fuji),
        ("Astia", .fuji),
        ("Classic_Chrome", .fuji),
        ("Classic_Neg", .fuji),
        ("Pro_Neg_Hi", .fuji),
        ("Pro_Neg_Std", .fuji),
        ("Eterna", .fuji),
        ("Eterna_Bleach_Bypass", .fuji),
        // Fuji - B&W
        ("Acros", .fuji),
        ("Monochrome", .fuji),
        ("Sepia", .fuji),
        // Kodak
        ("Portra_400", .kodak),
        ("Ektar_100", .kodak),
        ("Gold_200", .kodak),
        ("Tri_X_400", .kodak),
        // Ilford
        ("HP5_Plus", .ilford),
        ("Delta_3200", .ilford),
    ]

    func loadPresets() {
        guard presets.isEmpty else { return }
        isLoading = true

        let catalog = Self.presetCatalog
        Task.detached {
            var loaded: [FilmPreset] = []

            for entry in catalog {
                guard let url = Bundle.main.url(forResource: entry.fileName, withExtension: "cube") else {
                    continue
                }

                let name = entry.fileName
                    .replacingOccurrences(of: "_", with: " ")

                var preset = FilmPreset(
                    name: name,
                    category: entry.category,
                    fileName: entry.fileName
                )

                if let lutData = try? LUTParser.parse(cubeFileAt: url) {
                    preset.lutData = lutData.data
                    preset.lutSize = lutData.size
                }

                loaded.append(preset)
            }

            await MainActor.run { [weak self] in
                self?.presets = loaded
                self?.isLoading = false
            }
        }
    }

    func generateThumbnails(for sourceImage: CIImage) {
        let currentPresets = presets
        let thumbService = thumbnailService

        Task.detached {
            for preset in currentPresets {
                guard let lutData = preset.lutData, let lutSize = preset.lutSize else { continue }

                var editState = EditState()
                editState.activeLUTData = lutData
                editState.activeLUTSize = lutSize

                let thumbnail = await thumbService.generateThumbnail(
                    for: sourceImage,
                    withEditState: editState
                )

                let presetID = preset.id
                await MainActor.run { [weak self] in
                    guard let self,
                          let idx = self.presets.firstIndex(where: { $0.id == presetID }) else { return }
                    self.presets[idx].thumbnail = thumbnail
                }
            }
        }
    }
}
