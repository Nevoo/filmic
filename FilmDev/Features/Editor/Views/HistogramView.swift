import SwiftUI

struct HistogramView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        Group {
            if let histogramImage = viewModel.histogramImage {
                Image(decorative: histogramImage, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 60)
                    .frame(maxWidth: .infinity)
                    .opacity(0.8)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.filmdevBackground)
                    .frame(height: 60)
            }
        }
    }
}
