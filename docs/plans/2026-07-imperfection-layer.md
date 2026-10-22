# Plan: The Imperfection Layer

**Status:** executed & verified, 2026-07-10 (all 5 phases; leader/worker run with per-phase independent verification)
**Origin:** Dazz Cam competitor research, 2026-07-10 (see memory: `dazz-cam-research-2026-07`)
**Goal:** close the authenticity gap between FilmDev's technically clean renders and the "shot on film" feel that apps like Dazz Cam achieve — without sliding into lo-fi kitsch.

## Why

The research finding in one line: Dazz's color math is ordinary; the authenticity comes from **per-shot variance and texture coupling** — every frame gets different grain, occasional light leaks, and artifacts that interact with image content. Our pipeline is deterministic: `CIRandomGenerator` produces a static noise field, so every photo in a batch carries the *identical* grain pattern, which the eye reads as a pasted-on digital filter.

Taste guardrail: FilmDev emulates Fuji's refined in-camera sims, not a disposable camera. Every effect below defaults to subtle, is per-stock configurable via the recipe catalog, and is deterministic per image (same file → same render, forever — sidecars and exports must be reproducible).

## Non-goals (explicitly out of scope)

- Digicam/CCD/VHS look family (chroma noise, JPEG artifacts, smear) — different aesthetic, revisit only as a separate preset family later.
- Scanned overlay-texture library (real 35mm leak/dust scans) — v2 upgrade path if procedural leaks aren't convincing; noted per phase.
- Capture/live-preview features — FilmDev is an editor.

---

## Phase 1 — Per-image grain seed (S)

Every image gets a unique but stable grain pattern.

**Files:** `FilmDev/Core/Services/ImageProcessor.swift`, `FilmDev/Features/Editor/ViewModels/EditorViewModel.swift`, `FilmDev/Core/Services/ThumbnailService.swift`, `FilmDevCLI/main.swift`.

**Steps:**
1. Add a seed utility (new file `FilmDev/Core/Extensions/StableHash.swift` or inside ImageProcessor): FNV-1a 64-bit over a string, plus a SplitMix64 step to derive independent values. **Do NOT use Swift `Hasher`/`hashValue`** — it's randomly seeded per process; renders would differ between launches.
2. Seed source: `url.lastPathComponent` (survives the user moving folders; renaming a file re-rolls the grain, acceptable).
3. Thread `grainSeed: UInt64 = 0` through `ImageProcessor.process(image:editState:isDragging:)` and into `applyFilmGrain`. Derive `dx`, `dy` in `[0, 8192)` from the seed and translate the noise field before the existing scale/crop: `noiseOutput.transformed(by: .init(translationX: dx, y: dy))`. Seed 0 keeps today's exact output (offset 0,0).
4. Update call sites: `EditorViewModel` (3 sites — preview render at :197, export at :456, batch export at :571; all have `currentFileURL` / `fileURL`), `ThumbnailService.generateThumbnail` (add optional seed param; callers pass it where they have the URL), CLI `main.swift:185`.
5. CLI: add `--grain-seed N` override for determinism testing.

**Acceptance:**
- Same file rendered twice → byte-identical grain (diff two CLI exports).
- Two different files, same settings → visibly different grain pattern (crop a flat area, diff is nonzero).
- Slider drag doesn't reshuffle grain on the same image.

**Verify:** `filmdev-cli a.arw --preset Classic_Neg --grain 0.3 --out /tmp/g1 && filmdev-cli a.arw ... --out /tmp/g2 && cmp` the two; then repeat with `b.arw` and confirm the grain crops differ.

---

## Phase 2 — Luminance-coupled grain (M)

Grain amplitude should follow image tone: strongest in midtones, tapering to near-zero in deep shadows and blown highlights. This is the pro-colorist consensus on why uniform grain reads fake.

**Files:** `ImageProcessor.swift` only.

