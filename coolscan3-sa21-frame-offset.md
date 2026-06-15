# Coolscan3 / SA-21 frame-offset investigation

Tracking the multi-frame strip-holder (Nikon **SA-21**) frame-positioning drift in the
`coolscan3` SANE backend, and verifying the corrected `frame_offset` across multiple
film rolls.

- **Scanner:** Nikon **LS-50 ED** (Coolscan V ED), 4000 dpi
- **Device:** `coolscan3:usb:libusb:000:001`
- **Holder:** SA-21 strip-film adapter (6 frames)
- **Backend source:** `backend/coolscan3.c`
- **Started:** 2026-06-14

---

## 1. Hardware constants (from INQUIRY)

Dumped with:

```bash
SANE_DEBUG_COOLSCAN3=4 scanimage -d 'coolscan3:usb:libusb:000:001' -A 2>&1 \
  | grep -iE 'depth|focus|resolution|frame|boundary'
```

| value                         | device units | mm (@4000 dpi) | source |
|-------------------------------|--------------|----------------|--------|
| `resx_max` = `resy_max`       | 4000 dpi     | —              | inquiry |
| `unit_dpi` / `unit_mm`        | 4000 dpi     | 0.00635 mm/unit| `25.4 / resx_max` |
| `boundaryy` (holder window H) | **5959**     | 37.84 mm       | `subframe` max 37.8333 = (boundaryy-1)·unit_mm; `focusy` max 5958 |
| `frame_offset` (current code) | **6001**     | 38.11 mm       | `resy_max*1.5 + 1` (coolscan3.c:2563) |
| frames                        | 6            | —              | inquiry |
| max depth                     | 14 bit       | —              | inquiry |
| focus range                   | 0 / 323      | —              | inquiry |

Note: scanned at full 4000 dpi → pitch = 1, so **1 output pixel = 1 device unit = 0.00635 mm**.
That is why the TIFFs are 5959 px tall (= `boundaryy`).

---

## 2. The bug

`coolscan3.c:2563`

```c
s->frame_offset = s->resy_max * 1.5 + 1;   /* "works for LS-30, maybe not for others" */
```

Per-frame Y origin (coolscan3.c:2908):

```c
s->real_yoffset = ymin + (s->i_frame - 1) * s->frame_offset + s->subframe / s->unit_mm;
```

Two independent errors observed:

1. **Cumulative drift** — `frame_offset` (6001) is larger than the true frame pitch, so each
   successive frame over-advances and the image creeps. Measured drift ≈ 43 px/frame.

   ```
   frame_offset − boundaryy = 6001 − 5959 = 42 units/frame   ≈   measured 43 px/frame
   ```

   → **true pitch ≈ boundaryy (5959)**, not 6001.

