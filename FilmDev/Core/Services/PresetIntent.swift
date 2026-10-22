import Foundation

/// Maps image measurements to per-stock starting trims — the "lazy editor".
/// The LUT owns the look; these trims normalize the frame into the regime the
/// LUT was authored for (decode contract: auto-bright off, so exposure is
/// owned here). Each Fuji stock reacts differently: slide film protects
/// highlights at all costs, negative stocks tolerate clipping and want air in
/// the shadows.
enum PresetIntent {
    struct DerivedTrims: Sendable, Equatable {
        var exposure: Double
        var highlights: Double
        var shadows: Double
    }

    private struct StockCharacter {
        /// Creative exposure offset on top of the metered correction.
        var evBias: Double = 0
        /// Fraction of pixels the gain may NEWLY push into clipping. Mass the
        /// sensor already clipped is lost either way and doesn't count, so a
        /// blown overcast sky never holds the whole frame underexposed.
        /// Slide film is protective (~0.6–1%), negative film shrugs (~2–4%).
        var newClipBudget: Double = 0.010
        /// Baseline shadow lift the stock always gets.
        var shadowLift: Double = 0
        /// Baseline highlight compression the stock always gets.
        var highlightCompress: Double = 0
    }

    private static let characters: [String: StockCharacter] = [
        "Provia": StockCharacter(),
        "Velvia": StockCharacter(evBias: -0.10, newClipBudget: 0.006),
        "Astia": StockCharacter(evBias: 0.10, newClipBudget: 0.012, shadowLift: 0.05),
        "Classic_Chrome": StockCharacter(evBias: -0.15, newClipBudget: 0.015),
        // Recipe shoots DR400 — protect highlights harder than a plain negative.
        "Classic_Neg": StockCharacter(evBias: -0.05, newClipBudget: 0.010),
        "Pro_Neg_Hi": StockCharacter(newClipBudget: 0.020),
        "Pro_Neg_Std": StockCharacter(evBias: 0.10, newClipBudget: 0.020, shadowLift: 0.05, highlightCompress: 0.05),
        "Eterna": StockCharacter(evBias: 0.05, newClipBudget: 0.006, highlightCompress: 0.10),
        "Eterna_Bleach_Bypass": StockCharacter(evBias: -0.10, newClipBudget: 0.015),
        "Acros": StockCharacter(newClipBudget: 0.040),
        "Monochrome": StockCharacter(newClipBudget: 0.030),
        "Sepia": StockCharacter(newClipBudget: 0.020),
    ]

    /// Median linear luma the auto-exposure aims at. Slightly under mid-grey:
    /// film scans sit a touch dark and the filmic LUT toe expects headroom.
    private static let targetMedian = 0.15

    /// Above this linear luma a pixel counts as clipped (sensor or gain).
    private static let clipThreshold = 0.985

    /// Headroom past the budgeted clip point. Small: the toneShape soft knee
    /// keeps moderate overshoot textured, but the meter shouldn't lean on it.
    private static let shoulderAllowanceEV = 0.08

    /// Derive starting trims for `presetFileName` (nil = no look active,
    /// neutral character) from the frame's measurements.
    static func trims(for analysis: ImageAnalysis, presetFileName: String?) -> DerivedTrims {
        let character = presetFileName.flatMap { characters[$0] } ?? StockCharacter()

        let median = max(analysis.medianLuma, 0.0005)
        let alreadyClipped = analysis.massAbove(clipThreshold)

        // Low-key prior: real clipped sources plus lots of deep shadow means
        // the camera exposed for the lights on purpose (night, concerts,
        // funfairs). Film would print that dark — scale the metered lift down
        // instead of dragging the frame to mid-grey.
        let clippedEvidence = min(1.0, alreadyClipped / 0.02)
        let shadowEvidence = min(1.0, analysis.shadowFraction / 0.45)
        let lowKey = clippedEvidence * shadowEvidence

        var ev = log2(targetMedian / median) * (1.0 - 0.8 * lowKey) + character.evBias

        // Highlight protection by clip budget: find the luma where, once it
        // hits 1.0, the stock's allowance of newly clipped pixels (on top of
        // what the sensor already lost) is spent. The gain may not push past
        // that point, give or take the LUT shoulder.
        let guardValue = analysis.valueWithMassAbove(alreadyClipped + character.newClipBudget)
        let ceiling = log2(1.0 / max(guardValue, 0.001)) + shoulderAllowanceEV
        ev = min(ev, ceiling)
        ev = max(-2.5, min(3.0, ev))

        var shadows = character.shadowLift
        var highlights = character.highlightCompress

        // If the shadow mass stays crushed after the gain, give it air —
        // film negatives never render true black in the mids of a scene.
        let gainedP05 = analysis.p05 * pow(2.0, ev)
        if gainedP05 < 0.004 && analysis.shadowFraction > 0.10 {
            shadows += 0.08
        }
        // Big bright mass (sky) → ease the top end into the LUT shoulder.
        if analysis.highlightFraction > 0.15 {
            highlights += 0.10
        }

        return DerivedTrims(
            exposure: ev,
            highlights: min(highlights, 0.4),
            shadows: min(shadows, 0.4)
        )
    }
}
