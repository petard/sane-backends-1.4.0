#!/usr/bin/env python3
"""Locate the inter-frame gap (clear film base) in coolscan3 strip scans.

Usage:  python3 measure_gap.py frameA.tiff frameB.tiff ...

For a negative, the clear film base in the inter-frame gap shows up as a bright
band near the top. Its position drifts with frame number when frame_offset is
wrong; after the fix (frame_offset = boundaryy) the position should be ~constant.
At 4000 dpi (full res) 1 output px = 1 device unit = 0.00635 mm.

See coolscan3-sa21-frame-offset.md for the full method and verification log.
"""
import sys
from PIL import Image


def gap_center(path):
    im = Image.open(path).convert('RGB')
    W, H = im.size
    px = im.load()
    rows = []
    for y in range(0, int(H * 0.30), 3):           # scan top 30%
        s = n = 0
        for x in range(0, W, 16):
            r, g, b = px[x, y]
            s += (r + g + b) / 3
            n += 1
        rows.append((y, s / n))
    # The clear film base in the gap is the BRIGHTEST band (~109 on this roll);
    # the film rebate / frame-number printing is dimmer (~80). Anchor to the
    # peak and grow the contiguous run around it, so the rebate never leaks in.
    peak_i = max(range(len(rows)), key=lambda i: rows[i][1])
    thr = 0.85 * rows[peak_i][1]
    lo = hi = peak_i
    while lo > 0 and rows[lo - 1][1] > thr:
        lo -= 1
    while hi < len(rows) - 1 and rows[hi + 1][1] > thr:
        hi += 1
    c = (rows[lo][0] + rows[hi][0]) / 2
    return W, H, c, 100 * c / H


def main(paths):
    results = []
    for p in paths:
        W, H, c, pct = gap_center(p)
        print(f'{p}: {W}x{H}  gapCenter={c:.0f}px  ({pct:.2f}% of H)')
        results.append((p, c, H))
    if len(results) >= 2:
        (_, c0, H0), (_, c1, _) = results[0], results[-1]
        print(f'\ndrift across first/last: {c1 - c0:+.0f}px  '
              f'(target ~0 after fix; constant offset = {c0:.0f}px '
              f'= {c0 * 0.00635:.1f} mm at 4000 dpi)')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
