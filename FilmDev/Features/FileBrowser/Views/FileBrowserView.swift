import SwiftUI

struct FileBrowserView: View {
    @Environment(FileBrowserViewModel.self) private var viewModel

    var body: some View {
        List {
            if viewModel.files.isEmpty {
                Text("Open a folder to browse images")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.files) { file in
                    Label(file.name, systemImage: file.isDirectory ? "folder" : "photo")
                }
            }
        }
        .listStyle(.sidebar)
    }
}
