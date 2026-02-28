#!/bin/bash
set -e

# Usage: ./make_icns.sh <source-png> [output-name] [--rounded]
# Example: ./make_icns.sh IconBase.png AppIcon --rounded

SRC="$1"
if [ -z "$SRC" ]; then
  echo "Usage: $0 <source-png> [output-name] [--rounded]"
  exit 1
fi
OUTNAME="${2:-AppIcon}"
ROUND=false
if [ "${3}" = "--rounded" ] || [ "${2}" = "--rounded" ]; then
  ROUND=true
fi
OUTDIR="${OUTNAME}.iconset"

mkdir -p "$OUTDIR"

if [ "$ROUND" = true ]; then
  if ! command -v convert >/dev/null 2>&1; then
    echo "--rounded requested but ImageMagick 'convert' not found. Install with: brew install imagemagick"
    exit 1
  fi
fi

function make_png() {
  local size=$1
  local outpath=$2
  sips -z "$size" "$size" "$SRC" --out "$outpath" >/dev/null
  if [ "$ROUND" = true ]; then
    local radius=$(( size / 6 ))
    convert "$outpath" -alpha set -background none \
      \( -size ${size}x${size} xc:none -draw "roundrectangle 0,0 $((size-1)),$((size-1)) ${radius},${radius}" \) -compose DstIn -composite "$outpath"
  fi
}

# Create required icon sizes using sips (macOS built-in)
make_png 16  "$OUTDIR/icon_16x16.png"
make_png 32  "$OUTDIR/icon_16x16@2x.png"
make_png 32  "$OUTDIR/icon_32x32.png"
make_png 64  "$OUTDIR/icon_32x32@2x.png"
make_png 128 "$OUTDIR/icon_128x128.png"
make_png 256 "$OUTDIR/icon_128x128@2x.png"
make_png 256 "$OUTDIR/icon_256x256.png"
make_png 512 "$OUTDIR/icon_256x256@2x.png"
make_png 512 "$OUTDIR/icon_512x512.png"
make_png 1024 "$OUTDIR/icon_512x512@2x.png"

# Create the .icns file
iconutil -c icns "$OUTDIR" -o "${OUTNAME}.icns"

echo "Created ${OUTNAME}.icns (from ${SRC})"
echo "You can remove ${OUTDIR} if you don't need the iconset folder."