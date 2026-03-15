import SwiftUI

struct DetailAdjustmentsView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 4) {
            HStack {
                Text("Detail")
                    .font(.headline)
                    .foregroundStyle(Color.filmdevText)
                Spacer()
            }

            AdjustmentSlider(
                label: "Sharpening",
                value: $vm.editState.sharpening,
                range: 0...2.0,
                format: "raw",
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )

            AdjustmentSlider(
                label: "Noise Reduction",
                value: $vm.editState.noiseReduction,
                range: 0...1.0,
                onDragChanged: { viewModel.onSliderDragChanged() },
                onDragEnded: { viewModel.onSliderDragEnded() }
            )
        }
    }
}
