import SwiftUI

struct BasicAdjustmentsView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 4) {
            HStack {
                Text("Adjustments")
                    .font(.headline)
                    .foregroundStyle(Color.filmdevText)
                Spacer()
                Button("Reset") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.editState = EditState()
                        viewModel.updatePreview()
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.filmdevAccent)
                .buttonStyle(.plain)
                .disabled(viewModel.editState.isDefault)
            }

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

            AdjustmentSlider(
                label: "Whites",
                value: $vm.editState.whites,
                range: -1.0...1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Blacks",
                value: $vm.editState.blacks,
                range: -1.0...1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )
        }
    }
}
