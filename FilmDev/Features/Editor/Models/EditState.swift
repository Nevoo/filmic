import Foundation
import CoreGraphics

struct EditState: Equatable, Codable, Sendable {
    // Basic adjustments
    var exposure: Double = 0       // -3.0 to +3.0 EV
    var contrast: Double = 0       // -1.0 to +1.0
    var highlights: Double = 0     // -1.0 to +1.0
    var shadows: Double = 0        // -1.0 to +1.0
    var whites: Double = 0         // -1.0 to +1.0
    var blacks: Double = 0         // -1.0 to +1.0

    // Color adjustments
    var hue: Double = 0            // -π to +π radians
    var saturation: Double = 0     // -1.0 to +1.0
    var vibrance: Double = 0       // -1.0 to +1.0

    // LUT
    var activeLUTName: String?
    var activeLUTData: Data?
    var activeLUTSize: Int?

    // Curves (5 control points each)
    var rgbCurve: [CGPoint] = EditState.defaultCurvePoints
    var redCurve: [CGPoint] = EditState.defaultCurvePoints
    var greenCurve: [CGPoint] = EditState.defaultCurvePoints
    var blueCurve: [CGPoint] = EditState.defaultCurvePoints

    // White balance (RAW decode-time)
    var temperature: Double = 6500  // Kelvin, 2000–10000
    var tint: Double = 0            // -150 to +150

    // Detail
    var sharpening: Double = 0      // 0 to 2.0
    var noiseReduction: Double = 0  // 0 to 1.0

    // Effects
    var vignetteIntensity: Double = 0  // -1.0 to 3.0 (0 = off)
    var vignetteRadius: Double = 1.0   // 0.0 to 2.0
    var grainAmount: Double = 0        // 0 to 1.0
    var grainSize: Double = 0.5        // 0.25 to 2.0

    // Crop (normalized 0–1 coordinates, nil = no crop)
    var cropRect: CodableRect?

    static let defaultCurvePoints: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.0),
        CGPoint(x: 0.25, y: 0.25),
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75),
        CGPoint(x: 1.0, y: 1.0)
    ]

    var isDefault: Bool {
        exposure == 0 && contrast == 0 &&
        highlights == 0 && shadows == 0 &&
        whites == 0 && blacks == 0 &&
        hue == 0 && saturation == 0 && vibrance == 0 &&
        activeLUTData == nil &&
        rgbCurve == Self.defaultCurvePoints &&
        redCurve == Self.defaultCurvePoints &&
        greenCurve == Self.defaultCurvePoints &&
        blueCurve == Self.defaultCurvePoints &&
        temperature == 6500 && tint == 0 &&
        sharpening == 0 && noiseReduction == 0 &&
        vignetteIntensity == 0 && vignetteRadius == 1.0 &&
        grainAmount == 0 && grainSize == 0.5 &&
        cropRect == nil
    }

    mutating func reset() {
        self = EditState()
    }

    /// Reloads LUT data from the bundled .cube file matching `activeLUTName`.
    /// Call after decoding from a sidecar file.
    mutating func reloadLUTIfNeeded() {
        guard let lutName = activeLUTName, activeLUTData == nil else { return }
        let fileName = lutName.replacingOccurrences(of: " ", with: "_")
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "cube"),
              let lutData = try? LUTParser.parse(cubeFileAt: url) else {
            // LUT file not found — clear the reference
            activeLUTName = nil
            activeLUTSize = nil
            return
        }
        activeLUTData = lutData.data
        activeLUTSize = lutData.size
    }

    // Codable conformance for CGPoint
    enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks
        case hue, saturation, vibrance
        case activeLUTName
        case rgbCurve, redCurve, greenCurve, blueCurve
        case temperature, tint
        case sharpening, noiseReduction
        case vignetteIntensity, vignetteRadius
        case grainAmount, grainSize
        case cropRect
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        whites = try container.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try container.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        hue = try container.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        activeLUTName = try container.decodeIfPresent(String.self, forKey: .activeLUTName)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        sharpening = try container.decodeIfPresent(Double.self, forKey: .sharpening) ?? 0
        noiseReduction = try container.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        vignetteIntensity = try container.decodeIfPresent(Double.self, forKey: .vignetteIntensity) ?? 0
        vignetteRadius = try container.decodeIfPresent(Double.self, forKey: .vignetteRadius) ?? 1.0
        grainAmount = try container.decodeIfPresent(Double.self, forKey: .grainAmount) ?? 0
        grainSize = try container.decodeIfPresent(Double.self, forKey: .grainSize) ?? 0.5
        cropRect = try container.decodeIfPresent(CodableRect.self, forKey: .cropRect)

        if let points = try container.decodeIfPresent([CodablePoint].self, forKey: .rgbCurve) {
            rgbCurve = points.map { $0.cgPoint }
        }
        if let points = try container.decodeIfPresent([CodablePoint].self, forKey: .redCurve) {
            redCurve = points.map { $0.cgPoint }
        }
        if let points = try container.decodeIfPresent([CodablePoint].self, forKey: .greenCurve) {
            greenCurve = points.map { $0.cgPoint }
        }
        if let points = try container.decodeIfPresent([CodablePoint].self, forKey: .blueCurve) {
            blueCurve = points.map { $0.cgPoint }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(whites, forKey: .whites)
        try container.encode(blacks, forKey: .blacks)
        try container.encode(hue, forKey: .hue)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encodeIfPresent(activeLUTName, forKey: .activeLUTName)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(sharpening, forKey: .sharpening)
        try container.encode(noiseReduction, forKey: .noiseReduction)
        try container.encode(vignetteIntensity, forKey: .vignetteIntensity)
        try container.encode(vignetteRadius, forKey: .vignetteRadius)
        try container.encode(grainAmount, forKey: .grainAmount)
        try container.encode(grainSize, forKey: .grainSize)
        try container.encode(rgbCurve.map { CodablePoint($0) }, forKey: .rgbCurve)
        try container.encode(redCurve.map { CodablePoint($0) }, forKey: .redCurve)
        try container.encode(greenCurve.map { CodablePoint($0) }, forKey: .greenCurve)
        try container.encode(blueCurve.map { CodablePoint($0) }, forKey: .blueCurve)
        try container.encodeIfPresent(cropRect, forKey: .cropRect)
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
