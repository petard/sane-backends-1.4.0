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

The per-frame pitch is selected by the `--adapter` option (in `cs3_convert_options`):

```c
if (s->adapter == CS3_ADAPTER_SA20)
    s->frame_offset = s->resy_max * 1.5 + 1;  /* LS-30 / SA-20 feeder, ~38.11 mm */
else
    s->frame_offset = s->boundaryy;           /* SA-21 (default): pitch = holder window */
```

The old `resy_max*1.5+1` heuristic always targets ~38.11 mm (since `1.5×25.4=38.1` when
`resx_max==resy_max`) and was only ever *validated for the LS-30*. It is selected by
`--adapter sa20`; `sa21` uses `boundaryy` (measured-correct on the LS-50 ED).

> **Default adapter is model-aware:** LS-30 and LS-2000 (the models shipping with the
> SA-20 feeder) default to `sa20`; all other models default to `sa21`. The user can
> override either way with `--adapter`. (The LS-30/LS-2000 default is untested on
> hardware — verified only that the LS-50 ED stays on `sa21`.)

**(b) Options:**

| option | values / unit | default | notes |
|---|---|---|---|
| `--adapter` | `sa21` \| `sa20` | `sa21` | selects frame pitch (SA-21 holder vs LS-30 SA-20) |
| `--frame-base-offset` | mm | 0 | constant Y shift of holder origin; small nudges only (see §6 down-shift limit) |

(The earlier `--frame-offset` mm option was removed in favour of `--adapter`.)

Geometry (`cs3_convert_options`):

```c
real_yoffset = ymin + frame_base/unit_mm + (i_frame-1)*frame_offset + subframe/unit_mm;
```

`frame-base-offset` and `subframe` both add a constant shift; keep both small.

Example (per-frame, IR, full res) — `--adapter` defaults to sa21 so it can be omitted on
the LS-50; crop the top gap with `--tl-y` (see §6):

```bash
DEV='coolscan3:usb:libusb:000:001'
scanimage -d "$DEV" --frame 4 --tl-y 1100 \
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
- ✅ **Options implemented & verified:** `--adapter` (`sa21` default = boundaryy /
  `sa20` = LS-30 pitch; verified frame-2 yoffset 5959 vs 6001) and `--frame-base-offset`.
  The earlier `--frame-offset` mm option was removed in favour of `--adapter`.
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

---

## 7. Adapter detection — INQUIRY vendor page 0xc1 (2026-06-15)

The backend reads a SCSI INQUIRY **vendor page `0xc1`** (`cs3_page_inquiry(s, 0xc1)`).
Its length is self-describing (`n = recv_buf[3] + 4`; 87 bytes on the LS-50 ED). Most
capabilities come from fixed offsets here (resolutions, `boundaryx/y`, focus, depth).

Originally the only holder signal used was `n_frames = recv_buf[75]`. Dumping the full
page with an **SA-21 strip** vs an **MA-21 slide mount** inserted (both empty of film
where noted) on the LS-50 ED revealed which bytes encode the adapter:

| byte | SA-21 | MA-21 | meaning |
|------|-------|-------|---------|
| **74** | `0x06` | `0x01` | **adapter frame *capacity*** — independent of load state. 1 = slide mount, N = N-frame strip. **This is the adapter-type discriminator.** |
| 75 | `0x00` | `0x01` | frames currently *loaded* (the historical `n_frames`). SA-21 was empty → 0; a loaded 6-frame strip reads 6; the slide mount always reads 1. |
| 58–61 (`boundaryy`) | 5959 | 5782 | scannable window height differs per holder |
| 17 | `0x31` | `0x22` | adapter-specific parameter |
| 48–49 | `0x0000` | `0x1695` | adapter-specific Y limit |
| 60–61 | `0x1747` | `0x1696` | (low half of boundaryy) |
| 64–65 | `0x1747` | `0x0000` | adapter-specific Y limit |
| 71, 73 | `0x61` | `0x00` | strip inter-frame spacing (0 for single-frame slide) |

Full SA-21 dump (empty), for reference:
```
off  0: 06 c1 00 53 03 00 3a 00 0f 00 00 00 40 01 01 00
off 16: 01 31 0f a0 0f a0 00 5a 00 00 00 00 00 00 00 00
off 32: 00 00 00 00 00 00 0f 6a 0f a0 0f a0 00 5a 00 00
off 48: 00 00 00 00 00 00 00 00 00 00 00 00 17 47 00 00
off 64: 17 47 00 00 00 00 00 61 00 61 06 00 00 00 01 43
off 80: 00 00 0e 0f 6a 00 01
```

### Key points
- **Byte 74 (capacity)** distinguishes *slide vs strip* and is stable regardless of
  whether film is loaded. **Byte 75 (loaded)** is what tells you if film/a slide is present.
- **Byte 74 does NOT distinguish SA-20 vs SA-21** — both are 6-frame strips and read `0x06`.
  The SA-20/SA-21 *pitch* choice therefore still relies on the model-based `--adapter`
  default (LS-30/LS-2000 → sa20). Byte 74 solves "slide vs strip/batch", not "which strip".
- A batch/bulk feeder (SF-200) is untested; it would presumably report its own capacity.
- `boundaryy` itself changes with the holder (5959 strip vs 5782 slide); since
  `frame_offset = boundaryy` (sa21), the pitch self-adjusts to the mounted holder.

### `scanimage -L` reporting
`cs3_open()` now issues the `0xc1` inquiry while building the device list and folds the
adapter name + film status into the SANE device **`type`** string (which `-L` prints):

| byte 74 (capacity) | `-L` suffix |
|--------------------|-------------|
| 1 (MA-21 slide) | `film scanner, MA-21 slide adapter` |
| 6 (SA-21 strip) | `film scanner, SA-21 strip adapter, film loaded` / `…, no film` (byte 75) |
| other >1 | `film scanner, <N>-frame strip adapter, film loaded` / `…, no film` |
| 0 / page unavailable | `film scanner` |

> **No load state for the MA-21 slide adapter:** byte 75 reads 1 whether or not a slide is
> physically present (confirmed: two byte-identical no-slide dumps), so slide presence is
> not detectable from page 0xc1. Film status is reported only for the strip adapter, where
> byte 75 = loaded frame count (0 = empty). A with-slide dump (to recheck for a presence
> bit) is a TODO once a slide is available.

Verified (MA-21 inserted, no slide):
```
device `coolscan3:usb:libusb:001:001' is a Nikon LS-50 ED film scanner, MA-21 slide adapter
```
