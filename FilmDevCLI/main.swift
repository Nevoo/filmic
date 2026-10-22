import Foundation
import CoreImage

// Headless render harness. Runs the exact app pipeline (libraw decode →
// toneShape → LUT → optics → grain) on a RAW file so looks can be tuned and
// verified without launching the app.
//
// Usage:
//   filmdev-cli <input.arw> [--preset Name | --preset all] [--out dir]
//               [--lut-dir dir] [--exposure EV] [--no-effects] [--scale N]
//               [--halation N] [--glow N] [--grain N] [--grain-seed N]
//               [--leak N] [--leak-variant N] [--date-stamp] [--auto] [--suffix S]
//
// --date-stamp composites the orange 7-segment quartz date-back stamp onto the
// export (bottom-right), reading the capture date from the RAW's EXIF. Off by
// default; without it the output is unchanged.
//
// --grain-seed overrides the filename-derived per-image grain seed. Same file
// (or same --grain-seed) → byte-identical render; different seed → only the
// grain pattern changes. Seed 0 reproduces the pre-seed output.
//
// --leak forces the light-leak intensity (0 = off), bypassing the presence roll.
// --leak-variant picks a leak shape/colour (reroll counter; 0 = default). With
// --auto the leak presence is rolled exactly like the app: bernoulli over the
// stock's leakProbability, seeded by (file name + stock).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
    exit(1)
}

// MARK: - Argument parsing

var inputPath: String?
var presetNames: [String] = ["Provia"]
var outDir = FileManager.default.currentDirectoryPath
var lutDir = "FilmDev/Resources/LUTs/fuji"
var exposureOverride: Double?
var noEffects = false
var scale = 1.0
var auto = false
var halationOverride: Double?
var glowOverride: Double?
var grainOverride: Double?
var grainSeedOverride: UInt64?
var leakOverride: Double?
var leakVariantOverride: Int?
var dateStamp = false
var outSuffix = ""

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--preset":
        guard let value = argIterator.next() else { fail("--preset needs a value") }
        if value.lowercased() == "all" {
            presetNames = FilmPreset.catalog.map(\.fileName)
        } else {
            presetNames = value.split(separator: ",").map(String.init)
        }
    case "--out":
        guard let value = argIterator.next() else { fail("--out needs a value") }
        outDir = value
    case "--lut-dir":
        guard let value = argIterator.next() else { fail("--lut-dir needs a value") }
        lutDir = value
    case "--exposure":
        guard let value = argIterator.next(), let ev = Double(value) else { fail("--exposure needs a number") }
        exposureOverride = ev
    case "--no-effects":
        noEffects = true
    case "--auto":
        auto = true
    case "--halation":
        guard let value = argIterator.next(), let v = Double(value) else { fail("--halation needs a number") }
        halationOverride = v
    case "--glow":
        guard let value = argIterator.next(), let v = Double(value) else { fail("--glow needs a number") }
        glowOverride = v
    case "--grain":
        guard let value = argIterator.next(), let v = Double(value) else { fail("--grain needs a number") }
        grainOverride = v
    case "--grain-seed":
        guard let value = argIterator.next(), let v = UInt64(value) else { fail("--grain-seed needs a non-negative integer") }
        grainSeedOverride = v
    case "--leak":
        guard let value = argIterator.next(), let v = Double(value) else { fail("--leak needs a number") }
        leakOverride = v
    case "--leak-variant":
        guard let value = argIterator.next(), let v = Int(value) else { fail("--leak-variant needs an integer") }
        leakVariantOverride = v
    case "--date-stamp":
        dateStamp = true
    case "--suffix":
        guard let value = argIterator.next() else { fail("--suffix needs a value") }
        outSuffix = value
    case "--scale":
        guard let value = argIterator.next(), let s = Double(value), s > 0, s <= 1 else { fail("--scale needs 0–1") }
        scale = s
    default:
        if arg.hasPrefix("--") { fail("unknown flag \(arg)") }
        inputPath = arg
    }
}

guard let inputPath else { fail("no input file given") }
let inputURL = URL(fileURLWithPath: inputPath)
let outDirURL = URL(fileURLWithPath: outDir, isDirectory: true)
let lutDirURL = URL(fileURLWithPath: lutDir, isDirectory: true)
try? FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true)

// MARK: - Pipeline

let context = FilmColorPipeline.makeContext(highQualityDownsample: true)
let decoder = RAWDecoder(context: context)
let processor = ImageProcessor(context: context)

// Register the DSEG7 font before rendering when the stamp is requested. Skipped
// entirely otherwise, so the default output path is untouched.
if dateStamp, !DateStamp.registerFont() {
    FileHandle.standardError.write(Data("warning: DSEG7 date-stamp font not found; stamp will be skipped\n".utf8))
}

let decoded: RAWDecoder.DecodeResult
do {
    decoded = try decoder.load(url: inputURL)
} catch {
    fail("decode failed: \(error.localizedDescription)")
}

let baseName = inputURL.deletingPathExtension().lastPathComponent

