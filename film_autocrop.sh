#!/usr/bin/env bash
#
# film_autocrop.sh -- auto-detect the film-holder border in a scanner TIFF and
# crop to the image frame.  Input TIFF -> output TIFF with "-processed" appended.
#
#   Usage:  film_autocrop.sh INPUT.tiff [OUTPUT.tiff]
#           (default OUTPUT = INPUT with "-processed" before the extension)
#
# Border model (from the scanner's direct output):
#   * Left/right: a solid vertical band -- BLACK on negatives, WHITE on
#     positives.  Either way it is a flat, untextured strip, so it shows up as
#     LOW per-column texture (std) at the edges; the image content is textured.
#   * Top: a solid horizontal band (the orange film base on negatives, dark on
#     positives) -- the film-base gap.  The previous frame may PROTRUDE above
#     this band, and the current frame below it may be smooth (e.g. sky), so
#     the band is found by BRIGHTNESS, not texture: it is the brightness
#     extreme (bright on negatives, dark on positives).  The crop is placed
#     just below the deepest such band within the top region.
#   * Bottom: no border -- kept in full.
#
# Left/right borders are found by TEXTURE (flat = border) so one rule covers
# both negative (black) and positive (white) side borders.  The top border is
# found by BRIGHTNESS because there the current content can be flatter than the
# border itself.  The script reports negative vs positive from the side-border
# brightness and uses it to know which brightness extreme the top border is.
#
# Tunables (override via environment):
#   COL_FRAC     column-texture threshold = COL_FRAC * median(col std).   [0.30]
#   BORDER_FRAC  top band must exceed median + BORDER_FRAC*(peak-median).  [0.50]
#   TOP_LIMIT    search the top border only within this top fraction.     [0.30]
#   ROW_INSET    inset inside the detected L/R borders for the row scan.  [0.03]
#   MARGIN       extra pixels trimmed inward on each detected edge.          [0]
#   NBINS_X/NBINS_Y  profile resolution (bins across width / height). [160/200]
#
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $(basename "$0") INPUT.tiff [OUTPUT.tiff]"
IN=$1
ext=${IN##*.}
OUT=${2:-"${IN%.*}-processed.${ext}"}

command -v gmic >/dev/null 2>&1 || die "gmic not found -- install it: brew install gmic"
[ -f "$IN" ] || die "input not found: $IN"

COL_FRAC=${COL_FRAC:-0.30}
BORDER_FRAC=${BORDER_FRAC:-0.50}
TOP_LIMIT=${TOP_LIMIT:-0.30}
MARGIN=${MARGIN:-0}
NBINS_X=${NBINS_X:-160}
NBINS_Y=${NBINS_Y:-200}

# preserve input bit depth (G'MIC 3.x type names: uint8 / uint16)
OTYPE=uint16
if command -v identify >/dev/null 2>&1; then
	[ "$(identify -format '%z' "$IN" 2>/dev/null || echo 16)" = "8" ] && OTYPE=uint8
fi

# G'MIC picks the output format from the extension, so the profile temp must
# end in .txt (otherwise it writes a binary .cimg that tr can't read).
TMPD=$(mktemp -d -t film_autocrop.XXXXXX) || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT
TMP="$TMPD/p.txt"

# Texture profile: per-bin standard deviation along one axis.  std = sqrt(E[L^2]
# - E[L]^2), reduced to NBINS via averaging resize.  Border bins ~0, content high.
_prof() { # $1 = crop spec, $2 = "W,H" target profile size
	gmic -input "$IN" "-crop[0]" "$1" "-luminance[0]" "+mul[0]" "[0]" \
		"-resize[0]" "$2,1,1,2" "-resize[1]" "$2,1,1,2" \
		"-sqr[0]" "-sub[1]" "[0]" "-sqrt[1]" "-keep[1]" \
		"-output[0]" "$TMP" 2>/dev/null
	tr ',\n' '  ' < "$TMP" | tr -s ' ' | sed 's/^ //;s/ *$//'
}

# awk median helper, shared by the two detectors below
read -r -d '' MEDIAN_FN <<'AWK' || true
function median(a,n,  i,j,t){
	for(i=1;i<=n;i++)for(j=i+1;j<=n;j++)if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}
	return (n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2
}
AWK

# 1. left/right borders from column texture --------------------------------
COLS=$(_prof "0,0,100%,100%" "$NBINS_X,1")
read -r xL xR <<EOF
$(awk -v C="$COLS" -v fr="$COL_FRAC" "$MEDIAN_FN"'
BEGIN{
	n=split(C,c," "); for(i=1;i<=n;i++)cc[i]=c[i];
	th=fr*median(cc,n);
	lo=0; hi=0; for(i=1;i<=n;i++) if(c[i]>th){ if(lo==0)lo=i; hi=i }
	if(lo==0){ lo=1; hi=n }            # no border found -> full width
	printf "%.6f %.6f", (lo-1)/n, hi/n
}')
EOF

# 2. negative vs positive from the side-border brightness ------------------
gmic -input "$IN" "-crop[0]" 0,0,1%,100% "-luminance[0]" "-resize[0]" 1,1,1,1,2 \
	"-output[0]" "$TMP" 2>/dev/null
edge=$(tr -d ' \n' < "$TMP")
kind=$(awk -v e="$edge" 'BEGIN{ print (e>128) ? "positive" : "negative" }')

# 3. top border from row BRIGHTNESS over the content width -----------------
# The inter-frame top border is the film-base gap -- a uniform band that is the
# brightness EXTREME (bright on negatives, dark on positives), distinct from
# both a protruding previous frame above it and the current image below (which
# may be smooth, e.g. sky, so texture alone is unreliable).  Working in the
# "border direction" (V = mean on negatives, 255-mean on positives), we find
# the DEEPEST band brighter than median+BORDER_FRAC*(peak-median) within the
# top region, and crop just below it.  Inset a few % inside the detected L/R
# borders so a residual side-border sliver does not skew the row means.
ROW_INSET=${ROW_INSET:-0.03}
ROWCROP=$(awk -v a="$xL" -v b="$xR" -v p="$ROW_INSET" 'BEGIN{
	l=(a+p)*100; r=(b-p)*100; if(l>=r){l=20;r=80};
	printf "%.4f%%,0,%.4f%%,100%%", l, r}')
gmic -input "$IN" "-crop[0]" "$ROWCROP" "-luminance[0]" "-resize[0]" "1,$NBINS_Y,1,1,2" \
	"-output[0]" "$TMP" 2>/dev/null
ROWM=$(tr ',\n' '  ' < "$TMP" | tr -s ' ' | sed 's/^ //;s/ *$//')
yT=$(awk -v M="$ROWM" -v kind="$kind" -v lim="$TOP_LIMIT" -v bf="$BORDER_FRAC" "$MEDIAN_FN"'
BEGIN{
	n=split(M,m," "); if(n<5){ print "0"; exit }
	for(i=1;i<=n;i++)mm[i]=m[i]; med=median(mm,n);
	pos=(kind=="positive"); vmed = pos ? 255-med : med;
	L=int(n*lim); ext=0;
	for(i=1;i<=L;i++){ v = pos ? 255-m[i] : m[i]; if(v>ext)ext=v }
	th = vmed + bf*(ext - vmed);
	bottom=0; i=1;
	while(i<=L){
		v = pos ? 255-m[i] : m[i];
		if(v>th){ s=i; while(i<=L){ vv = pos ? 255-m[i] : m[i]; if(vv>th)i++; else break }
			if(i-s>=2) bottom=i-1 }
		else i++
	}
	printf "%.6f", bottom/n            # crop just below the deepest border band
}')

# 4. crop (optionally trimming MARGIN extra px inward) ---------------------
read -r W H <<EOF
$(identify -format '%w %h' "$IN" 2>/dev/null || echo "0 0")
EOF
x0=$(awk -v a="$xL" -v w="$W" -v m="$MARGIN" 'BEGIN{printf "%d", a*w+m}')
x1=$(awk -v b="$xR" -v w="$W" -v m="$MARGIN" 'BEGIN{printf "%d", b*w-1-m}')
y0=$(awk -v t="$yT" -v h="$H" -v m="$MARGIN" 'BEGIN{printf "%d", t*h+m}')
y1=$((H - 1))

gmic -input "$IN" "-crop[0]" "$x0,$y0,$x1,$y1" "-output[0]" "$OUT,$OTYPE" 2>/dev/null

printf '>> %s  [%s]  crop x:%d-%d y:%d-%d  ->  %s\n' \
	"$IN" "$kind" "$x0" "$x1" "$y0" "$y1" "$OUT"
