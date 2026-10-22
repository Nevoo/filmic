import SwiftUI

enum CropAspectRatio: String, CaseIterable, Sendable {
    case free = "Free"
    case square = "1:1"
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"

    /// Returns the aspect ratio oriented to match the given image dimensions.
    /// For a portrait image, a 3:2 ratio returns 2/3 instead of 3/2.
    func ratio(for imageSize: CGSize) -> CGFloat? {
        let base: CGFloat? = switch self {
        case .free: nil
        case .square: 1.0
        case .fourThree: 4.0 / 3.0
        case .threeTwo: 3.0 / 2.0
        case .sixteenNine: 16.0 / 9.0
        }
        guard let base else { return nil }
        let isPortrait = imageSize.height > imageSize.width
        return isPortrait ? 1.0 / base : base
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
            let imageFrame = fittedImageFrame(in: viewSize)
            let displayRect = normalizedToView(cropRect, in: imageFrame)

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
                        let newRect = applyDrag(handle: handle, delta: delta, initial: initialRect, bounds: imageFrame)
                        cropRect = viewToNormalized(newRect, in: imageFrame)
                    }
                    .onEnded { _ in
                        dragHandle = nil
                    }
            )
            .onChange(of: aspectRatio) {
                adjustCropToAspectRatio(in: imageFrame)
            }
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

    private func applyDrag(handle: CropHandle, delta: CGSize, initial: CGRect, bounds: CGRect) -> CGRect {
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
        rect.size.width = max(rect.size.width, minSize)
        rect.size.height = max(rect.size.height, minSize)

        // Enforce aspect ratio, anchoring the corner opposite the dragged handle
        if let ratio = aspectRatio.ratio(for: imageSize), handle != .center {
            let currentRatio = rect.width / rect.height
            let anchorRight = [CropHandle.topLeft, .bottomLeft, .left].contains(handle)
            let anchorBottom = [CropHandle.topLeft, .topRight, .top].contains(handle)

            if currentRatio > ratio {
                let newWidth = rect.height * ratio
                if anchorRight {
                    rect.origin.x += rect.width - newWidth
                }
                rect.size.width = newWidth
            } else {
                let newHeight = rect.width / ratio
                if anchorBottom {
                    rect.origin.y += rect.height - newHeight
                }
                rect.size.height = newHeight
            }
        }

        // Clamp to bounds
        rect.origin.x = max(bounds.minX, min(rect.origin.x, bounds.maxX - rect.width))
        rect.origin.y = max(bounds.minY, min(rect.origin.y, bounds.maxY - rect.height))
        rect.size.width = min(rect.width, bounds.maxX - rect.origin.x)
        rect.size.height = min(rect.height, bounds.maxY - rect.origin.y)

        return rect
    }

    // MARK: - Aspect Ratio Adjustment

    /// Immediately adjusts the crop rect to match the selected aspect ratio,
    /// keeping it centered and as large as possible within bounds.
    private func adjustCropToAspectRatio(in bounds: CGRect) {
        guard let ratio = aspectRatio.ratio(for: imageSize) else { return }

        let displayRect = normalizedToView(cropRect, in: bounds)
        let centerX = displayRect.midX
        let centerY = displayRect.midY

        var newWidth = displayRect.width
        var newHeight = displayRect.height

        let currentRatio = newWidth / newHeight
        if currentRatio > ratio {
            newWidth = newHeight * ratio
        } else {
            newHeight = newWidth / ratio
        }

        var newRect = CGRect(
            x: centerX - newWidth / 2,
            y: centerY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )

        // Clamp to bounds
        newRect.origin.x = max(bounds.minX, min(newRect.origin.x, bounds.maxX - newRect.width))
        newRect.origin.y = max(bounds.minY, min(newRect.origin.y, bounds.maxY - newRect.height))

        cropRect = viewToNormalized(newRect, in: bounds)
    }

    // MARK: - Coordinate Conversion

    private func fittedImageFrame(in viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (viewSize.width - fittedSize.width) / 2,
            y: (viewSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func normalizedToView(_ normalized: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + normalized.origin.x * bounds.width,
            y: bounds.minY + normalized.origin.y * bounds.height,
            width: normalized.width * bounds.width,
            height: normalized.height * bounds.height
        )
    }

    private func viewToNormalized(_ viewRect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: (viewRect.origin.x - bounds.minX) / bounds.width,
            y: (viewRect.origin.y - bounds.minY) / bounds.height,
            width: viewRect.width / bounds.width,
            height: viewRect.height / bounds.height
        )
    }
}
