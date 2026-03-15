import SwiftUI

struct AdjustmentSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1.0...1.0
    var format: String = "%+.0f"
    var defaultValue: Double = 0
    var onDragChanged: (() -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.filmdevTextSecondary)

                Spacer()

                Text(formattedValue)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.filmdevText)
                    .frame(width: 60, alignment: .trailing)
            }

            Slider(value: $value, in: range) { editing in
                if editing {
                    isDragging = true
                    onDragChanged?()
                } else {
                    isDragging = false
                    onDragEnded?()
                }
            }
            .tint(Color.filmdevAccent)
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.15)) {
                    value = defaultValue
                    onDragEnded?()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var formattedValue: String {
        if format.contains("EV") {
            return String(format: format, value)
        }
        if format.contains("°") {
            let degrees = value * 180.0 / .pi
            return String(format: "%+.0f°", degrees)
        }
        if format == "K" {
            return "\(Int(value)) K"
        }
        if format == "raw" {
            return String(format: "%.2f", value)
        }
        let scaled = value * 100
        return String(format: "%+.0f", scaled)
    }
}
