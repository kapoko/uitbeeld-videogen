#!/usr/bin/env bash
# generate.sh - render spectrum and composite to background

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BG="$SCRIPT_DIR/background.jpg"
ENV_FILE="$SCRIPT_DIR/.env"

TITLE_TEXT=""
POSTER_BLEND_BG_R="90"   # #5ab885
POSTER_BLEND_BG_G="184"  # #5ab885
POSTER_BLEND_BG_B="133"  # #5ab885
POSTER_BLACK_FLOOR="40"
POSTER_NOISE="35"
POSTER_BORDER_PX="15"
POSTER_BORDER_COLOR="0xf9d24d"
POSTER_WIDTH="580"
POSTER_X="1172"

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
  echo "Usage: $0 -i <input-audio> [-t <title text>] [-p <poster-image>] [--bars-only] [--compose-only]"
  echo ""
  echo "When -t is used without -p, TMDB_API_KEY is loaded from .env (or prompted once if missing)."
}

trim_spaces() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

capitalize_title() {
  local raw_title="$1"
  printf '%s' "$raw_title" | tr '[:lower:]' '[:upper:]'
}

is_http_url() {
  local value="$1"
  [[ "$value" =~ ^https?:// ]]
}

ensure_tmdb_credentials() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi

  if [ -n "${TMDB_API_KEY:-}" ]; then
    return
  fi

  if [ ! -t 0 ]; then
    echo "Error: missing TMDB_API_KEY in $ENV_FILE and no interactive input available." >&2
    exit 1
  fi

  printf "Enter TMDB API key: "
  IFS= read -r TMDB_API_KEY
  TMDB_API_KEY="$(trim_spaces "$TMDB_API_KEY")"
  if [ -z "$TMDB_API_KEY" ]; then
    echo "Error: TMDB API key cannot be empty." >&2
    exit 1
  fi

  printf 'TMDB_API_KEY=%s\n' "$TMDB_API_KEY" > "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  echo "Saved TMDB API key to: $ENV_FILE"
}

fetch_tmdb_poster() {
  local raw_title="$1"
  local output_path="$2"
  local normalized_title=""
  local search_title=""
  local search_year=""
  local encoded_query=""
  local tmdb_url=""
  local poster_path=""

  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required to fetch TMDB posters." >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required to fetch TMDB posters." >&2
    exit 1
  fi

  ensure_tmdb_credentials

  normalized_title="$raw_title"
  if [[ "$normalized_title" =~ ^#[0-9]+:[[:space:]]*(.+)$ ]]; then
    normalized_title="${BASH_REMATCH[1]}"
  fi

  if [[ "$normalized_title" =~ ^(.+)[[:space:]]\(([0-9]{4})\)[[:space:]]*$ ]]; then
    search_title="${BASH_REMATCH[1]}"
    search_year="${BASH_REMATCH[2]}"
  elif [[ "$normalized_title" =~ ^(.+)[[:space:]]([0-9]{4})[[:space:]]*$ ]]; then
    search_title="${BASH_REMATCH[1]}"
    search_year="${BASH_REMATCH[2]}"
  else
    search_title="$normalized_title"
  fi
  search_title="$(trim_spaces "$search_title")"

  encoded_query="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$search_title")"

  tmdb_url="https://api.themoviedb.org/3/search/movie?include_adult=false&query=${encoded_query}"
  if [ -n "$search_year" ]; then
    tmdb_url="${tmdb_url}&year=${search_year}"
  fi

  TMDB_JSON="$(mktemp /tmp/generate-tmdb-XXXXXX.json)"
  curl -fsSL "${tmdb_url}&api_key=${TMDB_API_KEY}" -o "$TMDB_JSON"

  poster_path="$(python3 - "$TMDB_JSON" "$search_title" "$search_year" <<'PY'
import json
import sys

json_path = sys.argv[1]
title = (sys.argv[2] or "").strip().casefold()
year = (sys.argv[3] or "").strip()

with open(json_path, "r", encoding="utf-8") as f:
    data = json.load(f)

results = data.get("results", [])

def score(movie):
    movie_title = (movie.get("title") or "").strip().casefold()
    original_title = (movie.get("original_title") or "").strip().casefold()
    release_date = movie.get("release_date") or ""
    movie_year = release_date[:4] if len(release_date) >= 4 else ""
    poster = movie.get("poster_path")

    if not poster:
        return (-1, -1, -1)

    exact_title = 1 if title and (movie_title == title or original_title == title) else 0
    year_match = 1 if year and movie_year == year else 0
    popularity = float(movie.get("popularity") or 0.0)
    return (exact_title, year_match, popularity)

best = None
best_score = (-1, -1, -1)
for movie in results:
    current = score(movie)
    if current > best_score:
        best = movie
        best_score = current

if best and best.get("poster_path"):
    print(best["poster_path"])
PY
)"

  if [ -z "$poster_path" ]; then
    echo "Error: no TMDB poster found for '$search_title'${search_year:+ ($search_year)}." >&2
    exit 1
  fi

  curl -fsSL "https://image.tmdb.org/t/p/original${poster_path}" -o "$output_path"
}

process_poster_darker_color() {
  local poster_path="$1"
  local tmp_output=""
  local threshold=0

  if [ ! -f "$poster_path" ]; then
    echo "Error: poster file not found for processing: $poster_path" >&2
    exit 1
  fi

  threshold=$((POSTER_BLEND_BG_R + POSTER_BLEND_BG_G + POSTER_BLEND_BG_B))
  tmp_output="$(mktemp /tmp/generate-poster-XXXXXX).jpg"

  ffmpeg -y -i "$poster_path" \
    -vf "hue=s=0,format=rgb24,geq=r='if(lte(r(X,Y)+g(X,Y)+b(X,Y),${threshold}),max(r(X,Y),${POSTER_BLACK_FLOOR}),${POSTER_BLEND_BG_R})':g='if(lte(r(X,Y)+g(X,Y)+b(X,Y),${threshold}),max(g(X,Y),${POSTER_BLACK_FLOOR}),${POSTER_BLEND_BG_G})':b='if(lte(r(X,Y)+g(X,Y)+b(X,Y),${threshold}),max(b(X,Y),${POSTER_BLACK_FLOOR}),${POSTER_BLEND_BG_B})'" \
    -frames:v 1 "$tmp_output"

  mv "$tmp_output" "$poster_path"
}

compose_background_with_poster() {
  local bg_path="$1"
  local poster_path="$2"
  local output_path="$3"
  local bg_height=""
  local poster_width=""
  local poster_height=""
  local inner_width=0
  local scaled_height=""
  local centered_y=""

  if [ ! -f "$bg_path" ]; then
    echo "Error: background file not found: $bg_path" >&2
    exit 1
  fi
  if [ ! -f "$poster_path" ]; then
    echo "Error: poster file not found for background compose: $poster_path" >&2
    exit 1
  fi

  bg_height="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$bg_path")"
  poster_width="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$poster_path")"
  poster_height="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$poster_path")"
  inner_width=$((POSTER_WIDTH - (POSTER_BORDER_PX * 2)))
  if [ "$inner_width" -le 0 ]; then
    echo "Error: POSTER_WIDTH must be greater than 2*POSTER_BORDER_PX." >&2
    exit 1
  fi
  if [ -n "$bg_height" ] && [ -n "$poster_width" ] && [ -n "$poster_height" ]; then
    scaled_height="$(python3 -c 'import sys; w=int(sys.argv[1]); h=int(sys.argv[2]); tw=int(sys.argv[3]); b=int(sys.argv[4]); print(round(h*tw/w) + (2*b))' "$poster_width" "$poster_height" "$inner_width" "$POSTER_BORDER_PX")"
    centered_y=$(( (bg_height - scaled_height) / 2 ))
    echo "Poster centered y resolves to: ${centered_y}px"
  fi

  ffmpeg -y -i "$bg_path" -i "$poster_path" \
    -filter_complex "[1:v]scale=${inner_width}:-1,pad=w=iw+${POSTER_BORDER_PX}*2:h=ih+${POSTER_BORDER_PX}*2:x=${POSTER_BORDER_PX}:y=${POSTER_BORDER_PX}:color=${POSTER_BORDER_COLOR},noise=alls=${POSTER_NOISE}:allf=u[poster];[0:v][poster]overlay=x=${POSTER_X}:y=(H-h)/2,format=yuv420p[v]" \
    -map "[v]" -frames:v 1 "$output_path"
}

