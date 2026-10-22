#!/usr/bin/env python3
"""
Generate 33x33x33 .cube LUT files for FilmDev film simulations.

All presets use per-channel tone curves + saturation/hue adjustments + split
toning — the same approach used by professional LUT makers (VSCO, RNI).

Usage:
    python3 scripts/generate_luts.py
    python3 scripts/generate_luts.py --diagnose

Outputs .cube files to FilmDev/Resources/LUTs/{fuji,kodak,ilford}/
"""

import sys
import numpy as np
from pathlib import Path

# ---------------------------------------------------------------------------
# LUT infrastructure
# ---------------------------------------------------------------------------

LUT_SIZE = 33
OUTPUT_ROOT = Path(__file__).resolve().parent.parent / "FilmDev" / "Resources" / "LUTs"


def identity_lut(size: int = LUT_SIZE) -> np.ndarray:
    """Return an identity LUT as (size^3, 3) float64 array, R-fastest order for .cube."""
    coords = np.linspace(0.0, 1.0, size)
    b, g, r = np.meshgrid(coords, coords, coords, indexing="ij")
    return np.stack([r, g, b], axis=-1).reshape(-1, 3)


def write_cube(lut: np.ndarray, path: Path, title: str, size: int = LUT_SIZE):
    """Write a .cube file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        f.write(f'TITLE "{title}"\n')
        f.write("DOMAIN_MIN 0.0 0.0 0.0\n")
        f.write("DOMAIN_MAX 1.0 1.0 1.0\n")
        f.write(f"LUT_3D_SIZE {size}\n\n")
        for row in lut:
            f.write(f"{row[0]:.6f} {row[1]:.6f} {row[2]:.6f}\n")
    print(f"  wrote {path.relative_to(OUTPUT_ROOT.parent.parent.parent)}")


# ---------------------------------------------------------------------------
# Color-space helpers
# ---------------------------------------------------------------------------

def rgb_to_hsl(rgb: np.ndarray) -> np.ndarray:
    """Convert (N,3) RGB [0,1] to HSL [0,1]."""
    r, g, b = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    c = mx - mn
    l = (mx + mn) / 2.0

    h = np.zeros_like(l)
    s = np.zeros_like(l)

    mask = c > 1e-10
    mask_r = mask & (mx == r)
    mask_g = mask & (mx == g) & ~mask_r
    mask_b = mask & ~mask_r & ~mask_g

    h[mask_r] = ((g[mask_r] - b[mask_r]) / c[mask_r]) % 6.0
    h[mask_g] = (b[mask_g] - r[mask_g]) / c[mask_g] + 2.0
    h[mask_b] = (r[mask_b] - g[mask_b]) / c[mask_b] + 4.0
    h = h / 6.0
    h = h % 1.0

    denom = 1.0 - np.abs(2.0 * l - 1.0)
    safe = denom > 1e-10
    s[mask & safe] = c[mask & safe] / denom[mask & safe]
    s = np.clip(s, 0, 1)

    return np.stack([h, s, l], axis=-1)


def hsl_to_rgb(hsl: np.ndarray) -> np.ndarray:
    """Convert (N,3) HSL [0,1] to RGB [0,1]."""
    h, s, l = hsl[:, 0], hsl[:, 1], hsl[:, 2]
    c = (1.0 - np.abs(2.0 * l - 1.0)) * s
    hp = h * 6.0
    x = c * (1.0 - np.abs(hp % 2.0 - 1.0))
    m = l - c / 2.0
    z = np.zeros_like(c)

    rgb = np.zeros_like(hsl)
    for lo, hi, vals in [
        (0, 1, (c, x, z)),
        (1, 2, (x, c, z)),
        (2, 3, (z, c, x)),
        (3, 4, (z, x, c)),
        (4, 5, (x, z, c)),
        (5, 6, (c, z, x)),
    ]:
        mask = (hp >= lo) & (hp < hi)
        for ch in range(3):
            rgb[mask, ch] = vals[ch][mask]

    rgb[:, 0] += m
    rgb[:, 1] += m
    rgb[:, 2] += m
    return np.clip(rgb, 0, 1)


def to_linear(rgb: np.ndarray) -> np.ndarray:
    """Convert display-referred sRGB values to linear light."""
    rgb = np.clip(rgb, 0, 1)
    return np.where(
        rgb <= 0.04045,
        rgb / 12.92,
        ((rgb + 0.055) / 1.055) ** 2.4,
    )


def to_srgb(linear: np.ndarray) -> np.ndarray:
    """Convert linear-light RGB values back to display-referred sRGB."""
    linear = np.clip(linear, 0, 1)
    return np.where(
        linear <= 0.0031308,
        linear * 12.92,
        1.055 * np.power(linear, 1.0 / 2.4) - 0.055,
    )


def _srgb_scalar_to_linear(v: float) -> float:
    if v <= 0.04045:
        return v / 12.92
    return ((v + 0.055) / 1.055) ** 2.4


def enc_curve(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Author tone-curve control points in display-encoded (sRGB) space.

    The filmic engine applies tone curves to LINEAR luminance, where encoded
    intuition is badly wrong — "whites settle at 0.93" in linear is encoded
    0.97 (paper white), and an encoded-thinking S-curve collapses to near
    identity. This converts encoded (in, out) pairs to the linear pairs the
    engine expects, so curves do what their authors meant. ALWAYS wrap color
    stock tone_curves in this.
    """
    return [(_srgb_scalar_to_linear(a), _srgb_scalar_to_linear(b)) for a, b in points]


