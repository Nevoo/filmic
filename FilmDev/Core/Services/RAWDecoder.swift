import CoreImage
import Foundation

/// LibRaw-backed RAW decoder. Holds the libraw context for the currently
/// loaded file so WB / param changes don't re-read the file from disk —
/// only the demosaic + processing pass is re-run.
final class RAWDecoder: @unchecked Sendable {
    struct WhiteBalance: Sendable {
        let temperature: Double
        let tint: Double
    }

    struct DecodeResult: Sendable {
        let image: CIImage
        let asShotWB: WhiteBalance
    }

    private let context: CIContext
    private let lock = NSLock()
    private var librawData: UnsafeMutablePointer<libraw_data_t>?
    private var fallbackImage: CIImage?

    private static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "dng", "orf", "rw2", "srw", "pef", "x3f"
    ]

    init(context: CIContext) {
        self.context = context
    }

    deinit {
        if let data = librawData {
            libraw_close(data)
        }
    }

    /// Decode the file at `url`. For RAW files, runs the libraw pipeline
    /// (unpack → AHD demosaic → camera-WB → sRGB output). For non-RAW, falls
    /// back to `CIImage(contentsOf:)`.
    func load(url: URL) throws -> DecodeResult {
        lock.lock()
        defer { lock.unlock() }

        if let data = librawData {
            libraw_close(data)
            librawData = nil
        }
        fallbackImage = nil

        let ext = url.pathExtension.lowercased()
        if Self.rawExtensions.contains(ext) {
            return try loadRAW(url: url)
        }

        guard let image = CIImage(contentsOf: url) else {
            throw AppError.rawDecodeFailed(url: url)
        }
        let normalized = FilmColorPipeline.normalizeDecodedImage(image)
        fallbackImage = normalized
        return DecodeResult(
            image: normalized,
            asShotWB: WhiteBalance(temperature: 6500, tint: 0)
        )
    }

    /// Apply a temperature/tint shift to the cached decoded image via
    /// `CITemperatureAndTint`. Avoids re-running the libraw demosaic for
    /// drag-time previews; the slider's neutral point is the camera as-shot WB.
    func updateWB(temperature: Double, tint: Double) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }

        if librawData == nil {
            return fallbackImage
        }
        // libraw's camera WB is already baked in. The slider applies an
        // additional shift on top, treating 6500K / 0 tint as the neutral
        // reference for the as-shot image.
        guard let base = currentBaseImage() else { return nil }
        if abs(temperature - 6500) < 1 && abs(tint) < 1 {
            return base
        }
        return base.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: CGFloat(temperature), y: CGFloat(tint))
        ])
    }

    // MARK: - libraw pipeline

    private var cachedBaseImage: CIImage?

    private func currentBaseImage() -> CIImage? {
        cachedBaseImage
    }

    private func loadRAW(url: URL) throws -> DecodeResult {
        guard let raw = libraw_init(0) else {
            throw AppError.rawDecodeFailed(url: url)
        }

        let openResult = url.path.withCString { libraw_open_file(raw, $0) }
        guard openResult == 0 else {
            libraw_close(raw)
            throw AppError.rawDecodeFailed(url: url)
        }

        guard libraw_unpack(raw) == 0 else {
            libraw_close(raw)
            throw AppError.rawDecodeFailed(url: url)
        }

        // Output configuration. AHD demosaic, 16-bit sRGB output, camera WB.
        // Decode contract: camera-WB, auto-bright DISABLED, bounded
        // display-referred sRGB. Auto-bright is off so tone/exposure is owned
        // downstream (the look LUT and, later, the analyzer) rather than libraw
        // stretching every frame independently, which would fight the film
        // curve baked into the LUT and make results inconsistent per image.
        raw.pointee.params.output_bps = 16
        raw.pointee.params.output_color = 1   // sRGB
        raw.pointee.params.use_camera_wb = 1
        raw.pointee.params.use_auto_wb = 0
        raw.pointee.params.no_auto_bright = 1  // disable auto-bright; tone owned downstream
        raw.pointee.params.user_qual = 3      // AHD demosaic
        // sRGB transfer curve so the output is gamma-encoded and ready for
        // CIImage tagged as sRGB. CIContext (workingColorSpace = linear sRGB)
        // will decode the gamma into the working space automatically.
        raw.pointee.params.gamm.0 = 1.0 / 2.4
        raw.pointee.params.gamm.1 = 12.92

        guard libraw_dcraw_process(raw) == 0 else {
            libraw_close(raw)
            throw AppError.rawDecodeFailed(url: url)
        }

        var errc: Int32 = 0
        guard let processedPtr = libraw_dcraw_make_mem_image(raw, &errc), errc == 0 else {
            libraw_close(raw)
            throw AppError.rawDecodeFailed(url: url)
        }
        defer { libraw_dcraw_clear_mem(processedPtr) }

        guard let ciImage = makeCIImage(from: processedPtr) else {
            libraw_close(raw)
            throw AppError.rawDecodeFailed(url: url)
        }

        librawData = raw
        cachedBaseImage = ciImage

        // libraw doesn't expose a temperature/tint pair directly. Default
        // sliders to 6500/0; the WB shift slider is relative to camera as-shot.
        let asShotWB = WhiteBalance(temperature: 6500, tint: 0)
        return DecodeResult(image: ciImage, asShotWB: asShotWB)
    }

    /// Build a CIImage from a libraw processed image buffer. The buffer is
    /// 16-bit RGB in sRGB primaries with sRGB gamma encoding applied.
    /// libraw's `data` field is a C flex-array (`unsigned char data[1]`); the
    /// actual pixel bytes live past the struct header in libraw's allocation,
    /// so we read via the pointer + offset rather than via the imported tuple.
    private func makeCIImage(from processedPtr: UnsafeMutablePointer<libraw_processed_image_t>) -> CIImage? {
        let processed = processedPtr.pointee
        let width = Int(processed.width)
        let height = Int(processed.height)
        let bits = Int(processed.bits)
        let colors = Int(processed.colors)
        let dataSize = Int(processed.data_size)

        guard colors == 3, (bits == 8 || bits == 16), width > 0, height > 0, dataSize > 0 else {
            return nil
        }

        guard let bytePtr = filmdev_libraw_image_data(processedPtr) else { return nil }
        let dataCopy = Data(bytes: bytePtr, count: dataSize)

        let bytesPerComponent = bits / 8
        let bytesPerPixel = colors * bytesPerComponent
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = FilmColorPipeline.displayColorSpace   // sRGB

        var bitmapInfo: CGBitmapInfo = []
        if bits == 16 {
            // libraw writes 16-bit components in host byte order (little-endian
            // on Apple Silicon). CGImage defaults to big-endian for 16-bit, so
            // flag little-endian explicitly.
            bitmapInfo.insert(.byteOrder16Little)
        }
        bitmapInfo.insert(CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))

        guard let provider = CGDataProvider(data: dataCopy as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bits,
            bitsPerPixel: bits * colors,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        return CIImage(cgImage: cgImage)
    }
}
