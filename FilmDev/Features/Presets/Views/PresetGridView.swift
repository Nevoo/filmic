import SwiftUI

struct PresetGridView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @Environment(PresetViewModel.self) private var presetViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var isNoneSelected: Bool {
        viewModel.editState.activeLUTName == nil
    }

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 10) {
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
                    noneCard
                }

                ForEach(FilmPreset.LookGroup.allCases) { group in
                    let groupPresets = presetViewModel.presets.filter { $0.group == group }
                    if !groupPresets.isEmpty {
                        HStack {
                            Text(group.rawValue)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.filmdevTextSecondary)
                            Spacer()
                        }
                        .padding(.top, 2)

                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(groupPresets) { preset in
                                PresetCard(
                                    preset: preset,
                                    isSelected: viewModel.editState.activeLUTName == preset.name,
                                    isDefault: viewModel.defaultPresetName == preset.name,
                                    action: {
                                        withAnimation(.spring(response: 0.3)) {
                                            viewModel.applyPreset(preset)
                                        }
                                    },
                                    onSetDefault: {
                                        if viewModel.defaultPresetName == preset.name {
                                            viewModel.setDefaultPreset(nil)
                                        } else {
                                            viewModel.setDefaultPreset(preset.name)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }

                // Look strength — only meaningful when a look is applied.
                if !isNoneSelected {
                    AdjustmentSlider(
                        label: "Look Strength",
                        value: $vm.editState.lutIntensity,
                        range: 0...1,
                        format: "%",
                        defaultValue: 1.0,
                        fillFromMinimum: true,
                        onDragChanged: { viewModel.onSliderDragChanged() },
                        onDragEnded: { viewModel.onSliderDragEnded() }
                    )
                    .padding(.top, 4)
                }
            }
        }
    }

    private var noneCard: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.filmdevBackground)
                    .aspectRatio(1.0, contentMode: .fit)
                Image(systemName: "nosign")
                    .font(.title3)
                    .foregroundStyle(Color.filmdevTextSecondary)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isNoneSelected ? Color.filmdevAccent : Color.clear, lineWidth: 2)
            )

            Text("None")
                .font(.caption2)
                .foregroundStyle(isNoneSelected ? Color.filmdevAccent : Color.filmdevTextSecondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3)) {
                viewModel.clearActiveLUT()
            }
        }
        .help("Remove the film look")
    }
}
