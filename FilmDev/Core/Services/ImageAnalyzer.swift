import CoreImage

/// Measurements taken on the decoded base image. The decode contract is
/// camera-WB, auto-bright disabled, bounded display-referred sRGB — so every
/// frame lands here un-normalized, and these numbers are the single input the
/// auto-edit (PresetIntent) derives its trims from. All luma values are linear
/// (working-space) Rec.709 luminance in 0–1.
struct ImageAnalysis: Sendable, Equatable {
    let medianLuma: Double
    let meanLuma: Double
    /// 5th percentile — where the shadow mass sits.
    let p05: Double
    /// 99.5th percentile — the practical highlight ceiling (ignores specular dust).
    let p995: Double
    /// Fraction of pixels brighter than 0.9 linear (sky / blown mass).
    let highlightFraction: Double
    /// Fraction of pixels darker than 0.02 linear (crushed mass).
    let shadowFraction: Double
    /// Normalized cumulative luma distribution (cdf[i] = fraction of pixels at
    /// or below bin i). Lets consumers answer "how much mass clips at gain g"
    /// — the question fixed percentiles can't, because mass the sensor already
    /// clipped shouldn't count against lifting exposure.
    let cdf: [Double]

    /// Fraction of pixels strictly brighter than `value` (linear luma).
    func massAbove(_ value: Double) -> Double {
        guard !cdf.isEmpty else { return 0 }
        let bin = Int(value * Double(cdf.count))
        guard bin < cdf.count else { return 0 }
        return 1.0 - cdf[max(0, bin)]
    }

    /// The luma value above which `mass` fraction of pixels live — i.e. the
    /// (1 − mass) percentile.
    func valueWithMassAbove(_ mass: Double) -> Double {
        guard !cdf.isEmpty else { return 1 }
        let target = 1.0 - mass
        for bin in 0..<cdf.count where cdf[bin] >= target {
            return (Double(bin) + 0.5) / Double(cdf.count)
        }
        return 1.0
    }
}

/// Computes `ImageAnalysis` from a decoded frame: renders a ~256px proxy to a
/// CPU buffer and takes the stats in plain Swift. Deliberately NOT
/// CIAreaHistogram — its results drift wildly with the proxy size (verified
/// against CPU readback), and ~43k pixels of arithmetic is trivial anyway.
struct ImageAnalyzer: @unchecked Sendable {
    private let context: CIContext
    private let binCount = 512
    private let proxyLongEdge: Double

    init(context: CIContext, proxyLongEdge: Double = 256) {
        self.context = context
        self.proxyLongEdge = proxyLongEdge
    }

    func analyze(image: CIImage) -> ImageAnalysis? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return nil }

        let longEdge = max(extent.width, extent.height)
        let scale = min(1.0, proxyLongEdge / longEdge)
        var proxy = image
        if scale < 1.0 {
            proxy = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let width = Int(proxy.extent.width.rounded(.down))
        let height = Int(proxy.extent.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }

        // Working-space (linear) readback: colorSpace nil = no color matching.
        var buffer = [Float](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                context.render(
                    proxy,
                    toBitmap: baseAddress,
                    rowBytes: width * 4 * MemoryLayout<Float>.size,
                    bounds: CGRect(x: proxy.extent.minX, y: proxy.extent.minY,
                                   width: CGFloat(width), height: CGFloat(height)),
                    format: .RGBAf,
                    colorSpace: nil
                )
            }
        }

        var lumas = [Double]()
        lumas.reserveCapacity(width * height)
        var mean = 0.0
        var highlightMass = 0.0
        var shadowMass = 0.0
        var weights = [Double](repeating: 0, count: binCount)
        for i in 0..<(width * height) {
            let r = Double(buffer[i * 4])
            let g = Double(buffer[i * 4 + 1])
            let b = Double(buffer[i * 4 + 2])
            // Clamp: working space is extended, but the decode contract is
            // bounded; protect the bin math from stray negatives/overshoot.
            let y = max(0.0, min(1.0, 0.2126 * r + 0.7152 * g + 0.0722 * b))
            lumas.append(y)
            mean += y
            if y > 0.9 { highlightMass += 1 }
            if y < 0.02 { shadowMass += 1 }
            let bin = min(binCount - 1, Int(y * Double(binCount)))
            weights[bin] += 1
        }
        let total = Double(lumas.count)
        guard total > 0 else { return nil }

        lumas.sort()
        func percentile(_ p: Double) -> Double {
            lumas[min(lumas.count - 1, Int(p * Double(lumas.count)))]
        }

        var cdf = [Double](repeating: 0, count: binCount)
        var running = 0.0
        for bin in 0..<binCount {
            running += weights[bin]
            cdf[bin] = running / total
        }

        return ImageAnalysis(
            medianLuma: percentile(0.5),
            meanLuma: mean / total,
            p05: percentile(0.05),
            p995: percentile(0.995),
            highlightFraction: highlightMass / total,
            shadowFraction: shadowMass / total,
            cdf: cdf
        )
    }
}
