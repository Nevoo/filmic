# Project: FilmDev

## Quick Reference
- **Platform**: macOS 14+
- **Language**: Swift 6.0
- **UI Framework**: SwiftUI
- **Architecture**: MVVM with @Observable
- **Minimum Deployment**: macOS 14.0
- **Package Manager**: Swift Package Manager
- **Image Processing**: Core Image (GPU-accelerated via Metal)

## Purpose
Native macOS image editor focused on applying film simulation LUTs to Sony ARW RAW files. Main value prop: pre-made film looks (like Fuji's in-camera simulations) with basic adjustment controls.

## Project Structure
```
FilmDev/
├── App/                        # App entry point
│   └── FilmDevApp.swift
├── Features/
│   ├── Editor/
│   │   ├── Views/
│   │   │   ├── ContentView.swift
│   │   │   ├── ImagePreviewView.swift
│   │   │   ├── AdjustmentPanelView.swift
│   │   │   ├── AdjustmentSlider.swift
│   │   │   ├── BasicAdjustmentsView.swift
│   │   │   ├── CurveEditorView.swift
│   │   │   └── ExportSheet.swift
│   │   ├── ViewModels/
│   │   │   └── EditorViewModel.swift
│   │   └── Models/
│   │       ├── EditState.swift
│   │       └── ExportSettings.swift
│   ├── FileBrowser/
│   │   ├── Views/
│   │   │   ├── FileBrowserView.swift
│   │   │   └── ThumbnailGridItem.swift
│   │   └── ViewModels/
│   │       └── FileBrowserViewModel.swift
│   └── Presets/
│       ├── Views/
│       │   ├── PresetGridView.swift
│       │   └── PresetCard.swift
│       ├── ViewModels/
│       │   └── PresetViewModel.swift
│       └── Models/
│           └── FilmPreset.swift
├── Core/
│   ├── Services/
│   │   ├── ImageProcessor.swift        # CIFilter pipeline
│   │   ├── RAWDecoder.swift            # CIRAWFilter wrapper
│   │   ├── LUTParser.swift             # .cube file parser
│   │   ├── ExportService.swift         # JPEG/PNG/TIFF export
│   │   └── ThumbnailService.swift      # Background thumbnail gen
│   └── Extensions/
│       ├── CIFilter+Extensions.swift
│       └── Color+Theme.swift
├── Resources/
│   ├── Assets.xcassets/
│   └── LUTs/                           # Bundled .cube files
│       ├── fuji/
│       ├── kodak/
│       └── ilford/
└── Tests/
```

## Coding Standards

### Swift Style
- Use Swift 6 strict concurrency
- Prefer `@Observable` over `ObservableObject`
- Use `async/await` for all async operations
- Follow Apple's Swift API Design Guidelines
- Use `guard` for early exits
- Prefer value types (structs) over reference types (classes)

### SwiftUI Patterns
- Extract views when they exceed 100 lines
- Use `@State` for local view state only
- Use `@Environment` for dependency injection
- Prefer `NavigationSplitView` for the three-panel layout
- Use `@Bindable` for bindings to @Observable objects

### Navigation Pattern
```swift
// Three-panel layout
NavigationSplitView {
    FileBrowserView()           // Sidebar
} detail: {
    HSplitView {
        ImagePreviewView()      // Center
        AdjustmentPanelView()   // Right sidebar
    }
}
```

### Error Handling
```swift
enum AppError: LocalizedError {
    case rawDecodeFailed(url: URL)
    case lutParseFailed(reason: String)
    case exportFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .rawDecodeFailed(let url): return "Failed to decode RAW: \(url.lastPathComponent)"
        case .lutParseFailed(let reason): return "LUT parse error: \(reason)"
        case .exportFailed(let error): return "Export failed: \(error.localizedDescription)"
        }
    }
}
```

## Core Image Pipeline
All image processing uses Core Image filters chained non-destructively:
```
CIRAWFilter → CIExposureAdjust → CIHighlightShadowAdjust → CIColorCubeWithColorSpace (LUT) → CIToneCurve → render
```
- `CIContext` is created once, backed by Metal
- Filters are lazy — GPU only executes on render
- Preview renders at reduced resolution during slider drag
- Use `Task` cancellation for debouncing rapid updates

## DO NOT
- Force unwrap optionals (`!`) — use `guard let` or `if let`
- Use deprecated APIs — always target the latest macOS 14+ APIs
- Ignore Swift 6 strict concurrency warnings — fix all `Sendable` and actor isolation issues
- Modify bundled LUT `.cube` files in `Resources/LUTs/`
- Use `ObservableObject` / `@Published` — use `@Observable` instead
- Use `DispatchQueue` — use Swift Concurrency (`async/await`, `Task`, actors)
- Add `print()` for debugging — use `os.Logger` if logging is needed
- Skip `@MainActor` annotations on view models and UI-updating code

## Python Scripts
- Virtual environment: `scripts/.venv/`
- Run scripts with: `scripts/.venv/bin/python3 scripts/<script>.py`
- Do NOT use system python or install packages globally

## Key Conventions
- `EditState` is the single source of truth for all adjustments
- Sidecar `.filmdev` JSON files store edits alongside RAW files
- LUTs are .cube format parsed to `Data` for `CIColorCubeWithColorSpace`
- Dark theme enforced via `.preferredColorScheme(.dark)`
- All rendering happens on background tasks, UI updates on `@MainActor`
