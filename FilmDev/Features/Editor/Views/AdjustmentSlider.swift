import SwiftUI

/// Section header with a right-aligned group "Reset", shared by the Tone / Color
/// / Effects adjustment groups so the styling and disable behavior live once.
struct GroupResetHeader: View {
    let title: String
    let isDefault: Bool
    let reset: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.filmdevText)
            Spacer()
            Button("Reset") {
                withAnimation(.easeOut(duration: 0.15)) { reset() }
            }
            .font(.caption)
            .foregroundStyle(Color.filmdevAccent)
            .buttonStyle(.plain)
            .disabled(isDefault)
        }
    }
}

/// A single adjustment control: label, inline numeric entry, per-slider reset,
/// and a track whose fill is anchored at the *default* value. Anchoring the fill
/// at neutral means a slider sitting at zero reads as "untouched" instead of
/// showing a half-filled accent track.
struct AdjustmentSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1.0...1.0
    var format: String = "%+.0f"
    var defaultValue: Double = 0
    /// When true the fill grows from the range minimum instead of the default
    /// value — right for unipolar strength controls whose default sits at full.
    var fillFromMinimum: Bool = false
    var onDragChanged: (() -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var dragStarted = false
    @State private var isEditingText = false
    @State private var textValue = ""
    @FocusState private var fieldFocused: Bool

    private let thumbSize: CGFloat = 14
    private let trackHeight: CGFloat = 4

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.filmdevTextSecondary)

                Spacer()

                if !isAtDefault {
                    Button(action: reset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.filmdevTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default")
                }

                valueLabel
            }

            track
        }
        .padding(.vertical, 2)
    }

    // MARK: - Value label / numeric entry

    @ViewBuilder
    private var valueLabel: some View {
        if isEditingText {
            TextField("", text: $textValue)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.filmdevText)
                .frame(width: 62)
                .focused($fieldFocused)
                .onSubmit { commitText() }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commitText() }
                }
        } else {
            Text(displayString(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.filmdevText)
                .frame(width: 62, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture {
                    textValue = editableString(value)
                    isEditingText = true
                    fieldFocused = true
                }
                .help("Click to type a value")
        }
    }

    // MARK: - Track

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usable = max(1, width - thumbSize)
            let anchor = fillFromMinimum ? range.lowerBound : defaultValue
            let valueX = thumbSize / 2 + CGFloat(fraction(value)) * usable
            let defaultX = thumbSize / 2 + CGFloat(fraction(anchor)) * usable

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.filmdevBorder.opacity(0.6))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.filmdevAccent)
                    .frame(width: abs(valueX - defaultX), height: trackHeight)
                    .offset(x: min(valueX, defaultX))

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(radius: 1, y: 0.5)
                    .offset(x: valueX - thumbSize / 2)
            }
            .frame(height: thumbSize)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragStarted {
                            dragStarted = true
                            // Commit the pre-edit state for undo before mutating value.
                            onDragChanged?()
                        }
                        value = valueFor(x: gesture.location.x, usable: usable)
                        onDragChanged?()
                    }
                    .onEnded { _ in
                        dragStarted = false
                        onDragEnded?()
                    }
            )
            .onTapGesture(count: 2) { reset() }
        }
        .frame(height: thumbSize)
    }

    // MARK: - Value mapping

    private func fraction(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (v - range.lowerBound) / span))
    }

    private func valueFor(x: CGFloat, usable: CGFloat) -> Double {
        let f = min(1, max(0, (x - thumbSize / 2) / usable))
        return range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
    }

    private var isAtDefault: Bool {
        abs(value - defaultValue) < (range.upperBound - range.lowerBound) * 0.0005
    }

    private func reset() {
        guard !isAtDefault else { return }
        onDragChanged?()
        value = defaultValue
        onDragEnded?()
    }

    private func commitText() {
        defer { isEditingText = false }
        guard let parsed = parse(textValue) else { return }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        onDragChanged?()
        value = clamped
        onDragEnded?()
    }

    // MARK: - Formatting

    /// Per-format display rules in one place: how to scale the model value, how
    /// many decimals, the unit suffix, and whether to show a +/- sign.
    private struct Unit {
        var scale: Double
        var decimals: Int
        var suffix: String
        var signed: Bool
    }

    private var unit: Unit {
        if format.contains("EV") { return Unit(scale: 1, decimals: 1, suffix: " EV", signed: true) }
        if format.contains("°") { return Unit(scale: 180.0 / .pi, decimals: 0, suffix: "°", signed: true) }
        if format == "K" { return Unit(scale: 1, decimals: 0, suffix: " K", signed: false) }
        if format == "%" { return Unit(scale: 100, decimals: 0, suffix: "%", signed: false) }
        if format == "raw" { return Unit(scale: 1, decimals: 2, suffix: "", signed: false) }
        return Unit(scale: 100, decimals: 0, suffix: "", signed: true)
    }

    private func displayString(_ v: Double) -> String {
        let u = unit
        let spec = "%\(u.signed ? "+" : "").\(u.decimals)f"
        return String(format: spec, v * u.scale) + u.suffix
    }

    /// Value shown inside the editable field (no unit suffix or sign decoration).
    private func editableString(_ v: Double) -> String {
        let u = unit
        return String(format: "%.\(u.decimals)f", v * u.scale)
    }

    private func parse(_ s: String) -> Double? {
        let cleaned = s.filter { "0123456789.+-".contains($0) }
        guard let raw = Double(cleaned) else { return nil }
        return raw / unit.scale
    }
}
