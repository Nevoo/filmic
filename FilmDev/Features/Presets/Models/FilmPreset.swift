import Foundation
import CoreGraphics

struct PresetDefaults: Codable, Sendable {
    var grainAmount: Double?
    var grainSize: Double?
    var vignetteIntensity: Double?
    var halationIntensity: Double?
    var glowIntensity: Double?
    var glowRadius: Double?
    // Light-leak recipe. `leakProbability` is the per-image bernoulli chance the
    // stock earns a leak at all (most frames get none — presence-randomness is
    // the authenticity signal); `leakIntensity` is the screen-blend strength when
    // one lands. Both nil for stocks with no leak character (slide film, B&W).
    var leakProbability: Double?
    var leakIntensity: Double?
}

struct FilmPreset: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let category: PresetCategory
    let group: LookGroup
    let fileName: String  // .cube file name without extension
    var thumbnail: CGImage?
    var lutData: Data?
    var lutSize: Int?
    var defaults: PresetDefaults?

    enum PresetCategory: String, CaseIterable, Identifiable {
        case fuji = "Fuji"
        case kodak = "Kodak"
        case ilford = "Ilford"
        case custom = "Custom"

        var id: String { rawValue }
    }

    /// How looks are grouped in the picker. Fuji-only catalog splits into the
    /// two families that matter for selection: color sims and B&W sims.
    enum LookGroup: String, CaseIterable, Identifiable {
        case color = "Color"
        case blackWhite = "Black & White"

        var id: String { rawValue }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FilmPreset, rhs: FilmPreset) -> Bool {
        lhs.id == rhs.id
    }
}

extension FilmPreset {
    struct CatalogEntry: Sendable {
        let fileName: String
        let group: LookGroup
        let defaults: PresetDefaults?
    }

    /// Fuji-only catalog — the single source of truth for which looks exist and
    /// the per-stock "recipe" (grain + optics defaults) stamped when a look is
    /// applied. Kodak/Ilford were dropped in the Fuji-first pivot. Shared by
    /// the app (PresetViewModel) and the headless CLI harness.
    ///
    /// Optics rationale: halation is the red-orange bleed of the emulsion the
    /// sim emulates — strong on consumer negative (Classic Neg) and cine stock
    /// (Eterna), restrained on slide film, absent on B&W (anti-halation
    /// backing). Glow is diffusion "air" — most present on the soft portrait
    /// stocks (Astia, Pro Neg Std), barely there on documentary looks.
    static let catalog: [CatalogEntry] = [
        // Color sims
        CatalogEntry(fileName: "Provia", group: .color, defaults: PresetDefaults(
            grainAmount: 0.05, grainSize: 0.4, vignetteIntensity: 0,
            halationIntensity: 0.12, glowIntensity: 0.05, glowRadius: 0.5)),
        CatalogEntry(fileName: "Velvia", group: .color, defaults: PresetDefaults(
            grainAmount: 0.06, grainSize: 0.4, vignetteIntensity: 0.2,
            halationIntensity: 0.12, glowIntensity: 0.04, glowRadius: 0.5)),
        CatalogEntry(fileName: "Astia", group: .color, defaults: PresetDefaults(
            grainAmount: 0.05, grainSize: 0.4, vignetteIntensity: 0,
            halationIntensity: 0.12, glowIntensity: 0.12, glowRadius: 0.6)),
        CatalogEntry(fileName: "Classic_Chrome", group: .color, defaults: PresetDefaults(
            grainAmount: 0.10, grainSize: 0.5, vignetteIntensity: 0.2,
            halationIntensity: 0.08, glowIntensity: 0.04, glowRadius: 0.4,
            leakProbability: 0.10, leakIntensity: 0.12)),
        // Classic Neg recipe: Grain Effect "Strong Small" → more grain, finer.
        CatalogEntry(fileName: "Classic_Neg", group: .color, defaults: PresetDefaults(
            grainAmount: 0.18, grainSize: 0.35, vignetteIntensity: 0.3,
            halationIntensity: 0.18, glowIntensity: 0.06, glowRadius: 0.5,
            leakProbability: 0.15, leakIntensity: 0.15)),
        CatalogEntry(fileName: "Pro_Neg_Hi", group: .color, defaults: PresetDefaults(
            grainAmount: 0.10, grainSize: 0.45, vignetteIntensity: 0,
            halationIntensity: 0.18, glowIntensity: 0.06, glowRadius: 0.5)),
        CatalogEntry(fileName: "Pro_Neg_Std", group: .color, defaults: PresetDefaults(
            grainAmount: 0.08, grainSize: 0.45, vignetteIntensity: 0,
            halationIntensity: 0.15, glowIntensity: 0.10, glowRadius: 0.6)),
        CatalogEntry(fileName: "Eterna", group: .color, defaults: PresetDefaults(
            grainAmount: 0.08, grainSize: 0.5, vignetteIntensity: 0.25,
            halationIntensity: 0.22, glowIntensity: 0.10, glowRadius: 0.6)),
        CatalogEntry(fileName: "Eterna_Bleach_Bypass", group: .color, defaults: PresetDefaults(
            grainAmount: 0.15, grainSize: 0.6, vignetteIntensity: 0.3,
            halationIntensity: 0.15, glowIntensity: 0.03, glowRadius: 0.4,
            leakProbability: 0.12, leakIntensity: 0.12)),
        // B&W sims
        CatalogEntry(fileName: "Acros", group: .blackWhite, defaults: PresetDefaults(
            grainAmount: 0.10, grainSize: 0.4, vignetteIntensity: 0.25,
            halationIntensity: 0, glowIntensity: 0.06, glowRadius: 0.5)),
        CatalogEntry(fileName: "Monochrome", group: .blackWhite, defaults: PresetDefaults(
            grainAmount: 0.08, grainSize: 0.5, vignetteIntensity: 0,
            halationIntensity: 0, glowIntensity: 0.04, glowRadius: 0.5)),
        CatalogEntry(fileName: "Sepia", group: .blackWhite, defaults: PresetDefaults(
            grainAmount: 0.10, grainSize: 0.5, vignetteIntensity: 0.2,
            halationIntensity: 0.10, glowIntensity: 0.10, glowRadius: 0.6)),
    ]
}