# ---------------------------------------------------------------------------
# Tone curve & color helpers
# ---------------------------------------------------------------------------

HUE_RANGES = {
    "red": (0.0, 1 / 12),
    "red2": (11 / 12, 1.0),
    "orange": (1 / 12, 1 / 6),
    "yellow": (1 / 6, 1 / 4),
    "green": (1 / 4, 5 / 12),
    "cyan": (5 / 12, 1 / 2),
    "blue": (1 / 2, 7 / 12),
    "purple": (7 / 12, 3 / 4),
    "magenta": (3 / 4, 11 / 12),
}


def _spline_curve(x: np.ndarray, points: list[tuple[float, float]]) -> np.ndarray:
    """Apply a piecewise-linear tone curve defined by control points."""
    points = sorted(points, key=lambda p: p[0])
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return np.clip(np.interp(x, xs, ys), 0, 1)


def _smoothstep(edge0: float, edge1: float, x: np.ndarray) -> np.ndarray:
    """Hermite smooth interpolation between two edges."""
    t = np.clip((x - edge0) / max(edge1 - edge0, 1e-6), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def apply_saturation(
    lut: np.ndarray,
    global_sat: float = 1.0,
    per_hue: dict[str, float] | None = None,
) -> np.ndarray:
    """Adjust saturation globally and per hue region."""
    hsl = rgb_to_hsl(lut)
    hsl[:, 1] *= global_sat

    if per_hue:
        for hue_name, factor in per_hue.items():
            if hue_name in HUE_RANGES:
                lo, hi = HUE_RANGES[hue_name]
                mask = (hsl[:, 0] >= lo) & (hsl[:, 0] < hi)
                hsl[mask, 1] *= factor

    hsl[:, 1] = np.clip(hsl[:, 1], 0, 1)
    return hsl_to_rgb(hsl)


def apply_hue_shift(lut: np.ndarray, shifts: dict[str, float]) -> np.ndarray:
    """Shift hues in specific regions. Values are fractions of full circle."""
    hsl = rgb_to_hsl(lut)
    for hue_name, shift in shifts.items():
        if hue_name in HUE_RANGES:
            lo, hi = HUE_RANGES[hue_name]
            mask = (hsl[:, 0] >= lo) & (hsl[:, 0] < hi)
            hsl[mask, 0] = (hsl[mask, 0] + shift) % 1.0
    return hsl_to_rgb(hsl)


def apply_split_tone(
    lut: np.ndarray,
    shadow_color: tuple[float, float, float],
    highlight_color: tuple[float, float, float],
    shadow_strength: float = 0.15,
    highlight_strength: float = 0.10,
) -> np.ndarray:
    """Inject color into shadows and highlights."""
    out = lut.copy()
    lum = 0.2126 * out[:, 0] + 0.7152 * out[:, 1] + 0.0722 * out[:, 2]

    shadow_w = np.clip(1.0 - lum / 0.5, 0, 1) * shadow_strength
    highlight_w = np.clip((lum - 0.5) / 0.5, 0, 1) * highlight_strength

    for ch in range(3):
        out[:, ch] += shadow_w * (shadow_color[ch] - out[:, ch])
        out[:, ch] += highlight_w * (highlight_color[ch] - out[:, ch])

    return np.clip(out, 0, 1)


def apply_luminance_saturation(
    rgb: np.ndarray,
    lum: np.ndarray,
    shadow_amount: float = 0.0,
    highlight_amount: float = 0.0,
    midtone_boost: float = 0.0,
    shadow_end: float = 0.42,
    highlight_start: float = 0.58,
) -> np.ndarray:
    """Adjust saturation by tonal region in linear light."""
    out = rgb.copy()
    shadow_w = 1.0 - _smoothstep(0.0, shadow_end, lum)
    highlight_w = _smoothstep(highlight_start, 1.0, lum)
    mid_w = np.clip(1.0 - shadow_w - highlight_w, 0.0, 1.0)
    sat = 1.0 - shadow_w * shadow_amount - highlight_w * highlight_amount + mid_w * midtone_boost
    sat = np.clip(sat, 0.0, 2.0)
    gray = lum[:, None]
    return np.clip(gray + (out - gray) * sat[:, None], 0, 1)


def apply_filmic_color(lut: np.ndarray, params: dict) -> np.ndarray:
    """Luminance-aware film emulation authored in linear light."""
    out = to_linear(lut)

    luma_weights = np.array(params.get("luma_weights", (0.2126, 0.7152, 0.0722)))
    lum = np.clip(out @ luma_weights, 0.0, 1.0)

    tone_curve = params["tone_curve"]
    tone = _spline_curve(lum, tone_curve)
    density = np.divide(tone, np.maximum(lum, 1e-5))
    density_amount = params.get("density_amount", 1.0)
    density = 1.0 + (density - 1.0) * density_amount
    out *= density[:, None]

    mid = params.get("midpoint", 0.5)
    shadow_w = 1.0 - _smoothstep(mid * 0.35, mid, lum)
    shadow_floor = _smoothstep(params.get("shadow_floor_start", 0.02), params.get("shadow_floor_end", 0.14), lum)
    shadow_w *= shadow_floor
    highlight_w = _smoothstep(mid, 1.0, lum)

    shadow_tint = np.array(params.get("shadow_tint", (0.0, 0.0, 0.0)))
    highlight_tint = np.array(params.get("highlight_tint", (0.0, 0.0, 0.0)))
    out += shadow_w[:, None] * shadow_tint[None, :]
    out += highlight_w[:, None] * highlight_tint[None, :]

    out = apply_luminance_saturation(
        out,
        np.clip(out @ luma_weights, 0.0, 1.0),
        shadow_amount=params.get("shadow_desat", 0.0),
        highlight_amount=params.get("highlight_desat", 0.0),
        midtone_boost=params.get("midtone_sat_boost", 0.0),
        shadow_end=params.get("shadow_end", 0.42),
        highlight_start=params.get("highlight_start", 0.58),
    )

    coupling = params.get("coupling")
    if coupling:
        mix_amt = coupling.get("amount", 0.0)
        if mix_amt > 0:
            matrix = np.array(coupling["matrix"])
            mixed = out @ matrix.T
            out = out * (1.0 - mix_amt) + mixed * mix_amt

    out = np.clip(to_srgb(out), 0, 1)

    # Lifted-black toe (film-base floor). The multiplicative `density` above
    # SHAPES the toe but cannot raise a mathematical zero (0 * density == 0), so
    # a stock without a split_tone clips to pure black at input (0,0,0) even
    # though its tone_curve promises a lifted toe. This restores the floor those
    # curves imply ("blacks ~0.02-0.05"). Applied in display space so the values
    # match the target directly; strongest at true black, faded out through the
    # deep shadows by `black_lift_end`. Default is None -> exact no-op, so stocks
    # that already carry a present toe (via split_tone) are untouched.
    black_lift = params.get("black_lift")
    if black_lift is not None:
        lift = np.atleast_1d(np.asarray(black_lift, dtype=np.float64))
        if lift.size == 1:
            lift = np.repeat(lift, 3)
        srgb_lum = np.clip(out @ luma_weights, 0.0, 1.0)
        lift_end = params.get("black_lift_end", 0.06)
        w = 1.0 - _smoothstep(0.0, lift_end, srgb_lum)
        out = out + w[:, None] * lift[None, :]

    return np.clip(out, 0, 1)


# ---------------------------------------------------------------------------
# Processing pipelines
# ---------------------------------------------------------------------------

def process_color(lut, params):
    """
    Color film simulation pipeline.

    Two mutually exclusive paths:
      - filmic_color present -> terminal linear-light film engine. It owns the
        full render; any per-hue saturation / hue shift / split-tone seasoning
        lives INSIDE the filmic_color dict so it is explicit and never stacks
        with the legacy keys by accident.
      - otherwise -> legacy path: per-channel tone curves -> saturation/hue ->
        split toning. Kept only for stocks not yet migrated to the filmic engine.
    """
    out = lut.copy()

    if "filmic_color" in params:
        fc = params["filmic_color"]
        out = apply_filmic_color(out, fc)
        # Display-referred seasoning, contained in the filmic dict.
        if "saturation" in fc:
            sat = fc["saturation"]
            out = apply_saturation(out, global_sat=sat.get("global", 1.0), per_hue=sat.get("per_hue"))
        if "hue_shift" in fc:
            out = apply_hue_shift(out, fc["hue_shift"])
        if "split_tone" in fc:
            st = fc["split_tone"]
            out = apply_split_tone(
                out,
                shadow_color=st["shadow_color"],
                highlight_color=st["highlight_color"],
                shadow_strength=st.get("shadow_strength", 0.15),
                highlight_strength=st.get("highlight_strength", 0.10),
            )
        return np.clip(out, 0, 1)

    # --- Legacy path (not-yet-migrated stocks) ---

    # Per-channel tone curves
    if "r_curve" in params:
        out[:, 0] = _spline_curve(out[:, 0], params["r_curve"])
        out[:, 1] = _spline_curve(out[:, 1], params["g_curve"])
        out[:, 2] = _spline_curve(out[:, 2], params["b_curve"])
    elif "curve" in params:
        for ch in range(3):
            out[:, ch] = _spline_curve(out[:, ch], params["curve"])

    # Saturation
    if "saturation" in params:
        sat = params["saturation"]
        out = apply_saturation(
            out,
            global_sat=sat.get("global", 1.0),
            per_hue=sat.get("per_hue"),
        )

    # Hue shift
    if "hue_shift" in params:
        out = apply_hue_shift(out, params["hue_shift"])

    # Split tone
    if "split_tone" in params:
        st = params["split_tone"]
        out = apply_split_tone(
            out,
            shadow_color=st["shadow_color"],
            highlight_color=st["highlight_color"],
            shadow_strength=st.get("shadow_strength", 0.15),
            highlight_strength=st.get("highlight_strength", 0.10),
        )

    return np.clip(out, 0, 1)


def process_bw(lut, params):
    """
    B&W film simulation pipeline:
    RGB -> weighted luminance -> tone curve -> optional tint
    """
    weights = params["weights"]
    tint = params.get("tint", None)

    lum = weights[0] * lut[:, 0] + weights[1] * lut[:, 1] + weights[2] * lut[:, 2]

    # Tone curve
    if "curve" in params:
        lum = _spline_curve(lum, params["curve"])

    if tint:
        out = np.stack([lum * t for t in tint], axis=-1)
    else:
        out = np.stack([lum, lum, lum], axis=-1)

    return np.clip(out, 0, 1)


# ---------------------------------------------------------------------------
# Film stock definitions — per-channel tone curves + color adjustments
#
# Curves are (input, output) control points in [0,1].
# All presets target full dynamic range: blacks ~0.02-0.05, whites ~0.94-0.98.
# ---------------------------------------------------------------------------

# === Kodak Color Negative ===

PORTRA_400 = {
    "type": "color",
    # Portra: warm, creamy, slightly desaturated skin tones
    # Soft S-curve, lifted blacks, gentle highlight rolloff
    "r_curve": [
        (0.0, 0.035), (0.05, 0.07), (0.15, 0.17), (0.30, 0.34),
        (0.50, 0.55), (0.70, 0.73), (0.85, 0.86), (0.95, 0.94), (1.0, 0.97),
    ],
    "g_curve": [
        (0.0, 0.03), (0.05, 0.06), (0.15, 0.15), (0.30, 0.31),
        (0.50, 0.51), (0.70, 0.70), (0.85, 0.83), (0.95, 0.92), (1.0, 0.95),
    ],
    "b_curve": [
        (0.0, 0.025), (0.05, 0.05), (0.15, 0.13), (0.30, 0.27),
        (0.50, 0.46), (0.70, 0.64), (0.85, 0.78), (0.95, 0.88), (1.0, 0.92),
    ],
    "saturation": {
        "global": 0.92,
        "per_hue": {
            "red": 0.80, "red2": 0.80, "orange": 0.85,
            "green": 1.05, "blue": 1.02, "cyan": 0.95,
        },
    },
    "hue_shift": {"orange": 0.008, "yellow": 0.01},
    "split_tone": {
        "shadow_color": (0.30, 0.22, 0.14),
        "highlight_color": (1.0, 0.97, 0.90),
        "shadow_strength": 0.12,
        "highlight_strength": 0.06,
    },
}

EKTAR_100 = {
    "type": "color",
    # Ektar: vivid, punchy, saturated — landscape/product film
    # Steep S-curve, deep blacks, strong color
    "r_curve": [
        (0.0, 0.01), (0.05, 0.03), (0.12, 0.09), (0.25, 0.22),
        (0.50, 0.54), (0.70, 0.76), (0.85, 0.90), (0.95, 0.96), (1.0, 0.98),
    ],
    "g_curve": [
        (0.0, 0.01), (0.05, 0.03), (0.12, 0.08), (0.25, 0.21),
        (0.50, 0.52), (0.70, 0.74), (0.85, 0.88), (0.95, 0.95), (1.0, 0.97),
    ],
    "b_curve": [
        (0.0, 0.01), (0.05, 0.02), (0.12, 0.07), (0.25, 0.19),
        (0.50, 0.48), (0.70, 0.70), (0.85, 0.85), (0.95, 0.93), (1.0, 0.96),
    ],
    "saturation": {
        "global": 1.25,
        "per_hue": {
            "red": 1.10, "red2": 1.10, "orange": 1.08,
            "green": 1.20, "blue": 1.15, "cyan": 1.10, "yellow": 1.12,
        },
    },
    "split_tone": {
        "shadow_color": (0.22, 0.16, 0.10),
        "highlight_color": (1.0, 0.98, 0.93),
        "shadow_strength": 0.08,
        "highlight_strength": 0.04,
    },
}

GOLD_200 = {
    "type": "color",
    # Gold: warm amber consumer stock, nostalgic, less dynamic range
    # Strong warm cast, lifted blacks, compressed highlights
    "r_curve": [
        (0.0, 0.05), (0.05, 0.09), (0.15, 0.19), (0.30, 0.36),
        (0.50, 0.56), (0.70, 0.73), (0.85, 0.85), (0.95, 0.92), (1.0, 0.95),
    ],
    "g_curve": [
        (0.0, 0.04), (0.05, 0.07), (0.15, 0.16), (0.30, 0.32),
        (0.50, 0.51), (0.70, 0.68), (0.85, 0.81), (0.95, 0.89), (1.0, 0.93),
    ],
    "b_curve": [
        (0.0, 0.03), (0.05, 0.05), (0.15, 0.11), (0.30, 0.23),
        (0.50, 0.40), (0.70, 0.56), (0.85, 0.70), (0.95, 0.82), (1.0, 0.87),
    ],
    "saturation": {
        "global": 1.00,
        "per_hue": {
            "red": 0.95, "orange": 1.05, "yellow": 1.15,
            "green": 1.08, "blue": 0.85, "cyan": 0.88,
        },
    },
    "hue_shift": {"orange": 0.01, "yellow": 0.015},
    "split_tone": {
        "shadow_color": (0.32, 0.24, 0.14),
        "highlight_color": (1.0, 0.95, 0.82),
        "shadow_strength": 0.15,
        "highlight_strength": 0.08,
    },
}

# === Fuji Slide / Reversal ===

VELVIA = {
    "type": "color",
    # Velvia: the landscape film. Extreme saturation and high contrast, but the
    # punch comes from density + tonal saturation + channel coupling, not a flat
    # HSL multiply. Highlights stay saturated longer than other stocks.
    "filmic_color": {
        # Hard slide-film S: crushed toe, fast mids, firm shoulder.
        "tone_curve": enc_curve([
            (0.0, 0.008), (0.06, 0.035), (0.18, 0.125), (0.35, 0.295),
            (0.50, 0.52), (0.68, 0.75), (0.82, 0.885), (0.93, 0.945), (1.0, 0.965),
        ]),
        "density_amount": 1.0,
        "midpoint": 0.50,
        "shadow_tint": (0.0, 0.0, 0.003),
        "highlight_tint": (0.004, 0.002, 0.004),
        "shadow_floor_start": 0.03,
        "shadow_floor_end": 0.16,
        # Deepest present toe in the set — Velvia's crushed slide toe, lifted just
        # off pure black so it reads as film base, not a clipped digital zero.
        "black_lift": (0.011, 0.009, 0.014),
        "shadow_desat": 0.05,
        "highlight_desat": 0.06,
        "midtone_sat_boost": 0.22,
        "shadow_end": 0.20,
        "highlight_start": 0.80,
        "coupling": {
            "amount": 0.06,
            "matrix": [
                [1.030, -0.015, -0.015],
                [-0.012, 1.025, -0.013],
                [-0.013, -0.012, 1.025],
            ],
        },
        "saturation": {
            "global": 1.12,
            "per_hue": {
                "red": 1.00, "red2": 1.00, "orange": 1.02,
                "green": 1.14, "blue": 1.12, "cyan": 1.10, "yellow": 1.04,
            },
        },
        "hue_shift": {"green": 0.008, "cyan": 0.006, "blue": -0.004},
    },
}

PROVIA = {
    "type": "color",
    # Provia: neutral, balanced general-purpose slide film. The reference look —
    # honest contrast, a clean shoulder, a touch of pop that leans nowhere.
    "filmic_color": {
        # Honest general-purpose S: real toe, gentle pop, clean shoulder.
        "tone_curve": enc_curve([
            (0.0, 0.015), (0.06, 0.045), (0.18, 0.145), (0.35, 0.315),
            (0.50, 0.51), (0.68, 0.725), (0.82, 0.86), (0.93, 0.93), (1.0, 0.955),
        ]),
        "density_amount": 0.95,
        "midpoint": 0.50,
        "shadow_tint": (0.0, 0.0, 0.0),
        "highlight_tint": (0.004, 0.002, 0.006),
        "shadow_floor_start": 0.04,
        "shadow_floor_end": 0.18,
        # Real, present toe for the neutral reference slide — deeper than the
        # negatives but no longer clipped to zero.
        "black_lift": (0.017, 0.013, 0.020),
        "shadow_desat": 0.06,
        "highlight_desat": 0.10,
        "midtone_sat_boost": 0.10,
        "shadow_end": 0.22,
        "highlight_start": 0.74,
        "coupling": {
            "amount": 0.03,
            "matrix": [
                [1.012, 0.004, -0.016],
                [0.004, 1.006, -0.010],
                [-0.008, 0.006, 1.002],
            ],
        },
        "saturation": {
            "global": 1.05,
            "per_hue": {"green": 1.06, "blue": 1.04, "cyan": 1.04},
        },
    },
}

ASTIA = {
    "type": "color",
    # Astia: soft, flattering portrait slide film. Lifted toe for milky blacks,
    # strong highlight desaturation for creamy rolloff, protected skin tones.
    "filmic_color": {
        # Soft S: milky lifted toe, gentle mids, creamy early shoulder.
        "tone_curve": enc_curve([
            (0.0, 0.025), (0.06, 0.06), (0.18, 0.16), (0.35, 0.33),
            (0.50, 0.505), (0.68, 0.705), (0.82, 0.84), (0.93, 0.91), (1.0, 0.94),
        ]),
        "density_amount": 0.85,
        "midpoint": 0.52,
        "shadow_tint": (0.004, 0.003, 0.004),
        "highlight_tint": (0.012, 0.006, 0.0),
        "shadow_floor_start": 0.06,
        "shadow_floor_end": 0.22,
        # Milky lifted blacks are Astia's stated identity — highest slide floor,
        # a soft warm-neutral so shadows read creamy rather than crushed.
        "black_lift": (0.026, 0.021, 0.030),
        "black_lift_end": 0.09,
        "shadow_desat": 0.04,
        "highlight_desat": 0.16,
        "midtone_sat_boost": 0.06,
        "shadow_end": 0.24,
        "highlight_start": 0.72,
        "coupling": {
            "amount": 0.03,
            "matrix": [
                [1.010, 0.006, -0.016],
                [0.004, 1.004, -0.008],
                [-0.006, 0.006, 1.000],
            ],
        },
        "saturation": {
            "global": 1.00,
            "per_hue": {"red": 0.90, "red2": 0.90, "orange": 0.92, "green": 1.04},
        },
    },
}

# === Fuji Digital Simulations ===

CLASSIC_CHROME = {
    "type": "color",
    # Classic Chrome: muted, earthy documentary/street look. Heavy shadow
    # desaturation, warm earthy shadow tint, greens/cyans pulled way down. The
    # desaturation is the identity — shadow_desat does the tonal work, the
    # nested global/per-hue does the rest.
    "filmic_color": {
        # Documentary S: deep shadows, punchy low-mids, restrained highlights.
        "tone_curve": enc_curve([
            (0.0, 0.012), (0.06, 0.038), (0.18, 0.13), (0.35, 0.305),
            (0.50, 0.515), (0.68, 0.73), (0.82, 0.855), (0.93, 0.92), (1.0, 0.945),
        ]),
        "density_amount": 0.95,
        "midpoint": 0.55,
        "shadow_tint": (0.012, 0.006, -0.004),
        "highlight_tint": (0.006, 0.002, -0.004),
        "shadow_floor_start": 0.05,
        "shadow_floor_end": 0.22,
        "shadow_desat": 0.18,
        "highlight_desat": 0.10,
        "midtone_sat_boost": 0.0,
        "shadow_end": 0.26,
        "highlight_start": 0.74,
        "coupling": {
            "amount": 0.05,
            "matrix": [
                [1.018, 0.014, -0.032],
                [0.010, 1.000, -0.010],
                [-0.012, 0.020, 0.992],
            ],
        },
        "saturation": {
            "global": 0.72,
            "per_hue": {
                "green": 0.58, "yellow": 0.66, "orange": 0.85,
                "cyan": 0.62, "blue": 0.78,
            },
        },
        "hue_shift": {"orange": 0.012, "yellow": 0.018, "green": 0.02},
        "split_tone": {
            "shadow_color": (0.28, 0.20, 0.12),
            "highlight_color": (1.0, 0.96, 0.88),
            "shadow_strength": 0.16,
            "highlight_strength": 0.06,
        },
    },
}

CLASSIC_NEG = {
    "type": "color",
    # Classic Neg: denser contrast, richer mids, warm highlights and cooler shadows.
    # Tuned 2026-06 against a community recipe + reference frames (WB 5100K
    # R2/B-2, Tone H-2 S-2, Color +4, Chrome FX Blue strong): warm creamy
    # whites baked in, olive-shifted greens, dusty dense blues, soft shoulder.
    "filmic_color": {
        # Shoulder lands below 1.0 so the warm highlight_tint can't push a
        # channel into a hard clip — the rolloff is the whole point of the look.
        # Matte contrast: the punch lives in the crushed toe; upper mids and
        # highlights sit AT or BELOW identity (H-2). Pushing 0.6–0.85 up would
        # shove sunlit skin into the flat shoulder and erase its texture.
        "tone_curve": enc_curve([
            (0.0, 0.015), (0.06, 0.04), (0.18, 0.13), (0.35, 0.315),
            (0.50, 0.525), (0.68, 0.705), (0.82, 0.815), (0.93, 0.895), (1.0, 0.925),
        ]),
        "density_amount": 0.95,
        "midpoint": 0.60,
        # Cool-teal shadows vs warm cream highlights — the recipe's R+2/B-2
        # on a warm WB reads as this split, so it lives in the LUT.
        "shadow_tint": (-0.006, 0.002, 0.006),
        "highlight_tint": (0.020, 0.006, -0.008),
        "shadow_floor_start": 0.10,
        "shadow_floor_end": 0.26,
        "shadow_desat": 0.03,
        "highlight_desat": 0.03,
        "midtone_sat_boost": 0.03,
        "shadow_end": 0.24,
        "highlight_start": 0.76,
        "coupling": {
            "amount": 0.04,
            "matrix": [
                [1.015, 0.010, -0.015],
                [0.006, 1.00, -0.006],
                [-0.010, 0.015, 0.995],
            ],
        },
        # Seasoning is nested here, not at the top level, so it stays part of
        # the filmic render and never stacks via the legacy keys.
        # Color +4 richness carried by mids/reds; greens go muted-olive,
        # blues/cyans dusty-dense (the Chrome FX Blue read).
        "saturation": {
            "global": 1.05,
            "per_hue": {
                "green": 0.80, "yellow": 0.90, "red": 1.03, "red2": 1.03,
                "orange": 1.03, "cyan": 0.85, "blue": 0.86,
            },
        },
        "hue_shift": {"green": 0.032, "yellow": 0.010, "orange": 0.004, "cyan": 0.012, "blue": 0.006},
        # Global warm cast (the fixed 5100K feel): cream highlights, cool
        # slate shadows.
        "split_tone": {
            "shadow_color": (0.22, 0.26, 0.32),
            "highlight_color": (1.0, 0.95, 0.86),
            "shadow_strength": 0.08,
            "highlight_strength": 0.09,
        },
    },
}

PRO_NEG_HI = {
    "type": "color",
    # Pro Neg Hi: portrait negative — slightly warm, moderate contrast, clean
    # skin. A restrained look that flatters faces without going muddy.
    "filmic_color": {
        # Portrait-negative S: moderate punch, flattering highlight ramp.
        "tone_curve": enc_curve([
            (0.0, 0.015), (0.06, 0.045), (0.18, 0.14), (0.35, 0.315),
            (0.50, 0.515), (0.68, 0.73), (0.82, 0.855), (0.93, 0.92), (1.0, 0.95),
        ]),
        "density_amount": 0.90,
        "midpoint": 0.52,
        "shadow_tint": (0.006, 0.002, -0.002),
        "highlight_tint": (0.008, 0.003, -0.002),
        "shadow_floor_start": 0.05,
        "shadow_floor_end": 0.20,
        # Portrait negative: lifted toe in the 0.02 range, faintly warm to keep
        # skin shadows clean rather than clipped.
        "black_lift": (0.020, 0.015, 0.023),
        "shadow_desat": 0.06,
        "highlight_desat": 0.12,
        "midtone_sat_boost": 0.06,
        "shadow_end": 0.22,
        "highlight_start": 0.74,
        "coupling": {
            "amount": 0.035,
            "matrix": [
                [1.014, 0.008, -0.022],
                [0.006, 1.002, -0.008],
                [-0.008, 0.008, 1.000],
            ],
        },
        "saturation": {
            "global": 1.02,
            "per_hue": {"red": 1.03, "orange": 1.05, "yellow": 1.0},
        },
    },
}

PRO_NEG_STD = {
    "type": "color",
    # Pro Neg Std: low-contrast studio negative. Lifted blacks, compressed
    # highlights, muted across the board — a soft, controlled base.
    "filmic_color": {
        # Soft studio S: lifted blacks, low mid contrast, early shoulder —
        # but still a real curve, not flat.
        "tone_curve": enc_curve([
            (0.0, 0.025), (0.06, 0.062), (0.18, 0.165), (0.35, 0.335),
            (0.50, 0.50), (0.68, 0.70), (0.82, 0.82), (0.93, 0.89), (1.0, 0.925),
        ]),
        "density_amount": 0.80,
        "midpoint": 0.52,
        "shadow_tint": (0.004, 0.003, 0.003),
        "highlight_tint": (0.004, 0.003, 0.0),
        "shadow_floor_start": 0.06,
        "shadow_floor_end": 0.24,
        # Low-contrast studio negative: its comment promises lifted blacks, so
        # give it the highest negative floor (~0.03), soft and near-neutral.
        "black_lift": (0.029, 0.024, 0.033),
        "black_lift_end": 0.09,
        "shadow_desat": 0.10,
        "highlight_desat": 0.12,
        "midtone_sat_boost": 0.0,
        "shadow_end": 0.24,
        "highlight_start": 0.72,
        "coupling": {
            "amount": 0.03,
            "matrix": [
                [1.010, 0.006, -0.016],
                [0.004, 1.002, -0.006],
                [-0.006, 0.006, 1.000],
            ],
        },
        "saturation": {
            "global": 0.80,
            "per_hue": {"red": 0.90, "orange": 0.86, "yellow": 0.82, "green": 0.78},
        },
    },
}

ETERNA = {
    "type": "color",
    # Eterna: cinema stock, flat/log-like and desaturated with cool shadows.
    # Low density, compressed highlights, mids pulled down a touch — the graded
    # "footage" feel rather than a snapshot.
    "filmic_color": {
        # Cine log-ish S: raised toe, compressed shoulder, but enough mid
        # slope that footage reads graded rather than undeveloped.
        "tone_curve": enc_curve([
            (0.0, 0.03), (0.06, 0.07), (0.18, 0.175), (0.35, 0.345),
            (0.50, 0.495), (0.68, 0.665), (0.82, 0.785), (0.93, 0.865), (1.0, 0.90),
        ]),
        "density_amount": 0.85,
        "midpoint": 0.50,
        "shadow_tint": (-0.006, 0.0, 0.012),
        "highlight_tint": (0.002, 0.002, 0.004),
        "shadow_floor_start": 0.06,
        "shadow_floor_end": 0.24,
        "shadow_desat": 0.16,
        "highlight_desat": 0.14,
        "midtone_sat_boost": -0.04,
        "shadow_end": 0.28,
        "highlight_start": 0.70,
        "coupling": {
            "amount": 0.03,
            "matrix": [
                [1.006, 0.006, -0.012],
                [0.004, 1.000, -0.004],
                [-0.004, 0.008, 1.004],
            ],
        },
        "saturation": {
            "global": 0.58,
            "per_hue": {"green": 0.78, "cyan": 0.82, "blue": 0.86, "orange": 0.90},
        },
        "split_tone": {
            "shadow_color": (0.14, 0.16, 0.22),
            "highlight_color": (0.97, 0.96, 0.93),
            "shadow_strength": 0.10,
            "highlight_strength": 0.04,
        },
    },
}

ETERNA_BLEACH_BYPASS = {
    "type": "color",
    # Eterna Bleach Bypass: high contrast, very desaturated, gritty. Steep
    # curve, crushed toe, near-monochrome color with retained luminance contrast.
    "filmic_color": {
        # Steepest S in the set: crushed toe, hot highlights, gritty.
        "tone_curve": enc_curve([
            (0.0, 0.005), (0.06, 0.028), (0.18, 0.115), (0.35, 0.30),
            (0.50, 0.545), (0.68, 0.775), (0.82, 0.895), (0.93, 0.95), (1.0, 0.975),
        ]),
        "density_amount": 1.0,
        "midpoint": 0.50,
        "shadow_tint": (0.002, 0.002, 0.004),
        "highlight_tint": (0.004, 0.004, 0.004),
        "shadow_floor_start": 0.04,
        "shadow_floor_end": 0.16,
        # Bleach bypass is gritty crushed-shadow by design — give it the
        # smallest lift, just enough to clear pure-black clipping.
        "black_lift": (0.009, 0.008, 0.010),
        "shadow_desat": 0.20,
        "highlight_desat": 0.18,
        "midtone_sat_boost": -0.05,
        "shadow_end": 0.24,
        "highlight_start": 0.76,
        "coupling": {
            "amount": 0.02,
            "matrix": [
                [1.004, 0.004, -0.008],
                [0.002, 1.000, -0.002],
                [-0.004, 0.004, 1.000],
            ],
        },
        "saturation": {"global": 0.34},
    },
}

# === B&W Films ===

ACROS = {
    "type": "bw",
    "weights": (0.25, 0.65, 0.10),
    # Acros: fine detail, moderate contrast, clean tones
    "curve": [
        (0.0, 0.01), (0.05, 0.03), (0.15, 0.12), (0.30, 0.28),
        (0.50, 0.52), (0.70, 0.73), (0.85, 0.87), (0.95, 0.95), (1.0, 0.98),
    ],
}

TRI_X_400 = {
    "type": "bw",
    "weights": (0.35, 0.55, 0.10),
    # Tri-X: gritty, high contrast, deep blacks, photojournalism
    "curve": [
        (0.0, 0.0), (0.03, 0.01), (0.10, 0.04), (0.20, 0.14),
        (0.35, 0.32), (0.50, 0.55), (0.65, 0.74), (0.80, 0.88),
        (0.90, 0.94), (0.95, 0.97), (1.0, 0.99),
    ],
}

HP5_PLUS = {
    "type": "bw",
    "weights": (0.28, 0.62, 0.10),
    # HP5: versatile, moderate contrast, slightly softer than Tri-X
    "curve": [
        (0.0, 0.01), (0.05, 0.03), (0.15, 0.13), (0.30, 0.29),
        (0.50, 0.52), (0.70, 0.72), (0.85, 0.86), (0.95, 0.94), (1.0, 0.97),
    ],
}

DELTA_3200 = {
    "type": "bw",
    "weights": (0.24, 0.68, 0.08),
    # Delta 3200: pushed, low contrast, lifted shadows, dreamy
    "curve": [
        (0.0, 0.04), (0.05, 0.07), (0.15, 0.16), (0.30, 0.31),
        (0.50, 0.50), (0.70, 0.68), (0.85, 0.82), (0.95, 0.91), (1.0, 0.95),
    ],
}

MONOCHROME = {
    "type": "bw",
    "weights": (0.22, 0.70, 0.08),
    # Monochrome: clean, moderate
    "curve": [
        (0.0, 0.01), (0.05, 0.04), (0.15, 0.14), (0.30, 0.30),
        (0.50, 0.51), (0.70, 0.71), (0.85, 0.85), (0.95, 0.94), (1.0, 0.97),
    ],
}

SEPIA = {
    "type": "bw",
    "weights": (0.22, 0.70, 0.08),
    "curve": [
        (0.0, 0.02), (0.05, 0.05), (0.15, 0.14), (0.30, 0.30),
        (0.50, 0.51), (0.70, 0.71), (0.85, 0.85), (0.95, 0.94), (1.0, 0.97),
    ],
    "tint": (1.08, 0.94, 0.76),
}

# ---------------------------------------------------------------------------
# Pipeline dispatcher
# ---------------------------------------------------------------------------

PIPELINES = {
    "color": process_color,
    "bw": process_bw,
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

FILM_SIMS: list[tuple[str, str, dict]] = [
    # Fuji - Slide
    ("fuji", "Provia", PROVIA),
    ("fuji", "Velvia", VELVIA),
    ("fuji", "Astia", ASTIA),
    # Fuji - Digital
    ("fuji", "Classic_Chrome", CLASSIC_CHROME),
    ("fuji", "Classic_Neg", CLASSIC_NEG),
    ("fuji", "Pro_Neg_Hi", PRO_NEG_HI),
    ("fuji", "Pro_Neg_Std", PRO_NEG_STD),
    ("fuji", "Eterna", ETERNA),
    ("fuji", "Eterna_Bleach_Bypass", ETERNA_BLEACH_BYPASS),
    # Fuji - B&W
    ("fuji", "Acros", ACROS),
    ("fuji", "Monochrome", MONOCHROME),
    ("fuji", "Sepia", SEPIA),
    # Kodak - Color Negative
    ("kodak", "Portra_400", PORTRA_400),
    ("kodak", "Ektar_100", EKTAR_100),
    ("kodak", "Gold_200", GOLD_200),
    # Kodak - B&W
    ("kodak", "Tri_X_400", TRI_X_400),
    # Ilford - B&W
    ("ilford", "HP5_Plus", HP5_PLUS),
    ("ilford", "Delta_3200", DELTA_3200),
]


def diagnose_lut(name: str, lut: np.ndarray):
    """Print per-preset diagnostic stats for a generated LUT."""
    n = lut.shape[0]
    channels = ["R", "G", "B"]
    clip_lo = np.sum(lut <= 0.001, axis=0)
    clip_hi = np.sum(lut >= 0.999, axis=0)

    size = LUT_SIZE
    black_idx = 0
    mid = size // 2
    gray_idx = mid * size * size + mid * size + mid
    white_idx = n - 1

    print(f"\n{'='*60}")
    print(f"  {name}")
    print(f"{'='*60}")
    print(f"  {'Chan':>4}   {'Min':>6}  {'Max':>6}  {'Mean':>6}  {'ClipLo':>7}  {'ClipHi':>7}")
    for i, ch in enumerate(channels):
        lo_pct = 100 * clip_lo[i] / n
        hi_pct = 100 * clip_hi[i] / n
        flag_lo = " !" if lo_pct > 5 else ""
        flag_hi = " !" if hi_pct > 5 else ""
        print(
            f"  {ch:>4}   {lut[:, i].min():>6.3f}  {lut[:, i].max():>6.3f}  "
            f"{lut[:, i].mean():>6.3f}  {lo_pct:>6.1f}%{flag_lo}  {hi_pct:>6.1f}%{flag_hi}"
        )
    print(f"  Output at black  (0,0,0): ({lut[black_idx, 0]:.3f}, {lut[black_idx, 1]:.3f}, {lut[black_idx, 2]:.3f})")
    print(f"  Output at gray (0.5,0.5): ({lut[gray_idx, 0]:.3f}, {lut[gray_idx, 1]:.3f}, {lut[gray_idx, 2]:.3f})")
    print(f"  Output at white  (1,1,1): ({lut[white_idx, 0]:.3f}, {lut[white_idx, 1]:.3f}, {lut[white_idx, 2]:.3f})")


def main():
    diagnose = "--diagnose" in sys.argv

    if not diagnose:
        print(f"Generating {len(FILM_SIMS)} LUTs at {LUT_SIZE}x{LUT_SIZE}x{LUT_SIZE} ({LUT_SIZE**3} entries each)...")

    base = identity_lut(LUT_SIZE)

    for subdir, name, params in FILM_SIMS:
        title = name.replace("_", " ")
        pipeline = PIPELINES[params["type"]]
        lut = pipeline(base, params)

        if diagnose:
            diagnose_lut(name, lut)
        else:
            path = OUTPUT_ROOT / subdir / f"{name}.cube"
            write_cube(lut, path, title, LUT_SIZE)

    if not diagnose:
        print(f"\nDone! {len(FILM_SIMS)} .cube files written to {OUTPUT_ROOT}")


if __name__ == "__main__":
    main()
