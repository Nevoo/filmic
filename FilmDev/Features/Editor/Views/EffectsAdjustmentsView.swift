import SwiftUI

struct EffectsAdjustmentsView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 4) {
            HStack {
                Text("Effects")
                    .font(.headline)
                    .foregroundStyle(Color.filmdevText)
                Spacer()
            }

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
                label: "Grain Amount",
                value: $vm.editState.grainAmount,
                range: 0...1.0,
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
        }
    }
}