2. **Constant base offset** — even with drift removed, the inter-frame gap sits ~15–16 %
   down from the top of every frame: a fixed origin offset of **≈963 units ≈ 6.1 mm**
   (the SA-21's frame-1 does not begin at film position 0).

### Derivation

The bright spike in the top-region row-brightness profile is the **clear film base in the
inter-frame gap**. Its distance from the window top:

```
gap_pos(N) = (S0 − gap_film) + (N−1)·(P − frame_offset)
```

Solving with the two measured points:

| frame N | gap center (px) | % of height |
|---------|-----------------|-------------|
| 2       | ~920            | 15.4 %      |
| 4       | ~834            | 14.0 %      |

```
2·(P − 6001) = 834 − 920 = −86   →   P = 5958  ≈ boundaryy (5959)   ✓
(S0 − gap_film) = 920 − (P−6001) ≈ 963 units ≈ 6.1 mm
```

---

## 3. The fix (APPLIED 2026-06-14)

**(a) Drift** — default per-frame advance now model-conditional (`coolscan3.c`,
`cs3_full_inquiry`):

```c
if (s->type == CS3_TYPE_LS30)
    s->frame_offset = s->resy_max * 1.5 + 1;  /* validated for LS-30 / SA-20 feeder */
else
    s->frame_offset = s->boundaryy;           /* SA-21 etc.: true pitch = holder window */
```

The old `resy_max*1.5+1` heuristic always targets ~38.11 mm (since `1.5×25.4=38.1` when
`resx_max==resy_max`). It was only ever *validated for the LS-30*, so that path is kept to
avoid regressing it (the LS-30 uses the SA-20 feeder, different holder geometry, and we
have no LS-30 `boundaryy` to confirm). All other models default to `boundaryy`
(measured-correct on the LS-50 ED). `--frame-offset` overrides either way.

> LS-2000 (also 2700 dpi, older) is untested under both old and new defaults — revisit if
> a user reports drift there.

**(b) Two new tunable options** (both mm, advanced, active only when frames > 1):

| option | controls | default | notes |
|---|---|---|---|
| `--frame-offset` | per-frame advance (pitch) | `boundaryy` × unit_mm (≈37.84 mm) | fixes/tunes the **drift** |
| `--frame-base-offset` | constant Y shift of the holder origin | 0 mm | fixes the **constant** offset; ≈6.1 mm for this roll |

Geometry now (`cs3_convert_options`):

```c
real_yoffset = ymin + frame_base/unit_mm + (i_frame-1)*frame_offset + subframe/unit_mm;
```

`frame-base-offset` and `subframe` both add a constant shift; use `frame-base-offset`
for the fixed per-holder origin and keep `subframe` for fine per-scan nudges.

Example (per-frame, IR, full res):

```bash
DEV='coolscan3:usb:libusb:000:001'
scanimage -d "$DEV" --frame 4 --frame-offset 37.84 --frame-base-offset 6.0 \
          --resolution 4000 --depth 14 --infrared=yes --format=tiff > out.tiff
```

> **Deploy (this machine):** the active backend lives in `~/.local/lib/sane/`, which the
> interactive shell has on `LD_LIBRARY_PATH`/`DYLD_LIBRARY_PATH`. Rebuild and copy:
> ```bash
> cd backend && make V_MAJOR=1 V_MINOR=0 V_REV=0 libsane-coolscan3.la
> cp .libs/libsane-coolscan3.1.so ~/.local/lib/sane/
> ```
> (The `V_MAJOR=...` overrides are needed because the tree was configured with
> `V_MAJOR=UNKNOWN`, which makes libtool's `-version-number` choke.)
> Note: brew's `scanimage` otherwise loads `/opt/homebrew/lib/sane/` (read-only Cellar
> symlink) — but `~/.local/lib/sane` on the library path takes precedence. A
> **non-interactive shell does NOT inherit** that env, so prefix one-off commands with
> `DYLD_LIBRARY_PATH="$HOME/.local/lib/sane:$DYLD_LIBRARY_PATH"` or they'll silently use
> the old brew backend (frame offset 6001, no new options).

---

## 4. Measurement method (reusable)

For each frame, scan full-frame (no crop) at full res with IR, then locate the inter-frame
gap (clear film base = bright spike near the top in a negative).

### Scan

```bash
export DYLD_LIBRARY_PATH="$HOME/.local/lib/sane:$DYLD_LIBRARY_PATH"   # use the fixed backend
DEV='coolscan3:usb:libusb:000:001'
for N in 1 2 3 4 5 6; do
  scanimage -d "$DEV" --frame $N --resolution 4000 --depth 14 \
            --infrared=yes --format=tiff > "roll<ID>-f0${N}.tiff"
done
```

### Measure gap position

```python
# measure_gap.py  —  usage: python3 measure_gap.py roll1-f02.tiff roll1-f04.tiff ...
import sys
from PIL import Image

def gap_center(path):
    im = Image.open(path).convert('RGB'); W, H = im.size; px = im.load()
    rows = []
    for y in range(0, int(H * 0.30), 6):           # scan top 30%
        s = n = 0
        for x in range(0, W, 24):
            r, g, b = px[x, y]; s += (r + g + b) / 3; n += 1
        rows.append((y, s / n))
    mx = max(v for _, v in rows)
    base = sorted(v for _, v in rows)[len(rows) // 4]
    thr = (mx + base) / 2
    band = [y for y, v in rows if v > thr]         # contiguous bright run = gap
    c = (min(band) + max(band)) / 2
    return W, H, c, 100 * c / H

for p in sys.argv[1:]:
    W, H, c, pct = gap_center(p)
    print(f'{p}: {W}x{H}  gapCenter={c:.0f}px  ({pct:.2f}% of H)')
```

> Caveat: film-edge frame numbers printed in the rebate can add extra bright rows below
> the true gap and skew a naive band center (seen on frame 4). Eyeball the profile and/or
> restrict the search window if a frame looks off.

### Interpret

- `boundaryy` and `frame_offset` (current) are fixed per scanner — see §1.
- Per-frame drift (units) = slope of `gapCenter` vs frame N. Expect **0** after the fix.
- Constant offset (mm) = residual `gapCenter` × `unit_mm` after drift is removed.
- At 4000 dpi: **1 px = 1 unit = 0.00635 mm**. At resolution R: 1 px = `(4000/R)` units.

---

## 5. Verification log

Goal: confirm `frame_offset = boundaryy` (drift → 0) and find the per-roll `subframe`
across rolls. Add a block per roll.

### Roll 1 — `2026-06-14` (LS-50 ED, SA-21) — pre-fix baseline

Files: `~/Pictures/2026/2026-06-14/test-02-ir_1.tiff` (frame 2),
`test-04-ir_1.tiff` (frame 4). Backend: **unfixed** (`frame_offset = 6001`).

| frame | gap center (px) | % of H | notes |
|-------|-----------------|--------|-------|
| 2     | ~920            | 15.4 % | |
| 4     | ~834            | 14.0 % | rebate frame-numbers visible in band |

- Measured drift: **~43 px/frame** (matches `6001 − 5959 = 42`).
- Implied true pitch: **~5958 ≈ boundaryy**.
- Implied constant offset: **~963 units ≈ 6.1 mm**.

### Roll 1 — `2026-06-15` (LS-50 ED, SA-21) — POST-FIX verification ✅

Same physical strip, re-scanned with the **fixed** backend (`frame offset: 5959`
confirmed live; `--frame-offset` default 37.8396 mm, `--frame-base-offset` default 0).
Files: `/tmp/roll1-fix-f0{2,4}.tiff`. Scanned `--resolution 4000 --depth 14
--infrared=yes`. Measured with hardened `measure_gap.py` (peak-anchored, ignores rebate).

| frame | gap center (px) | % of H | notes |
|-------|-----------------|--------|-------|
| 2     | 946             | 15.88 %| |
| 4     | 952             | 15.98 %| rebate band present but excluded by peak anchor |

- **Drift: +6 px across 2 frames ≈ +2 px/frame — eliminated** (was −43 px/frame). ✅
- Constant offset: **946 px ≈ 6.0 mm** → `--frame-base-offset 6.0`.
- **Base-offset option verified end-to-end:** re-scanning frame 2 with
  `--frame-base-offset 6.0` moved the gap from 946 px (15.9 %) to 64 px (1.1 %),
  i.e. pulled to the top edge so the frame fills the window
  (`/tmp/roll1-fix-f02-base6.tiff`). To clear the gap fully off the top, ~6.5–7 mm.

> Gotcha: `--depth` accepts only `8|14` (not 16); 14-bit is packed into the 16-bit TIFF.
> `measure_gap.py`'s old mid-threshold detector was fooled by frame 4's rebate band
> (reported a bogus center ~1218 px); the peak-anchored version reports 952 px correctly.

### Roll 2 — `<date>` — `<backend: fixed/unfixed>`

| frame | gap center (px) | % of H | notes |
|-------|-----------------|--------|-------|
|       |                 |        | |

- Drift: __ px/frame  (target: 0 after fix)
- Constant offset: __ mm  → subframe = __

### Roll 3 — `<date>`

| frame | gap center (px) | % of H | notes |
|-------|-----------------|--------|-------|
|       |                 |        | |

---

## 6. Status / open questions

- ✅ **Drift fix verified** on the LS-50 ED (Roll 1 post-fix: −43 → +2 px/frame).
- ✅ **Tunable options implemented & verified:** `--frame-offset` (default `boundaryy`)
  and `--frame-base-offset` (default 0); base offset confirmed end-to-end.
- ⚠️ **`--frame-base-offset` (and `--subframe`) cannot shift down past the frame end
  (2026-06-15, hardware-verified).** A 6 mm down-shift produced a flat constant-fill band
  (value ~66.6) over the bottom ~14% (frames 4 & 6). **Not a bug in this work:** `--subframe
  6.0` reproduces the *identical* artifact (same start row, same value), and `subframe`
  predates these changes. Root cause: the scanner only delivers data up to a fixed per-frame
  limit ≈ `frame_origin + boundaryy` (measured abs Y ≈ 23952 units / 152 mm for frame 4);
  any window shifted past it gets filler for the overrun. This limit is **not** moved by
  `subframe`, `frame_base`, or the boundary table (`cs3_set_boundary`) — a speculative
  change adding `frame_base` there had zero effect and was reverted.
  - The un-shifted (`base 0`) scan already captures the **full frame**; the ~6 mm gap is
    real clear-film-base sitting inside the window, not lost data.
  - **Correct way to remove the top gap: crop with `--tl-y` (not a down-shift).** Verified:
    `--frame 4 --tl-y 1100` (≈7 mm at full-res device units) removes the gap with **no fill
    band** (br-y auto-clamps to boundaryy-1, keeping the window inside the deliverable
    limit). `--frame-base-offset` remains useful only for *small* nudges, like `subframe`.
- ⏳ Is the constant offset (~6.0 mm) **stable across rolls/holders**, or does it vary with
  how the strip is inserted? Next: scan ≥2 more rolls, log in §5. If stable, consider
  baking ~6.0 mm in as the SA-21 default; if it varies, leave it user-set.
- ⏳ Verify the same correction on other SA-21-capable models (LS-40 / LS-IV ED).
- ⏳ LS-30 path kept on the old `resy_max*1.5+1` formula (unverified — no hardware).
