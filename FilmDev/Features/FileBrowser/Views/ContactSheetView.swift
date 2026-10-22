import SwiftUI

struct ContactSheetView: View {
    @Environment(FileBrowserViewModel.self) private var viewModel
    @Environment(EditorViewModel.self) private var editorViewModel

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        Group {
            if viewModel.files.isEmpty {
                emptyState
            } else {
                // Resolve the sorted/filtered list once per render instead of
                // re-sorting for both the count and the grid.
                let items = viewModel.imageItems
                VStack(spacing: 0) {
                    controlBar(count: items.count)
                    Divider().background(Color.filmdevBorder)
                    grid(items: items)
                }
            }
        }
        .background(Color.filmdevBackground)
    }

    private func controlBar(count: Int) -> some View {
        @Bindable var vm = viewModel
        return HStack(spacing: 12) {
            Text("\(count) photos")
                .font(.caption)
                .foregroundStyle(Color.filmdevTextSecondary)

            Spacer()

            Toggle(isOn: $vm.showEditedOnly) {
                Label("Edited only", systemImage: "circle.fill")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show only photos with saved edits")

            Picker("Sort", selection: $vm.sortOrder) {
                ForEach(FileBrowserViewModel.SortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .help("Sort order")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func grid(items: [FileBrowserViewModel.FileItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { file in
                    ThumbnailGridItem(
                        url: file.url,
                        name: file.name,
                        isSelected: viewModel.selectedFile == file,
                        hasSidecar: file.hasSidecar
                    )
                    .onTapGesture(count: 2) {
                        viewModel.enterEditMode(file: file)
                        editorViewModel.loadImage(from: file.url)
                    }
                    .onTapGesture(count: 1) {
                        viewModel.selectedFile = file
                    }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(Color.filmdevTextSecondary)

            Text("Open a folder to browse images")
                .font(.title3)
                .foregroundStyle(Color.filmdevTextSecondary)

            Text("Cmd+Shift+O to open a folder")
                .font(.caption)
                .foregroundStyle(Color.filmdevTextSecondary.opacity(0.7))

            Button("Open Folder...") {
                viewModel.openDirectory()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.filmdevAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
