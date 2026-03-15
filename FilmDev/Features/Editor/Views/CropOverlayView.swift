import SwiftUI

enum CropAspectRatio: String, CaseIterable, Sendable {
    case free = "Free"
    case square = "1:1"
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"

    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1.0
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        }
    }
}

struct CropOverlayView: View {
    @Binding var cropRect: CGRect
    let imageSize: CGSize
    let aspectRatio: CropAspectRatio

    @State private var dragHandle: CropHandle?
    @State private var dragStart: CGPoint = .zero
    @State private var initialRect: CGRect = .zero

    enum CropHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case center
    }

    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size
            let displayRect = normalizedToView(cropRect, in: viewSize)

            ZStack {
                // Darkened area outside crop
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: viewSize))
                    path.addRect(displayRect)
                }
                .fill(style: FillStyle(eoFill: true))
                .foregroundStyle(.black.opacity(0.5))

                // Crop border
                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: displayRect.width, height: displayRect.height)
                    .position(x: displayRect.midX, y: displayRect.midY)

                // Rule of thirds grid
                ruleOfThirdsGrid(in: displayRect)

                // Corner handles
                ForEach(cornerPositions(in: displayRect), id: \.handle) { item in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .position(item.position)
                        .contentShape(Rectangle().size(width: 44, height: 44))
                }

                // Edge handles
                ForEach(edgePositions(in: displayRect), id: \.handle) { item in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: item.isHorizontal ? 24 : 4, height: item.isHorizontal ? 4 : 24)
                        .position(item.position)
                        .contentShape(Rectangle().size(width: 44, height: 44))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragHandle == nil {
                            dragStart = value.startLocation
                            initialRect = displayRect
                            dragHandle = hitTest(value.startLocation, in: displayRect)
                        }
                        guard let handle = dragHandle else { return }
                        let delta = CGSize(
                            width: value.location.x - dragStart.x,
                            height: value.location.y - dragStart.y
                        )
                        let newRect = applyDrag(handle: handle, delta: delta, initial: initialRect, bounds: viewSize)
                        cropRect = viewToNormalized(newRect, in: viewSize)
                    }
                    .onEnded { _ in
                        dragHandle = nil
                    }
            )
        }
    }

    // MARK: - Grid

    private func ruleOfThirdsGrid(in rect: CGRect) -> some View {
        Canvas { context, _ in
            let color = Color.white.opacity(0.3)
            for i in 1...2 {
                let fraction = CGFloat(i) / 3.0

                var hPath = Path()
                hPath.move(to: CGPoint(x: rect.minX, y: rect.minY + fraction * rect.height))
                hPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fraction * rect.height))
                context.stroke(hPath, with: .color(color), lineWidth: 0.5)

                var vPath = Path()
                vPath.move(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.minY))
                vPath.addLine(to: CGPoint(x: rect.minX + fraction * rect.width, y: rect.maxY))
                context.stroke(vPath, with: .color(color), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Handle Positions

    private struct HandleInfo: Identifiable {
        let handle: CropHandle
        let position: CGPoint
        var isHorizontal: Bool = false
        var id: String {
            switch handle {
            case .topLeft: return "tl"
            case .topRight: return "tr"
            case .bottomLeft: return "bl"
            case .bottomRight: return "br"
            case .top: return "t"
            case .bottom: return "b"
            case .left: return "l"
            case .right: return "r"
            case .center: return "c"
            }
        }
    }

    private func cornerPositions(in rect: CGRect) -> [HandleInfo] {
        [
            HandleInfo(handle: .topLeft, position: CGPoint(x: rect.minX, y: rect.minY)),
            HandleInfo(handle: .topRight, position: CGPoint(x: rect.maxX, y: rect.minY)),
            HandleInfo(handle: .bottomLeft, position: CGPoint(x: rect.minX, y: rect.maxY)),
            HandleInfo(handle: .bottomRight, position: CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
    }

    private func edgePositions(in rect: CGRect) -> [HandleInfo] {
        [
            HandleInfo(handle: .top, position: CGPoint(x: rect.midX, y: rect.minY), isHorizontal: true),
            HandleInfo(handle: .bottom, position: CGPoint(x: rect.midX, y: rect.maxY), isHorizontal: true),
            HandleInfo(handle: .left, position: CGPoint(x: rect.minX, y: rect.midY)),
            HandleInfo(handle: .right, position: CGPoint(x: rect.maxX, y: rect.midY)),
        ]
    }

    // MARK: - Hit Testing

    private func hitTest(_ point: CGPoint, in rect: CGRect) -> CropHandle {
        let threshold: CGFloat = 22

        let corners: [(CropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]

        for (handle, pos) in corners {
            if hypot(point.x - pos.x, point.y - pos.y) < threshold {
                return handle
            }
        }

        let edges: [(CropHandle, CGPoint)] = [
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
        ]

        for (handle, pos) in edges {
            if hypot(point.x - pos.x, point.y - pos.y) < threshold {
                return handle
            }
        }

        return .center
    }

    // MARK: - Drag Application

    private func applyDrag(handle: CropHandle, delta: CGSize, initial: CGRect, bounds: CGSize) -> CGRect {
        let minSize: CGFloat = 30
        var rect = initial

        switch handle {
        case .topLeft:
            rect.origin.x += delta.width
            rect.origin.y += delta.height
            rect.size.width -= delta.width
            rect.size.height -= delta.height
        case .topRight:
            rect.size.width += delta.width
            rect.origin.y += delta.height
            rect.size.height -= delta.height
        case .bottomLeft:
            rect.origin.x += delta.width
            rect.size.width -= delta.width
            rect.size.height += delta.height
        case .bottomRight:
            rect.size.width += delta.width
            rect.size.height += delta.height
        case .top:
            rect.origin.y += delta.height
            rect.size.height -= delta.height
        case .bottom:
            rect.size.height += delta.height
        case .left:
            rect.origin.x += delta.width
            rect.size.width -= delta.width
        case .right:
            rect.size.width += delta.width
        case .center:
            rect.origin.x += delta.width
            rect.origin.y += delta.height
        }

        // Enforce minimum size
        if rect.width < minSize {
            rect.size.width = minSize
        }
        if rect.height < minSize {
            rect.size.height = minSize
        }

        // Enforce aspect ratio
        if let ratio = aspectRatio.ratio {
            let currentRatio = rect.width / rect.height
            if currentRatio > ratio {
                rect.size.width = rect.height * ratio
            } else {
                rect.size.height = rect.width / ratio
            }
        }

        // Clamp to bounds
        rect.origin.x = max(0, min(rect.origin.x, bounds.width - rect.width))
        rect.origin.y = max(0, min(rect.origin.y, bounds.height - rect.height))
        rect.size.width = min(rect.width, bounds.width - rect.origin.x)
        rect.size.height = min(rect.height, bounds.height - rect.origin.y)

        return rect
    }

    // MARK: - Coordinate Conversion

    private func normalizedToView(_ normalized: CGRect, in viewSize: CGSize) -> CGRect {
        CGRect(
            x: normalized.origin.x * viewSize.width,
            y: normalized.origin.y * viewSize.height,
            width: normalized.width * viewSize.width,
            height: normalized.height * viewSize.height
        )
    }

    private func viewToNormalized(_ viewRect: CGRect, in viewSize: CGSize) -> CGRect {
        CGRect(
            x: viewRect.origin.x / viewSize.width,
            y: viewRect.origin.y / viewSize.height,
            width: viewRect.width / viewSize.width,
            height: viewRect.height / viewSize.height
        )
    }
}
