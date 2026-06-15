#!/usr/bin/env bash
#
# ir_clean_gmic.sh -- IR-mask dust/scratch removal for film scans, using G'MIC.
#
# Takes an RGB scan and its pixel-aligned infrared (IR) scan -- e.g. the two
# frames a coolscan3 infrared scan produces -- builds a defect mask from the
# IR channel and inpaints the RGB image through it.
#
# The IR and RGB frames must be the same dimensions and aligned, which they
# are when they come from one scan pass (no registration needed).
#
#   Usage:  ir_clean_gmic.sh RGB.tif IR.tif [OUT.tif]
#
#   Produce the inputs with:
#     scanimage -d 'coolscan3:usb:libusb:000:001' --infrared=yes \
#       --format=tiff --batch=slide_%d.tif --batch-count=2
#     # slide_1.tif = RGB frame, slide_2.tif = infrared frame
#
# HOW THE MASK WORKS (designed to generalise across scans/films):
#   Dust and scratches scatter IR, so they read DARKER than their local
#   surroundings.  We estimate the local background with a median filter and
#   look at how far each pixel falls below it (the "defect map").
#
#   The threshold is ADAPTIVE and ROBUST: it is set per-image as
#   median + k*sigma, where sigma is estimated from the Median Absolute
#   Deviation (sigma = 1.4826*MAD) of the defect map.  Using median/MAD rather
#   than mean/std means the estimate is NOT inflated by the sparse, very-high-
#   contrast outliers (the defects themselves, plus frame borders and strong
#   image edges in the IR).  A plain mean+std threshold over a whole frame gets
#   pulled high by those borders and then either misses faint dust or, when
#   loosened, floods the mask with film grain; the MAD estimate tracks the true
#   grain-noise level, so the same k behaves consistently across whole frames,
#   crops, films and grain levels.  It is also depth-agnostic (8- or 16-bit).
#
#   Two passes are unioned so both defect shapes are handled while film grain
#   is rejected by SHAPE (grain = tiny isolated specks; hairs = long lines):
#     * DUST pass -- sensitive threshold, keep components >= a few pixels,
#                    small dilation. Catches dust specks.
#     * LINE pass -- lower threshold (catches the whole faint hair, which is
#                    connected), keep only LARGE connected components (drops
#                    grain), generous dilation to cover the hair's full width.
#
# Tunables (override via environment); defaults aimed at LS-50 @ high res:
#   IR_MEDIAN        background-estimate median radius (px). Must exceed the
#                    half-width of the defects you want to catch.        [5]
#   IR_BLUR          pre-denoise blur sigma on the IR channel.          [0.6]
#   IR_DUST_SENS     dust threshold in robust sigmas above noise. Lower=more.[4]
#   IR_DUST_MINAREA  drop dust components smaller than this (px) -- this is
#                    what rejects film grain (grain clumps are small).    [8]
#   IR_DUST_DILATE   grow dust mask by this radius (px).                   [2]
#   IR_LINE_SENS     line/scratch threshold in robust sigmas. Lower=more.[1.5]
#   IR_LINE_MINAREA  min connected-component size to count as a line (px).[40]
#   IR_LINE_DILATE   grow line mask by this radius -- covers hair width.  [5]
#   IR_INPAINT       fast (default) | patch  (see below)
#   SAVE_MASK        if 1, also write the mask next to OUT (*.mask.tif). [unset]
#
# Inpaint method:
#   fast  (default) -- fast median fill. Near-instant, ideal for dust and the
#                      thin hairs/scratches this mask produces.
#   patch           -- patch-based texture synthesis. Occasionally better on
#                      very wide damage, but VERY slow on full-res scans
#                      (multi-scale over the whole image). Params: GMIC_PATCH,
#                      GMIC_LOOKUP, GMIC_BLEND, GMIC_BLEND_SCALES.
#
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $(basename "$0") RGB.tif IR.tif [OUT.tif]"

RGB=$1
IR=$2
OUT=${3:-"${RGB%.*}_clean.tif"}

command -v gmic >/dev/null 2>&1 || die "gmic not found -- install it: brew install gmic"
[ -f "$RGB" ] || die "RGB file not found: $RGB"
[ -f "$IR" ]  || die "IR file not found: $IR"

# --- tunables ---------------------------------------------------------------
IR_MEDIAN=${IR_MEDIAN:-5}
IR_BLUR=${IR_BLUR:-0.6}
IR_DUST_SENS=${IR_DUST_SENS:-4}
IR_DUST_MINAREA=${IR_DUST_MINAREA:-8}
IR_DUST_DILATE=${IR_DUST_DILATE:-2}
IR_LINE_SENS=${IR_LINE_SENS:-1.5}
IR_LINE_MINAREA=${IR_LINE_MINAREA:-40}
IR_LINE_DILATE=${IR_LINE_DILATE:-5}

IR_INPAINT=${IR_INPAINT:-fast}
GMIC_PATCH=${GMIC_PATCH:-9}
GMIC_LOOKUP=${GMIC_LOOKUP:-16}
GMIC_BLEND=${GMIC_BLEND:-11}
GMIC_BLEND_SCALES=${GMIC_BLEND_SCALES:-4}

