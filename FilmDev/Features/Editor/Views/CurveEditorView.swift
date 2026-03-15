import SwiftUI

struct CurveEditorView: View {
    @Environment(EditorViewModel.self) private var viewModel
    @State private var selectedChannel: CurveChannel = .rgb

    enum CurveChannel: String, CaseIterable {
        case rgb = "RGB"
        case red = "Red"
        case green = "Green"
        case blue = "Blue"

        var color: Color {
            switch self {
            case .rgb: return .white
            case .red: return .red
            case .green: return .green
            case .blue: return .blue
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Curves")
                    .font(.headline)
                    .foregroundStyle(Color.filmdevText)
                Spacer()

                Picker("", selection: $selectedChannel) {
                    ForEach(CurveChannel.allCases, id: \.self) { channel in
                        Text(channel.rawValue).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            CurveCanvas(
                points: curveBinding,
                color: selectedChannel.color,
                onChanged: { viewModel.onSliderDragChanged() },
                onEnded: { viewModel.onSliderDragEnded() }
            )
            .frame(height: 200)
            .background(Color.filmdevBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var curveBinding: Binding<[CGPoint]> {
        @Bindable var vm = viewModel
        switch selectedChannel {
        case .rgb: return $vm.editState.rgbCurve
        case .red: return $vm.editState.redCurve
        case .green: return $vm.editState.greenCurve
        case .blue: return $vm.editState.blueCurve
        }
    }
}

struct CurveCanvas: View {
    @Binding var points: [CGPoint]
    let color: Color
    var onChanged: (() -> Void)?
    var onEnded: (() -> Void)?

    @State private var dragIndex: Int?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            Canvas { context, canvasSize in
                // Grid lines
                let gridColor = Color.filmdevBorder.opacity(0.5)
                for i in 1..<4 {
                    let pos = CGFloat(i) / 4.0

                    var hPath = Path()
                    hPath.move(to: CGPoint(x: 0, y: pos * canvasSize.height))
                    hPath.addLine(to: CGPoint(x: canvasSize.width, y: pos * canvasSize.height))
                    context.stroke(hPath, with: .color(gridColor), lineWidth: 0.5)

                    var vPath = Path()
                    vPath.move(to: CGPoint(x: pos * canvasSize.width, y: 0))
                    vPath.addLine(to: CGPoint(x: pos * canvasSize.width, y: canvasSize.height))
                    context.stroke(vPath, with: .color(gridColor), lineWidth: 0.5)
                }

                // Diagonal reference
                var diag = Path()
                diag.move(to: CGPoint(x: 0, y: canvasSize.height))
                diag.addLine(to: CGPoint(x: canvasSize.width, y: 0))
                context.stroke(diag, with: .color(Color.filmdevBorder), lineWidth: 1)

                // Curve
                let curvePoints = points.map { pt in
                    CGPoint(x: pt.x * canvasSize.width, y: (1 - pt.y) * canvasSize.height)
                }

                var curvePath = Path()
                if let first = curvePoints.first {
                    curvePath.move(to: first)
                    for point in curvePoints.dropFirst() {
                        curvePath.addLine(to: point)
                    }
                }
                context.stroke(curvePath, with: .color(color), lineWidth: 2)

                // Control points
                for pt in curvePoints {
                    let rect = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let normalized = CGPoint(
                            x: value.location.x / size.width,
                            y: 1 - value.location.y / size.height
                        )

                        if dragIndex == nil {
                            // Find closest point
                            var minDist = CGFloat.infinity
                            var closest = 0
                            for (i, pt) in points.enumerated() {
                                let dx = pt.x * size.width - value.location.x
                                let dy = (1 - pt.y) * size.height - value.location.y
                                let dist = sqrt(dx * dx + dy * dy)
                                if dist < minDist {
                                    minDist = dist
                                    closest = i
                                }
                            }
                            if minDist < 30 {
                                dragIndex = closest
                            }
                        }

                        if let idx = dragIndex {
                            let clampedY = max(0, min(1, normalized.y))
                            if idx == 0 {
                                // First endpoint: fixed at x=0
                                points[idx] = CGPoint(x: 0, y: clampedY)
                            } else if idx == points.count - 1 {
                                // Last endpoint: fixed at x=1
                                points[idx] = CGPoint(x: 1, y: clampedY)
                            } else {
                                // Middle points: constrain x between neighbors
                                let minX = points[idx - 1].x + 0.01
                                let maxX = points[idx + 1].x - 0.01
                                let clampedX = max(minX, min(maxX, normalized.x))
                                points[idx] = CGPoint(x: clampedX, y: clampedY)
                            }
                            onChanged?()
                        }
                    }
                    .onEnded { _ in
                        dragIndex = nil
                        onEnded?()
                    }
            )
        }
    }
}
