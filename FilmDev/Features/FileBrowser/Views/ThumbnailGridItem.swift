import SwiftUI

struct ThumbnailGridItem: View {
    let name: String
    let thumbnail: CGImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.filmdevBackground)
                    .frame(width: 80, height: 80)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(Color.filmdevTextSecondary)
                    }
            }

            Text(name)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(4)
        .background(isSelected ? Color.filmdevAccent.opacity(0.2) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
