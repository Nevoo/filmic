import SwiftUI
import CoreImage
import UniformTypeIdentifiers

@Observable
@MainActor
final class EditorViewModel {
    // State
    var editState = EditState()
    var previewImage: CGImage?
    var histogramData: HistogramData?
    var isLoading = false
    var isDragging = false
    var errorMessage: String?
    var currentFileURL: URL?
    var windowTitle: String = "FilmDev"
    var rawImage: CIImage?
    var imageLoadCount = 0

    @ObservationIgnored
    @AppStorage("defaultPresetName") var defaultPresetName: String = ""

    // Crop
    var isCropMode = false
    var cropAspectRatio: CropAspectRatio = .free
    var pendingCropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var pendingStraightenAngle: Double = 0  // radians; previewed live, committed on Apply

    // Before/After
    var isShowingBefore = false
    var originalPreviewImage: CGImage?

    // Zoom (1.0 = fit-to-view; the view publishes `fitToActualScale`, the zoom
    // value that maps image pixels 1:1 so "100%" is reachable on any image size).
    var zoom: CGFloat = 1.0
    var fitToActualScale: CGFloat = 1.0
    var maxZoom: CGFloat { max(8, fitToActualScale) }
    var zoomPercent: Int {
        fitToActualScale > 0 ? Int((zoom / fitToActualScale) * 100) : Int(zoom * 100)
    }
    func zoomIn() { zoom = min(maxZoom, zoom * 1.3) }
    func zoomOut() { zoom = max(0.5, zoom / 1.3) }
    func zoomToFit() { zoom = 1.0 }
    func zoomToActual() { zoom = max(0.5, min(maxZoom, fitToActualScale)) }

    // Undo/Redo
    private(set) var canUndo = false
    private(set) var canRedo = false
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []

    // Auto-edit. The analyzer measures each decoded frame once; PresetIntent
    // turns those measurements into per-stock starting trims for the fields
    // still owned by auto (EditState.autoFields). `lastAutoApplied` remembers
    // what auto last wrote so a hand-moved slider can be detected and the
    // field demoted to manual.
    private(set) var imageAnalysis: ImageAnalysis?
    private var lastAutoApplied: [EditState.EditField: Double] = [:]

    // Private
    private let ciContext: CIContext
    private let rawDecoder: RAWDecoder
    private let imageProcessor: ImageProcessor
    private let exportService: ExportService
    private let imageAnalyzer: ImageAnalyzer
    private var renderTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    private var wbDebounceTask: Task<Void, Never>?
    private var sidecarSaveTask: Task<Void, Never>?

    /// Target long-edge in pixels during slider drag. Beyond this, downscale
    /// so 60MP files don't stall the UI.
    private let dragPreviewLongEdge: CGFloat = 1600

    init() {
        let context = FilmColorPipeline.makeContext(highQualityDownsample: true)
        self.ciContext = context
        self.rawDecoder = RAWDecoder(context: context)
        self.imageProcessor = ImageProcessor(context: context)
        self.exportService = ExportService(context: context)
        self.imageAnalyzer = ImageAnalyzer(context: context)
    }

    // MARK: - File Operations

