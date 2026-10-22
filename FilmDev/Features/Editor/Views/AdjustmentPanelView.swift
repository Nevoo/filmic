import SwiftUI

struct AdjustmentPanelView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @State private var showExportSheet = false
    @State private var showAdvanced = false

    var body: some View {
        @Bindable var vm = viewModel

        ScrollView {
            VStack(spacing: 20) {
                // Reset All
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.resetAll()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset All")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.filmdevTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.editState.isDefault)
                }

                // Histogram
                HistogramView()

                // Film Looks
                PresetGridView()

                Divider()
                    .background(Color.filmdevBorder)

                // Primary tone controls
                BasicAdjustmentsView()

                // White Balance
                WhiteBalanceView()

                // Primary: Grain Amount
                AdjustmentSlider(
                    label: "Grain Amount",
                    value: $vm.editState.grainAmount,
                    range: 0...1.0,
                    onDragChanged: { viewModel.onSliderDragChanged() },
                    onDragEnded: { viewModel.onSliderDragEnded() }
                )

                Divider()
                    .background(Color.filmdevBorder)

                // Export button
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

                Divider()
                    .background(Color.filmdevBorder)

                // Advanced section
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(spacing: 20) {
                        ColorAdjustmentsView()

                        Divider()
                            .background(Color.filmdevBorder)

                        CurveEditorView()

                        Divider()
                            .background(Color.filmdevBorder)

                        EffectsAdjustmentsView()
                    }
                    .padding(.top, 12)
                }
                .font(.headline)
                .foregroundStyle(Color.filmdevText)

                Spacer()
            }
            .padding(16)
        }
        .background(Color.filmdevSurface)
        .sheet(isPresented: $showExportSheet) {
            ExportSheet()
        }
    }
}
