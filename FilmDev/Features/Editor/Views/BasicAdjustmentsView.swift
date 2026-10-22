import SwiftUI

struct BasicAdjustmentsView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 4) {
            GroupResetHeader(
                title: "Tone",
                isDefault: viewModel.editState.isToneDefault,
                reset: viewModel.resetToneGroup
            )

            AdjustmentSlider(
                label: "Exposure",
                value: $vm.editState.exposure,
                range: -3.0...3.0,
                format: "%+.1f EV",
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Contrast",
                value: $vm.editState.contrast,
                range: -1.0...1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Highlights",
                value: $vm.editState.highlights,
                range: -1.0...1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Shadows",
                value: $vm.editState.shadows,
                range: -1.0...1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )
        }
    }
}