# --- match output bit depth to the RGB input (8-bit -> uint8, else uint16) --
# (G'MIC 3.x pixel-type names: uint8 / uint16 / float32, not uchar/ushort)
OTYPE=uint16
if command -v identify >/dev/null 2>&1; then
	depth=$(identify -format '%z' "$RGB" 2>/dev/null || echo 16)
	[ "$depth" = "8" ] && OTYPE=uint8
fi

# --- pass 1: robust noise estimate (median + MAD) of the defect map ---------
# Build the defect map (median-background(IR) - IR) and read its median and its
# MAD via G'MIC's 'ic' (median) stat.  sigma = 1.4826*MAD matches a Gaussian's
# std but is immune to the sparse high-contrast outliers.  Absolute thresholds
# (median + k*sigma) are then derived in the shell and handed to pass 2.
stats=$(gmic \
	-input "$IR" -channels[0] 0 -blur[0] "$IR_BLUR" \
	+median[0] "$IR_MEDIAN" -sub[1] [0] -keep[1] \
	+fill[0] 'abs(i-ic)' \
	-echo 'CS3STAT_{-2,ic}_{-1,ic}' 2>&1 \
	| grep -oE 'CS3STAT_[-0-9.eE+]+_[-0-9.eE+]+' | head -1)
[ -n "$stats" ] || die "could not compute robust IR statistics via gmic"
MED=${stats#CS3STAT_}; MED=${MED%_*}
MAD=${stats##*_}
# sigma from MAD, with a floor so a degenerate (flat) IR can't flag everything
SIGMA=$(awk -v m="$MAD" 'BEGIN{s=1.4826*m; if(s<=0)s=1; print s}')
DUST_THR=$(awk -v c="$MED" -v s="$SIGMA" -v k="$IR_DUST_SENS" 'BEGIN{print c+k*s}')
LINE_THR=$(awk -v c="$MED" -v s="$SIGMA" -v k="$IR_LINE_SENS" 'BEGIN{print c+k*s}')

echo ">> RGB=$RGB  IR=$IR  ->  OUT=$OUT  (${OTYPE})"
echo ">> robust noise: median=$MED  MAD=$MAD  sigma=$SIGMA"
echo ">> dust: ${IR_DUST_SENS}sigma thr=$DUST_THR minarea=$IR_DUST_MINAREA dilate=$IR_DUST_DILATE"
echo ">> line: ${IR_LINE_SENS}sigma thr=$LINE_THR minarea=$IR_LINE_MINAREA dilate=$IR_LINE_DILATE"
if [ "$IR_INPAINT" = "patch" ]; then
	echo ">> inpaint: PATCH (slow) patch=$GMIC_PATCH lookup=$GMIC_LOOKUP blend=$GMIC_BLEND scales=$GMIC_BLEND_SCALES"
else
	echo ">> inpaint: fast median fill"
fi

# --- pipeline ---------------------------------------------------------------
# Images are referenced by name so index shuffling can't bite us.
#   [rgb]  : the colour image to repair (left untouched until inpaint)
#   [ir]   : infrared frame, single channel, lightly denoised
#   [base] : defect map = local-background(IR) - IR  (large where defects are)
#   [mask] : 0/255 defect mask -- nonzero = "inpaint here"
#
# DUST_THR / LINE_THR are the absolute median+k*sigma thresholds computed from
# the robust noise estimate in pass 1, so the fill is a plain 'i > thr'.
cmd=(gmic
	-input "$RGB"             -name[-1] rgb
	-input "$IR"              -name[-1] ir
	-channels[ir] 0
	-blur[ir] "$IR_BLUR"
	+median[ir] "$IR_MEDIAN"  -name[-1] base
	-sub[base] [ir]
	# DUST pass: sensitive threshold, drop tiny grain, light dilation
	+fill[base] "i>$DUST_THR?1:0" -name[-1] dust
	-area_fg[dust] 0
	-threshold[dust] "$IR_DUST_MINAREA"
	-dilate_circ[dust] "$IR_DUST_DILATE"
	# LINE pass: lower threshold, keep only large connected components, dilate wide
	+fill[base] "i>$LINE_THR?1:0" -name[-1] line
	-area_fg[line] 0
	-threshold[line] "$IR_LINE_MINAREA"
	-dilate_circ[line] "$IR_LINE_DILATE"
	# union the two passes into the final mask
	-max[dust] [line]
	-mul[dust] 255
	-name[dust] mask)

# optionally dump the mask for tuning (set SAVE_MASK=1)
if [ "${SAVE_MASK:-0}" = "1" ]; then
	cmd+=(-output[mask] "${OUT%.*}.mask.tif,uint8")
fi

if [ "$IR_INPAINT" = "patch" ]; then
	# patch-based: [mask],patch_size,lookup_size,lookup_factor,
	#   lookup_increment,blend_size,blend_threshold,blend_decay,
	#   blend_scales,is_blend_outer
	cmd+=(-inpaint[rgb] "[mask],$GMIC_PATCH,$GMIC_LOOKUP,0.1,1,$GMIC_BLEND,0,0.05,$GMIC_BLEND_SCALES,1")
else
	# fast fill: [mask],0,fast_method  (3 = high-connectivity median)
	cmd+=(-inpaint[rgb] "[mask],0,3")
fi
cmd+=(-keep[rgb]
	-output "$OUT,$OTYPE")

"${cmd[@]}"

echo ">> wrote $OUT"