    /// Presents an open panel and loads the chosen file. `onOpen` fires after the
    /// load is kicked off so the caller can move the UI into edit mode — Cmd+O
    /// otherwise loads an image while the app stays stuck on the contact sheet.
    func openFile(onOpen: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a RAW image file"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.loadImage(from: url)
                onOpen?(url)
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
        zoom = 1.0

        let sidecarState = loadSidecar(for: url)
        imageAnalysis = nil
        lastAutoApplied = [:]

        let decoder = rawDecoder
        let processor = imageProcessor
        let analyzer = imageAnalyzer
        Task.detached {
            do {
                let result = try decoder.load(url: url)
                let asShotWB = result.asShotWB
                let originalRendered = processor.render(image: result.image)
                let analysis = analyzer.analyze(image: result.image)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.rawImage = result.image
                    self.originalPreviewImage = originalRendered
                    self.imageAnalysis = analysis
                    self.isLoading = false
                    self.imageLoadCount += 1

                    if var restored = sidecarState {
                        // Persisted values are the truth for reopened images;
                        // auto only re-derives on look changes from here on.
                        restored.reloadLUTIfNeeded()
                        self.editState = restored
                        for field in restored.autoFields {
                            self.lastAutoApplied[field] = restored[field]
                        }
                    } else {
                        self.editState.temperature = asShotWB.temperature
                        self.editState.tint = asShotWB.tint
                        // Fresh image: every auto-managed field starts auto.
                        self.editState.autoFields = Set(EditState.EditField.allCases)
                        self.applyAutoTrims(to: &self.editState)
                    }

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

    func applyDefaultPresetIfNeeded(presets: [FilmPreset]) {
        guard editState.activeLUTData == nil,
              !defaultPresetName.isEmpty,
              let preset = presets.first(where: { $0.name == defaultPresetName }) else { return }
        applyPreset(preset)
    }

    func setDefaultPreset(_ name: String?) {
        defaultPresetName = name ?? ""
    }

    // MARK: - Preview Rendering

    func updatePreview() {
        renderTask?.cancel()

        guard let rawImage else { return }

        var state = editState
        if isCropMode {
            // Show the full (uncropped) frame with the pending straighten so the
            // crop overlay sits on the same geometry that Apply will commit.
            state.cropRect = nil
            state.straightenAngle = pendingStraightenAngle
        }
        let processor = imageProcessor
        let dragging = isDragging
        let scale = dragging ? dragScale(for: rawImage) : 1.0
        let grainSeed = grainSeed(for: currentFileURL)

        renderTask = Task.detached {
            let processed = processor.process(image: rawImage, editState: state, isDragging: dragging, grainSeed: grainSeed)
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

    private func dragScale(for image: CIImage) -> CGFloat {
        let longEdge = max(image.extent.width, image.extent.height)
        guard longEdge > dragPreviewLongEdge else { return 1.0 }
        return dragPreviewLongEdge / longEdge
    }

    private func updateHistogram(processed: CIImage) {
        histogramTask?.cancel()
        let processor = imageProcessor
        histogramTask = Task.detached {
            let histogram = processor.generateHistogram(from: processed)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.histogramData = histogram
            }
        }
    }

    func onSliderDragChanged() {
        if !isDragging {
            commitState()
        }
        isDragging = true
        updatePreview()
    }

    func onSliderDragEnded() {
        isDragging = false
        demoteManuallyEditedFields()
        updatePreview()
        scheduleSidecarSave()
    }

    func beginDirectEdit() {
        if !isDragging {
            commitState()
        }
        isDragging = true
    }

    func directEditChanged() {
        updatePreview()
    }

    func endDirectEdit() {
        isDragging = false
        demoteManuallyEditedFields()
        updatePreview()
        scheduleSidecarSave()
    }

    // MARK: - White Balance
    //
    // WB changes apply a CITemperatureAndTint shift on the cached libraw decode
    // so we keep the decode warm across temperature/tint drags. The drag-time
    // preview downscale keeps re-renders cheap even on 60MP files; a small
    // debounce smooths slider input.

    func onWBDragChanged() {
        if !isDragging {
            commitState()
        }
        isDragging = true
        wbDebounceTask?.cancel()
        wbDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            reDecodeWB()
        }
    }

    func onWBDragEnded() {
        isDragging = false
        wbDebounceTask?.cancel()
        reDecodeWB()
        scheduleSidecarSave()
    }

    private func reDecodeWB() {
        guard let warmed = rawDecoder.updateWB(
            temperature: editState.temperature,
            tint: editState.tint
        ) else { return }
        rawImage = warmed
        updatePreview()
    }

    // MARK: - Undo/Redo
    //
    // Snapshots drop heavy LUT bytes; reloadLUTIfNeeded() rehydrates on restore.

    func commitState() {
        var snapshot = editState
        snapshot.activeLUTData = nil
        snapshot.activeLUTSize = nil
        undoStack.append(snapshot)
        redoStack.removeAll()
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    func undo() {
        guard var previous = undoStack.popLast() else { return }
        var redoSnapshot = editState
        redoSnapshot.activeLUTData = nil
        redoSnapshot.activeLUTSize = nil
        redoStack.append(redoSnapshot)

        previous.reloadLUTIfNeeded()
        let wbChanged = editState.temperature != previous.temperature || editState.tint != previous.tint
        editState = previous
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if wbChanged {
            reDecodeWB()
        } else {
            updatePreview()
        }
    }

    func redo() {
        guard var next = redoStack.popLast() else { return }
        var undoSnapshot = editState
        undoSnapshot.activeLUTData = nil
        undoSnapshot.activeLUTSize = nil
        undoStack.append(undoSnapshot)

        next.reloadLUTIfNeeded()
        let wbChanged = editState.temperature != next.temperature || editState.tint != next.tint
        editState = next
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if wbChanged {
            reDecodeWB()
        } else {
            updatePreview()
        }
    }

    // MARK: - LUT Application

    func applyPreset(_ preset: FilmPreset) {
        if editState.activeLUTName == preset.name {
            clearActiveLUT()
        } else {
            mutate {
                $0.apply(preset: preset)
                // Roll the one-shot leak presence for this image+stock. The URL
                // is known here (apply(preset:) has none), so the outcome is
                // deterministic per image and then persisted in the sidecar.
                $0.rollLeak(imageIdentity: currentFileURL?.lastPathComponent ?? "", preset: preset)
                // Auto-owned trims re-derive for the new stock; manual trims persist.
                applyAutoTrims(to: &$0)
            }
        }
    }

    /// Rerolls the light leak's shape and colour. A discrete, undoable edit —
    /// `mutate` snapshots for undo, re-renders, and schedules a sidecar save,
    /// exactly like any other single edit.
    func rerollLeak() {
        guard editState.leakIntensity > 0 else { return }
        mutate { $0.leakVariant += 1 }
    }

    /// Clears the active film look. Public so a "None" preset card can call it.
    func clearActiveLUT() {
        guard editState.activeLUTName != nil else { return }
        mutate {
            $0.activeLUTName = nil
            $0.activeLUTData = nil
            $0.activeLUTSize = nil
            $0.activeLUTCategory = nil
            $0.lutIntensity = 1.0
            applyAutoTrims(to: &$0)
        }
    }

    // MARK: - Auto trims

    /// Stamps analyzer-derived trims for the state's active look onto the
    /// fields still owned by auto, and records what was written so manual
    /// divergence can be detected later.
    private func applyAutoTrims(to state: inout EditState) {
        guard let analysis = imageAnalysis else { return }
        let fileName = state.activeLUTName.map { $0.replacingOccurrences(of: " ", with: "_") }
        let trims = PresetIntent.trims(for: analysis, presetFileName: fileName)
        state.applyAutoTrims(trims)
        for field in state.autoFields {
            lastAutoApplied[field] = state[field]
        }
    }

    /// Any auto field whose value no longer matches what auto wrote was moved
    /// by hand — demote it to manual so re-derives never clobber it.
    private func demoteManuallyEditedFields() {
        for field in editState.autoFields {
            if let autoValue = lastAutoApplied[field],
               abs(editState[field] - autoValue) > 0.0001 {
                editState.autoFields.remove(field)
            }
        }
    }

    // MARK: - Edit Transactions / Group Resets

    /// Runs one edit as a transaction: snapshot for undo, apply the mutation,
    /// re-render (re-decoding the RAW when white balance changed), and schedule a
    /// sidecar save. The single envelope every discrete edit shares.
    private func mutate(_ body: (inout EditState) -> Void) {
        commitState()
        let oldTemperature = editState.temperature
        let oldTint = editState.tint
        body(&editState)
        if editState.temperature != oldTemperature || editState.tint != oldTint {
            reDecodeWB()
        } else {
            updatePreview()
        }
        scheduleSidecarSave()
    }

    func resetAll() { mutate { $0 = EditState() } }
    func resetToneGroup() { mutate { $0.resetTone() } }
    func resetColorGroup() { mutate { $0.resetColor() } }
    func resetEffectsGroup() { mutate { $0.resetEffects() } }

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
                let sourceURL = self.currentFileURL
                let grainSeed = self.grainSeed(for: self.currentFileURL)
                Task.detached {
                    let processed = processor.process(image: rawImage, editState: currentEditState, grainSeed: grainSeed)
                    do {
                        try exporter.export(image: processed, to: url, settings: settings, sourceURL: sourceURL)
                        await MainActor.run { [weak self] in
                            self?.isLoading = false
                            NSWorkspace.shared.activateFileViewerSelecting([url])
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
            if let existing = editState.cropRect {
                pendingCropRect = existing.cgRect
            } else {
                pendingCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
            pendingStraightenAngle = editState.straightenAngle
        }
        updatePreview()
    }

    func applyCrop() {
        commitState()
        editState.straightenAngle = pendingStraightenAngle
        let rect = pendingCropRect
        if rect.origin.x > 0.001 || rect.origin.y > 0.001 ||
           rect.width < 0.999 || rect.height < 0.999 {
            editState.cropRect = CodableRect(rect)
        } else {
            editState.cropRect = nil
        }
        isCropMode = false
        scheduleSidecarSave()
        updatePreview()
    }

    func cancelCrop() {
        isCropMode = false
        // Re-render with the saved crop restored (crop mode renders uncropped).
        updatePreview()
    }

    /// Clears the crop and straighten together (the geometry transaction).
    func clearCrop() {
        guard editState.cropRect != nil || editState.straightenAngle != 0 else {
            pendingStraightenAngle = 0
            isCropMode = false
            updatePreview()
            return
        }
        commitState()
        editState.cropRect = nil
        editState.straightenAngle = 0
        pendingStraightenAngle = 0
        isCropMode = false
        scheduleSidecarSave()
        updatePreview()
    }

    // MARK: - Batch Export

    /// Batch-exports `files`. Each file's `.filmdev` sidecar edits are applied
    /// (neutral when absent), so prior per-image work is honored. When `preset`
    /// is set its film look is layered on top, preserving each file's exposure/WB
    /// trims. Runs in the calling (structured) task so cancelling that task stops
    /// the run between files; heavy per-file work is offloaded to a detached task.
    func batchExport(
        files: [URL],
        preset: FilmPreset?,
        settings: ExportSettings,
        destination: URL?,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        let processor = imageProcessor
        let exporter = exportService

        for (index, fileURL) in files.enumerated() {
            try Task.checkCancellation()

            let grainSeed = grainSeed(for: fileURL)
            try await Task.detached {
                // Fresh decoder per file so its cached libraw decode doesn't get
                // reused across unrelated URLs.
                let context = FilmColorPipeline.makeContext()
                let decoder = RAWDecoder(context: context)
                let result = try decoder.load(url: fileURL)

                var editState = Self.loadSidecarState(for: fileURL) ?? {
                    var fresh = EditState()
                    fresh.autoFields = Set(EditState.EditField.allCases)
                    return fresh
                }()
                if let preset {
                    editState.apply(preset: preset)
                    // Same one-shot leak roll the editor does, seeded per file so
                    // a batch stays reproducible and only some frames earn a leak.
                    editState.rollLeak(imageIdentity: fileURL.lastPathComponent, preset: preset)
                }
                // Files without hand edits get the same auto-develop the
                // editor would produce: analyze, then derive per-stock trims
                // for whatever fields auto still owns.
                if !editState.autoFields.isEmpty,
                   let analysis = ImageAnalyzer(context: context).analyze(image: result.image) {
                    let lutFileName = editState.activeLUTName.map { $0.replacingOccurrences(of: " ", with: "_") }
                    editState.applyAutoTrims(PresetIntent.trims(for: analysis, presetFileName: lutFileName))
                }

                let processed = processor.process(image: result.image, editState: editState, grainSeed: grainSeed)

                let baseName = fileURL.deletingPathExtension().lastPathComponent
                let suffix = preset.map { "_\($0.name.replacingOccurrences(of: " ", with: "_"))" } ?? ""
                let outputDir = destination ?? fileURL.deletingLastPathComponent()
                let outputURL = outputDir
                    .appendingPathComponent("\(baseName)\(suffix).\(settings.format.fileExtension)")

                try exporter.export(image: processed, to: outputURL, settings: settings, sourceURL: fileURL)
            }.value

            progress(index + 1, files.count)
        }
    }

    // MARK: - Helpers

    /// Deterministic per-image grain seed, derived from the file name so the
    /// grain field is unique per photo yet reproducible across launches and
    /// exports. A nil URL yields 0 (grain-neutral, pre-seed output).
    private func grainSeed(for url: URL?) -> UInt64 {
        guard let url else { return 0 }
        return StableHash.seed(for: url.lastPathComponent)
    }

    private func exportFileName(settings: ExportSettings) -> String {
        guard let url = currentFileURL else { return "export.\(settings.format.fileExtension)" }
        let baseName = url.deletingPathExtension().lastPathComponent
        let lutSuffix = editState.activeLUTName.map { "_\($0)" } ?? ""
        return "\(baseName)\(lutSuffix).\(settings.format.fileExtension)"
    }

    // MARK: - Sidecar

    /// The `.filmdev` sidecar location for an image. Single source of the naming
    /// convention, shared by the editor, batch export, and the file browser.
    nonisolated static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("filmdev")
    }

    private func loadSidecar(for imageURL: URL) -> EditState? {
        Self.loadSidecarState(for: imageURL)
    }

    /// Loads sidecar edits off the main actor (used by batch export). Rehydrates
    /// the LUT bytes since sidecars only persist the LUT name/category.
    nonisolated static func loadSidecarState(for imageURL: URL) -> EditState? {
        let url = sidecarURL(for: imageURL)
        guard let data = try? Data(contentsOf: url),
              var state = try? JSONDecoder().decode(EditState.self, from: data) else {
            return nil
        }
        state.reloadLUTIfNeeded()
        return state
    }

    func scheduleSidecarSave() {
        sidecarSaveTask?.cancel()
        sidecarSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.saveSidecar()
        }
    }

    private func saveSidecar() {
        guard let imageURL = currentFileURL, !editState.isDefault else {
            if let imageURL = currentFileURL {
                try? FileManager.default.removeItem(at: Self.sidecarURL(for: imageURL))
            }
            return
        }
        let url = Self.sidecarURL(for: imageURL)
        guard let data = try? JSONEncoder().encode(editState) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
