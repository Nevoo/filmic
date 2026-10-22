import Foundation
import CoreGraphics

struct EditState: Equatable, Codable, Sendable {
    // Tone
    var exposure: Double = 0       // -3.0 to +3.0 EV
    var contrast: Double = 0       // -1.0 to +1.0
    var highlights: Double = 0     // -1.0 to +1.0
    var shadows: Double = 0        // -1.0 to +1.0

    // Color
    var saturation: Double = 0     // -1.0 to +1.0
    var vibrance: Double = 0       // -1.0 to +1.0

    // Master tone curve (applied post-LUT)
    var rgbCurve: [CGPoint] = EditState.defaultCurvePoints

    // White balance (RAW decode-time)
    var temperature: Double = 6500  // Kelvin, 2000–10000
    var tint: Double = 0            // -150 to +150

    // LUT
    var activeLUTName: String?
    var activeLUTData: Data?
    var activeLUTSize: Int?
    var activeLUTCategory: String?
    var lutIntensity: Double = 1.0  // 0 = no look, 1 = full strength

    // Effects
    var vignetteIntensity: Double = 0  // -1.0 to 3.0 (0 = off)
    var vignetteRadius: Double = 1.0   // 0.0 to 2.0
    var grainAmount: Double = 0        // 0 to 1.0
    var grainSize: Double = 0.5        // 0.25 to 2.0

    // Optics (film softness — spatial, applied post-LUT, never in the cube)
    var halationIntensity: Double = 0  // 0 to 1.0 (red/orange highlight bleed)
    var glowIntensity: Double = 0      // 0 to 1.0 (whole-image bloom / "air")
    var glowRadius: Double = 0.5       // 0.0 to 1.0 (normalized blur spread)

    // Light leak (procedural warm edge fog). Presence is a one-shot bernoulli
    // rolled at look-apply time (see rollLeak) and persisted here — the pipeline
    // never re-rolls, so a frame that "got a leak" keeps it forever.
    var leakIntensity: Double = 0      // 0 to 1.0 (0 = no leak)
    var leakVariant: Int = 0           // reroll counter; reshapes/recolors the leak

    // Crop (normalized 0–1)
    var cropRect: CodableRect?
    var straightenAngle: Double = 0  // radians; rotate + auto-crop, applied before the crop rect

    // Provenance: which auto-managed fields are still owned by the analyzer.
    // Auto fields re-derive when the look changes; a field leaves the set the
    // moment the user trims it by hand and never re-enters for this image.
    // Old sidecars carry no key → empty set → everything is manual, so
    // re-running auto never clobbers hand edits made before this existed.
    enum EditField: String, Codable, CaseIterable, Sendable {
        case exposure, highlights, shadows
    }
    var autoFields: Set<EditField> = []

    /// Stamps analyzer-derived trims onto the fields still owned by auto.
    /// Returns the values actually applied so the caller can track manual
    /// divergence later.
    mutating func applyAutoTrims(_ trims: PresetIntent.DerivedTrims) {
        if autoFields.contains(.exposure) { exposure = trims.exposure }
        if autoFields.contains(.highlights) { highlights = trims.highlights }
        if autoFields.contains(.shadows) { shadows = trims.shadows }
    }

    subscript(field: EditField) -> Double {
        switch field {
        case .exposure: exposure
        case .highlights: highlights
        case .shadows: shadows
        }
    }

