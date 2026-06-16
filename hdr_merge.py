#!/usr/bin/env python3
"""Radiometric linear HDR merge for aligned coolscan3 exposure brackets.

Usage:
    hdr_merge.py OUT.tiff EXPOSURE:FILE [EXPOSURE:FILE ...]
    hdr_merge.py out.tiff 0.5:b0.5.tiff 1:b1.tiff 2:b2.tiff 4:b4.tiff

Inputs must be the SAME frame scanned at different --exposure multipliers,
linear (identity gamma LUT) and WITHOUT --negative, so that pixel value is
proportional to (scene radiance x exposure). Because the scanner does not move
the film between scans, the brackets are already pixel-aligned.

Merge: each bracket is scaled to common radiance (pixel / exposure) and combined
with a per-pixel, per-channel "well-exposedness" weight (0 at black/clipped, peak
mid-tone); clipped highlights are discarded. Output is a 16-bit linear TIFF
master. For negative film, invert afterwards (e.g. `magick out.tiff -negate ...`).

Requires: numpy, tifffile  (pip install tifffile)
"""
import sys
import numpy as np

try:
    import tifffile
except ImportError:
    sys.exit("error: tifffile required -- pip install tifffile")


def merge(pairs):
    """pairs: list of (exposure_float, filepath). Returns float64 HxWxC radiance."""
    maxv = None
    acc = wsum = None
    for e, f in pairs:
        arr = tifffile.imread(f)
        if maxv is None:
            maxv = float(np.iinfo(arr.dtype).max)
            acc = np.zeros(arr.shape, np.float64)
            wsum = np.zeros(arr.shape, np.float64)
        a = arr.astype(np.float64)
        n = a / maxv
        w = 1.0 - (2.0 * n - 1.0) ** 2      # well-exposedness: 0 at 0/1, peak 0.5
        w = np.clip(w, 0.0, None)
        w[n >= 0.99] = 0.0                   # discard clipped highlights
        w += 1e-6                            # keep weight sum > 0 everywhere
        acc += w * (a / e)                   # scale to common (exposure=1) radiance
        wsum += w
    return acc / wsum


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    out = argv[1]
    pairs = []
    for a in argv[2:]:
        e, sep, f = a.partition(":")
        if not sep:
            sys.exit("bad arg %r (expected EXPOSURE:FILE)" % a)
        pairs.append((float(e), f))

    hdr = merge(pairs)
    scale = float(np.percentile(hdr, 99.9)) or float(hdr.max()) or 1.0
    out16 = (np.clip(hdr / scale, 0.0, 1.0) * 65535.0).astype(np.uint16)
    tifffile.imwrite(out, out16)
    h, w = out16.shape[:2]
    print("wrote %s  (%dx%d, %d brackets, norm=%.1f)" % (out, w, h, len(pairs), scale))


if __name__ == "__main__":
    main(sys.argv)
