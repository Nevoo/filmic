import SwiftUI

struct WhiteBalanceView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 4) {
            HStack {
                Text("White Balance")
                    .font(.headline)
                    .foregroundStyle(Color.filmdevText)
                Spacer()
            }

            AdjustmentSlider(
                label: "Temperature",
                value: $vm.editState.temperature,
                range: 2000...10000,
                format: "K",
                defaultValue: 6500,
                onDragChanged: { viewModel.onWBDragChanged() },
                onDragEnded: { viewModel.onWBDragEnded() }
            )

            AdjustmentSlider(
                label: "Tint",
                value: $vm.editState.tint,
                range: -150...150,
                format: "raw",
                onDragChanged: { viewModel.onWBDragChanged() },
                onDragEnded: { viewModel.onWBDragEnded() }
            )
        }
    }
}
