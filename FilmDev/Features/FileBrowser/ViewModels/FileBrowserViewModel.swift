import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class FileBrowserViewModel {
    var files: [FileItem] = []
    var selectedFile: FileItem?
    var currentDirectory: URL?

    struct FileItem: Identifiable, Hashable, Sendable {
        let id = UUID()
        let url: URL
        let name: String
        let isDirectory: Bool
        var thumbnail: CGImage?

        func hash(into hasher: inout Hasher) {
            hasher.combine(url)
        }

        static func == (lhs: FileItem, rhs: FileItem) -> Bool {
            lhs.url == rhs.url
        }
    }

    func openDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing RAW images"

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let url = panel.url
            Task { @MainActor in
                guard let url else { return }
                self?.loadDirectory(url)
            }
        }
    }

    func loadDirectory(_ url: URL) {
        currentDirectory = url

        Task.detached {
            let rawExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "dng", "orf", "rw2"]
            let imageExtensions: Set<String> = rawExtensions.union(["jpg", "jpeg", "png", "tiff", "heic"])

            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey],
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run { [weak self] in
                    self?.files = []
                }
                return
            }

            let items = contents.compactMap { fileURL in
                let ext = fileURL.pathExtension.lowercased()
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

                if isDir || imageExtensions.contains(ext) {
                    return FileItem(
                        url: fileURL,
                        name: fileURL.lastPathComponent,
                        isDirectory: isDir
                    )
                }
                return nil
            }.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

            await MainActor.run { [weak self] in
                self?.files = items
            }
        }
    }
}
