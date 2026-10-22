import SwiftUI

struct FileBrowserSidebarView: View {
    @Environment(FileBrowserViewModel.self) private var viewModel
    @Environment(EditorViewModel.self) private var editorViewModel

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedFile },
            set: { viewModel.selectedFile = $0 }
        )) {
            if viewModel.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(Color.filmdevTextSecondary)
                    Text("Open a folder")
                        .foregroundStyle(.secondary)
                    Button("Open Folder...") {
                        viewModel.openDirectory()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.filmdevAccent)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                if let dir = viewModel.currentDirectory {
                    Section(dir.lastPathComponent) {
                        directoryList
                    }
                } else {
                    directoryList
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var directoryList: some View {
        // Parent directory navigation
        if let dir = viewModel.currentDirectory, dir.pathComponents.count > 1 {
            Button {
                viewModel.loadDirectory(dir.deletingLastPathComponent())
            } label: {
                Label("..", systemImage: "arrow.up.doc")
                    .foregroundStyle(Color.filmdevTextSecondary)
            }
            .buttonStyle(.plain)
        }

        // Directories first
        ForEach(viewModel.directories) { item in
            Label(item.name, systemImage: "folder")
                .onTapGesture {
                    viewModel.loadDirectory(item.url)
                }
        }

        // Image files (sorted/filtered to match the contact sheet)
        ForEach(viewModel.imageItems) { file in
            HStack(spacing: 6) {
                Image(systemName: fileIcon(for: file.url))
                    .foregroundStyle(Color.filmdevTextSecondary)
                    .frame(width: 16)
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if file.hasSidecar {
                    Circle()
                        .fill(Color.filmdevAccent)
                        .frame(width: 6, height: 6)
                        .help("Has saved edits")
                }
            }
            .tag(file)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                viewModel.enterEditMode(file: file)
                editorViewModel.loadImage(from: file.url)
            }
            .onTapGesture(count: 1) {
                viewModel.selectedFile = file
            }
        }
    }

    private func fileIcon(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let rawExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "dng", "orf", "rw2"]
        return rawExtensions.contains(ext) ? "camera.aperture" : "photo"
    }

}
