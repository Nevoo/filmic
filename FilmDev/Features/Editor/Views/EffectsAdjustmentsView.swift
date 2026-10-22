import SwiftUI

struct EffectsAdjustmentsView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 4) {
            GroupResetHeader(
                title: "Effects",
                isDefault: viewModel.editState.isEffectsDefault,
                reset: viewModel.resetEffectsGroup
            )

            AdjustmentSlider(
                label: "Vignette",
                value: $vm.editState.vignetteIntensity,
                range: -1.0...3.0,
                format: "raw",
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Vignette Radius",
                value: $vm.editState.vignetteRadius,
                range: 0.0...2.0,
                format: "raw",
                defaultValue: 1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Grain Size",
                value: $vm.editState.grainSize,
                range: 0.25...2.0,
                format: "raw",
                defaultValue: 0.5,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Halation",
                value: $vm.editState.halationIntensity,
                range: 0...1.0,
                format: "raw",
                fillFromMinimum: true,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Glow",
                value: $vm.editState.glowIntensity,
                range: 0...1.0,
                format: "raw",
                fillFromMinimum: true,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Glow Radius",
                value: $vm.editState.glowRadius,
                range: 0...1.0,
                format: "raw",
                defaultValue: 0.5,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            // Light Leak — presence is normally rolled per image when a look is
            // applied, but the slider lets any frame carry one by hand. The dice
            // rerolls the shape/colour; it's a discrete, undoable edit.
            AdjustmentSlider(
                label: "Light Leak",
                value: $vm.editState.leakIntensity,
                range: 0...1.0,
                format: "raw",
                fillFromMinimum: true,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            HStack(spacing: 4) {
                Spacer()
                Button(action: { viewModel.rerollLeak() }) {
                    Label("Reroll", systemImage: "die.face.5")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.filmdevAccent)
                .disabled(viewModel.editState.leakIntensity <= 0)
                .help("Roll a different light leak")
            }
            .padding(.top, 1)
        }
    }
}