**Steps:**
1. Replace the `monoGrain → CIOverlayBlendMode → CIDissolveTransition` tail of `applyFilmGrain` with one custom `CIColorKernel` taking two samples (base pixel + blurred noise pixel):
   ```
   kernel vec4 filmGrain(__sample base, __sample noise, float amount) {
       float Y = dot(base.rgb, vec3(0.2126, 0.7152, 0.0722));
       float w = smoothstep(0.015, 0.12, Y) * (1.0 - smoothstep(0.65, 0.97, Y));
       float g = noise.r - 0.5;
       return vec4(base.rgb + g * amount * w * K, base.a);
   }
   ```
   Keep the existing noise generation + size-scaled Gaussian blur upstream (that's the grain *structure*; this phase changes the *application*).
2. Tune `K` (overall gain) by A/B against the current overlay-blend output at each catalog stock's default `grainAmount` — the recipes were tuned against the old math, and overlay blending already had implicit luminance coupling, so match perceived strength in midtones, not numerically.
3. Keep the slight per-channel decorrelation the old `monoGrain` matrix had (B channel weighted differently) — either two noise reads or a small channel offset on `g`. Color-negative grain has faint chroma; B&W stocks (Acros/Monochrome/Sepia route through the same code) should stay pure luma — acceptable to keep chroma ≈ 0 for all in v1.
4. Re-check the 12 catalog `grainAmount`/`grainSize` defaults with the CLI `--preset all` contact sheet; adjust `FilmPreset.catalog` values if perceived strength shifted.

**Acceptance:**
- Grain visible in midtone areas, near-invisible in <2% shadows and >95% highlights (inspect crops of a high-DR test frame).
- No luminance shift from grain: mean luma of a flat midtone patch unchanged within noise (grain is zero-centered additive, unlike overlay blend which wasn't).
- All presets still read balanced on the test set.

**Risk:** this changes every existing render with grain. Do it in the same release as Phase 1 (which also changes grain) so users see one grain transition, not two.

---

## Phase 3 — Procedural light-leak stage (L)

Seeded, occasional, edge-anchored warm leaks. The Dazz/Huji insight: *most frames get none* — presence-randomness is the feature, not the leak itself.

**Files:** `ImageProcessor.swift`, `EditState.swift`, `FilmPreset.swift`, `EffectsAdjustmentsView.swift`, `EditorViewModel.swift`, `FilmDevCLI/main.swift`.

**Design decisions (settled here so execution doesn't re-litigate):**
- **Presence is rolled once, at look-apply time, and the outcome is stored in EditState** — not rolled in the pipeline. `apply(preset:)` has no image identity, but every apply path (EditorViewModel, batch export, CLI) knows the URL: roll `bernoulli(stock.leakProbability)` from `stableHash(fileName + stockName)` there, then set `leakIntensity` to the stock default or 0. The sidecar persists the outcome, so a frame that "got a leak" keeps it forever, and the pipeline stays a pure function of EditState + seed. No confusing UI where a nonzero slider renders nothing.
- **Placement:** last effect stage, after vignette (screen blend only brightens; leaks read as on-film fog over the finished frame).
- **Not skipped during drag** — the leak is static per image; render cost is one cheap kernel + blur.

**Steps:**
1. `EditState`: add `leakIntensity: Double = 0` (0–1) and `leakVariant: Int = 0` (reroll counter). Update `CodingKeys`, decoder defaults, `isDefault`, `isEffectsDefault`, `resetEffects()`, and `apply(preset:)` reset block.
2. `PresetDefaults`: add `leakIntensity: Double?` and `leakProbability: Double?`. Catalog starting values — restrained: `Classic_Neg` p=0.25 i=0.35, `Eterna_Bleach_Bypass` p=0.2 i=0.3, `Classic_Chrome` p=0.15 i=0.25, disposable-adjacent stocks only; slide film (Provia/Velvia/Astia) and B&W get p=0 (users can still pull the slider up manually).
3. Leak generator in `ImageProcessor`: a `CIColorKernel` rendering 1–2 elongated Gaussian blobs in normalized coordinates, parameters computed in Swift from SplitMix64(seed + variant):
   - anchor edge (weighted toward left/right — cassette-mouth leaks enter from the film edge),
   - center position along that edge, elongation along the edge axis, width into frame (10–35% of short side),
   - color: warm ramp — hue jittered across red/orange/amber, rare magenta outlier (~10%),
   - per-blob gain jitter.
   Follow with a wide Gaussian blur (radius ~2–4% of frame), then reuse the existing `screen(_:over:intensity:)` helper with `leakIntensity`.
4. UI (`EffectsAdjustmentsView`): "Light Leak" group — intensity slider + a reroll (dice) button that increments `leakVariant`. Reroll is an undoable edit like any slider.
5. CLI: `--leak N` (force intensity), `--leak-variant N`. `--auto` path performs the same probability roll as the app.
6. Iterate on blob shape/color against reference Dazz/Huji sample images using the CLI harness before touching UI polish. If procedural blobs won't pass the squint test after a day of tuning, stop and fall back to the v2 path (bundle 6–10 scanned leak textures, same seeding/selection logic) rather than sinking more time into kernel sculpting.

**Acceptance:**
- With `--auto` over a 20-frame folder at p=0.25: roughly 4–6 frames show a leak; the *same* frames leak on every re-run.
- Leaks are edge-anchored, warm, soft; never a hard-edged blob; intensity 0.35 reads as an accent, not a special effect.
- Old sidecars decode with `leakIntensity = 0` (no visual change to existing edits).
- Reroll produces a visibly different leak; undo restores the previous one.

---

## Phase 4 — Date stamp on export (M)

The orange 7-segment quartz-date-back stamp. Small effort, disproportionate nostalgia payoff, pairs with the contact-sheet flow.

**Files:** `ExportService.swift`, `ExportSettings.swift`, `ExportSheet.swift`, `BatchExportSheet.swift`, `project.yml` (font resource), plus a small EXIF read.

**Steps:**
1. Bundle the DSEG7 Classic Italic font (SIL OFL — include its license file under `Resources/Fonts/`); register via `CTFontManagerRegisterFontsForURL` at app/CLI startup.
2. `ExportSettings`: `dateStampEnabled: Bool = false`. v1 is export-only (no preview/EditState involvement — keeps sidecars untouched); note a possible follow-up to preview it in the export sheet thumbnail.
3. Date source: EXIF `DateTimeOriginal` from the ARW (`CGImageSourceCopyPropertiesAtIndex` on the original file URL — both export paths have it). Fallback: file creation date. Format: classic quartz `'26 7 10` (apostrophe-year, no zero-padding).
4. Rendering in `ExportService.export`, **after** `resized()` so stamp size is stable in output pixels: render text via `CITextImageGenerator` (or CoreText into a bitmap if kerning control is needed) → tint orange (~RGB 1.0, 0.45, 0.1) → duplicate, blur ~2px, additive-composite for the LED glow → composite bottom-right at ~3.5% of long edge in height, ~2.5% margin, ~90% opacity.
5. UI: toggle in `ExportSheet` and `BatchExportSheet`. CLI: `--date-stamp`.

**Acceptance:**
- Stamp legible and proportionate at 2048px and at full ~7000px exports (both driven by output size, so one ratio works).
- Missing EXIF → falls back gracefully, never crashes or prints `1970`.
- Off by default; existing export flows unchanged when off.

---

## Phase 5 — LUT toe audit + full-look regression (S)

The community-recipe research ranked lifted/faded blacks as the single most universal "film look" move. `generate_luts.py` already targets "blacks ~0.02–0.05" per stock — verify it holds in the shipped cubes rather than trusting the comment.

**Steps:**
1. New `scripts/check_lut_toe.py` (run with `scripts/.venv/bin/python3`): parse each bundled `.cube`, report output for input (0,0,0) and the 2% gray patch, per stock. Flag any color stock with a true-zero floor; slide film (Provia/Velvia) is allowed a deeper toe than the negatives (Classic_Neg, Pro_Neg_*) per stock character.
2. If a stock's toe is off-character, fix in `generate_luts.py` params (`shadow_floor_start/end`, curve toe), regenerate, and re-render the contact sheet.
3. Final regression for the whole plan: `filmdev-cli test.arw --preset all --auto --out /tmp/regress` on 3 reference ARWs (high-DR daylight, low-light/night, portrait) before starting and after each phase; compare contact sheets side by side.

---

## Execution order & sizing

| Phase | Size | Depends on | Notes |
|---|---|---|---|
| 1. Grain seed | S | — | Ship with Phase 2 |
| 2. Luminance-coupled grain | M | 1 | One grain transition for users |
| 5. LUT toe audit | S | — | Can run any time; do early, it's cheap |
| 3. Light leaks | L | 1 (seed utility) | The risky one — timebox the procedural kernel |
| 4. Date stamp | M | — | Fully independent |

Cross-cutting checklist for any phase touching EditState: `CodingKeys` + decoder defaults (old sidecars must decode unchanged), `isDefault`/`isEffectsDefault`, `resetEffects()`, `apply(preset:)` reset block, undo snapshots, CLI flag parity, Swift 6 `Sendable` (all new state is value types).