INPUT=""
POSTER_IMAGE_PATH=""
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
    -p)
      if [ "$#" -lt 2 ]; then
        echo "Error: option -p requires an argument." >&2
        usage >&2
        exit 1
      fi
      POSTER_IMAGE_PATH="$2"
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

if [ -n "$TITLE_TEXT" ]; then
  TITLE_TEXT="$(capitalize_title "$TITLE_TEXT")"
fi

if [ "$COMPOSE_ONLY" -eq 0 ] && [ ! -f "$INPUT" ]; then
  echo "Error: input file not found: $INPUT" >&2
  exit 1
fi

if [ -n "$POSTER_IMAGE_PATH" ] && ! is_http_url "$POSTER_IMAGE_PATH" && [ ! -f "$POSTER_IMAGE_PATH" ]; then
  echo "Error: poster image not found: $POSTER_IMAGE_PATH" >&2
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
TMDB_JSON=""
POSTER_PATH=""
BG_COMPOSITE=""
BG_INPUT="$BG"
cleanup() {
  if [ -n "$TMDB_JSON" ]; then
    rm -f "$TMDB_JSON"
  fi
  if [ -n "$BG_COMPOSITE" ]; then
    rm -f "$BG_COMPOSITE"
  fi
}
trap cleanup EXIT

