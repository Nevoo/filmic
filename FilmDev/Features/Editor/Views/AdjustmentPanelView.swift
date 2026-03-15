import SwiftUI

struct AdjustmentPanelView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @State private var showExportSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Histogram
                HistogramView()

                // Presets section
                PresetGridView()

                Divider()
                    .background(Color.filmdevBorder)

                // White Balance
                WhiteBalanceView()

                Divider()
                    .background(Color.filmdevBorder)

                // Basic adjustments
                BasicAdjustmentsView()

                Divider()
                    .background(Color.filmdevBorder)

                // Color adjustments
                ColorAdjustmentsView()

                Divider()
                    .background(Color.filmdevBorder)

                // Curves
                CurveEditorView()

                Divider()
                    .background(Color.filmdevBorder)

                // Detail
                DetailAdjustmentsView()

                Divider()
                    .background(Color.filmdevBorder)

                // Effects
                EffectsAdjustmentsView()

                Divider()
                    .background(Color.filmdevBorder)

                // Export button
                VStack(spacing: 8) {
                    sectionHeader("Export")

                    Button {
                        showExportSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export Image")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.filmdevAccent)
                    .disabled(viewModel.previewImage == nil)
                }

                Spacer()
            }
            .padding(16)
        }
        .background(Color.filmdevSurface)
        .sheet(isPresented: $showExportSheet) {
            ExportSheet()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.filmdevText)
            Spacer()
        }
    }
}
