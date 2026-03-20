#!/usr/bin/env bash
# generate.sh - render spectrum, composite to background, optional title

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BG="$SCRIPT_DIR/background.jpg"

TITLE_TEXT=""
TITLE_FONT_FILE="$SCRIPT_DIR/Kanit-Bold.ttf"
TITLE_SIZE="95"
TITLE_COLOR="0xf9d24d"
TITLE_MARGIN_X="60"
TITLE_MARGIN_Y="30"

# CRT tuning
CRT_WARP_K1="0.05"
CRT_WARP_K2="0.01"
CRT_NOISE="70"
CRT_BLOOM_SIGMA="1.8"
CRT_BLOOM_OPACITY="0.28"

# Target quad on background image
# Top-left, top-right, bottom-left, bottom-right
X0=150
Y0=171
X1=393
Y1=174
X2=149
Y2=383
X3=391
Y3=374

usage() {
  echo "Usage: $0 -i <input-audio> [-t <title text>] [--bars-only] [--compose-only]"
}

INPUT=""
BARS_ONLY=0
COMPOSE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -i)
      if [ "$#" -lt 2 ]; then
        echo "Error: option -i requires an argument." >&2
        usage >&2
        exit 1
      fi
      INPUT="$2"
      shift 2
      ;;
    -t)
      if [ "$#" -lt 2 ]; then
        echo "Error: option -t requires an argument." >&2
        usage >&2
        exit 1
      fi
      TITLE_TEXT="$2"
      shift 2
      ;;
    --bars-only)
      BARS_ONLY=1
      shift
      ;;
    --compose-only)
      COMPOSE_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$BARS_ONLY" -eq 1 ] && [ "$COMPOSE_ONLY" -eq 1 ]; then
  echo "Error: --bars-only and --compose-only cannot be used together." >&2
  usage >&2
  exit 1
fi

if [ -z "$INPUT" ]; then
  echo "Error: -i is required." >&2
  usage >&2
  exit 1
fi

if [ "$COMPOSE_ONLY" -eq 0 ] && [ ! -f "$INPUT" ]; then
  echo "Error: input file not found: $INPUT" >&2
  exit 1
fi

IN_DIR="$(dirname "$INPUT")"
IN_NAME="$(basename "$INPUT")"
IN_BASE="${IN_NAME%.*}"
if [ "$IN_BASE" = "$IN_NAME" ]; then
  OUTPUT="$IN_DIR/$IN_NAME.mp4"
else
  OUTPUT="$IN_DIR/$IN_BASE.mp4"
fi

BARS_MOV="$SCRIPT_DIR/bars.mov"
TITLE_PNG=""
cleanup() {
  if [ -n "$TITLE_PNG" ]; then
    rm -f "$TITLE_PNG"
  fi
}
trap cleanup EXIT

if [ "$COMPOSE_ONLY" -eq 0 ]; then
  echo "Rendering spectrum: $INPUT -> $BARS_MOV"

  ffmpeg -y -i "$INPUT" \
    -filter_complex "[0:a]pan=mono|c0=FL,asplit=2[aout][avis];[avis]highpass=f=50,lowpass=f=4000,volume=1,aresample=22050,showfreqs=s=20x400:mode=bar:fscale=log:ascale=log:win_func=blackman:win_size=2048:overlap=0.8:averaging=5:rate=30:colors=white,scale=640:480:flags=neighbor,crop=640:474:0:6,pad=640:480:0:6:black,setsar=1,format=gray,geq=lum='if(lt(mod(X,32),30)*gt(lum(X,Y),26+(1-Y/H)*60+170*pow(1-Y/H,4)),255,0)'[alpha];color=c=white:s=640x480:r=30,format=rgb24[white];[white][alpha]alphamerge,format=yuva444p10le[v]" \
    -map "[v]" -map "[aout]" \
    -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le -r 30 -fps_mode cfr \
    -c:a aac -b:a 192k \
    -shortest \
    "$BARS_MOV"

  if [ "$BARS_ONLY" -eq 1 ]; then
    echo "Done: $BARS_MOV"
    exit 0
  fi
else
  if [ ! -f "$BARS_MOV" ]; then
    echo "Error: bars file not found: $BARS_MOV" >&2
    exit 1
  fi
  echo "Skipping spectrum render (--compose-only), using: $BARS_MOV"
fi

# Local coordinates for perspective filter (relative to overlay origin)
LX0=0
LY0=0
LX1=$((X1 - X0))
LY1=$((Y1 - Y0))
LX2=$((X2 - X0))
LY2=$((Y2 - Y0))
LX3=$((X3 - X0))
LY3=$((Y3 - Y0))

