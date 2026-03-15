import SwiftUI

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
