#!/usr/bin/env bash
#
# hdr_scan.sh — HDR film scan for the coolscan3 backend.
#
# Scans the same frame at several exposures (--exposure brackets) and fuses them
# with enfuse to recover detail in both dense shadows and thin highlights.
#
# Why brackets align for free: the scanner does not move the film between scans
# (same frame, no advance), so the brackets are pixel-aligned by construction —
# no image registration step is needed.
#
# Requirements:
#   - enfuse           (brew install enblend-enfuse)
#   - the coolscan3 backend on the SANE library path
#
# Usage:
#   ./hdr_scan.sh <frame> <output.tiff> [exposure ...]
#   RES=2000 ./hdr_scan.sh 1 frame1-hdr.tiff
#   ./hdr_scan.sh 1 frame1-hdr.tiff 0.5 1 2 4
#
# Notes:
#   - Brackets are scanned WITHOUT --negative so that --exposure is the only
#     variable (the pos/neg bit also retunes analog exposure, which would fight
#     the bracketing). For negative film, invert the fused result afterwards,
#     e.g.:  magick out.tiff -negate out-positive.tiff
#   - Resolution must be >= 1000 (the backend rejects lower; use preview for low res).
#   - Bracket files are kept next to the output in <output>_brackets/ for reuse.

set -euo pipefail

FRAME="${1:?usage: hdr_scan.sh <frame> <output.tiff> [exposure ...]}"
OUT="${2:?usage: hdr_scan.sh <frame> <output.tiff> [exposure ...]}"
shift 2

# Exposure brackets (multipliers). Default spans 3 stops around 1x.
if [ "$#" -ge 1 ]; then
	EXPOSURES=("$@")
else
	EXPOSURES=(0.5 1 2 4)
fi

RES="${RES:-4000}"          # scan resolution (>= 1000); override with RES=2000 etc.
DEPTH="${DEPTH:-14}"        # 8 or 14

command -v enfuse >/dev/null 2>&1 || {
	echo "error: enfuse not found — install it: brew install enblend-enfuse" >&2
	exit 1
}

export DYLD_LIBRARY_PATH="$HOME/.local/lib/sane:${DYLD_LIBRARY_PATH:-}"
DEV=$(scanimage -L 2>/dev/null | grep -oE 'coolscan3:[^ ]+' | tr -d "\`'") || true
[ -n "${DEV:-}" ] || { echo "error: no coolscan3 device found (scanimage -L)" >&2; exit 1; }

BR_DIR="${OUT%.*}_brackets"
mkdir -p "$BR_DIR"

echo "HDR scan: device=$DEV frame=$FRAME res=$RES depth=$DEPTH exposures=${EXPOSURES[*]}"

FILES=()
for E in "${EXPOSURES[@]}"; do
	f="$BR_DIR/bracket_${E}.tiff"
	echo "  scanning exposure ${E}x -> $f"
	# --autofocus on each bracket: focus affects sharpness, not X/Y alignment.
	scanimage -d "$DEV" \
		--frame "$FRAME" \
		--exposure "$E" \
		--autofocus \
		--resolution "$RES" \
		--depth "$DEPTH" \
		--negative=no \
		--format=tiff > "$f"
	FILES+=("$f")
done

echo "fusing ${#FILES[@]} brackets -> $OUT"
# Aligned linear stack -> straight exposure fusion (no align_image_stack needed).
enfuse --output="$OUT" "${FILES[@]}"

echo "done: $OUT  (brackets kept in $BR_DIR/)"
echo "for negative film, invert: magick \"$OUT\" -negate \"${OUT%.*}-positive.${OUT##*.}\""
