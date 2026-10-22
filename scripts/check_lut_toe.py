#!/usr/bin/env python3
"""
Audit the black toe (lifted-black floor) of every bundled .cube LUT.

The community-recipe research ranked lifted/faded blacks as the single most
universal "film look" move. generate_luts.py *claims* "blacks ~0.02-0.05" per
stock, but nobody has verified the shipped cubes. This script reads the actual
cubes and measures the LUT output for input black (0,0,0) and 2% gray
(0.02, 0.02, 0.02) via proper trilinear interpolation of the 3D lattice.

Run:
    scripts/.venv/bin/python3 scripts/check_lut_toe.py

Verdict rules (from docs/plans/2026-07-imperfection-layer.md, Phase 5):
  - COLOR stock with a true-zero floor (max output channel < 0.005 at black)
    is FLAGGED as off-character: negatives and slide film alike should retain a
    present toe, not clip to pure black.
  - Slide film (Provia, Velvia, Astia) is allowed a *deeper* (lower) toe than
    the negative stocks (Classic_Neg, Classic_Chrome, Pro_Neg_*, Eterna*),
    so a low-but-present floor on a slide stock is fine.
  - B&W stocks (Acros, Monochrome, Sepia, Tri-X, HP5, Delta) are reported for
    reference but never flagged — their toe is their own character.

Exit code is the number of flagged color stocks (0 = clean).
"""

import sys
from pathlib import Path

import numpy as np

LUT_ROOT = Path(__file__).resolve().parent.parent / "FilmDev" / "Resources" / "LUTs"

# True-zero threshold: a color stock whose loudest black channel is below this
# has effectively clipped its toe to pure black.
TRUE_ZERO_MAX = 0.005

# Stock classification (mirrors generate_luts.py FILM_SIMS "type" + tonal family).
SLIDE = {"Provia", "Velvia", "Astia"}
COLOR_NEG = {
    "Classic_Neg", "Classic_Chrome", "Pro_Neg_Hi", "Pro_Neg_Std",
    "Eterna", "Eterna_Bleach_Bypass",
    "Portra_400", "Ektar_100", "Gold_200",
}
BW = {"Acros", "Monochrome", "Sepia", "Tri_X_400", "HP5_Plus", "Delta_3200"}


def parse_cube(path: Path) -> tuple[int, np.ndarray]:
    """Parse a .cube file -> (size, (size^3, 3) float array in R-fastest order)."""
    size = None
    rows = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            key = s.split()[0].upper()
            if key == "LUT_3D_SIZE":
                size = int(s.split()[1])
                continue
            if key in ("TITLE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_1D_SIZE"):
                continue
            parts = s.split()
            if len(parts) == 3:
                try:
                    rows.append([float(parts[0]), float(parts[1]), float(parts[2])])
                except ValueError:
                    continue
    if size is None:
        raise ValueError(f"{path}: missing LUT_3D_SIZE")
    data = np.asarray(rows, dtype=np.float64)
    if data.shape[0] != size ** 3:
        raise ValueError(f"{path}: expected {size**3} rows, found {data.shape[0]}")
    return size, data


def sample_trilinear(size: int, data: np.ndarray, rgb: tuple[float, float, float]) -> np.ndarray:
    """Trilinear-interpolate the 3D LUT at input `rgb` in [0,1].

    .cube rows are R-fastest: flat index = b_idx*size^2 + g_idx*size + r_idx,
    so the lattice reshapes to axes [b, g, r, channel].
    """
    grid = data.reshape(size, size, size, 3)  # [b, g, r, ch]

    def split(v: float) -> tuple[int, int, float]:
        vf = float(np.clip(v, 0.0, 1.0)) * (size - 1)
        i0 = int(np.floor(vf))
        i1 = min(i0 + 1, size - 1)
        return i0, i1, vf - i0

    r0, r1, fr = split(rgb[0])
    g0, g1, fg = split(rgb[1])
    b0, b1, fb = split(rgb[2])

    def corner(ri, gi, bi):
        return grid[bi, gi, ri]

    # interpolate along R
    c00 = corner(r0, g0, b0) * (1 - fr) + corner(r1, g0, b0) * fr
    c10 = corner(r0, g1, b0) * (1 - fr) + corner(r1, g1, b0) * fr
    c01 = corner(r0, g0, b1) * (1 - fr) + corner(r1, g0, b1) * fr
    c11 = corner(r0, g1, b1) * (1 - fr) + corner(r1, g1, b1) * fr
    # along G
    c0 = c00 * (1 - fg) + c10 * fg
    c1 = c01 * (1 - fg) + c11 * fg
    # along B
    return c0 * (1 - fb) + c1 * fb


def classify(name: str) -> str:
    if name in SLIDE:
        return "slide"
    if name in COLOR_NEG:
        return "color-neg"
    if name in BW:
        return "bw"
    return "unknown"


def verdict(kind: str, black: np.ndarray) -> tuple[str, bool]:
    """Return (verdict text, is_flagged)."""
    bmax = float(black.max())
    if kind == "bw":
        return "b&w (not flagged)", False
    if kind == "unknown":
        return "UNKNOWN class - review", False
    # color stock
    if bmax < TRUE_ZERO_MAX:
        return "FLAG true-zero toe (clipped to black)", True
    if kind == "slide":
        return f"ok - deep toe (slide, floor {bmax:.3f})", False
    return f"ok - lifted toe (floor {bmax:.3f})", False


def main() -> int:
    cubes = sorted(LUT_ROOT.rglob("*.cube"))
    if not cubes:
        print(f"No .cube files found under {LUT_ROOT}", file=sys.stderr)
        return 0

    # Order: slide, color-neg, bw, unknown — so the flaggable groups read first.
    order = {"slide": 0, "color-neg": 1, "bw": 2, "unknown": 3}
    records = []
    for path in cubes:
        name = path.stem
        kind = classify(name)
        size, data = parse_cube(path)
        black = sample_trilinear(size, data, (0.0, 0.0, 0.0))
        gray2 = sample_trilinear(size, data, (0.02, 0.02, 0.02))
        text, flagged = verdict(kind, black)
        records.append((order[kind], kind, name, black, gray2, text, flagged))
    records.sort(key=lambda r: (r[0], r[2]))

    header = (
        f"{'stock':<22} {'class':<10} "
        f"{'black R':>8} {'black G':>8} {'black B':>8}   "
        f"{'2% R':>7} {'2% G':>7} {'2% B':>7}   verdict"
    )
    print(f"LUT toe audit  (dir: {LUT_ROOT})")
    print(f"true-zero threshold: max black channel < {TRUE_ZERO_MAX}")
    print("=" * len(header))
    print(header)
    print("-" * len(header))

    last_kind = None
    flagged_names = []
    for _, kind, name, black, gray2, text, flagged in records:
        if kind != last_kind:
            if last_kind is not None:
                print()
            last_kind = kind
        if flagged:
            flagged_names.append(name)
        print(
            f"{name:<22} {kind:<10} "
            f"{black[0]:>8.4f} {black[1]:>8.4f} {black[2]:>8.4f}   "
            f"{gray2[0]:>7.4f} {gray2[1]:>7.4f} {gray2[2]:>7.4f}   {text}"
        )

    print("=" * len(header))
    if flagged_names:
        print(f"FLAGGED ({len(flagged_names)}): {', '.join(flagged_names)}")
    else:
        print("No color stocks flagged - every color toe is present.")
    return len(flagged_names)


if __name__ == "__main__":
    sys.exit(main())