if [ -n "$POSTER_IMAGE_PATH" ]; then
  POSTER_PATH="$IN_DIR/poster.jpg"
  if is_http_url "$POSTER_IMAGE_PATH"; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "Error: curl is required when -p is a URL." >&2
      exit 1
    fi
    echo "Downloading poster image: $POSTER_IMAGE_PATH -> $POSTER_PATH"
    curl -fsSL "$POSTER_IMAGE_PATH" -o "$POSTER_PATH"
  else
    echo "Using provided poster image: $POSTER_IMAGE_PATH -> $POSTER_PATH"
    cp "$POSTER_IMAGE_PATH" "$POSTER_PATH"
  fi
elif [ -n "$TITLE_TEXT" ]; then
  POSTER_PATH="$IN_DIR/poster.jpg"
  echo "Fetching TMDB poster to: $POSTER_PATH"
  fetch_tmdb_poster "$TITLE_TEXT" "$POSTER_PATH"
fi

if [ -n "$POSTER_PATH" ] && [ -f "$POSTER_PATH" ]; then
  echo "Applying Darker Color blend to poster.jpg"
  process_poster_darker_color "$POSTER_PATH"
fi

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

if [ -n "$POSTER_PATH" ] && [ -f "$POSTER_PATH" ]; then
  BG_COMPOSITE="$(mktemp /tmp/generate-bg-XXXXXX).png"
  echo "Compositing processed poster onto background at x=${POSTER_X}, y=center"
  compose_background_with_poster "$BG" "$POSTER_PATH" "$BG_COMPOSITE"
  BG_INPUT="$BG_COMPOSITE"
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

FILTER_COMPLEX="${CORE_FILTER};[base]format=yuv420p[v]"

echo "Compositing final video: $BARS_MOV -> $OUTPUT"
ffmpeg -y \
  -framerate 30 -loop 1 -i "$BG_INPUT" \
  -i "$BARS_MOV" \
  -filter_complex "$FILTER_COMPLEX" \
  -map "[v]" -map 1:a \
  -c:v libx264 -r 30 -fps_mode cfr -c:a copy \
  -shortest \
  "$OUTPUT"

echo "Done: $OUTPUT"
