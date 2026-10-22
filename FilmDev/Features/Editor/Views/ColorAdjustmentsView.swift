import SwiftUI

struct ColorAdjustmentsView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 4) {
            GroupResetHeader(
                title: "Color",
                isDefault: viewModel.editState.isColorDefault,
                reset: viewModel.resetColorGroup
            )

            AdjustmentSlider(
                label: "Saturation",
                value: $vm.editState.saturation,
                range: -1.0...1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Vibrance",
                value: $vm.editState.vibrance,
                range: -1.0...1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )
        }
    }
}
