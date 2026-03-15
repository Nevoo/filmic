#!/usr/bin/env python3
"""
Generate 17x17x17 .cube LUT files for FilmDev film simulations.

Uses physically-inspired film emulsion modeling:
- H&D characteristic curves in log-exposure / density space
- Negative film: emulsion → transmittance → print paper → reflectance
- Slide film: reversal H&D curves → transmittance
- B&W: weighted luminance → negative H&D → print H&D → optional tint
- Digital sims: log-space tone curves with artistic adjustments

Usage:
    python3 filmdev/scripts/generate_luts.py

Outputs .cube files to filmdev/FilmDev/Resources/LUTs/{fuji,kodak,ilford}/
"""

import numpy as np
from pathlib import Path

# ---------------------------------------------------------------------------
# LUT infrastructure
# ---------------------------------------------------------------------------

LUT_SIZE = 17
OUTPUT_ROOT = Path(__file__).resolve().parent.parent / "FilmDev" / "Resources" / "LUTs"


def identity_lut(size: int = LUT_SIZE) -> np.ndarray:
    """Return an identity LUT as (size^3, 3) float64 array, B-fastest order for .cube."""
    coords = np.linspace(0.0, 1.0, size)
    # .cube iterates R(slowest), G(middle), B(fastest)
    # meshgrid indexing="ij": first arg = axis 0 (slowest), last = fastest
    r, g, b = np.meshgrid(coords, coords, coords, indexing="ij")
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
# Color-space helpers (kept for digital sims)
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


# ---------------------------------------------------------------------------
# Digital sim helpers (kept for Fuji digital modes)
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


# ---------------------------------------------------------------------------
# Physical film emulsion model
# ---------------------------------------------------------------------------

def hd_curve(log_h, d_min, d_max, gamma, speed, toe=1.0, shoulder=1.0):
    """
    Parametric H&D (Hurter-Driffield) characteristic curve.

    Models the sensitometric response of film emulsion as an asymmetric sigmoid
    in log-exposure / density space.

    Parameters:
        log_h:     log10(exposure) values
        d_min:     fog level (minimum density)
        d_max:     maximum density
        gamma:     contrast (slope of linear portion)
        speed:     film speed (horizontal position of curve)
        toe:       shadow rolloff sharpness (lower = softer toe)
        shoulder:  highlight rolloff sharpness (lower = softer shoulder)

    Returns:
        density values
    """
    x = (log_h - speed) * gamma
    k = np.where(x < 0, toe * x, shoulder * x)
    sigmoid = 1.0 / (1.0 + np.exp(-k))
    return d_min + (d_max - d_min) * sigmoid


def hd_curve_reversal(log_h, d_min, d_max, gamma, speed, toe=1.0, shoulder=1.0):
    """Reversal (slide) film H&D curve — high exposure = low density."""
    return d_min + d_max - hd_curve(log_h, d_min, d_max, gamma, speed, toe, shoulder)


def percentile_normalize(channel, lo_pct=0.5, hi_pct=99.5):
    """Normalize channel to [0,1] using percentiles (like enlarger exposure adjustment)."""
    lo = np.percentile(channel, lo_pct)
    hi = np.percentile(channel, hi_pct)
    if hi - lo < 1e-10:
        return np.clip(channel, 0, 1)
    return np.clip((channel - lo) / (hi - lo), 0, 1)


# ---------------------------------------------------------------------------
# Processing pipeline helpers
# ---------------------------------------------------------------------------

LOG_FLOOR = 1e-6


def _apply_hd_per_channel(log_h, channel_params, curve_fn=hd_curve):
    """Apply H&D curve per-channel using parameter dicts for R, G, B."""
    out = np.empty_like(log_h)
    for ch, p in enumerate(channel_params):
        out[:, ch] = curve_fn(
            log_h[:, ch], p["d_min"], p["d_max"], p["gamma"],
            p["speed"], p.get("toe", 1.0), p.get("shoulder", 1.0),
        )
    return out


def _apply_hd_single(log_h, p, curve_fn=hd_curve):
    """Apply H&D curve using a single parameter dict."""
    return curve_fn(
        log_h, p["d_min"], p["d_max"], p["gamma"],
        p["speed"], p.get("toe", 1.0), p.get("shoulder", 1.0),
    )


