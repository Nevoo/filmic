import SwiftUI
import CoreImage
import UniformTypeIdentifiers

@Observable
@MainActor
final class EditorViewModel {
    // State
    var editState = EditState()
    var previewImage: CGImage?
    var histogramImage: CGImage?
    var isLoading = false
    var isDragging = false
    var errorMessage: String?
    var currentFileURL: URL?
    var windowTitle: String = "FilmDev"
    var rawImage: CIImage?
    var imageLoadCount = 0

    // Crop
    var isCropMode = false
    var cropAspectRatio: CropAspectRatio = .free
    var pendingCropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    // Before/After
    var isShowingBefore = false
    var originalPreviewImage: CGImage?

    // Undo/Redo
    private(set) var canUndo = false
    private(set) var canRedo = false
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []

    // Private
    private let ciContext: CIContext
    private let rawDecoder: RAWDecoder
    private let imageProcessor: ImageProcessor
    private let exportService: ExportService
    private var renderTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    private var wbDebounceTask: Task<Void, Never>?

    init() {
        let context = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true
        ])
        self.ciContext = context
        self.rawDecoder = RAWDecoder(context: context)
        self.imageProcessor = ImageProcessor(context: context)
        self.exportService = ExportService(context: context)
    }

    // MARK: - File Operations

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .rawImage,
            .image
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a RAW image file"

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let url = panel.url
            Task { @MainActor in
                guard let url else { return }
                self?.loadImage(from: url)
            }
        }
    }

    func loadImage(from url: URL) {
        isLoading = true
        errorMessage = nil
        currentFileURL = url
        windowTitle = url.lastPathComponent
        editState.reset()
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false
        originalPreviewImage = nil

        let decoder = rawDecoder
        let processor = imageProcessor
        Task.detached {
            do {
                let decoded = try decoder.decode(url: url)
                // Render original (unedited) preview for before/after
                let originalRendered = processor.render(image: decoded)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.rawImage = decoded
                    self.originalPreviewImage = originalRendered
                    self.isLoading = false
                    self.imageLoadCount += 1
                    self.updatePreview()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.isLoading = false
                }
            }
        }
    }

    // MARK: - Preview Rendering

    func updatePreview() {
        renderTask?.cancel()

        guard let rawImage else { return }

        let state = editState
        let scale: CGFloat = isDragging ? previewScale(for: rawImage) : 1.0
        let processor = imageProcessor
        let dragging = isDragging

        renderTask = Task.detached {
            let processed = processor.process(image: rawImage, editState: state, isDragging: dragging)
            let rendered = processor.render(image: processed, scale: scale)

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.previewImage = rendered
                if !self.isDragging {
                    self.updateHistogram(processed: processed)
                }
            }
        }
    }

    private func updateHistogram(processed: CIImage) {
        histogramTask?.cancel()
        let processor = imageProcessor
        histogramTask = Task.detached {
            let histogram = processor.generateHistogram(from: processed)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.histogramImage = histogram
            }
        }
    }

    func onSliderDragChanged() {
        if !isDragging {
            commitState() // Capture pre-change state on first drag event
        }
        isDragging = true
        updatePreview()
    }

    func onSliderDragEnded() {
        isDragging = false
        updatePreview()
    }

    // MARK: - White Balance

    func onWBDragChanged() {
        if !isDragging {
            commitState() // Capture pre-change state on first drag event
        }
        isDragging = true
        wbDebounceTask?.cancel()
        wbDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            reDecodeRAW()
        }
    }

    func onWBDragEnded() {
        isDragging = false
        wbDebounceTask?.cancel()
        reDecodeRAW()
    }

    private func reDecodeRAW() {
        guard let url = currentFileURL else { return }
        let decoder = rawDecoder
        let temperature = editState.temperature
        let tint = editState.tint

        Task.detached {
            do {
                let decoded = try decoder.decode(url: url, temperature: temperature, tint: tint)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.rawImage = decoded
                    self.updatePreview()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Undo/Redo

    func commitState() {
        undoStack.append(editState)
        redoStack.removeAll()
        // Cap stack at 50 entries
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(editState)
        let wbChanged = editState.temperature != previous.temperature || editState.tint != previous.tint
        editState = previous
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if wbChanged {
            reDecodeRAW()
        } else {
            updatePreview()
        }
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(editState)
        let wbChanged = editState.temperature != next.temperature || editState.tint != next.tint
        editState = next
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if wbChanged {
            reDecodeRAW()
        } else {
            updatePreview()
        }
    }

    // MARK: - LUT Application

    func applyPreset(_ preset: FilmPreset) {
        commitState() // Capture pre-change state before modifying
        if editState.activeLUTName == preset.name {
            editState.activeLUTName = nil
            editState.activeLUTData = nil
            editState.activeLUTSize = nil
        } else {
            editState.activeLUTName = preset.name
            editState.activeLUTData = preset.lutData
            editState.activeLUTSize = preset.lutSize
        }
        updatePreview()
    }

    // MARK: - Export

    func exportImage(settings: ExportSettings) {
        guard let rawImage else { return }

        let panel = NSSavePanel()
        let contentType: UTType = switch settings.format {
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        case .heif: .heic
        }
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = exportFileName(settings: settings)
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let url = panel.url
            Task { @MainActor in
                guard let self, let url else { return }
                self.isLoading = true
                let currentEditState = self.editState
                let processor = self.imageProcessor
                let exporter = self.exportService
                Task.detached {
                    let processed = processor.process(image: rawImage, editState: currentEditState)
                    do {
                        try exporter.export(image: processed, to: url, settings: settings)
                        await MainActor.run { [weak self] in
                            self?.isLoading = false
                        }
                    } catch {
                        await MainActor.run { [weak self] in
                            self?.errorMessage = error.localizedDescription
                            self?.isLoading = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Crop

    func toggleCropMode() {
        isCropMode.toggle()
        if isCropMode {
            // Initialize pending crop to existing crop or full image
            if let existing = editState.cropRect {
                pendingCropRect = existing.cgRect
            } else {
                pendingCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }
    }

    func applyCrop() {
        commitState()
        let rect = pendingCropRect
        // Only apply if it's not the full image
        if rect.origin.x > 0.001 || rect.origin.y > 0.001 ||
           rect.width < 0.999 || rect.height < 0.999 {
            editState.cropRect = CodableRect(rect)
        } else {
            editState.cropRect = nil
        }
        isCropMode = false
        updatePreview()
    }

    func cancelCrop() {
        isCropMode = false
    }

    func clearCrop() {
        editState.cropRect = nil
        isCropMode = false
        updatePreview()
    }

    // MARK: - Helpers

    private func previewScale(for image: CIImage) -> CGFloat {
        let maxDimension = max(image.extent.width, image.extent.height)
        if maxDimension > 2000 {
            return 2000.0 / maxDimension
        }
        return 1.0
    }

    private func exportFileName(settings: ExportSettings) -> String {
        guard let url = currentFileURL else { return "export.\(settings.format.fileExtension)" }
        let baseName = url.deletingPathExtension().lastPathComponent
        let lutSuffix = editState.activeLUTName.map { "_\($0)" } ?? ""
        return "\(baseName)\(lutSuffix).\(settings.format.fileExtension)"
    }
}
