import SwiftUI
import os

@main
struct FilmDevApp: App {
    @State private var viewModel = EditorViewModel()
    @State private var presetViewModel = PresetViewModel()
    @State private var fileBrowserViewModel = FileBrowserViewModel()
    @State private var showExportSheet = false
    @State private var showBatchExportSheet = false

    private static let logger = Logger(subsystem: "com.filmdev.app", category: "fonts")

    init() {
        // Register the DSEG7 quartz-date font so the optional export stamp renders
        // in the right typeface. Failure is non-fatal: the export just skips the
        // stamp rather than falling back to a wrong font.
        if !DateStamp.registerFont() {
            Self.logger.error("DSEG7 date-stamp font failed to register; date stamp will be unavailable")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(presetViewModel)
                .environment(fileBrowserViewModel)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 600)
                .sheet(isPresented: $showExportSheet) {
                    ExportSheet()
                        .environment(viewModel)
                }
                .sheet(isPresented: $showBatchExportSheet) {
                    BatchExportSheet()
                        .environment(viewModel)
                        .environment(presetViewModel)
                        .environment(fileBrowserViewModel)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open...") {
                    viewModel.openFile { url in
                        fileBrowserViewModel.enterEditMode(url: url)
                    }
                }
                .keyboardShortcut("o")

                Button("Open Folder...") {
                    fileBrowserViewModel.openDirectory()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Export...") {
                    showExportSheet = true
                }
                .keyboardShortcut("s")
                .disabled(viewModel.previewImage == nil)

                Button("Batch Export...") {
                    showBatchExportSheet = true
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(fileBrowserViewModel.files.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    viewModel.undo()
                }
                .keyboardShortcut("z")
                .disabled(!viewModel.canUndo)

                Button("Redo") {
                    viewModel.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!viewModel.canRedo)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    viewModel.zoomIn()
                }
                .keyboardShortcut("+")
                .disabled(viewModel.previewImage == nil)

                Button("Zoom Out") {
                    viewModel.zoomOut()
                }
                .keyboardShortcut("-")
                .disabled(viewModel.previewImage == nil)

                Button("Zoom to Fit") {
                    viewModel.zoomToFit()
                }
                .keyboardShortcut("0")
                .disabled(viewModel.previewImage == nil)

                Button("Actual Size") {
                    viewModel.zoomToActual()
                }
                .keyboardShortcut("1")
                .disabled(viewModel.previewImage == nil)

                Divider()
            }
        }
    }
}
