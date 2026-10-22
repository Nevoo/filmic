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
        let context = FilmColorPipeline.makeContext()
        self.ciContext = context
        self.thumbnailService = ThumbnailService(context: context)
    }

    func loadPresets() {
        guard presets.isEmpty else { return }
        isLoading = true

        let catalog = FilmPreset.catalog
        Task.detached {
            var loaded: [FilmPreset] = []

            for entry in catalog {
                // Resolve whether the cubes are bundled with their folder
                // structure (LUTs/fuji/…) or flattened to the resources root.
                // Matches EditState.reloadLUTIfNeeded's lookup order.
                guard let url = Bundle.main.url(forResource: entry.fileName, withExtension: "cube", subdirectory: "LUTs/fuji")
                       ?? Bundle.main.url(forResource: entry.fileName, withExtension: "cube", subdirectory: "LUTs")
                       ?? Bundle.main.url(forResource: entry.fileName, withExtension: "cube") else {
                    continue
                }

                let name = entry.fileName
                    .replacingOccurrences(of: "_", with: " ")

                var preset = FilmPreset(
                    name: name,
                    category: .fuji,
                    group: entry.group,
                    fileName: entry.fileName,
                    defaults: entry.defaults
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

    /// Renders the per-look preview tiles. `analysis` carries the loaded
    /// frame's measurements so each tile gets the same per-stock auto trims
    /// the editor will apply — without it, tiles would show the raw decode
    /// (auto-bright off = dark) instead of the developed look.
    func generateThumbnails(for sourceImage: CIImage, analysis: ImageAnalysis?) {
        let currentPresets = presets
        let thumbService = thumbnailService

        Task.detached {
            for preset in currentPresets {
                guard let lutData = preset.lutData, let lutSize = preset.lutSize else { continue }

                var editState = EditState()
                editState.activeLUTData = lutData
                editState.activeLUTSize = lutSize
                if let analysis {
                    editState.autoFields = Set(EditState.EditField.allCases)
                    editState.applyAutoTrims(PresetIntent.trims(for: analysis, presetFileName: preset.fileName))
                }

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