def _apply_dir_coupler(density, strength):
    """DIR coupler: exposure-dependent cross-channel saturation boost."""
    if strength > 0:
        mean_density = np.mean(density, axis=1, keepdims=True)
        density = density + strength * (density - mean_density)
    return density


def _density_to_transmittance(density):
    """Beer-Lambert law: T = 10^(-D)."""
    return np.power(10.0, -density)


def _normalize_channels(data):
    """Percentile-normalize each channel of an (N,3) array to [0,1]."""
    out = np.empty_like(data)
    for ch in range(3):
        out[:, ch] = percentile_normalize(data[:, ch])
    return out


def _print_stage(transmittance, print_params):
    """Print paper stage: transmittance → print H&D → reflectance."""
    print_log = np.log10(np.clip(transmittance, LOG_FLOOR, None))
    if print_log.ndim == 1:
        print_density = _apply_hd_single(print_log, print_params)
    else:
        print_density = np.empty_like(print_log)
        for ch in range(3):
            print_density[:, ch] = _apply_hd_single(print_log[:, ch], print_params)
    return _density_to_transmittance(print_density)


# ---------------------------------------------------------------------------
# Processing pipelines
# ---------------------------------------------------------------------------

def process_color_negative(lut, params):
    """
    Color negative film pipeline:
    Input RGB [0,1] → log10(exposure) → per-channel H&D curves → negative density
    → subtract orange mask → DIR coupler cross-channel boost
    → transmittance (Beer-Lambert) → log10(transmittance)
    → print paper H&D curves → print density → reflectance → normalize → [0,1]
    """
    orange_mask = params.get("orange_mask", (0.0, 0.0, 0.0))

    log_h = np.log10(np.clip(lut, LOG_FLOOR, 1.0))
    neg_density = _apply_hd_per_channel(
        log_h, [params["r"], params["g"], params["b"]],
    )

    # Subtract orange mask (compensates for dye crossover in color negatives)
    neg_density -= np.array(orange_mask)
    neg_density = np.maximum(neg_density, 0.0)

    neg_density = _apply_dir_coupler(neg_density, params.get("dir_strength", 0.0))
    transmittance = _density_to_transmittance(neg_density)
    reflectance = _print_stage(transmittance, params["print"])

    return _normalize_channels(reflectance)


def process_slide(lut, params):
    """
    Slide / reversal film pipeline:
    Input RGB [0,1] → log10(exposure) → per-channel reversal H&D curves
    → DIR coupler boost → transmittance → normalize → [0,1]
    """
    log_h = np.log10(np.clip(lut, LOG_FLOOR, 1.0))
    density = _apply_hd_per_channel(
        log_h, [params["r"], params["g"], params["b"]],
        curve_fn=hd_curve_reversal,
    )

    density = _apply_dir_coupler(density, params.get("dir_strength", 0.0))
    transmittance = _density_to_transmittance(density)

    return _normalize_channels(transmittance)


def process_bw(lut, params):
    """
    B&W film pipeline:
    Input RGB → weighted luminance → log10(lum) → negative H&D curve
    → transmittance → print paper H&D curve → reflectance → normalize
    → optional tint → [0,1]
    """
    weights = params["weights"]
    tint = params.get("tint", None)

    lum = weights[0] * lut[:, 0] + weights[1] * lut[:, 1] + weights[2] * lut[:, 2]
    lum = np.clip(lum, LOG_FLOOR, None)

    log_h = np.log10(lum)
    neg_density = _apply_hd_single(log_h, params["negative"])
    transmittance = _density_to_transmittance(neg_density)
    reflectance = _print_stage(transmittance, params["print"])
    reflectance = percentile_normalize(reflectance)

    if tint:
        out = np.stack([reflectance * t for t in tint], axis=-1)
    else:
        out = np.stack([reflectance, reflectance, reflectance], axis=-1)

    return np.clip(out, 0, 1)


def process_digital(lut, params):
    """
    Digital simulation pipeline (Fuji digital processing modes):
    Input RGB → log10 → normalize to [0,1] → per-channel tone curves
    → saturation/hue/split-tone adjustments → [0,1]

    Working in log space gives more filmic rolloff than raw RGB curves.
    """
    # Work in log space for filmic rolloff
    log_rgb = np.log10(np.clip(lut, LOG_FLOOR, 1.0))
    # Normalize log values to [0,1] range
    log_min = np.log10(LOG_FLOOR)
    out = (log_rgb - log_min) / (0.0 - log_min)
    out = np.clip(out, 0, 1)

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


