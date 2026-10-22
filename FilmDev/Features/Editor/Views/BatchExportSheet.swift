import SwiftUI

struct BatchExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorViewModel.self) private var editorViewModel
    @Environment(PresetViewModel.self) private var presetViewModel
    @Environment(FileBrowserViewModel.self) private var fileBrowserViewModel

    @State private var selectedPreset: FilmPreset?
    @State private var settings = ExportSettings()
    @State private var destination: URL?
    @State private var isExporting = false
    @State private var progress: (current: Int, total: Int) = (0, 0)
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?

    private var imageFiles: [FileBrowserViewModel.FileItem] {
        fileBrowserViewModel.files.filter { !$0.isDirectory }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Batch Export")
                .font(.title2.bold())

            // File count
            HStack {
                Image(systemName: "photo.stack")
                Text("\(imageFiles.count) images in folder")
                Spacer()
            }
            .foregroundStyle(Color.filmdevTextSecondary)

            Divider()

            // Preset picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Film Simulation")
                    .font(.headline)

                Picker("Preset", selection: $selectedPreset) {
                    Text("Keep each photo's saved edits").tag(nil as FilmPreset?)
                    ForEach(presetViewModel.presets) { preset in
                        Text(preset.name).tag(preset as FilmPreset?)
                    }
                }
                .labelsHidden()

                Text(selectedPreset == nil
                     ? "Each photo exports with its own saved .filmdev edits (neutral if none)."
                     : "Applies this look to every photo, keeping each photo's saved exposure/WB trims.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Format settings
            VStack(alignment: .leading, spacing: 8) {
                Text("Format")
                    .font(.headline)

                Picker("Format", selection: $settings.format) {
                    ForEach(ExportSettings.ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                ExportQualityRow(settings: $settings)

                Toggle("Date stamp", isOn: $settings.dateStampEnabled)
                    .toggleStyle(.checkbox)
            }

            // Output folder
            VStack(alignment: .leading, spacing: 8) {
                Text("Output")
                    .font(.headline)
                HStack {
                    Text(destination?.path ?? "Alongside the originals")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if destination != nil {
                        Button("Reset") { destination = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.filmdevAccent)
                    }
                    Button("Choose…") { chooseDestination() }
                        .controlSize(.small)
                }
            }

            if isExporting {
                VStack(spacing: 8) {
                    ProgressView(value: Double(progress.current), total: Double(max(1, progress.total)))
                    Text("Exporting \(progress.current) of \(progress.total)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button(isExporting ? "Stop" : "Cancel") {
                    if isExporting {
                        exportTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export All") {
                    startBatchExport()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.filmdevAccent)
                .disabled(imageFiles.isEmpty || isExporting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 450, height: 560)
        .interactiveDismissDisabled(isExporting)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an output folder"
        if panel.runModal() == .OK {
            destination = panel.url
        }
    }

    private func startBatchExport() {
        isExporting = true
        errorMessage = nil
        let files = imageFiles.map(\.url)
        let preset = selectedPreset
        let exportSettings = settings
        let outputDir = destination

        exportTask = Task {
            do {
                try await editorViewModel.batchExport(
                    files: files,
                    preset: preset,
                    settings: exportSettings,
                    destination: outputDir,
                    progress: { current, total in
                        Task { @MainActor in
                            progress = (current, total)
                        }
                    }
                )
                let revealFolder = outputDir ?? files.first?.deletingLastPathComponent()
                if let revealFolder {
                    NSWorkspace.shared.activateFileViewerSelecting([revealFolder])
                }
                dismiss()
            } catch is CancellationError {
                isExporting = false
            } catch {
                errorMessage = error.localizedDescription
                isExporting = false
            }
        }
    }
}
