import Foundation

struct LUTParser: Sendable {
    struct LUTData: Sendable {
        let data: Data
        let size: Int
    }

    static func parse(cubeFileAt url: URL) throws -> LUTData {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var size: Int?
        var colors: [Float] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Parse LUT size
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, let s = Int(parts[1]) {
                    size = s
                }
                continue
            }

            // Skip other metadata keywords
            if trimmed.hasPrefix("TITLE") || trimmed.hasPrefix("DOMAIN_MIN") || trimmed.hasPrefix("DOMAIN_MAX") || trimmed.hasPrefix("LUT_1D_SIZE") {
                continue
            }

            // Parse color values (R G B)
            let components = trimmed.split(separator: " ").compactMap { Float($0) }
            if components.count == 3 {
                colors.append(components[0]) // R
                colors.append(components[1]) // G
                colors.append(components[2]) // B
                colors.append(1.0)           // A (always 1.0)
            }
        }

        guard let lutSize = size else {
            throw AppError.lutParseFailed(reason: "Missing LUT_3D_SIZE declaration")
        }

        let expectedCount = lutSize * lutSize * lutSize * 4
        guard colors.count == expectedCount else {
            throw AppError.lutParseFailed(reason: "Expected \(expectedCount) values, got \(colors.count)")
        }

        let data = colors.withUnsafeBytes { Data($0) }

        return LUTData(data: data, size: lutSize)
    }
}
