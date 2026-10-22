import CoreImage
import CoreGraphics

struct HistogramData: Equatable, Sendable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]
    let luminance: [Float]
}

struct ImageProcessor: @unchecked Sendable {
    private let context: CIContext
    private let toneShapeKernel: CIColorKernel?
    private let halationMaskKernel: CIColorKernel?
    private let glowWeightKernel: CIColorKernel?
    private let filmGrainKernel: CIColorKernel?
    private let lightLeakKernel: CIColorKernel?
    private let curveCubeDimension = 33

    init(context: CIContext) {
        self.context = context
        self.toneShapeKernel = Self.makeToneShapeKernel()
        self.halationMaskKernel = Self.makeHalationMaskKernel()
        self.glowWeightKernel = Self.makeGlowWeightKernel()
        self.filmGrainKernel = Self.makeFilmGrainKernel()
        self.lightLeakKernel = Self.makeLightLeakKernel()
    }

    // MARK: - Pipeline

    /// Display-referred pipeline. Input is the libraw decode contract:
    /// camera-WB, auto-bright disabled, bounded sRGB (display-referred) in the
    /// working color space. `toneShape` does exposure + tone-region shaping in
    /// that space and stays bounded ~[0,1], so the result is safe to feed the LUT.
    /// `grainSeed` gives each image a unique but stable grain field: same seed →
    /// byte-identical grain forever, different seeds → different pattern. Seed 0
    /// (the default) reproduces the pre-seed output exactly. Derive it from a
    /// file identity via `StableHash.seed(for:)`.
    func process(image: CIImage, editState: EditState, isDragging: Bool = false, grainSeed: UInt64 = 0) -> CIImage {
        let exposureGain = pow(2.0, editState.exposure)
        var result = applyToneShape(
            image,
            exposureGain: exposureGain,
            highlights: editState.highlights,
            shadows: editState.shadows,
            contrast: editState.contrast
        )

        // Stage B — display-referred creative ops.
        result = applyActiveLUT(from: editState, to: result)

        if editState.saturation != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.0 + editState.saturation * 0.4
            ])
        }
        if editState.vibrance != 0 {
            result = result.applyingFilter("CIVibrance", parameters: [
                "inputAmount": editState.vibrance * 0.6
            ])
        }

        result = applyCurve(editState.rgbCurve, to: result)

        // Optics — spatial film softness on the graded image, before grain.
        // Skipped during drag (like grain) since the blurs are the heavy passes.
        if !isDragging {
            if editState.halationIntensity > 0 {
                result = applyHalation(to: result, intensity: editState.halationIntensity)
            }
            if editState.glowIntensity > 0 {
                result = applyGlow(to: result, intensity: editState.glowIntensity, radius: editState.glowRadius)
            }
        }

        if editState.grainAmount > 0 && !isDragging {
            result = applyFilmGrain(to: result, amount: editState.grainAmount, size: editState.grainSize, seed: grainSeed)
        }
        if editState.vignetteIntensity != 0 {
            result = result.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: editState.vignetteIntensity,
                kCIInputRadiusKey: editState.vignetteRadius
            ])
        }

        // Light leak — the last effect stage, screened over the finished frame.
        // Static per image (presence + shape are seeded, not re-rolled), so it
        // runs during drag too: it's one cheap kernel plus a blur. Placed after
        // the vignette so the warm fog reads as light hitting the film on top of
        // the darkened corners, not something the lens produced.
        if editState.leakIntensity > 0 {
            result = applyLightLeak(
                to: result,
                intensity: editState.leakIntensity,
                seed: grainSeed,
                variant: editState.leakVariant
            )
        }

        // Straighten: rotate + auto-crop to the largest rect inside the rotated
        // frame (CIStraightenFilter keeps the input extent, so no empty corners
        // and downstream crop coords still map 1:1).
        if editState.straightenAngle != 0 {
            result = result.applyingFilter("CIStraightenFilter", parameters: [
                kCIInputAngleKey: editState.straightenAngle
            ])
        }

        if let crop = editState.cropRect {
            let extent = result.extent
            let cropY = 1.0 - crop.y - crop.height
            let cropCGRect = CGRect(
                x: extent.origin.x + crop.x * extent.width,
                y: extent.origin.y + cropY * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            )
            result = result.cropped(to: cropCGRect)
        }

        return result
    }

    func render(image: CIImage, scale: CGFloat = 1.0) -> CGImage? {
        var renderImage = image
        if scale < 1.0 {
            renderImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = renderImage.extent
        guard !extent.isInfinite && !extent.isEmpty else { return nil }
        return context.createCGImage(renderImage, from: extent)
    }

    // MARK: - Histogram

    func generateHistogram(from image: CIImage) -> HistogramData? {
        let extent = image.extent
        guard !extent.isInfinite && !extent.isEmpty else { return nil }
        let binCount = 256
        let pixelCount = max(1.0, extent.width * extent.height)
        let histogram = image.applyingFilter("CIAreaHistogram", parameters: [
            "inputScale": 1.0 / pixelCount,
            "inputCount": binCount,
            "inputExtent": CIVector(cgRect: extent)
        ])

        var pixels = [Float](repeating: 0, count: binCount * 4)
        pixels.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                context.render(
                    histogram,
                    toBitmap: baseAddress,
                    rowBytes: binCount * 4 * MemoryLayout<Float>.size,
                    bounds: CGRect(x: 0, y: 0, width: binCount, height: 1),
                    format: .RGBAf,
                    colorSpace: nil
                )
            }
        }

        var red = [Float](repeating: 0, count: binCount)
        var green = [Float](repeating: 0, count: binCount)
        var blue = [Float](repeating: 0, count: binCount)
        var luminance = [Float](repeating: 0, count: binCount)

        for index in 0..<binCount {
            let offset = index * 4
            let r = max(0, pixels[offset])
            let g = max(0, pixels[offset + 1])
            let b = max(0, pixels[offset + 2])
            red[index] = r
            green[index] = g
            blue[index] = b
            luminance[index] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        return HistogramData(red: red, green: green, blue: blue, luminance: luminance)
    }

    // MARK: - Kernel

    private func applyToneShape(_ image: CIImage,
                                exposureGain: Double,
                                highlights: Double,
                                shadows: Double,
                                contrast: Double) -> CIImage {
        guard let kernel = toneShapeKernel else { return image }
        let args: [Any] = [
            image,
            Float(exposureGain),
            Float(highlights),
            Float(shadows),
            Float(contrast)
        ]
        return kernel.apply(extent: image.extent, arguments: args) ?? image
    }

    // Single-pass tone shaping in display-referred space. The libraw decode is
    // camera-WB, auto-bright disabled, bounded sRGB, so the input here is
    // already display-referred in the working color space. The kernel scales
    // RGB by a luminance-norm ratio: chroma stays put, only tone changes, so
    // there is no per-channel hue shift under contrast.
    private static func makeToneShapeKernel() -> CIColorKernel? {
        let source = """
        kernel vec4 toneShape(__sample px,
                                float exposureGain,
                                float highlights,
                                float shadows,
                                float contrast) {
            vec3 c = px.rgb * exposureGain;

            float Y = max(dot(c, vec3(0.2627, 0.678, 0.0593)), 0.0001);
            float Yout = Y;

            // Highlights and shadows applied as gamma-style curves on the
            // luminance norm. Gamma-form tapers naturally at the extremes —
            // no risk of an additive lift overshooting into haze.
            if (highlights != 0.0) {
                float w = smoothstep(0.4, 1.0, Y);
                // positive highlights → exponent > 1 → compress brights
                // negative highlights → exponent < 1 → boost brights
                Yout = pow(Yout, 1.0 + w * highlights * 0.6);
            }
            if (shadows != 0.0) {
                float w = 1.0 - smoothstep(0.0, 0.35, Y);
                // positive shadows → exponent < 1 → lift darks
                // negative shadows → exponent > 1 → crush darks
                Yout = pow(Yout, 1.0 - w * shadows * 0.4);
            }
            if (contrast != 0.0) {
                // Gentle gamma around middle grey, anchored at 0.18.
                Yout = 0.18 * pow(max(Yout / 0.18, 0.0001), 1.0 + contrast * 0.4);
            }

            // Soft highlight knee: exposure gain can push luminance past 1.0,
            // and everything past 1.0 would hard-clamp at the LUT input —
            // flat, textureless patches (lost information). Roll the top end
            // off instead: 1.0 -> 0.95, +1EV overshoot -> ~0.99, asymptote 1.0.
            float knee = 0.90;
            if (Yout > knee) {
                float t = (Yout - knee) / (1.0 - knee);
                Yout = knee + (1.0 - knee) * t / (1.0 + t);
            }

            float scale = max(Yout, 0.0) / Y;
            return vec4(c * scale, px.a);
        }
        """
        return CIColorKernel(source: source)
    }

    // MARK: - LUT

    private func applyActiveLUT(from editState: EditState, to image: CIImage) -> CIImage {
        guard let lutData = editState.activeLUTData,
              let lutSize = editState.activeLUTSize else {
            return image
        }
        let looked = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": lutSize,
            "inputCubeData": lutData,
            "inputColorSpace": FilmColorPipeline.displayColorSpace
        ])

        // Blend the look back toward the un-LUT'd image for sub-full strength.
        let intensity = max(0, min(1, editState.lutIntensity))
        guard intensity < 0.999 else { return looked }
        return looked.applyingFilter("CIDissolveTransition", parameters: [
            "inputTargetImage": image,
            "inputTime": 1.0 - intensity
        ])
    }

    // MARK: - Curve

    private func applyCurve(_ curve: [CGPoint], to image: CIImage) -> CIImage {
        let isIdentity = curve.allSatisfy { abs($0.x - $0.y) < 0.001 }
        guard !isIdentity, curve.count >= 2 else { return image }

        let dimension = curveCubeDimension
        var cube = [Float]()
        cube.reserveCapacity(dimension * dimension * dimension * 4)

        for blueIndex in 0..<dimension {
            let blue = CGFloat(blueIndex) / CGFloat(dimension - 1)
            let curvedBlue = Float(Self.sampleToneCurve(at: blue, points: curve))
            for greenIndex in 0..<dimension {
                let green = CGFloat(greenIndex) / CGFloat(dimension - 1)
                let curvedGreen = Float(Self.sampleToneCurve(at: green, points: curve))
                for redIndex in 0..<dimension {
                    let red = CGFloat(redIndex) / CGFloat(dimension - 1)
                    cube.append(Float(Self.sampleToneCurve(at: red, points: curve)))
                    cube.append(curvedGreen)
                    cube.append(curvedBlue)
                    cube.append(1)
                }
            }
        }

        let cubeData = cube.withUnsafeBytes { Data($0) }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": cubeData,
            "inputColorSpace": FilmColorPipeline.displayColorSpace
        ])
    }

    /// Monotone cubic Hermite interpolation (Fritsch–Carlson). Smooth (C¹), never
    /// overshoots past the control points, stays monotonic where the data is, and
    /// reproduces a straight line exactly for collinear points — so the identity
    /// curve is truly identity. Used for both the on-screen curve and the LUT.
    static func sampleToneCurve(at x: CGFloat, points: [CGPoint]) -> CGFloat {
        guard points.count >= 2, let first = points.first, let last = points.last else {
            return points.first?.y ?? x
        }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }

        let m = monotoneTangents(points)

        var i = 0
        while i < points.count - 1 && x > points[i + 1].x { i += 1 }
        let p1 = points[i]
        let p2 = points[i + 1]
        let h = p2.x - p1.x
        guard h > 0 else { return p1.y }

        let t = (x - p1.x) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2

        let y = h00 * p1.y + h10 * h * m[i] + h01 * p2.y + h11 * h * m[i + 1]
        return max(0, min(1, y))
    }

    /// Per-point tangents constrained for monotonicity (Fritsch–Carlson).
    private static func monotoneTangents(_ points: [CGPoint]) -> [CGFloat] {
        let n = points.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }

        var secant = [CGFloat](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            let dx = points[k + 1].x - points[k].x
            secant[k] = dx > 0 ? (points[k + 1].y - points[k].y) / dx : 0
        }

        var m = [CGFloat](repeating: 0, count: n)
        m[0] = secant[0]
        m[n - 1] = secant[n - 2]
        for k in 1..<(n - 1) {
            m[k] = (secant[k - 1] + secant[k]) / 2
        }

        for k in 0..<(n - 1) {
            if secant[k] == 0 {
                m[k] = 0
                m[k + 1] = 0
            } else {
                let alpha = m[k] / secant[k]
                let beta = m[k + 1] / secant[k]
                let sum = alpha * alpha + beta * beta
                if sum > 9 {
                    let tau = 3 / sum.squareRoot()
                    m[k] = tau * alpha * secant[k]
                    m[k + 1] = tau * beta * secant[k]
                }
            }
        }
        return m
    }

    // MARK: - Grain

    private func applyFilmGrain(to image: CIImage, amount: Double, size: Double, seed: UInt64) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite && !extent.isEmpty else { return image }

        guard let randomGenerator = CIFilter(name: "CIRandomGenerator"),
              let noiseOutput = randomGenerator.outputImage else {
            return image
        }

        // CIRandomGenerator emits one fixed (infinite) noise field, so without
        // this every photo would carry the identical grain — a pasted-on look.
        // Slide the sampling window by a per-image offset so each frame gets a
        // different pattern; the offset is stable per seed, so renders stay
        // reproducible. Applied before the scale/crop below. Seed 0 → (0,0).
        let (dx, dy) = Self.grainOffset(seed: seed)
        let seededNoise = noiseOutput.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        let scaleTransform = CGAffineTransform(scaleX: size, y: size)
        let grain = seededNoise
            .transformed(by: scaleTransform)
            .cropped(to: extent)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: size * 0.8
            ])
            .cropped(to: extent)

        // Luminance-coupled additive application. The blurred noise field above
        // is the grain *structure*; the kernel decides *where* it lands. Real
        // film grain lives in the midtones — deep shadows are too dense and
        // blown highlights too saturated to hold visible grain — so uniform
        // grain reads as a pasted-on digital texture. The kernel weights the
        // grain by a midtone window (see makeFilmGrainKernel) and adds it
        // zero-centered (noise.r - 0.5), so a flat patch keeps its mean: no
        // luminance lift, unlike the overlay blend this replaced.
        guard let kernel = filmGrainKernel else { return image }
        return kernel.apply(extent: extent, arguments: [image, grain, Float(amount)]) ?? image
    }

    /// Luminance-coupled, zero-centered additive grain.
    ///
    /// `w` is a midtone window built from two smoothsteps: it ramps in over the
    /// deep shadows (0.015–0.12 linear luma) and rolls back out across the
    /// highlights (0.65–0.97), so grain is strongest in the midtones and tapers
    /// to ~zero in crushed blacks and clipped whites. `g = noise.r - 0.5` is the
    /// zero-mean grain sample; adding it (rather than overlay-blending) leaves
    /// the patch mean untouched. `K` is the overall gain, tuned by A/B against
    /// the prior overlay-blend output at the catalog stocks' default grain
    /// amounts so perceived midtone strength is unchanged. The same `g` feeds
    /// all three channels — pure-luma grain, chroma ≈ 0 — which is correct for
    /// the B&W sims and an acceptable v1 simplification for the colour sims.
    private static func makeFilmGrainKernel() -> CIColorKernel? {
        // POSIX locale forces a '.' decimal separator: a localized ',' would be
        // invalid kernel source, the compile would fail, and grain would
        // silently vanish. (Plain String(format:) already uses '.', but pin it.)
        let k = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), grainGain)
        let source = """
        kernel vec4 filmGrain(__sample base, __sample noise, float amount) {
            float Y = dot(base.rgb, vec3(0.2126, 0.7152, 0.0722));
            float w = smoothstep(0.015, 0.12, Y) * (1.0 - smoothstep(0.65, 0.97, Y));
            float g = noise.r - 0.5;
            return vec4(base.rgb + g * amount * w * \(k), base.a);
        }
        """
        return CIColorKernel(source: source)
    }

    /// Overall grain gain `K`. Tuned so the new midtone grain amplitude matches
    /// the prior overlay-blend output at the catalog stocks' default grain
    /// amounts. Measured on RVN03908 (full-res midtone diff-image stddev, A/B
    /// against the old overlay build, floor-modelled from two K points): the
    /// per-stock match points cluster at 0.32–0.36, so K=0.34 lands all three
    /// tuning stocks within ~±4% of the old perceived strength.
    private static let grainGain: Float = 0.34

    /// Per-image grain-field translation derived from the seed. Two independent
    /// SplitMix64 draws give dx, dy in [0, 8192) — enough distinct windows that
    /// no two files collide in practice. Seed 0 → (0,0), reproducing the
    /// pre-seed render byte-for-byte.
    private static func grainOffset(seed: UInt64) -> (dx: CGFloat, dy: CGFloat) {
        guard seed != 0 else { return (0, 0) }
        let vx = StableHash.splitMix64(seed)
        let vy = StableHash.splitMix64(vx)
        return (CGFloat(vx % 8192), CGFloat(vy % 8192))
    }

    // MARK: - Optics

    // Halation: the reddish bleed film shows around bright sources, where light
    // punched through the emulsion and re-exposed the red layer. A soft highlight
    // mask (NOT a hard clip count, so grading artifacts don't drive it) is tinted
    // red/orange, blurred, and screened back.
    //
    // Two blur scales: a tight ring carrying most of the energy (real halation
    // hugs the source) and a wide faint falloff. A single wide Gaussian doesn't
    // read at all — small sources (string lights) dilute into invisibility.
    private func applyHalation(to image: CIImage, intensity: Double) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, let kernel = halationMaskKernel else { return image }

        // Near-clip threshold (0.94–0.995 linear luma): halation hugs light
        // sources and speculars. A lower threshold sweeps in sunlit fabric and
        // skies and washes the whole frame milky — screen blends only brighten.
        let source = kernel.apply(extent: extent, arguments: [image, Float(0.94), Float(0.995)]) ?? image

        let frame = min(extent.width, extent.height)
        let clamped = source.clampedToExtent()
        let tight = clamped
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: frame * 0.004])
            .cropped(to: extent)
        let wide = clamped
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: frame * 0.016])
            .cropped(to: extent)

        // Sum the scales with gain so the bleed survives the blur dilution.
        let bloom = tight.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: wide.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.9, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.9, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.9, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        ])

        return screen(bloom, over: image, intensity: intensity)
    }

    // Glow: a blurred copy of the image, weighted toward its highlights, then
    // screened back — the bloom of a diffusion filter. The highlight weighting
    // is what keeps it from being fog: an UNmasked screen of a blurred copy
    // lifts shadows and blacks across the whole frame (screen only brightens),
    // which reads as haze, not air. Radius is normalized 0–1.
    private func applyGlow(to image: CIImage, intensity: Double, radius: Double) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, let weight = glowWeightKernel else { return image }

        let r = min(extent.width, extent.height) * (0.008 + max(0, min(1, radius)) * 0.04)
        let blurred = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r])
            .cropped(to: extent)

        // Weight the blurred copy by its own luminance (soft ramp over
        // 0.35–0.9 linear): highlights bloom, mids barely, shadows stay dense.
        let bloom = weight.apply(extent: extent, arguments: [blurred, Float(0.35), Float(0.9)]) ?? blurred

        return screen(bloom, over: image, intensity: intensity)
    }

    /// Scale `foreground` by `intensity`, then screen it over `background`.
    /// Screen keeps black regions of the foreground inert, so masked-out areas
    /// pass the background through untouched.
    private func screen(_ foreground: CIImage, over background: CIImage, intensity: Double) -> CIImage {
        let i = CGFloat(max(0, min(1, intensity)))
        let scaled = foreground.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: i, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: i, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: i, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        return scaled.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: background
        ])
    }

    // MARK: - Light leak

    // Procedural warm edge fog. Whether a frame gets a leak at all is decided
    // upstream (EditState.rollLeak, seeded per image) — by the time we're here
    // leakIntensity is already nonzero, so this only renders the shape. The
    // blob geometry + colour are computed in Swift from a SplitMix64 chain
    // seeded by the per-image grain seed (an independent stream, so leaks don't
    // correlate with grain offsets) folded with the reroll variant. The kernel
    // paints 1–2 elongated Gaussian blobs anchored at/just past a frame edge; a
    // wide blur then softens them to fog before a screen blend lays them over
    // the finished frame. Screen only brightens and black regions are inert, so
    // the rest of the image passes through untouched.
    private func applyLightLeak(to image: CIImage, intensity: Double, seed: UInt64, variant: Int) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, let kernel = lightLeakKernel else { return image }

        let blobs = Self.leakBlobs(seed: seed, variant: variant)
        let args: [Any] = [
            image,
            Float(extent.width), Float(extent.height),
            Float(extent.origin.x), Float(extent.origin.y),
            blobs.0.geom, blobs.0.color,
            blobs.1.geom, blobs.1.color
        ]
        let field = kernel.apply(extent: extent, arguments: args) ?? image

        // Wide blur (≈3% of the short side) turns the already-smooth Gaussians
        // into soft fog with no hard edge. clampedToExtent keeps the frame-edge
        // brightness from decaying into a dark seam under the blur.
        let frame = min(extent.width, extent.height)
        let bloom = field
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: frame * 0.03])
            .cropped(to: extent)

        return screen(bloom, over: image, intensity: intensity)
    }

    /// One warm leak blob: `geom` = (centerX, centerY, sigmaX, sigmaY) in
    /// normalized [0,1] frame coords, `color` = gain-scaled warm RGB. A blob
    /// with a zero colour contributes nothing (the "only one blob" case).
    private struct LeakBlob {
        let geom: CIVector
        let color: CIVector
        static let none = LeakBlob(
            geom: CIVector(x: 0, y: 0, z: 1, w: 1),
            color: CIVector(x: 0, y: 0, z: 0)
        )
    }

    /// Deterministic SplitMix64 draw stream for leak parameters. Seeded from the
    /// per-image grain seed XOR'd with a constant (an independent stream, so leak
    /// geometry doesn't track grain offsets) plus the reroll variant, so the same
    /// image+variant reproduces the same leak forever and each reroll is fresh.
    private struct LeakRNG {
        private var state: UInt64
        init(seed: UInt64, variant: Int) {
            let v = UInt64(bitPattern: Int64(variant))
            state = (seed ^ 0xB529_7A4D_68E3_1DA4) &+ (v &* 0x9E37_79B9_7F4A_7C15) &+ 1
        }
        mutating func unit() -> Double {
            state = StableHash.splitMix64(state)
            return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double {
            lo + (hi - lo) * unit()
        }
    }

    private static func leakBlobs(seed: UInt64, variant: Int) -> (LeakBlob, LeakBlob) {
        var rng = LeakRNG(seed: seed, variant: variant)
        // Mostly a single leak; occasionally a second, fainter one.
        let twoBlobs = rng.unit() < 0.35
        let blob0 = makeLeakBlob(&rng, secondary: false)
        let blob1 = twoBlobs ? makeLeakBlob(&rng, secondary: true) : .none
        return (blob0, blob1)
    }

    private static func makeLeakBlob(_ rng: inout LeakRNG, secondary: Bool) -> LeakBlob {
        // Anchor edge: weighted toward left/right (cassette-mouth leaks enter
        // from the film edge); the remaining ~20% bloom from a corner.
        let edgeRoll = rng.unit()
        let cx: Double, cy: Double, sigmaX: Double, sigmaY: Double
        if edgeRoll < 0.40 {
            // Left edge: peak at/just off the frame, tall and thin.
            cx = rng.range(-0.10, 0.05)
            cy = rng.range(0.10, 0.90)
            sigmaX = rng.range(0.10, 0.30)   // width into the frame
            sigmaY = rng.range(0.22, 0.55)   // elongation along the edge
        } else if edgeRoll < 0.80 {
            // Right edge.
            cx = rng.range(0.95, 1.10)
            cy = rng.range(0.10, 0.90)
            sigmaX = rng.range(0.10, 0.30)
            sigmaY = rng.range(0.22, 0.55)
        } else {
            // Corner bloom.
            let left = rng.unit() < 0.5
            let top = rng.unit() < 0.5
            cx = left ? rng.range(-0.08, 0.05) : rng.range(0.95, 1.08)
            cy = top ? rng.range(0.95, 1.08) : rng.range(-0.08, 0.05)
            sigmaX = rng.range(0.18, 0.35)
            sigmaY = rng.range(0.18, 0.35)
        }

        // Warm colour ramp: red → orange → amber, with a rare (~10%) magenta
        // outlier. A per-blob gain jitters relative brightness; a secondary blob
        // is pulled down so it reads as a fainter companion, not a twin.
        var gain = rng.range(0.75, 1.15)
        if secondary { gain *= 0.6 }
        let r: Double, g: Double, b: Double
        if rng.unit() < 0.10 {
            r = 1.0
            g = rng.range(0.20, 0.35)
            b = rng.range(0.42, 0.60)
        } else {
            let t = rng.unit()               // 0 = red, 1 = amber
            r = 1.0
            g = 0.30 + t * 0.42
            b = 0.10 + t * 0.14
        }

        return LeakBlob(
            geom: CIVector(x: cx, y: cy, z: max(sigmaX, 0.02), w: max(sigmaY, 0.02)),
            color: CIVector(x: r * gain, y: g * gain, z: b * gain)
        )
    }

    // destCoord() gives the working-space pixel position; we normalize by the
    // frame size (origin + extent passed in) so the blob geometry is resolution-
    // independent. Two axis-aligned anisotropic Gaussians are summed; a zero
    // colour blob drops out. Output is the raw leak field (black = no leak),
    // blurred and screened by the caller.
    private static func makeLightLeakKernel() -> CIColorKernel? {
        let source = """
        kernel vec4 lightLeak(__sample unused, float w, float h, float ox, float oy,
                              vec4 b0, vec3 c0, vec4 b1, vec3 c1) {
            vec2 p = destCoord();
            float x = (p.x - ox) / w;
            float y = (p.y - oy) / h;
            float dx0 = (x - b0.x) / b0.z;
            float dy0 = (y - b0.y) / b0.w;
            float g0 = exp(-0.5 * (dx0 * dx0 + dy0 * dy0));
            float dx1 = (x - b1.x) / b1.z;
            float dy1 = (y - b1.y) / b1.w;
            float g1 = exp(-0.5 * (dx1 * dx1 + dy1 * dy1));
            vec3 acc = c0 * g0 + c1 * g1;
            return vec4(acc, 1.0);
        }
        """
        return CIColorKernel(source: source)
    }

    private static func makeHalationMaskKernel() -> CIColorKernel? {
        let source = """
        kernel vec4 halationMask(__sample px, float lo, float hi) {
            float Y = dot(px.rgb, vec3(0.2126, 0.7152, 0.0722));
            float m = smoothstep(lo, hi, Y);
            // Red/orange halation dye colour, weighted by highlight mass.
            vec3 tint = vec3(1.0, 0.32, 0.10);
            return vec4(tint * m, 1.0);
        }
        """
        return CIColorKernel(source: source)
    }

    private static func makeGlowWeightKernel() -> CIColorKernel? {
        let source = """
        kernel vec4 glowWeight(__sample px, float lo, float hi) {
            float Y = dot(px.rgb, vec3(0.2126, 0.7152, 0.0722));
            float m = smoothstep(lo, hi, Y);
            return vec4(px.rgb * m, 1.0);
        }
        """
        return CIColorKernel(source: source)
    }
}
