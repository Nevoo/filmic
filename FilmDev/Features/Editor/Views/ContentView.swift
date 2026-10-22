import SwiftUI

struct ContentView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @Environment(PresetViewModel.self) private var presetViewModel
    @Environment(FileBrowserViewModel.self) private var fileBrowserViewModel

    var body: some View {
        NavigationSplitView {
            FileBrowserSidebarView()
        } detail: {
            if fileBrowserViewModel.isEditing {
                HSplitView {
                    ImagePreviewView()
                        .frame(minWidth: 500)

                    AdjustmentPanelView()
                        .frame(width: 300)
                }
            } else {
                ContactSheetView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if fileBrowserViewModel.isEditing {
                    Button {
                        fileBrowserViewModel.exitEditMode()
                    } label: {
                        Image(systemName: "chevron.left")
                        Text("Browse")
                    }
                    .help("Return to contact sheet (Esc)")
                } else if let selected = fileBrowserViewModel.selectedFile, !selected.isDirectory {
                    Button {
                        openSelected()
                    } label: {
                        Image(systemName: "slider.horizontal.below.rectangle")
                        Text("Edit")
                    }
                    .help("Edit \(selected.name) (Return)")
                }
            }

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
                        .foregroundStyle(viewModel.isCropMode ? Color.filmdevAccent : Color.primary)
                }
                .help(viewModel.isCropMode ? "Exit crop" : "Crop")
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
                presetViewModel.generateThumbnails(for: rawImage, analysis: viewModel.imageAnalysis)
            }
            viewModel.applyDefaultPresetIfNeeded(presets: presetViewModel.presets)
        }
        .onKeyPress(.escape) {
            // Cancel an active tool before leaving the editor.
            if viewModel.isCropMode {
                viewModel.cancelCrop()
                return .handled
            }
            if fileBrowserViewModel.isEditing {
                fileBrowserViewModel.exitEditMode()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            if viewModel.isCropMode {
                viewModel.applyCrop()
                return .handled
            }
            if !fileBrowserViewModel.isEditing,
               let selected = fileBrowserViewModel.selectedFile, !selected.isDirectory {
                openSelected()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("\\")) {
            // Hold-to-compare convention: tap "\" to toggle the original.
            guard fileBrowserViewModel.isEditing, viewModel.originalPreviewImage != nil else {
                return .ignored
            }
            viewModel.isShowingBefore.toggle()
            return .handled
        }
    }

    private func openSelected() {
        guard let selected = fileBrowserViewModel.selectedFile, !selected.isDirectory else { return }
        fileBrowserViewModel.enterEditMode(file: selected)
        viewModel.loadImage(from: selected.url)
    }
}
