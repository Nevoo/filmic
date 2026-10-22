import SwiftUI

struct ThumbnailGridItem: View {
    let url: URL
    let name: String
    let isSelected: Bool
    var hasSidecar: Bool = false

    @State private var thumbnail: CGImage?
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                swatch
                    .frame(minWidth: 140, minHeight: 100)
                    .frame(maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if hasSidecar {
                    Circle()
                        .fill(Color.filmdevAccent)
                        .frame(width: 8, height: 8)
                        .padding(4)
                        .help("Has saved edits")
                }
            }

            Text(name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Color.filmdevText)
        }
        .padding(4)
        .background(isSelected ? Color.filmdevAccent.opacity(0.2) : .clear)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.filmdevAccent : .clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Each cell loads its own thumbnail on appear and updates independently,
        // so previews fill in live as they're ready (and only visible cells load).
        .task(id: url) {
            thumbnail = await ThumbnailCache.shared.thumbnail(for: url)
            didLoad = true
        }
    }

    @ViewBuilder
    private var swatch: some View {
        if let thumbnail {
            // .fit (not .fill) so composition isn't cropped when triaging.
            Image(decorative: thumbnail, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.filmdevBackground)
                .overlay {
                    if didLoad {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(Color.filmdevTextSecondary)
                    } else {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
        }
    }
}
