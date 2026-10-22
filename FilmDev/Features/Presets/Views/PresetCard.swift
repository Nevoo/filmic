import SwiftUI

struct PresetCard: View {
    let preset: FilmPreset
    let isSelected: Bool
    let isDefault: Bool
    let action: () -> Void
    let onSetDefault: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
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

                // Visible default affordance — no longer buried in a context menu.
                if isDefault || hovering {
                    Button(action: onSetDefault) {
                        Image(systemName: isDefault ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundStyle(isDefault ? Color.filmdevAccent : .white)
                            .padding(4)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help(isDefault ? "Remove as default look" : "Set as default look")
                }
            }

            Text(preset.name)
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.filmdevAccent : Color.filmdevTextSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(isDefault ? "Remove Default" : "Set as Default", action: onSetDefault)
        }
    }
}