# ---------------------------------------------------------------------------
# Film stock parameter definitions
# ---------------------------------------------------------------------------

# === Color Negatives ===

PORTRA_400 = {
    "type": "color_negative",
    "r": {"d_min": 0.20, "d_max": 2.4, "gamma": 0.55, "speed": -0.50, "toe": 0.8, "shoulder": 0.7},
    "g": {"d_min": 0.18, "d_max": 2.5, "gamma": 0.55, "speed": -0.48, "toe": 0.8, "shoulder": 0.7},
    "b": {"d_min": 0.16, "d_max": 2.6, "gamma": 0.55, "speed": -0.45, "toe": 0.8, "shoulder": 0.7},
    "orange_mask": (0.15, 0.08, 0.0),
    "dir_strength": 0.15,
    "print": {"d_min": 0.04, "d_max": 1.9, "gamma": 2.2, "speed": -0.55, "toe": 1.1, "shoulder": 0.85},
}

EKTAR_100 = {
    "type": "color_negative",
    "r": {"d_min": 0.15, "d_max": 2.8, "gamma": 0.65, "speed": -0.55, "toe": 1.0, "shoulder": 0.85},
    "g": {"d_min": 0.12, "d_max": 2.9, "gamma": 0.65, "speed": -0.52, "toe": 1.0, "shoulder": 0.85},
    "b": {"d_min": 0.10, "d_max": 3.0, "gamma": 0.65, "speed": -0.50, "toe": 1.0, "shoulder": 0.85},
    "orange_mask": (0.12, 0.06, 0.0),
    "dir_strength": 0.35,
    "print": {"d_min": 0.04, "d_max": 2.1, "gamma": 2.5, "speed": -0.60, "toe": 1.2, "shoulder": 0.9},
}

GOLD_200 = {
    "type": "color_negative",
    "r": {"d_min": 0.22, "d_max": 2.3, "gamma": 0.58, "speed": -0.48, "toe": 0.9, "shoulder": 0.75},
    "g": {"d_min": 0.20, "d_max": 2.4, "gamma": 0.58, "speed": -0.46, "toe": 0.9, "shoulder": 0.75},
    "b": {"d_min": 0.18, "d_max": 2.1, "gamma": 0.52, "speed": -0.38, "toe": 0.85, "shoulder": 0.70},
    "orange_mask": (0.20, 0.12, 0.0),
    "dir_strength": 0.20,
    "print": {"d_min": 0.04, "d_max": 2.0, "gamma": 2.3, "speed": -0.55, "toe": 1.1, "shoulder": 0.85},
}

# === Slide / Reversal Films ===

VELVIA = {
    "type": "slide",
    "r": {"d_min": 0.08, "d_max": 3.6, "gamma": 2.0, "speed": -0.40, "toe": 1.3, "shoulder": 1.1},
    "g": {"d_min": 0.06, "d_max": 3.6, "gamma": 2.0, "speed": -0.38, "toe": 1.3, "shoulder": 1.1},
    "b": {"d_min": 0.08, "d_max": 3.5, "gamma": 1.95, "speed": -0.42, "toe": 1.3, "shoulder": 1.1},
    "dir_strength": 0.40,
}

PROVIA = {
    "type": "slide",
    "r": {"d_min": 0.08, "d_max": 3.2, "gamma": 1.7, "speed": -0.42, "toe": 1.1, "shoulder": 1.0},
    "g": {"d_min": 0.06, "d_max": 3.2, "gamma": 1.7, "speed": -0.40, "toe": 1.1, "shoulder": 1.0},
    "b": {"d_min": 0.08, "d_max": 3.1, "gamma": 1.65, "speed": -0.44, "toe": 1.1, "shoulder": 1.0},
    "dir_strength": 0.20,
}

