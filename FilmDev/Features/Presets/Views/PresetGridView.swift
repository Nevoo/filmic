import SwiftUI

struct PresetGridView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @Environment(PresetViewModel.self) private var presetViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Film Looks")
                    .font(.headline)
                    .foregroundStyle(Color.filmdevText)
                Spacer()
            }

            if presetViewModel.presets.isEmpty {
                Text("No presets found")
                    .font(.caption)
                    .foregroundStyle(Color.filmdevTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(presetViewModel.presets) { preset in
                        PresetCard(
                            preset: preset,
                            isSelected: viewModel.editState.activeLUTName == preset.name
                        ) {
                            withAnimation(.spring(response: 0.3)) {
                                viewModel.applyPreset(preset)
                            }
                        }
                    }
                }
            }
        }
    }
}
