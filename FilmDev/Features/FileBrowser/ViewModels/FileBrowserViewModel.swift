import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import CoreImage

@Observable
@MainActor
final class FileBrowserViewModel {
    var files: [FileItem] = []
    var selectedFile: FileItem?
    var currentDirectory: URL?
    var editingFile: FileItem?
    var sortOrder: SortOrder = .name
    var showEditedOnly = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Name"
        case dateNewest = "Newest first"
        case dateOldest = "Oldest first"
        var id: String { rawValue }
    }

    struct FileItem: Identifiable, Hashable, Sendable {
        let id = UUID()
        let url: URL
        let name: String
        let isDirectory: Bool
        var date: Date?
        var hasSidecar: Bool = false

        func hash(into hasher: inout Hasher) {
            hasher.combine(url)
        }

        static func == (lhs: FileItem, rhs: FileItem) -> Bool {
            lhs.url == rhs.url
        }
    }

    var isEditing: Bool { editingFile != nil }

    /// Directories in the current folder (always sorted by name, shown first).
    var directories: [FileItem] {
        files.filter(\.isDirectory)
    }

    /// Image files with the active sort + filter applied. Both the sidebar and
    /// the contact sheet render from this so they stay in sync.
    var imageItems: [FileItem] {
        var items = files.filter { !$0.isDirectory }
        if showEditedOnly {
            items = items.filter(\.hasSidecar)
        }
        switch sortOrder {
        case .name:
            items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateNewest:
            items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .dateOldest:
            items.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        }
        return items
    }

    func enterEditMode(file: FileItem) {
        editingFile = file
        selectedFile = file
    }

    /// Enters edit mode for a file opened outside the folder browser (e.g. Cmd+O).
    /// FileItem equates by URL, so if the file is already in `files` this also
    /// lights up its selection in the sidebar/contact sheet.
    func enterEditMode(url: URL) {
        let item = files.first(where: { $0.url == url })
            ?? FileItem(url: url, name: url.lastPathComponent, isDirectory: false)
        editingFile = item
        selectedFile = item
    }

    func exitEditMode() {
        // Edits in the editor may have created/removed the sidecar; refresh that
        // one file's flag rather than re-stat'ing the whole folder on every render.
        if let edited = editingFile {
            refreshSidecarFlag(for: edited.url)
        }
        editingFile = nil
    }

    private func hasSidecar(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: EditorViewModel.sidecarURL(for: url).path)
    }

    /// Re-checks one file's cached sidecar flag (single filesystem stat).
    func refreshSidecarFlag(for url: URL) {
        guard let idx = files.firstIndex(where: { $0.url == url }) else { return }
        let exists = hasSidecar(for: url)
        if files[idx].hasSidecar != exists {
            files[idx].hasSidecar = exists
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
                includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run { [weak self] in
                    self?.files = []
                }
                return
            }

            // Sidecar presence is derived once here from the directory listing
            // (no per-file stat), then cached on each item so view bodies never
            // touch the filesystem.
            let sidecarStems = Set(
                contents
                    .filter { $0.pathExtension.lowercased() == "filmdev" }
                    .map { $0.deletingPathExtension().lastPathComponent }
            )

            let items = contents.compactMap { fileURL -> FileItem? in
                let ext = fileURL.pathExtension.lowercased()
                let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey])
                let isDir = values?.isDirectory ?? false

                if isDir || imageExtensions.contains(ext) {
                    return FileItem(
                        url: fileURL,
                        name: fileURL.lastPathComponent,
                        isDirectory: isDir,
                        date: values?.creationDate ?? values?.contentModificationDate,
                        hasSidecar: !isDir && sidecarStems.contains(fileURL.deletingPathExtension().lastPathComponent)
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

/// Generates and caches contact-sheet thumbnails on demand. Each grid cell
/// requests its own thumbnail (see `ThumbnailGridItem`), so only visible images
/// are decoded and each cell updates the instant its thumbnail is ready — no
/// whole-array re-render or view-identity hacks required.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    // NSCache auto-evicts under memory pressure, so browsing a large library
    // across many folders doesn't grow unbounded for the whole session.
    private let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.countLimit = 500
        return cache
    }()
    private static let maxSize = 300
    private static let fallbackContext = FilmColorPipeline.makeContext()

    func thumbnail(for url: URL) async -> CGImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image = await Task.detached(priority: .utility) {
            Self.generate(for: url)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    private static func generate(for url: URL) -> CGImage? {
        // Read the embedded preview (every modern RAW has one — fast).
        // `IfAbsent` falls through to decoding the full image only if no preview
        // exists; `Always` would force a full 60MP decode every time.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return thumb
            }
        }

        // Fallback for formats CGImageSource can't thumbnail.
        if let ciImage = CIImage(contentsOf: url) {
            let normalized = FilmColorPipeline.normalizeDecodedImage(ciImage)
            let extent = normalized.extent
            if !extent.isInfinite && !extent.isEmpty {
                let scale = min(CGFloat(maxSize) / extent.width, CGFloat(maxSize) / extent.height, 1.0)
                let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return fallbackContext.createCGImage(scaled, from: scaled.extent)
            }
        }
        return nil
    }
}