var analysis: ImageAnalysis?
if auto {
    if ProcessInfo.processInfo.environment["FILMDEV_DEBUG_ANALYZER"] != nil {
        for edge in [256.0, 512.0, 1024.0] {
            if let a = ImageAnalyzer(context: context, proxyLongEdge: edge).analyze(image: decoded.image) {
                print(String(format: "proxy %6.0f: median=%.4f mean=%.4f p05=%.4f p995=%.4f hi=%.3f lo=%.3f",
                             edge, a.medianLuma, a.meanLuma, a.p05, a.p995, a.highlightFraction, a.shadowFraction))
            }
        }
        // Ground truth: CPU readback of a ~256px proxy, stats in plain Swift.
        let img = decoded.image
        let s = 256.0 / max(img.extent.width, img.extent.height)
        let proxy = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = Int(proxy.extent.width.rounded(.down))
        let h = Int(proxy.extent.height.rounded(.down))
        var buf = [Float](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { bytes in
            if let base = bytes.baseAddress {
                context.render(proxy, toBitmap: base, rowBytes: w * 4 * MemoryLayout<Float>.size,
                               bounds: CGRect(x: proxy.extent.minX, y: proxy.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                               format: .RGBAf, colorSpace: nil)
            }
        }
        var lumas: [Double] = []
        lumas.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        lumas.sort()
        let n = lumas.count
        print(String(format: "cpu readback: median=%.4f mean=%.4f p05=%.4f p995=%.4f",
                     lumas[n / 2], lumas.reduce(0, +) / Double(n), lumas[n * 5 / 100], lumas[min(n - 1, n * 995 / 1000)]))
    }
    analysis = ImageAnalyzer(context: context).analyze(image: decoded.image)
    if let a = analysis {
        print(String(format: "analysis: median=%.4f mean=%.4f p05=%.4f p995=%.4f hi=%.3f lo=%.3f",
                     a.medianLuma, a.meanLuma, a.p05, a.p995, a.highlightFraction, a.shadowFraction))
    } else {
        fail("analysis failed")
    }
}

for fileName in presetNames {
    var state = EditState()

    if fileName.lowercased() != "none" {
        guard let entry = FilmPreset.catalog.first(where: { $0.fileName == fileName }) else {
            fail("unknown preset \(fileName); known: \(FilmPreset.catalog.map(\.fileName).joined(separator: ", ")), none")
        }
        let lutURL = lutDirURL.appendingPathComponent("\(fileName).cube")
        let lut: LUTParser.LUTData
        do {
            lut = try LUTParser.parse(cubeFileAt: lutURL)
        } catch {
            fail("LUT load failed for \(lutURL.path): \(error.localizedDescription)")
        }

        var preset = FilmPreset(
            name: fileName.replacingOccurrences(of: "_", with: " "),
            category: .fuji,
            group: entry.group,
            fileName: fileName,
            defaults: entry.defaults
        )
        preset.lutData = lut.data
        preset.lutSize = lut.size
        state.apply(preset: preset)

        // Match the app: --auto rolls the one-shot leak presence for this
        // image+stock (bernoulli over the stock's leakProbability). Without
        // --auto the CLI does raw preset application, so no leak unless forced.
        if auto {
            state.rollLeak(imageIdentity: inputURL.lastPathComponent, preset: preset)
            print(String(format: "leak %@ %@: %@ (i=%.3f)",
                         baseName, fileName,
                         state.leakIntensity > 0 ? "LEAK" : "none", state.leakIntensity))
        }
    }

    if let analysis {
        state.autoFields = Set(EditState.EditField.allCases)
        let trims = PresetIntent.trims(for: analysis, presetFileName: fileName)
        state.applyAutoTrims(trims)
        print(String(format: "%@: ev=%+.2f highlights=%.2f shadows=%.2f",
                     fileName, trims.exposure, trims.highlights, trims.shadows))
    }
    if let exposureOverride { state.exposure = exposureOverride }
    if noEffects {
        state.grainAmount = 0
        state.halationIntensity = 0
        state.glowIntensity = 0
        state.vignetteIntensity = 0
        state.leakIntensity = 0
    }
    if let halationOverride { state.halationIntensity = halationOverride }
    if let glowOverride { state.glowIntensity = glowOverride }
    if let grainOverride { state.grainAmount = grainOverride }
    if let leakOverride { state.leakIntensity = leakOverride }
    if let leakVariantOverride { state.leakVariant = leakVariantOverride }

    // Per-image grain seed: --grain-seed wins for determinism testing,
    // otherwise derive it from the file name (the app's default source).
    let grainSeed = grainSeedOverride ?? StableHash.seed(for: inputURL.lastPathComponent)

    var processed = processor.process(image: decoded.image, editState: state, grainSeed: grainSeed)
    if scale < 1.0 {
        processed = processed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    // Date stamp goes on last, after scaling, so it is sized in output pixels
    // (matching the app's post-resize placement).
    if dateStamp {
        processed = DateStamp.apply(to: processed, sourceURL: inputURL)
    }

    let outURL = outDirURL.appendingPathComponent("\(baseName)_\(fileName)\(outSuffix).jpg")
    do {
        let quality = NSNumber(value: 0.92)
        try context.writeJPEGRepresentation(
            of: processed,
            to: outURL,
            colorSpace: FilmColorPipeline.displayColorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        )
        print("wrote \(outURL.path)")
    } catch {
        fail("export failed: \(error.localizedDescription)")
    }
}
