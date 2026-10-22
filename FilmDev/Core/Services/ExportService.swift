import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct ExportService: @unchecked Sendable {
    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    /// Exports `image`. `sourceURL` is the original RAW, used only to read the
    /// capture date for the optional quartz date stamp — it never affects output
    /// unless `settings.dateStampEnabled` is true.
    func export(image: CIImage, to url: URL, settings: ExportSettings, sourceURL: URL? = nil) throws {
        guard let colorSpace = settings.colorProfile.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw AppError.exportFailed(description: "Failed to create export color space")
        }

        let resizedImage = resized(image, settings: settings)
        // Stamp after resize so the stamp is sized in final output pixels. When
        // disabled, `output` is the exact same image as before (byte-identical).
        let output = settings.dateStampEnabled
            ? DateStamp.apply(to: resizedImage, sourceURL: sourceURL)
            : resizedImage

        switch settings.format {
        case .jpeg:
            try context.writeJPEGRepresentation(
                of: output,
                to: url,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: settings.quality]
            )
        case .png:
            try context.writePNGRepresentation(
                of: output,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        case .tiff:
            try context.writeTIFFRepresentation(
                of: output,
                to: url,
                format: .RGBA16,
                colorSpace: colorSpace
            )
        case .heif:
            try context.writeHEIFRepresentation(
                of: output,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: settings.quality]
            )
        }
    }

    /// Downscales so the long edge fits `maxLongEdge`. Never upscales.
    private func resized(_ image: CIImage, settings: ExportSettings) -> CIImage {
        guard settings.resizeEnabled else { return image }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > CGFloat(settings.maxLongEdge), longEdge > 0 else { return image }
        let scale = CGFloat(settings.maxLongEdge) / longEdge
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

// MARK: - Date stamp

/// The optional orange 7-segment "quartz date back" stamp, composited onto
/// exports only. Deterministic per file: the date comes from the RAW's EXIF, so
/// the same file always stamps the same day. Everything here is a pure function
/// of the source file plus the output size — no EditState, no sidecar involvement.
enum DateStamp {
    private static let fontResourceName = "DSEG7Classic-BoldItalic"

    // MARK: Font location & registration

    /// Locates the bundled DSEG7 font. Checks the app bundle first (macOS app),
    /// then the source tree relative to the working directory and the executable
    /// (the CLI reads its resources from disk, like it does for LUTs).
    static func fontURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: fontResourceName, withExtension: "ttf") {
            return bundled
        }
        let fm = FileManager.default
        let relativePath = "FilmDev/Resources/Fonts/\(fontResourceName).ttf"
        var candidates = [URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(relativePath)]
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("\(fontResourceName).ttf"))
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Registers the font process-wide. Returns false (never throws/crashes) when
    /// the font can't be found or registered; callers log and continue stampless.
    @discardableResult
    static func registerFont() -> Bool {
        guard let url = fontURL() else { return false }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        // "already registered" is a success for our purposes.
        if !ok, let cfError = error?.takeUnretainedValue(),
           CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
            return true
        }
        return ok
    }

    // MARK: Date resolution

    /// The stamp text (e.g. `'26 4 5`) for the source file, or nil when no date
    /// can be read (→ render nothing; never a 1970/epoch fallback).
    static func stampText(for sourceURL: URL?) -> String? {
        guard let url = sourceURL else { return nil }
        if let date = exifDate(from: url) {
            // Parse and format in UTC so the printed date matches the literal
            // EXIF calendar date exactly, on any machine.
            let utc = TimeZone(secondsFromGMT: 0) ?? .current
            return text(for: date, timeZone: utc)
        }
        if let date = fileCreationDate(from: url) {
            return text(for: date, timeZone: .current)
        }
        return nil
    }

    private static func exifDate(from url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    private static func fileCreationDate(from url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }

    /// Formats the classic quartz date-back style: apostrophe + 2-digit year,
    /// space, month (no zero pad), space, day (no zero pad). Guards against
    /// pre-1970 sentinels so a broken date never prints.
    private static func text(for date: Date, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, year > 1970,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return String(format: "'%02d %d %d", year % 100, month, day)
    }

    // MARK: Rendering

    /// Composites the date stamp bottom-right onto `image` (already at output
    /// resolution). Returns `image` unchanged when no date is available or the
    /// font can't be loaded, so a stamp is never rendered in the wrong typeface.
    static func apply(to image: CIImage, sourceURL: URL?) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0,
              let text = stampText(for: sourceURL),
              let fontURL = fontURL(),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            return image
        }

        let longEdge = max(extent.width, extent.height)
        // DSEG7's cap height fills the em, so point size == rendered digit height.
        let pointSize = longEdge * 0.035
        guard let stamp = renderStamp(text: text, pointSize: pointSize, descriptor: descriptor) else {
            return image
        }

        // LED glow: a soft blurred copy added under the crisp text. The blur
        // scales with the text so the glow stays proportionate at any size.
        let glow = stamp.applyingGaussianBlur(sigma: Double(pointSize * 0.035))
        let glowing = stamp.applyingFilter(
            "CIAdditionCompositing",
            parameters: [kCIInputBackgroundImageKey: glow]
        )
        let faded = glowing.applyingFilter(
            "CIColorMatrix",
            parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.9)]
        )

        // Anchor the text's ink bottom-right corner at the margin inset.
        let margin = longEdge * 0.025
        let dx = (extent.maxX - margin) - stamp.extent.maxX
        let dy = (extent.minY + margin) - stamp.extent.minY
        let placed = faded.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        return placed.composited(over: image).cropped(to: extent)
    }

    /// Renders the stamp text as an orange LED CIImage cropped tightly to its ink
    /// (so placement is exact). Two details make it read like a real quartz back:
    /// DSEG7 has no apostrophe glyph, so a leading `'` year mark is drawn as a
    /// synthesized rounded bar at cap height (top of the digit line), sheared to
    /// match the italic; and DSEG7's space advance is far narrower than a digit,
    /// so each inter-group space is kerned up to a full digit width, keeping the
    /// year/month/day groups evenly separated (a single-digit month and day would
    /// otherwise merge).
    private static func renderStamp(text: String, pointSize: CGFloat, descriptor: CTFontDescriptor) -> CIImage? {
        let ledFont = CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
        let orange = CGColor(srgbRed: 1.0, green: 0.45, blue: 0.1, alpha: 1.0)

        // A leading apostrophe is drawn as a synthesized tick, not a text glyph.
        let hasYearTick = text.hasPrefix("'")
        let digitsText = hasYearTick ? String(text.dropFirst()) : text

        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
        let nsText = digitsText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let attributed = NSMutableAttributedString(string: digitsText)
        attributed.addAttribute(colorKey, value: orange, range: fullRange)
        attributed.addAttribute(fontKey, value: ledFont, range: fullRange)
        let extraKern = max(0, advanceWidth(of: "0", in: ledFont) - advanceWidth(of: " ", in: ledFont))
        let spaceScalar = UInt16(UnicodeScalar(" ").value)
        for index in 0..<nsText.length where nsText.character(at: index) == spaceScalar {
            attributed.addAttribute(kernKey, value: extraKern, range: NSRange(location: index, length: 1))
        }

        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padding = ceil(pointSize * 0.6)
        let tickAreaWidth = hasYearTick ? pointSize * 0.42 : 0
        let width = Int((typographicWidth + tickAreaWidth + padding * 2).rounded(.up))
        let height = Int((ascent + descent + padding * 2).rounded(.up))
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setShouldAntialias(true)
        let baselineY = padding + descent
        ctx.textPosition = CGPoint(x: padding + tickAreaWidth, y: baselineY)
        // Ink bounds are in the context's user space at the current text position.
        var inkBounds = CTLineGetImageBounds(line, ctx)
        CTLineDraw(line, ctx)

        if hasYearTick {
            let capTop = baselineY + ascent
            let tickHeight = pointSize * 0.34
            let tickWidth = pointSize * 0.12
            let tickX = padding + pointSize * 0.14
            let slant = min(0.4, max(-0.4, tan(-CTFontGetSlantAngle(ledFont) * .pi / 180)))
            let tickRect = CGRect(x: tickX, y: capTop - tickHeight, width: tickWidth, height: tickHeight)
            let bar = CGPath(
                roundedRect: tickRect,
                cornerWidth: tickWidth * 0.35, cornerHeight: tickWidth * 0.35, transform: nil)
            var shear = CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: -slant * baselineY, ty: 0)
            ctx.setFillColor(orange)
            if let sheared = bar.copy(using: &shear) {
                ctx.addPath(sheared)
                ctx.fillPath()
            }
            let tickInk = CGRect(x: tickX, y: capTop - tickHeight,
                                 width: tickWidth + abs(slant) * tickHeight, height: tickHeight)
            inkBounds = inkBounds.union(tickInk)
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        let bitmap = CIImage(cgImage: cgImage)
        let inkRect = inkBounds.integral.intersection(bitmap.extent)
        guard !inkRect.isNull, inkRect.width > 0, inkRect.height > 0 else { return bitmap }
        return bitmap.cropped(to: inkRect)
    }

    /// Horizontal advance of a single character in `font`, from the real glyph
    /// metrics — used to size the even inter-group gaps and the year-tick area.
    private static func advanceWidth(of character: Character, in font: CTFont) -> CGFloat {
        var utf16 = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count) else { return 0 }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)
        return advances.first?.width ?? 0
    }
}
