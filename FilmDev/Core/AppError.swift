import Foundation

enum AppError: LocalizedError, Sendable {
    case rawDecodeFailed(url: URL)
    case lutParseFailed(reason: String)
    case exportFailed(description: String)
    case fileNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .rawDecodeFailed(let url): return "Failed to decode RAW: \(url.lastPathComponent)"
        case .lutParseFailed(let reason): return "LUT parse error: \(reason)"
        case .exportFailed(let description): return "Export failed: \(description)"
        case .fileNotFound(let path): return "File not found: \(path)"
        }
    }
}
