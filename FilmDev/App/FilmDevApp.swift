import SwiftUI

@main
struct FilmDevApp: App {
    @State private var viewModel = EditorViewModel()
    @State private var presetViewModel = PresetViewModel()
    @State private var fileBrowserViewModel = FileBrowserViewModel()
    @State private var showExportSheet = false

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
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open...") {
                    viewModel.openFile()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Export...") {
                    showExportSheet = true
                }
                .keyboardShortcut("s")
                .disabled(viewModel.previewImage == nil)
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
        }
    }
}
