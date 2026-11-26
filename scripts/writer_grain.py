"""Rebuild the seamless paper-density masks shared by the Mac and portable renderers."""
from pathlib import Path
import math
import random

SIZE = 96


def field(rng, columns, rows, skew=0):
    grid = [[rng.random() for _ in range(columns)] for _ in range(rows)]

    def sample(x, y):
        u = (x / SIZE + skew * y / SIZE) * columns
        v = y / SIZE * rows
        i, j = math.floor(u), math.floor(v)
        fx, fy = u - i, v - j
        fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
        def row(n):
            return grid[n % rows][i % columns] * (1-fx) + grid[n % rows][(i+1) % columns] * fx
        return row(j) * (1-fy) + row(j+1) * fy
    return sample


def clamp(x):
    return min(1, max(0, x))


def mask(tip):
    rng = random.Random(614 + tip)
    fine = field(rng, 44, 44)
    tooth = field(rng, 19, 23)
    pool = field(rng, 8, 9)
    fiber = field(rng, 9, 45, 1)
    output = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            f, t, p, strand = (sample(x, y) for sample in (fine, tooth, pool, fiber))
            # A soft change in density inside an inked area is visible on dark and colored paper.
            if tip == 0:     # Rolling ball, small skips and lengthwise scuffs
                alpha = 0.51 + 0.34*t + 0.18*f + 0.18*strand - 0.44*clamp((0.42-strand)*4)
            elif tip == 1:   # Loaded brush, a dark core with soft paper mottling
                alpha = 0.64 + 0.24*t + 0.13*p + 0.12*f - 0.10*clamp((0.32-t)*4)
            elif tip == 2:   # Dry bundles already have large gaps in their vector silhouette
                alpha = 0.36 + 0.38*t + 0.23*f + 0.20*strand - 0.31*clamp((0.4-strand)*4)
            elif tip == 3:   # Felt tip, fine stipple in an even-width line
                alpha = 0.59 + 0.36*f + 0.23*t - 0.30*clamp((0.40-f)*4)
            elif tip == 4:   # Gel, saturated bead with scattered tiny thin spots
                alpha = 0.82 + 0.13*p + 0.13*f - 0.43*clamp((0.39-f)*4)*(0.45+0.55*t)
            elif tip == 5:   # Broad nib, pooled ink between paper fibers
                alpha = 0.48 + 0.38*p + 0.23*strand + 0.15*t - 0.21*clamp((0.42-t)*3)
            else:            # Graphite, exposed paper valleys and dense raised ridges
                alpha = 0.04 + 1.5*clamp(0.56*t+0.33*f+0.23*strand-0.26)
            output.append(round(255*clamp(alpha)))
    return output


if __name__ == "__main__":
    target = Path(__file__).resolve().parents[1] / "web/assets/writer-grain.bin"
    target.write_bytes(b"".join(mask(tip) for tip in range(7)))
