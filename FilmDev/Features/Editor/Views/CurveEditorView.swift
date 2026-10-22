import SwiftUI

struct CurveEditorView: View {
    @Environment(EditorViewModel.self) private var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Curve")
                    .font(.headline)
                    .foregroundStyle(Color.filmdevText)

                Button {
                    viewModel.commitState()
                    withAnimation(.easeOut(duration: 0.15)) {
                        vm.editState.rgbCurve = EditState.defaultCurvePoints
                    }
                    viewModel.endDirectEdit()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(Color.filmdevTextSecondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.editState.rgbCurve == EditState.defaultCurvePoints)
                .help("Reset curve")

                Spacer()
            }

            CurveCanvas(
                points: $vm.editState.rgbCurve,
                color: Color.filmdevText,
                activeColor: Color.filmdevAccent,
                onBegin: { viewModel.beginDirectEdit() },
                onChanged: { viewModel.directEditChanged() },
                onEnded: { viewModel.endDirectEdit() }
            )
            .frame(height: 220)
            .background(Color.filmdevBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.filmdevBorder.opacity(0.9), lineWidth: 1)
            }
        }
    }
}

struct CurveCanvas: View {
    @Binding var points: [CGPoint]
    let color: Color
    let activeColor: Color
    var onBegin: (() -> Void)?
    var onChanged: (() -> Void)?
    var onEnded: (() -> Void)?

    @State private var dragIndex: Int?
    @State private var didBeginInteraction = false

    private let hitRadius: CGFloat = 24
    private let handleRadius: CGFloat = 6
    private let plotInsets = EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14)

    var body: some View {
        GeometryReader { geometry in
            let plotArea = plotRect(in: geometry.size)

            Canvas { context, canvasSize in
                let rect = plotRect(in: canvasSize)
                drawGrid(in: rect, context: &context)
                drawReferenceLine(in: rect, context: &context)

                let path = curvePath(in: rect)
                context.stroke(path, with: .color(color.opacity(0.28)), lineWidth: 5)
                context.stroke(path, with: .color(color.opacity(0.96)), lineWidth: 2)

                for (index, point) in points.enumerated() {
                    let screenPoint = screenPoint(for: point, in: rect)
                    let isActive = index == dragIndex
                    let fill = isActive ? activeColor : Color.filmdevSurface
                    let stroke = isActive ? activeColor : color.opacity(0.92)

                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: screenPoint.x - handleRadius,
                            y: screenPoint.y - handleRadius,
                            width: handleRadius * 2,
                            height: handleRadius * 2
                        )),
                        with: .color(fill)
                    )
                    context.stroke(
                        Path(ellipseIn: CGRect(
                            x: screenPoint.x - handleRadius,
                            y: screenPoint.y - handleRadius,
                            width: handleRadius * 2,
                            height: handleRadius * 2
                        )),
                        with: .color(stroke),
                        lineWidth: isActive ? 2 : 1.4
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: plotArea))
            .onTapGesture(count: 2) { location in
                removePointIfPossible(at: location, in: plotArea)
            }
            .overlay(alignment: .topLeading) {
                if let index = dragIndex, points.indices.contains(index) {
                    coordinateLabel(for: points[index])
                        .padding(8)
                }
            }
        }
    }

    private func coordinateLabel(for point: CGPoint) -> some View {
        Text("In \(Int(point.x * 255))  ·  Out \(Int(point.y * 255))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Color.filmdevText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    private func dragGesture(in plotRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let normalized = normalizedPoint(for: value.location, in: plotRect)

                if dragIndex == nil {
                    if let existingIndex = closestPoint(to: value.location, in: plotRect, within: hitRadius) {
                        beginInteractionIfNeeded()
                        dragIndex = existingIndex
                    } else {
                        beginInteractionIfNeeded()
                        dragIndex = insertPoint(normalized)
                    }
                }

                guard let index = dragIndex else { return }
                updatePoint(at: index, with: normalized)
                onChanged?()
            }
            .onEnded { _ in
                dragIndex = nil
                if didBeginInteraction {
                    didBeginInteraction = false
                    onEnded?()
                }
            }
    }

    private func beginInteractionIfNeeded() {
        guard !didBeginInteraction else { return }
        didBeginInteraction = true
        onBegin?()
    }

    @discardableResult
    private func insertPoint(_ point: CGPoint) -> Int {
        let clampedX = max(0.01, min(0.99, point.x))
        let clampedY = max(0, min(1, point.y))
        let insertIndex = points.firstIndex { $0.x > clampedX } ?? points.count
        points.insert(CGPoint(x: clampedX, y: clampedY), at: insertIndex)
        return insertIndex
    }

    private func updatePoint(at index: Int, with point: CGPoint) {
        guard points.indices.contains(index) else { return }
        let clampedY = max(0, min(1, point.y))

        if index == points.startIndex {
            points[index] = CGPoint(x: 0, y: clampedY)
            return
        }

        if index == points.index(before: points.endIndex) {
            points[index] = CGPoint(x: 1, y: clampedY)
            return
        }

        let minX = points[index - 1].x + 0.012
        let maxX = points[index + 1].x - 0.012
        let clampedX = max(minX, min(maxX, point.x))
        points[index] = CGPoint(x: clampedX, y: clampedY)
    }

    private func removePointIfPossible(at location: CGPoint, in plotRect: CGRect) {
        guard let index = closestPoint(to: location, in: plotRect, within: hitRadius),
              index != points.startIndex,
              index != points.index(before: points.endIndex),
              points.count > 2 else { return }

        onBegin?()
        points.remove(at: index)
        onChanged?()
        onEnded?()
    }

    private func closestPoint(to location: CGPoint, in plotRect: CGRect, within radius: CGFloat) -> Int? {
        var closestIndex: Int?
        var closestDistance = CGFloat.infinity

        for (index, point) in points.enumerated() {
            let screenPoint = screenPoint(for: point, in: plotRect)
            let distance = hypot(screenPoint.x - location.x, screenPoint.y - location.y)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        guard closestDistance <= radius else { return nil }
        return closestIndex
    }

    private func drawGrid(in rect: CGRect, context: inout GraphicsContext) {
        let gridColor = Color.filmdevBorder.opacity(0.58)
        for index in 1..<4 {
            let fraction = CGFloat(index) / 4

            var horizontal = Path()
            horizontal.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            horizontal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
            context.stroke(horizontal, with: .color(gridColor), lineWidth: 0.7)

            var vertical = Path()
            vertical.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            vertical.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            context.stroke(vertical, with: .color(gridColor), lineWidth: 0.7)
        }
    }

    private func drawReferenceLine(in rect: CGRect, context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.stroke(
            path,
            with: .color(Color.filmdevTextSecondary.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 5])
        )
    }

    private func curvePath(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }

        let steps = max(24, Int(rect.width))
        for step in 0...steps {
            let x = CGFloat(step) / CGFloat(steps)
            let y = ImageProcessor.sampleToneCurve(at: x, points: points)
            let point = screenPoint(for: CGPoint(x: x, y: y), in: rect)

            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: plotInsets.leading,
            y: plotInsets.top,
            width: max(1, size.width - plotInsets.leading - plotInsets.trailing),
            height: max(1, size.height - plotInsets.top - plotInsets.bottom)
        )
    }

    private func screenPoint(for point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.maxY - point.y * rect.height
        )
    }

    private func normalizedPoint(for location: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: max(0, min(1, (location.x - rect.minX) / rect.width)),
            y: max(0, min(1, 1 - (location.y - rect.minY) / rect.height))
        )
    }
}