    /// A tone curve starts as just its two endpoints (a straight identity line).
    /// Points are added by clicking on the curve — no premade interior points.
    static let defaultCurvePoints: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.0),
        CGPoint(x: 1.0, y: 1.0)
    ]

    var isDefault: Bool {
        exposure == 0 && contrast == 0 &&
        highlights == 0 && shadows == 0 &&
        saturation == 0 && vibrance == 0 &&
        activeLUTData == nil &&
        isCurveDefault(rgbCurve) &&
        vignetteIntensity == 0 && vignetteRadius == 1.0 &&
        grainAmount == 0 && grainSize == 0.5 &&
        halationIntensity == 0 && glowIntensity == 0 && glowRadius == 0.5 &&
        leakIntensity == 0 && leakVariant == 0 &&
        cropRect == nil && straightenAngle == 0
    }

    private func isCurveDefault(_ curve: [CGPoint]) -> Bool {
        curve.allSatisfy { abs($0.x - $0.y) < 0.001 }
    }

    var isToneDefault: Bool {
        let d = EditState()
        return exposure == d.exposure && contrast == d.contrast &&
               highlights == d.highlights && shadows == d.shadows
    }

    var isColorDefault: Bool {
        let d = EditState()
        return saturation == d.saturation && vibrance == d.vibrance
    }

    var isEffectsDefault: Bool {
        let d = EditState()
        return vignetteIntensity == d.vignetteIntensity && vignetteRadius == d.vignetteRadius &&
               grainAmount == d.grainAmount && grainSize == d.grainSize &&
               halationIntensity == d.halationIntensity && glowIntensity == d.glowIntensity &&
               glowRadius == d.glowRadius &&
               leakIntensity == d.leakIntensity && leakVariant == d.leakVariant
    }

    mutating func reset() {
        self = EditState()
    }

    /// Resets only the tone controls (exposure + contrast/highlights/shadows),
    /// leaving the film look, color, curve, effects, WB and crop untouched.
    mutating func resetTone() {
        let d = EditState()
        exposure = d.exposure
        contrast = d.contrast
        highlights = d.highlights
        shadows = d.shadows
    }

    /// Resets only the color controls.
    mutating func resetColor() {
        let d = EditState()
        saturation = d.saturation
        vibrance = d.vibrance
    }

    /// Resets only the effects controls (vignette + grain).
    mutating func resetEffects() {
        let d = EditState()
        vignetteIntensity = d.vignetteIntensity
        vignetteRadius = d.vignetteRadius
        grainAmount = d.grainAmount
        grainSize = d.grainSize
        halationIntensity = d.halationIntensity
        glowIntensity = d.glowIntensity
        glowRadius = d.glowRadius
        leakIntensity = d.leakIntensity
        leakVariant = d.leakVariant
    }

    /// Stamps a film look onto this state: sets the LUT at full strength and
    /// resets preset-managed effects to neutral before applying the look's
    /// defaults (so switching looks never leaves the prior look's grain behind).
    /// Single source of truth for the editor and batch-export paths.
    mutating func apply(preset: FilmPreset) {
        activeLUTName = preset.name
        activeLUTData = preset.lutData
        activeLUTSize = preset.lutSize
        activeLUTCategory = preset.category.rawValue
        lutIntensity = 1.0

        let d = EditState()
        grainAmount = d.grainAmount
        grainSize = d.grainSize
        vignetteIntensity = d.vignetteIntensity
        halationIntensity = d.halationIntensity
        glowIntensity = d.glowIntensity
        glowRadius = d.glowRadius
        // Leak presence is NOT stamped from defaults here — apply(preset:) has no
        // image identity. Reset to neutral; the caller rolls it via rollLeak once
        // the URL is known, so the outcome is deterministic per image.
        leakIntensity = d.leakIntensity
        leakVariant = d.leakVariant
        if let defaults = preset.defaults {
            if let grain = defaults.grainAmount { grainAmount = grain }
            if let size = defaults.grainSize { grainSize = size }
            if let vignette = defaults.vignetteIntensity { vignetteIntensity = vignette }
            if let halation = defaults.halationIntensity { halationIntensity = halation }
            if let glow = defaults.glowIntensity { glowIntensity = glow }
            if let glowRad = defaults.glowRadius { glowRadius = glowRad }
        }
    }

    /// One-shot light-leak presence roll for this image + stock. Presence is
    /// decided HERE, at look-apply time — never inside the pipeline — so the
    /// outcome persists in the sidecar and the render stays a pure function of
    /// EditState + seed. A bernoulli(`leakProbability`) trial seeded by
    /// (imageIdentity + stock) sets `leakIntensity` to the stock default or 0.
    /// Stocks with no leak recipe (probability nil/0) always resolve to 0; the
    /// user can still pull the slider up by hand. `imageIdentity` is the image's
    /// file name (same identity that seeds the grain field).
    mutating func rollLeak(imageIdentity: String, preset: FilmPreset) {
        guard let probability = preset.defaults?.leakProbability,
              let intensity = preset.defaults?.leakIntensity,
              probability > 0, intensity > 0 else {
            leakIntensity = 0
            return
        }
        // FNV-1a over a leak-specific identity, then one SplitMix64 step for a
        // well-distributed unit draw. The "|leak" tag decorrelates this trial
        // from the grain seed (which hashes the bare file name).
        let seed = StableHash.seed(for: "\(imageIdentity)|\(preset.name)|leak")
        let roll = Double(StableHash.splitMix64(seed) >> 11) * (1.0 / 9_007_199_254_740_992.0)
        leakIntensity = roll < probability ? intensity : 0
    }

    /// Reloads LUT data from the bundled .cube file matching `activeLUTName`.
    /// Used after sidecar decode and undo/redo (undo snapshots drop `activeLUTData`
    /// to keep the stack from holding 50 megabytes of cube data).
    mutating func reloadLUTIfNeeded() {
        guard let lutName = activeLUTName, activeLUTData == nil else { return }
        let fileName = lutName.replacingOccurrences(of: " ", with: "_")
        let subdirectory = activeLUTCategory.map { "LUTs/\($0.lowercased())" }
        guard let url = (subdirectory.flatMap { Bundle.main.url(forResource: fileName, withExtension: "cube", subdirectory: $0) }
                         ?? Bundle.main.url(forResource: fileName, withExtension: "cube", subdirectory: "LUTs")
                         ?? Bundle.main.url(forResource: fileName, withExtension: "cube")),
              let lutData = try? LUTParser.parse(cubeFileAt: url) else {
            activeLUTName = nil
            activeLUTSize = nil
            return
        }
        activeLUTData = lutData.data
        activeLUTSize = lutData.size
    }

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows
        case saturation, vibrance
        case rgbCurve
        case temperature, tint
        case activeLUTName, activeLUTCategory, lutIntensity
        case vignetteIntensity, vignetteRadius
        case grainAmount, grainSize
        case halationIntensity, glowIntensity, glowRadius
        case leakIntensity, leakVariant
        case cropRect, straightenAngle
        case autoFields
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        activeLUTName = try container.decodeIfPresent(String.self, forKey: .activeLUTName)
        activeLUTCategory = try container.decodeIfPresent(String.self, forKey: .activeLUTCategory)
        lutIntensity = try container.decodeIfPresent(Double.self, forKey: .lutIntensity) ?? 1.0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        vignetteIntensity = try container.decodeIfPresent(Double.self, forKey: .vignetteIntensity) ?? 0
        vignetteRadius = try container.decodeIfPresent(Double.self, forKey: .vignetteRadius) ?? 1.0
        grainAmount = try container.decodeIfPresent(Double.self, forKey: .grainAmount) ?? 0
        grainSize = try container.decodeIfPresent(Double.self, forKey: .grainSize) ?? 0.5
        halationIntensity = try container.decodeIfPresent(Double.self, forKey: .halationIntensity) ?? 0
        glowIntensity = try container.decodeIfPresent(Double.self, forKey: .glowIntensity) ?? 0
        glowRadius = try container.decodeIfPresent(Double.self, forKey: .glowRadius) ?? 0.5
        leakIntensity = try container.decodeIfPresent(Double.self, forKey: .leakIntensity) ?? 0
        leakVariant = try container.decodeIfPresent(Int.self, forKey: .leakVariant) ?? 0
        cropRect = try container.decodeIfPresent(CodableRect.self, forKey: .cropRect)
        straightenAngle = try container.decodeIfPresent(Double.self, forKey: .straightenAngle) ?? 0
        autoFields = try container.decodeIfPresent(Set<EditField>.self, forKey: .autoFields) ?? []

        if let points = try container.decodeIfPresent([CodablePoint].self, forKey: .rgbCurve) {
            rgbCurve = points.map { $0.cgPoint }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encodeIfPresent(activeLUTName, forKey: .activeLUTName)
        try container.encodeIfPresent(activeLUTCategory, forKey: .activeLUTCategory)
        try container.encode(lutIntensity, forKey: .lutIntensity)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(vignetteIntensity, forKey: .vignetteIntensity)
        try container.encode(vignetteRadius, forKey: .vignetteRadius)
        try container.encode(grainAmount, forKey: .grainAmount)
        try container.encode(grainSize, forKey: .grainSize)
        try container.encode(halationIntensity, forKey: .halationIntensity)
        try container.encode(glowIntensity, forKey: .glowIntensity)
        try container.encode(glowRadius, forKey: .glowRadius)
        try container.encode(leakIntensity, forKey: .leakIntensity)
        try container.encode(leakVariant, forKey: .leakVariant)
        try container.encode(rgbCurve.map { CodablePoint($0) }, forKey: .rgbCurve)
        try container.encodeIfPresent(cropRect, forKey: .cropRect)
        try container.encode(straightenAngle, forKey: .straightenAngle)
        try container.encode(autoFields, forKey: .autoFields)
    }
}

struct CodablePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct CodableRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
