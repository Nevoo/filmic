import SwiftUI

struct ImagePreviewView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var pinchBase: CGFloat = 1.0
    @State private var isPinching = false

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
                        let displayImage = (viewModel.isShowingBefore ? viewModel.originalPreviewImage : nil)
                            ?? cgImage
                        let fittedSize = fittedImageSize(
                            imageSize: CGSize(width: CGFloat(displayImage.width), height: CGFloat(displayImage.height)),
                            viewSize: geometry.size
                        )
                        Image(decorative: displayImage, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(viewModel.zoom)
                            .offset(offset)
                            .gesture(dragGesture(fittedSize: fittedSize, viewSize: geometry.size))
                            .gesture(magnificationGesture(fittedSize: fittedSize, viewSize: geometry.size))
                            .onTapGesture(count: 2) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    viewModel.zoomToFit()
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
                            .onAppear { publishFitScale(displayImage: displayImage, viewSize: geometry.size) }
                            .onChange(of: geometry.size) { publishFitScale(displayImage: displayImage, viewSize: geometry.size) }
                            .onChange(of: viewModel.imageLoadCount) { publishFitScale(displayImage: displayImage, viewSize: geometry.size) }
                            .onChange(of: viewModel.zoom) {
                                offset = constrainOffset(fittedSize: fittedSize, viewSize: geometry.size)
                                lastOffset = offset
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
        .overlay(alignment: .bottomTrailing) {
            if viewModel.previewImage != nil && !viewModel.isCropMode {
                zoomControl
                    .padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.isCropMode {
                cropToolbar
                    .padding(.bottom, 16)
            }
        }
        .onChange(of: viewModel.currentFileURL) {
            withAnimation(.easeOut(duration: 0.2)) {
                offset = .zero
                lastOffset = .zero
            }
        }
    }

    // MARK: - Zoom control

    private var zoomControl: some View {
        HStack(spacing: 8) {
            Button { viewModel.zoomToFit() } label: { Text("Fit") }
                .buttonStyle(.plain)
                .help("Fit to window (⌘0)")

            Divider().frame(height: 12)

            Button { viewModel.zoomOut() } label: { Image(systemName: "minus") }
                .buttonStyle(.plain)
                .help("Zoom out (⌘−)")

            Text("\(viewModel.zoomPercent)%")
                .font(.caption.monospacedDigit())
                .frame(width: 42)

            Button { viewModel.zoomIn() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("Zoom in (⌘+)")

            Divider().frame(height: 12)

            Button { viewModel.zoomToActual() } label: { Text("100%") }
                .buttonStyle(.plain)
                .help("Actual size (⌘1)")
        }
        .font(.caption)
        .foregroundStyle(Color.filmdevText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Crop toolbar

    private var cropToolbar: some View {
        @Bindable var vm = viewModel
        return VStack(spacing: 12) {
            AdjustmentSlider(
                label: "Straighten",
                value: $vm.pendingStraightenAngle,
                range: -0.2618...0.2618,   // ±15°
                format: "°",
                defaultValue: 0,
                onDragChanged: { viewModel.updatePreview() },
                onDragEnded: { viewModel.updatePreview() }
            )
            .frame(width: 360)

            HStack(spacing: 16) {
                Picker("Aspect", selection: $vm.cropAspectRatio) {
                    ForEach(CropAspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                if viewModel.editState.cropRect != nil || viewModel.editState.straightenAngle != 0 {
                    Button("Clear") {
                        viewModel.clearCrop()
                    }
                    .buttonStyle(.bordered)
                    .help("Remove the crop and straighten")
                }

                Button("Cancel") {
                    viewModel.cancelCrop()
                }
                .buttonStyle(.bordered)
                .help("Cancel (Esc)")

                Button("Apply") {
                    viewModel.applyCrop()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.filmdevAccent)
                .help("Apply (Return)")
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Geometry

    private func fittedImageSize(imageSize: CGSize, viewSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = viewSize.width / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        let fitScale = min(scaleX, scaleY)
        return CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
    }

    /// Tells the view model what zoom value corresponds to 100% (pixel-accurate)
    /// for the current image and view size.
    private func publishFitScale(displayImage: CGImage, viewSize: CGSize) {
        let fitted = fittedImageSize(
            imageSize: CGSize(width: CGFloat(displayImage.width), height: CGFloat(displayImage.height)),
            viewSize: viewSize
        )
        guard fitted.width > 0 else { return }
        viewModel.fitToActualScale = CGFloat(displayImage.width) / fitted.width
    }

    private func constrainOffset(fittedSize: CGSize, viewSize: CGSize) -> CGSize {
        let scaledWidth = fittedSize.width * viewModel.zoom
        let scaledHeight = fittedSize.height * viewModel.zoom

        let maxOffsetX = max(0, (scaledWidth - viewSize.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - viewSize.height) / 2)

        return CGSize(
            width: max(-maxOffsetX, min(maxOffsetX, offset.width)),
            height: max(-maxOffsetY, min(maxOffsetY, offset.height))
        )
    }

    private func dragGesture(fittedSize: CGSize, viewSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = constrainOffset(fittedSize: fittedSize, viewSize: viewSize)
            }
            .onEnded { _ in
                offset = constrainOffset(fittedSize: fittedSize, viewSize: viewSize)
                lastOffset = offset
            }
    }

    private func magnificationGesture(fittedSize: CGSize, viewSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // Accumulate from the zoom at the start of this pinch session so
                // repeated pinches compound instead of snapping back to the value.
                if !isPinching {
                    isPinching = true
                    pinchBase = viewModel.zoom
                }
                viewModel.zoom = max(0.5, min(viewModel.maxZoom, pinchBase * value))
                offset = constrainOffset(fittedSize: fittedSize, viewSize: viewSize)
                lastOffset = offset
            }
            .onEnded { _ in
                isPinching = false
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
