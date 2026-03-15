import SwiftUI

struct ImagePreviewView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @State private var magnification: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        @Bindable var vm = viewModel

        GeometryReader { geometry in
            ZStack {
                Color.filmdevBackground

                if let cgImage = viewModel.previewImage {
                    if viewModel.isCropMode {
                        Image(decorative: cgImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay {
                                CropOverlayView(
                                    cropRect: $vm.pendingCropRect,
                                    imageSize: CGSize(
                                        width: CGFloat(cgImage.width),
                                        height: CGFloat(cgImage.height)
                                    ),
                                    aspectRatio: viewModel.cropAspectRatio
                                )
                            }
                    } else {
                        let displayImage = (viewModel.isShowingBefore && viewModel.originalPreviewImage != nil)
                            ? viewModel.originalPreviewImage!
                            : cgImage
                        Image(decorative: displayImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(magnification)
                            .offset(offset)
                            .gesture(dragGesture)
                            .gesture(magnificationGesture)
                            .onTapGesture(count: 2) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    magnification = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                                viewModel.isShowingBefore = pressing
                            }, perform: {})
                            .overlay(alignment: .topLeading) {
                                if viewModel.isShowingBefore {
                                    Text("Original")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                                        .padding(12)
                                }
                            }
                    }
                } else if !viewModel.isLoading {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.filmdevTextSecondary)

                        Text("Open a RAW image to get started")
                            .font(.title3)
                            .foregroundStyle(Color.filmdevTextSecondary)

                        Text("Cmd+O to open")
                            .font(.caption)
                            .foregroundStyle(Color.filmdevTextSecondary.opacity(0.7))
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .bottom) {
            if viewModel.isCropMode {
                cropToolbar
                    .padding(.bottom, 16)
            }
        }
    }

    private var cropToolbar: some View {
        @Bindable var vm = viewModel
        return HStack(spacing: 16) {
            Picker("Aspect", selection: $vm.cropAspectRatio) {
                ForEach(CropAspectRatio.allCases, id: \.self) { ratio in
                    Text(ratio.rawValue).tag(ratio)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Button("Cancel") {
                viewModel.cancelCrop()
            }
            .buttonStyle(.bordered)

            Button("Apply") {
                viewModel.applyCrop()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.filmdevAccent)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                magnification = max(0.1, min(10.0, value))
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                viewModel.loadImage(from: url)
            }
        }
        return true
    }
}