ASTIA = {
    "type": "slide",
    "r": {"d_min": 0.10, "d_max": 3.0, "gamma": 1.5, "speed": -0.44, "toe": 0.95, "shoulder": 0.9},
    "g": {"d_min": 0.08, "d_max": 3.0, "gamma": 1.5, "speed": -0.42, "toe": 0.95, "shoulder": 0.9},
    "b": {"d_min": 0.10, "d_max": 2.9, "gamma": 1.45, "speed": -0.46, "toe": 0.95, "shoulder": 0.9},
    "dir_strength": 0.12,
}

# === B&W Films ===

ACROS = {
    "type": "bw",
    "weights": (0.25, 0.65, 0.10),
    "negative": {"d_min": 0.08, "d_max": 2.8, "gamma": 0.68, "speed": -0.50, "toe": 1.0, "shoulder": 0.9},
    "print": {"d_min": 0.04, "d_max": 2.2, "gamma": 2.8, "speed": -0.55, "toe": 1.3, "shoulder": 0.95},
}

TRI_X_400 = {
    "type": "bw",
    "weights": (0.35, 0.55, 0.10),
    "negative": {"d_min": 0.10, "d_max": 2.6, "gamma": 0.72, "speed": -0.48, "toe": 0.9, "shoulder": 0.85},
    "print": {"d_min": 0.04, "d_max": 2.3, "gamma": 2.6, "speed": -0.55, "toe": 1.2, "shoulder": 0.9},
}

HP5_PLUS = {
    "type": "bw",
    "weights": (0.28, 0.62, 0.10),
    "negative": {"d_min": 0.09, "d_max": 2.5, "gamma": 0.62, "speed": -0.48, "toe": 0.95, "shoulder": 0.85},
    "print": {"d_min": 0.04, "d_max": 2.1, "gamma": 2.4, "speed": -0.55, "toe": 1.15, "shoulder": 0.9},
}

DELTA_3200 = {
    "type": "bw",
    "weights": (0.24, 0.68, 0.08),
    "negative": {"d_min": 0.15, "d_max": 2.2, "gamma": 0.48, "speed": -0.42, "toe": 0.8, "shoulder": 0.7},
    "print": {"d_min": 0.05, "d_max": 1.8, "gamma": 2.0, "speed": -0.50, "toe": 1.0, "shoulder": 0.85},
}

MONOCHROME = {
    "type": "bw",
    "weights": (0.22, 0.70, 0.08),
    "negative": {"d_min": 0.10, "d_max": 2.3, "gamma": 0.58, "speed": -0.48, "toe": 0.9, "shoulder": 0.8},
    "print": {"d_min": 0.04, "d_max": 1.9, "gamma": 2.2, "speed": -0.52, "toe": 1.1, "shoulder": 0.85},
}

SEPIA = {
    "type": "bw",
    "weights": (0.22, 0.70, 0.08),
    "negative": {"d_min": 0.10, "d_max": 2.3, "gamma": 0.58, "speed": -0.48, "toe": 0.9, "shoulder": 0.8},
    "print": {"d_min": 0.04, "d_max": 1.9, "gamma": 2.2, "speed": -0.52, "toe": 1.1, "shoulder": 0.85},
    "tint": (1.10, 0.95, 0.75),
}

# === Digital Simulations (Fuji digital processing modes) ===

CLASSIC_CHROME = {
    "type": "digital",
    "curve": [
        (0.0, 0.04), (0.10, 0.14), (0.25, 0.28), (0.5, 0.50),
        (0.75, 0.71), (0.90, 0.84), (1.0, 0.94),
    ],
    "saturation": {
        "global": 0.75,
        "per_hue": {"green": 0.6, "yellow": 0.7, "orange": 0.85, "cyan": 0.7},
    },
    "hue_shift": {"orange": 0.01, "yellow": 0.015},
    "split_tone": {
        "shadow_color": (0.25, 0.18, 0.10),
        "highlight_color": (1.0, 0.97, 0.90),
        "shadow_strength": 0.18,
        "highlight_strength": 0.06,
    },
}

