import SwiftUI

struct PresetCard: View {
    let preset: FilmPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.filmdevBackground)
                        .aspectRatio(1.0, contentMode: .fit)

                    if let thumbnail = preset.thumbnail {
                        Image(decorative: thumbnail, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "film")
                            .font(.title3)
                            .foregroundStyle(Color.filmdevTextSecondary)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.filmdevAccent : Color.clear, lineWidth: 2)
                )

                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.filmdevAccent : Color.filmdevTextSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
