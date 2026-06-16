# coolscan3 backend — command-line manual

Reference for scanning Nikon Coolscan film scanners with the patched `coolscan3`
SANE backend via `scanimage`. Option ranges/defaults below are from a **Nikon
LS-50 ED** (Coolscan V ED, 4000 dpi); other models differ (e.g. max resolution,
boundaries). All options are set on the `scanimage` command line.

## Contents
- [Quick start](#quick-start)
- [Device selection & deploy notes](#device-selection--deploy-notes)
- [Examples](#examples)
- [Option reference](#option-reference)
- [Important gotchas](#important-gotchas)

---

## Quick start

```bash
DEV=$(scanimage -L | grep -oE 'coolscan3:[^ ]+' | tr -d '`'"'")
scanimage -d "$DEV" --resolution 4000 --depth 14 --format=tiff > scan.tiff
```

## Device selection & deploy notes

- List devices / confirm the adapter+film state:
  ```bash
  scanimage -L
  # device `coolscan3:usb:libusb:001:001' is a Nikon LS-50 ED film scanner, SA-21 strip adapter, film loaded
  ```
  The trailing text is reported by the backend: adapter name (MA-21 slide / SA-21
  or SA-20 strip / SA-30 roll / SF-210 feeder / N-frame) and film/slide status.
- The USB path (`…001:001`) can change when the scanner re-enumerates; resolve it
  dynamically with `scanimage -L` as in the snippet above.
- **This machine:** the patched backend lives in `~/.local/lib/sane/`. An
  interactive shell already has it on `LD_LIBRARY_PATH`/`DYLD_LIBRARY_PATH`; for
  scripts/non-interactive shells prefix:
  ```bash
  export DYLD_LIBRARY_PATH="$HOME/.local/lib/sane:$DYLD_LIBRARY_PATH"
  ```
  Otherwise the stock brew backend (no patches) is used.

---

## Examples

### 1. Single-file scan (RGB, full resolution)
```bash
DEV=$(scanimage -L | grep -oE 'coolscan3:[^ ]+' | tr -d '`'"'")
scanimage -d "$DEV" \
  --resolution 4000 \
  --depth 14 \
  --format=tiff > scan.tiff
```

### 2. Single-file scan with autofocus and negative inversion
```bash
scanimage -d "$DEV" \
  --resolution 4000 --depth 14 \
  --negative=yes --autofocus \
  --format=tiff > scan.tiff
```
`--negative=yes` makes the scanner output a positive image from C-41 negative film
(inversion is done in the scanner firmware; a residual orange/cyan cast may remain).

### 3. Scan with the infrared channel (dust/scratch data)
With `--infrared=yes` the scan is delivered as **two frames**: an RGB frame, then a
grayscale infrared frame. Use `--batch` with **`--batch-count=2`** so `scanimage`
writes both frames to separate files (without `--batch-count=2` only the first file
is produced):
```bash
scanimage -d "$DEV" \
  --resolution 4000 --depth 14 \
  --infrared=yes \
  --format=tiff --batch=scan_%d.tiff --batch-count=2
# -> scan_1.tiff = RGB image
#    scan_2.tiff = infrared channel (grayscale), same geometry
```
Feed `scan_2.tiff` (IR) into a dust/scratch removal step (e.g. `ir_clean_gmic.sh`).

### 4. Multi-frame batch (film strip in the SA-21)
With a strip loaded (`scanimage -L` shows `film loaded`), the `--frame*` options
activate. Scan all six frames to separate files:
```bash
scanimage -d "$DEV" \
  --frame 1 --frame-count 6 \
  --resolution 4000 --depth 14 \
  --format=tiff --batch=frame_%d.tiff
```
Add `--infrared=yes` to also get the IR frames — each physical frame then yields two
output files (RGB then IR), so set `--batch-count` to `2 × frames` (e.g. `--batch-count=12`
for 6 frames).

### 5. Low-resolution preview (the ONLY supported sub-1000 dpi path)
```bash
scanimage -d "$DEV" --preview=yes --preview-resolution 400 --format=tiff > preview.tiff
```

---

## Option reference

Types: **bool** = `[=(yes|no)]`, **fixed** = decimal, **int** = integer,
**list** = enumerated. Defaults/ranges shown are for the LS-50 ED.

### Image format

| option | type / unit | range | default | notes |
|--------|-------------|-------|---------|-------|
| `--depth` | list | `8` \| `14` | `8` | bits per channel. **Not 16** — 14-bit is packed into a 16-bit TIFF. |
| `--resolution` | list, dpi | `4000…90` (`4000,2000,1333,1000,800,…`) | `4000` | both axes. **Must be ≥ 1000** (see gotchas). |
| `--x-resolution` / `--y-resolution` | list, dpi | same list | inactive | only active when `--independent-res=yes`. |
| `--independent-res` | bool | yes/no | no | enables separate X/Y resolution. |
| `--preview` | bool | yes/no | no | preview mode; uses `--preview-resolution`, exempt from the 1000-dpi floor. |
| `--preview-resolution` | list, dpi | same list | `400` | resolution used in preview mode. |
| `--samples-per-scan` | int | `1…16` | `1` | multi-sampling (averaged); inactive on some models. |

### Color, exposure & tone

| option | type / unit | range | default | notes |
|--------|-------------|-------|---------|-------|
| `--negative` | bool | yes/no | no | invert colours for negative film (firmware inversion). |
| `--exposure` | fixed, ×multiplier | `0…10` (step ~0.1) | `1` | global exposure multiplier for all channels. |
| `--red-exposure` | fixed, µs | `50…20000` (step 10) | `1200` | red channel integration time. |
| `--green-exposure` | fixed, µs | `50…20000` (step 10) | `1200` | green channel integration time. |
| `--blue-exposure` | fixed, µs | `50…20000` (step 10) | `1000` | blue channel integration time. |
| `--ae` | bool | yes/no | no | auto-exposure pre-scan; **overrides** the exposure values above. |
| `--ae-wb` | bool | yes/no | no | auto-exposure + white balance; overrides exposure values. |
| `--red-gamma-table` | int list | `0…16383` (n_lut entries) | identity | per-channel tone LUT (applied in the ASIC). |
| `--green-gamma-table` | int list | `0…16383` | identity | |
| `--blue-gamma-table` | int list | `0…16383` | identity | |

Effective per-channel exposure sent to the scanner = `exposure × channel_µs`
(converted to the scanner's 10 ns units). E.g. default red = `1.0 × 1200 µs` = 1.2 ms.

### Infrared

| option | type | range | default | notes |
|--------|------|-------|---------|-------|
| `--infrared` | bool | yes/no | no | also capture the IR channel; delivered as a 2nd (grayscale) frame — use `--batch`. |

### Geometry / cropping

`scanimage` exposes these as the standard geometry flags (in **device pixels at max
resolution**, i.e. independent of `--resolution`):

| flag | meaning | range | default |
|------|---------|-------|---------|
| `-l` | left (top-left X) | `0…3945` | `0` |
| `-t` | top (top-left Y) | `0…5958` | `0` |
| `-x` | width | `0…3945` | `3945` |
| `-y` | height | `0…5958` | `5958` |

(`3945` = `boundaryx-1`, `5958` = `boundaryy-1`.) The long forms `--tl-x` / `--tl-y`
/ `--br-x` / `--br-y` also work. Setting `-t` (top) without a height makes `scanimage`
clamp the bottom to the maximum — a harmless `rounded value of br-y …` notice.

### Multi-frame film holder

Active only when a multi-frame strip is loaded (`scanimage -L` shows `film loaded`;
otherwise these are inactive).

| option | type / unit | range | default | notes |
|--------|-------------|-------|---------|-------|
| `--frame` | int | `1…N` (e.g. `1…6`) | `1` | which frame to scan. |
| `--frame-count` | int | `1…N` | `1` | number of frames to scan (use with `--batch`). |
| `--subframe` | fixed, mm | `0…37.83` | `0` | fine Y nudge within the selected frame (small values only). |
| `--adapter` | list | `sa21` \| `sa20` | model-dependent* | frame pitch: `sa21` = holder window; `sa20` = LS-30 pitch. |
| `--frame-base-offset` | fixed, mm | `0…37.83` | `0` | constant Y shift of the holder origin (small values only). |

\* Default is `sa20` on LS-30/LS-2000, `sa21` on all other models.

### Film / slide handling

| option | type | notes |
|--------|------|-------|
| `--load` | button | load the next slide/strip. |
| `--autoload` | bool (no) | auto-load before each scan. |
| `--eject` | button | eject the loaded medium. |
| `--reset` | button | re-initialize the scanner. |

### Focus

| option | type / unit | range | default | notes |
|--------|-------------|-------|---------|-------|
| `--autofocus` | bool | yes/no | no | autofocus before scan. |
| `--focus-on-centre` | bool | yes/no | yes | use scan-area centre as the AF point. |
| `--focus` | int | `0…323` | `0` | manual focus position. |
| `--focusx` / `--focusy` | int, px | `0…3945` / `0…5958` | inactive | manual AF point (active when `--focus-on-centre=no`). |

---

## Important gotchas

1. **Resolution must be ≥ 1000 dpi.** Scanning below 1000 dpi crashes the scanner
   (it hangs mid-transfer and needs a power cycle). The backend aborts such scans:
   `Resolution lower than 1000, use --preview and --preview-resolution instead`.
   Low-resolution scanning works **only** in preview mode.
2. **`--depth` is `8` or `14`, not 16.** 14-bit data is packed into a 16-bit TIFF.
3. **Infrared = two frames.** `--infrared=yes` yields an RGB frame then a grayscale
   IR frame; use `--batch=name_%d.tiff --batch-count=2` to write both (`--batch-count=2`
   is required — otherwise only the first file is produced).
4. **Don't interrupt a scan.** Killing `scanimage` mid-transfer desyncs the USB
   state and requires a full power cycle (power off + unplug USB) to recover.
5. **Geometry is in device pixels** (max-resolution units), not millimetres and not
   output pixels — independent of `--resolution`.
6. **Multi-frame options need a strip loaded.** `--frame`, `--frame-count`,
   `--adapter`, `--frame-base-offset` are inactive until `scanimage -L` reports
   `film loaded`.
7. **`--frame-base-offset` / `--subframe` are for small nudges only** — shifting the
   window far down past the frame end produces a constant-fill band at the bottom
   (the scanner won't deliver lines past its per-frame limit).
8. **`--ae` / `--ae-wb` override manual exposure** (`--exposure`, `--*-exposure`).