CLASSIC_NEG = {
    "type": "digital",
    "curve": [
        (0.0, 0.0), (0.08, 0.05), (0.20, 0.19), (0.35, 0.37),
        (0.5, 0.53), (0.70, 0.68), (0.85, 0.81), (1.0, 0.92),
    ],
    "saturation": {
        "global": 0.88,
        "per_hue": {
            "green": 0.55, "yellow": 0.65, "red": 1.25, "red2": 1.25,
            "orange": 0.90, "cyan": 0.60,
        },
    },
    "hue_shift": {"green": 0.03, "yellow": 0.02, "orange": 0.015},
    "split_tone": {
        "shadow_color": (0.22, 0.15, 0.10),
        "highlight_color": (0.98, 0.95, 0.85),
        "shadow_strength": 0.15,
        "highlight_strength": 0.08,
    },
}

PRO_NEG_HI = {
    "type": "digital",
    "curve": [
        (0.0, 0.0), (0.10, 0.09), (0.25, 0.23), (0.5, 0.52),
        (0.75, 0.78), (0.90, 0.91), (1.0, 1.0),
    ],
    "saturation": {
        "global": 1.08,
        "per_hue": {"red": 1.05, "orange": 1.10},
    },
    "split_tone": {
        "shadow_color": (0.18, 0.14, 0.12),
        "highlight_color": (1.0, 0.98, 0.94),
        "shadow_strength": 0.06,
        "highlight_strength": 0.04,
    },
}

PRO_NEG_STD = {
    "type": "digital",
    "curve": [
        (0.0, 0.04), (0.10, 0.13), (0.25, 0.28), (0.5, 0.50),
        (0.75, 0.72), (0.90, 0.85), (1.0, 0.95),
    ],
    "saturation": {
        "global": 0.72,
        "per_hue": {"red": 0.90, "orange": 0.85, "yellow": 0.80, "green": 0.75},
    },
    "split_tone": {
        "shadow_color": (0.16, 0.14, 0.15),
        "highlight_color": (1.0, 0.99, 0.97),
        "shadow_strength": 0.04,
        "highlight_strength": 0.02,
    },
}

ETERNA = {
    "type": "digital",
    "curve": [
        (0.0, 0.06), (0.10, 0.14), (0.25, 0.29), (0.5, 0.49),
        (0.75, 0.69), (0.90, 0.81), (1.0, 0.91),
    ],
    "saturation": {
        "global": 0.60,
        "per_hue": {"green": 0.80, "cyan": 0.85, "blue": 0.90},
    },
    "split_tone": {
        "shadow_color": (0.14, 0.16, 0.20),
        "highlight_color": (0.96, 0.95, 0.92),
        "shadow_strength": 0.10,
        "highlight_strength": 0.05,
    },
}

ETERNA_BLEACH_BYPASS = {
    "type": "digital",
    "curve": [
        (0.0, 0.0), (0.05, 0.01), (0.15, 0.07), (0.30, 0.23),
        (0.5, 0.53), (0.70, 0.81), (0.85, 0.93), (0.95, 0.98), (1.0, 1.0),
    ],
    "saturation": {"global": 0.30},
    "split_tone": {
        "shadow_color": (0.12, 0.12, 0.14),
        "highlight_color": (0.98, 0.97, 0.94),
        "shadow_strength": 0.08,
        "highlight_strength": 0.04,
    },
}


# ---------------------------------------------------------------------------
# Pipeline dispatcher
# ---------------------------------------------------------------------------

PIPELINES = {
    "color_negative": process_color_negative,
    "slide": process_slide,
    "bw": process_bw,
    "digital": process_digital,
}


def generate_lut(base, params):
    """Dispatch to the appropriate pipeline based on film type."""
    pipeline = PIPELINES[params["type"]]
    return pipeline(base.copy(), params)


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

FILM_SIMS: list[tuple[str, str, dict]] = [
    # (subdirectory, filename, parameters)
    # Fuji - Color (slide)
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


def main():
    print(f"Generating {len(FILM_SIMS)} LUTs at {LUT_SIZE}x{LUT_SIZE}x{LUT_SIZE} ({LUT_SIZE**3} entries each)...")
    base = identity_lut(LUT_SIZE)

    for subdir, name, params in FILM_SIMS:
        title = name.replace("_", " ")
        lut = generate_lut(base, params)
        path = OUTPUT_ROOT / subdir / f"{name}.cube"
        write_cube(lut, path, title, LUT_SIZE)

    print(f"\nDone! {len(FILM_SIMS)} .cube files written to {OUTPUT_ROOT}")


if __name__ == "__main__":
    main()
