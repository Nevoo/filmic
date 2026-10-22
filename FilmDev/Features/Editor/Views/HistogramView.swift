import SwiftUI

struct HistogramView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        let data = viewModel.histogramData
        let clip = clipping(data)

        HistogramCanvas(data: data)
            .frame(height: 118)
            .background(Color.filmdevBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                clipIndicator(active: clip.shadow, help: "Shadow clipping")
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                clipIndicator(active: clip.highlight, help: "Highlight clipping")
                    .padding(6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.filmdevBorder.opacity(0.9), lineWidth: 1)
            }
            // Dim while dragging — the histogram is stale until the render settles.
            .opacity(viewModel.isDragging ? 0.4 : 1.0)
            .animation(.easeOut(duration: 0.15), value: viewModel.isDragging)
    }

    private func clipIndicator(active: Bool, help: String) -> some View {
        Circle()
            .fill(active ? Color.white : Color.filmdevTextSecondary.opacity(0.25))
            .frame(width: 6, height: 6)
            .help(active ? help : "")
    }

    /// A bin holding more than ~0.2% of pixels at pure black / pure white counts
    /// as clipping. Bins are stored as per-pixel fractions (CIAreaHistogram scale).
    private func clipping(_ data: HistogramData?) -> (shadow: Bool, highlight: Bool) {
        guard let data else { return (false, false) }
        let threshold: Float = 0.002
        let shadow = max(data.red.first ?? 0, data.green.first ?? 0, data.blue.first ?? 0) > threshold
        let highlight = max(data.red.last ?? 0, data.green.last ?? 0, data.blue.last ?? 0) > threshold
        return (shadow, highlight)
    }
}

private struct HistogramCanvas: View {
    let data: HistogramData?

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
            drawGrid(in: rect, context: &context)

            guard let data else {
                drawEmptyState(in: rect, context: &context)
                return
            }

            let luminance = displayBins(data.luminance)
            let red = displayBins(data.red)
            let green = displayBins(data.green)
            let blue = displayBins(data.blue)

            let fill = histogramPath(for: luminance, in: rect)
            context.fill(fill, with: .color(Color.filmdevText.opacity(0.22)))
            context.stroke(fill, with: .color(Color.filmdevText.opacity(0.72)), lineWidth: 1.2)

            context.stroke(linePath(for: red, in: rect), with: .color(Color.red.opacity(0.75)), lineWidth: 0.9)
            context.stroke(linePath(for: green, in: rect), with: .color(Color.green.opacity(0.68)), lineWidth: 0.9)
            context.stroke(linePath(for: blue, in: rect), with: .color(Color.blue.opacity(0.8)), lineWidth: 0.9)
        }
    }

    private func drawGrid(in rect: CGRect, context: inout GraphicsContext) {
        let gridColor = Color.filmdevBorder.opacity(0.55)
        for step in 1..<4 {
            let fraction = CGFloat(step) / 4

            var vertical = Path()
            vertical.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            vertical.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            context.stroke(vertical, with: .color(gridColor), lineWidth: 0.6)

            var horizontal = Path()
            horizontal.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            horizontal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
            context.stroke(horizontal, with: .color(gridColor), lineWidth: 0.6)
        }
    }

    private func drawEmptyState(in rect: CGRect, context: inout GraphicsContext) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.stroke(baseline, with: .color(Color.filmdevBorder.opacity(0.8)), lineWidth: 1)
    }

    private func displayBins(_ bins: [Float]) -> [CGFloat] {
        let positive = bins.filter { $0.isFinite && $0 > 0 }.sorted()
        guard let maxValue = positive.last, maxValue > 0 else {
            return Array(repeating: 0, count: bins.count)
        }

        let percentileIndex = min(positive.count - 1, Int(Double(positive.count - 1) * 0.985))
        let cap = max(positive[percentileIndex], maxValue * 0.08)

        return bins.map { value in
            guard value.isFinite, value > 0 else { return 0 }
            let normalized = min(CGFloat(value / cap), 1)
            return pow(normalized, 0.45)
        }
    }

    private func histogramPath(for bins: [CGFloat], in rect: CGRect) -> Path {
        var path = linePath(for: bins, in: rect)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func linePath(for bins: [CGFloat], in rect: CGRect) -> Path {
        var path = Path()
        guard bins.count > 1 else { return path }

        for index in bins.indices {
            let fraction = CGFloat(index) / CGFloat(bins.count - 1)
            let x = rect.minX + rect.width * fraction
            let y = rect.maxY - rect.height * min(max(bins[index], 0), 1)
            let point = CGPoint(x: x, y: y)

            if index == bins.startIndex {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }
}
