import SwiftUI

struct ContentView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @Environment(PresetViewModel.self) private var presetViewModel

    var body: some View {
        HSplitView {
            // Main preview area
            ImagePreviewView()
                .frame(minWidth: 500)

            // Right sidebar - adjustments
            AdjustmentPanelView()
                .frame(width: 300)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.isShowingBefore.toggle()
                } label: {
                    Image(systemName: viewModel.isShowingBefore ? "eye.slash" : "eye")
                }
                .help("Toggle Before/After")
                .disabled(viewModel.originalPreviewImage == nil)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.toggleCropMode()
                } label: {
                    Image(systemName: "crop")
                }
                .help("Crop")
                .disabled(viewModel.previewImage == nil)
            }
        }
        .background(Color.filmdevBackground)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.3))
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            presetViewModel.loadPresets()
        }
        .onChange(of: viewModel.imageLoadCount) {
            if let rawImage = viewModel.rawImage {
                presetViewModel.generateThumbnails(for: rawImage)
            }
        }
    }
}
