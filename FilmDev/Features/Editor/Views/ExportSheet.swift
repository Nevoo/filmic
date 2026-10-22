import SwiftUI

/// Quality slider shared by the single and batch export sheets (so the range and
/// percentage formatting stay in lockstep). Renders nothing for lossless formats.
struct ExportQualityRow: View {
    @Binding var settings: ExportSettings

    var body: some View {
        if settings.format.supportsQuality {
            HStack {
                Text("Quality")
                Slider(value: $settings.quality, in: 0.1...1.0)
                Text("\(Int(settings.quality * 100))%")
                    .monospacedDigit()
                    .frame(width: 40)
            }
        }
    }
}

struct ExportSheet: View {
    @Environment(EditorViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSettings()

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Image")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                Picker("Format", selection: $settings.format) {
                    ForEach(ExportSettings.ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                ExportQualityRow(settings: $settings)

                Picker("Color Profile", selection: $settings.colorProfile) {
                    ForEach(ExportSettings.ColorProfile.allCases) { profile in
                        Text(profile.rawValue).tag(profile)
                    }
                }

                Toggle("Resize", isOn: $settings.resizeEnabled)
                if settings.resizeEnabled {
                    HStack {
                        Text("Long edge")
                        Spacer()
                        TextField("px", value: $settings.maxLongEdge, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("px")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Date stamp", isOn: $settings.dateStampEnabled)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export") {
                    viewModel.exportImage(settings: settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.filmdevAccent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