# Half-plane coefficients for inside-quad alpha clip in local coordinates.
# For each edge A->B, inside is: (Bx-Ax)*(Y-Ay) - (By-Ay)*(X-Ax) >= 0
e0y=$((LX1 - LX0)); e0x=$((-(LY1 - LY0))); e0c=$(((LY1 - LY0) * LX0 - (LX1 - LX0) * LY0))
e1y=$((LX3 - LX1)); e1x=$((-(LY3 - LY1))); e1c=$(((LY3 - LY1) * LX1 - (LX3 - LX1) * LY1))
e2y=$((LX2 - LX3)); e2x=$((-(LY2 - LY3))); e2c=$(((LY2 - LY3) * LX3 - (LX2 - LX3) * LY3))
e3y=$((LX0 - LX2)); e3x=$((-(LY0 - LY2))); e3c=$(((LY0 - LY2) * LX2 - (LX0 - LX2) * LY2))

MASK_EXPR="if(gte(${e0y}*Y+${e0x}*X+${e0c},0)*gte(${e1y}*Y+${e1x}*X+${e1c},0)*gte(${e2y}*Y+${e2x}*X+${e2c},0)*gte(${e3y}*Y+${e3x}*X+${e3c},0),alpha(X,Y),0)"

CORE_FILTER="[1:v]format=rgba,split=2[ovrgb][ovalpha];[ovrgb]format=rgb24,lenscorrection=k1=${CRT_WARP_K1}:k2=${CRT_WARP_K2}:cx=0.5:cy=0.5:i=bilinear,format=yuv444p,noise=c0s=${CRT_NOISE}:c0f=t+u:c1s=0:c2s=0,format=rgb24,split=2[prebloom][prebloomblur];[prebloomblur]gblur=sigma=${CRT_BLOOM_SIGMA}[glow];[prebloom][glow]blend=all_mode=screen:all_opacity=${CRT_BLOOM_OPACITY},geq=r='clip(r(X,Y)*if(lt(mod(Y,3),1),0.82,1)*if(lt(mod(X,3),1),1.10,0.90),0,255)':g='clip(g(X,Y)*if(lt(mod(Y,3),1),0.82,1)*if(lt(mod(X,3),1),0.88,if(lt(mod(X,3),2),1.08,0.90)),0,255)':b='clip(b(X,Y)*if(lt(mod(Y,3),1),0.82,1)*if(lt(mod(X,3),2),0.88,1.10),0,255)',perspective=sense=destination:x0=${LX0}:y0=${LY0}:x1=${LX1}:y1=${LY1}:x2=${LX2}:y2=${LY2}:x3=${LX3}:y3=${LY3}[warprgb];[ovalpha]alphaextract,lenscorrection=k1=${CRT_WARP_K1}:k2=${CRT_WARP_K2}:cx=0.5:cy=0.5:i=bilinear,perspective=sense=destination:x0=${LX0}:y0=${LY0}:x1=${LX1}:y1=${LY1}:x2=${LX2}:y2=${LY2}:x3=${LX3}:y3=${LY3}[warpa];[warprgb][warpa]alphamerge,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='${MASK_EXPR}'[warp];[0:v][warp]overlay=${X0}:${Y0}:format=auto[base]"

if [ -n "$TITLE_TEXT" ]; then
  if ! command -v magick >/dev/null 2>&1; then
    echo "Error: ImageMagick 'magick' is required when using -t." >&2
    exit 1
  fi
  if [ ! -f "$TITLE_FONT_FILE" ]; then
    echo "Error: missing font file '$TITLE_FONT_FILE'." >&2
    exit 1
  fi

  TITLE_PNG="$(mktemp /tmp/generate-title-XXXXXX.png)"
  magick -background none -fill "#${TITLE_COLOR#0x}" -font "$TITLE_FONT_FILE" -pointsize "$TITLE_SIZE" label:"$TITLE_TEXT" "$TITLE_PNG"

  FILTER_COMPLEX="${CORE_FILTER};[2:v]format=rgba[title];[base][title]overlay=x=W-w-${TITLE_MARGIN_X}:y=H-h-${TITLE_MARGIN_Y}:format=auto,format=yuv420p[v]"

  echo "Compositing final video: $BARS_MOV -> $OUTPUT"
  ffmpeg -y \
    -framerate 30 -loop 1 -i "$BG" \
    -i "$BARS_MOV" \
    -framerate 30 -loop 1 -i "$TITLE_PNG" \
    -filter_complex "$FILTER_COMPLEX" \
    -map "[v]" -map 1:a \
    -c:v libx264 -r 30 -fps_mode cfr -c:a copy \
    -shortest \
    "$OUTPUT"
else
  FILTER_COMPLEX="${CORE_FILTER};[base]format=yuv420p[v]"

  echo "Compositing final video: $BARS_MOV -> $OUTPUT"
  ffmpeg -y \
    -framerate 30 -loop 1 -i "$BG" \
    -i "$BARS_MOV" \
    -filter_complex "$FILTER_COMPLEX" \
    -map "[v]" -map 1:a \
    -c:v libx264 -r 30 -fps_mode cfr -c:a copy \
    -shortest \
    "$OUTPUT"
fi

echo "Done: $OUTPUT"
