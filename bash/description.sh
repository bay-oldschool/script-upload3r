#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-t|--tv] <directory> [config.jsonc]

Build the final BBCode torrent description from output files and save it
as <name>_torrent_description.txt in the output directory.
Also builds <name>_upload_request.txt with all upload form fields.

Arguments:
  directory      Path to the content directory
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -t, --tv     Upload as TV show (category_id=12)
  -h, --help   Show this help message
EOF
  exit 0
}

# Simple JSON value reader (no jq needed)
json_val() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}
json_num() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]*" "$2" | head -1 | sed 's/.*:[[:space:]]*//'
}

TV_MODE=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    -t|-tv|--tv) TV_MODE=true ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo "Error: directory argument required"; usage; }

CONTENT_DIR="${POSITIONAL[0]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
CONFIG_FILE="${POSITIONAL[1]:-$ROOT_DIR/config.jsonc}"
OUT_DIR="$ROOT_DIR/output"

if [[ -f "$CONTENT_DIR" ]]; then
  SINGLE_FILE="$CONTENT_DIR"
  CONTENT_DIR="$(dirname "$CONTENT_DIR")"
  TORRENT_NAME=$(basename "$SINGLE_FILE" | sed 's/\.[^.]*$//')
else
  SINGLE_FILE=""
  TORRENT_NAME=$(basename "$CONTENT_DIR")
fi

GEMINI_FILE="$OUT_DIR/${TORRENT_NAME}_description.txt"
IMDB_FILE="$OUT_DIR/${TORRENT_NAME}_imdb.txt"
TMDB_FILE="$OUT_DIR/${TORRENT_NAME}_tmdb.txt"
SCREENS_FILE="$OUT_DIR/${TORRENT_NAME}_screens.txt"
TORRENT_DESC_FILE="$OUT_DIR/${TORRENT_NAME}_torrent_description.txt"

# Build title header
# Derive EN_TITLE from directory name (avoids encoding issues with special chars in TMDB titles)
EN_TITLE=$(echo "$TORRENT_NAME" | sed 's/[._]/ /g' | sed 's/ - [Ss][0-9]\{2\}.*//; s/\b[Ss][0-9]\{2\}\b.*//; s/\b[0-9]\{4\}\b.*//' | sed 's/ - WEBDL.*//I; s/ - WEB-DL.*//I; s/[[:space:](]*$//')
YEAR=$(echo "$TORRENT_NAME" | grep -oP '\b(19|20)\d{2}\b' | head -1 || true)
BG_TITLE=""

# Fallback: get year from IMDB file header
if [[ -z "$YEAR" && -f "$IMDB_FILE" ]]; then
  _RAW=$(tr -d '\r' < "$IMDB_FILE" | sed 's/^\xEF\xBB\xBF//')
  YEAR=$(echo "$_RAW" | grep -m1 "^===" | grep -oP '\((\d{4})\)' | head -1 | tr -d '()' || true)
fi
# Fallback: get year from TMDB file first result
if [[ -z "$YEAR" && -f "$TMDB_FILE" ]]; then
  YEAR=$(tr -d '\r' < "$TMDB_FILE" | sed 's/^\xEF\xBB\xBF//' | grep -m1 "^\[1\]" | grep -oP '\((\d{4})\)' | head -1 | tr -d '()' || true)
fi
# Override year from IMDB if directory had one (IMDB is more accurate)
if [[ -f "$IMDB_FILE" ]]; then
  _RAW=$(tr -d '\r' < "$IMDB_FILE" | sed 's/^\xEF\xBB\xBF//')
  _YEAR=$(echo "$_RAW" | grep -m1 "^===" | grep -oP '\((\d{4})\)' | head -1 | tr -d '()' || true)
  [[ -n "$_YEAR" ]] && YEAR="$_YEAR"
fi

BANNER_URL=""
TMDB_EN_TITLE=""
if [[ -f "$TMDB_FILE" ]]; then
  BG_TITLE=$(tr -d '\r' < "$TMDB_FILE" | sed 's/^\xEF\xBB\xBF//' | grep "^    BG Title:" | head -1 | sed 's/^    BG Title:[[:space:]]*//' || true)
  # Extract English title from TMDB best result line: "[1] Title (year)"
  TMDB_EN_TITLE=$(tr -d '\r' < "$TMDB_FILE" | sed 's/^\xEF\xBB\xBF//' | grep -m1 "^\[1\]" | sed 's/^\[1\] \(.*\) ([0-9]\{4\})$/\1/' || true)
  _TMDB_CLEAN=$(tr -d '\r' < "$TMDB_FILE" | sed 's/^\xEF\xBB\xBF//')
  # Get banner from the best-matched result (the one with BG Title after its Banner line)
  if [[ -n "$BG_TITLE" ]]; then
    BANNER_URL=$(echo "$_TMDB_CLEAN" | grep -B1 "^    BG Title:" | grep "^    Banner:" | head -1 | sed 's/^    Banner:[[:space:]]*//' || true)
  fi
  # Fallback: first non-empty banner from any result
  if [[ -z "$BANNER_URL" || "$BANNER_URL" == "(none)" ]]; then
    BANNER_URL=$(echo "$_TMDB_CLEAN" | grep "^    Banner:" | grep -v "(none)" | head -1 | sed 's/^    Banner:[[:space:]]*//' || true)
  fi
  [[ "$BANNER_URL" == "(none)" ]] && BANNER_URL=""
fi

_EN_HEADER="${TMDB_EN_TITLE:-$EN_TITLE}"
if [[ -n "$BG_TITLE" && "$BG_TITLE" != "$_EN_HEADER" ]]; then
  HEADER="[size=26][b]${_EN_HEADER} (${YEAR}) / ${BG_TITLE} (${YEAR})[/b][/size]"
else
  HEADER="[size=26][b]${_EN_HEADER} (${YEAR})[/b][/size]"
fi

# Build description body
DESCRIPTION=""

if [[ -f "$GEMINI_FILE" ]]; then
  DESCRIPTION=$(tr -d '\r' < "$GEMINI_FILE" | sed 's/^\xEF\xBB\xBF//')
elif [[ -f "$IMDB_FILE" ]]; then
  IMDB_CONTENT=$(tr -d '\r' < "$IMDB_FILE" | sed 's/^\xEF\xBB\xBF//')
  TITLE=$(echo "$IMDB_CONTENT" | grep -m1 "^===" | sed 's/^=== \(.*\) ===$/\1/' || true)
  RATING=$(echo "$IMDB_CONTENT" | grep "^Rating:" | sed 's/^Rating:[[:space:]]*//' || true)
  GENRES=$(echo "$IMDB_CONTENT" | grep "^Genres:" | sed 's/^Genres:[[:space:]]*//' || true)
  RUNTIME=$(echo "$IMDB_CONTENT" | grep "^Runtime:" | sed 's/^Runtime:[[:space:]]*//' || true)
  TAGLINE=$(echo "$IMDB_CONTENT" | grep "^Tagline:" | sed 's/^Tagline:[[:space:]]*//' || true)
  DIRECTOR=$(echo "$IMDB_CONTENT" | grep "^Director" | sed 's/^Director[^:]*:[[:space:]]*//' || true)
  CAST=$(echo "$IMDB_CONTENT" | grep "^Cast:" | sed 's/^Cast:[[:space:]]*//' || true)
  OVERVIEW=$(echo "$IMDB_CONTENT" | awk '/^Overview:/{found=1;next} found && /^[A-Za-z][A-Za-z ()]*:[[:space:]]/{exit} found{print}' | sed '/^[[:space:]]*$/d')

  DESCRIPTION="[b]${TITLE}[/b]"
  [[ -n "$TAGLINE" ]] && DESCRIPTION+=$'\n'"[i]${TAGLINE}[/i]"
  [[ -n "$DIRECTOR" ]] && DESCRIPTION+=$'\n'"[b]Director:[/b] ${DIRECTOR}"
  [[ -n "$CAST" ]]     && DESCRIPTION+=$'\n'"[b]Cast:[/b] ${CAST}"
  [[ -n "$RATING" ]]   && DESCRIPTION+=$'\n'"[b]Rating:[/b] ${RATING}"
  [[ -n "$GENRES" ]]   && DESCRIPTION+=$'\n'"[b]Genres:[/b] ${GENRES}"
  [[ -n "$RUNTIME" ]]  && DESCRIPTION+=$'\n'"[b]Runtime:[/b] ${RUNTIME}"
  [[ -n "$OVERVIEW" ]] && DESCRIPTION+=$'\n\n'"${OVERVIEW}"
fi

# Extract RT rating from IMDB file
RT_RATING=""
if [[ -f "$IMDB_FILE" ]]; then
  RT_RATING=$(tr -d '\r' < "$IMDB_FILE" | sed 's/^\xEF\xBB\xBF//' | grep "^RT Rating:" | sed 's/^RT Rating:[[:space:]]*//' || true)
fi

# Insert RT rating after IMDB rating line in description
if [[ -n "$RT_RATING" ]]; then
  _NEW=""
  _INSERTED=false
  while IFS= read -r _line; do
    _NEW+="${_line}"$'\n'
    if [[ "$_INSERTED" == false && "$_line" == *"[b]"*"[/b]"*"/10"* ]]; then
      _NEW+=$'\xf0\x9f\x8d\x85'" [b]Rotten Tomatoes:[/b] ${RT_RATING}"$'\n'
      _INSERTED=true
    fi
  done <<< "$DESCRIPTION"
  DESCRIPTION="${_NEW%$'\n'}"
fi

# Prepend banner and header
PREAMBLE=""
[[ -n "$BANNER_URL" ]] && PREAMBLE="[center][img=1920]${BANNER_URL}[/img][/center]"$'\n\n'
[[ -n "$HEADER" ]] && PREAMBLE="${PREAMBLE}${HEADER}"$'\n\n'
[[ -n "$PREAMBLE" ]] && DESCRIPTION="${PREAMBLE}${DESCRIPTION}"

if [[ -f "$SCREENS_FILE" ]]; then
  IMGS="[center]"
  while IFS= read -r url; do
    url="${url//\\\//\/}"
    url="${url//$'\r'/}"
    url=$(echo "$url" | sed 's/^\xEF\xBB\xBF//')
    [[ -n "$url" ]] && IMGS+="[url=${url}][img=400]${url}[/img][/url]"
  done < "$SCREENS_FILE"
  IMGS+="[/center]"
  DESCRIPTION+=$'\n\n'"${IMGS}"
fi

SIG_URL="$(json_val tracker_url "$CONFIG_FILE")/torrents?name=SCRIPT+UPLOAD3R"
DESCRIPTION+=$'\n\n'"[center][url=${SIG_URL}][color=#7760de][size=16]⚡ Uploaded using SCRIPT UPLOAD3R ⚡[/size][/color][/url]
[size=9][color=#5f5f5f]Bash script torrent creator/uploader for Windows proudly developed by AI[/color][/size][/center]"

# Make hashtags linkable to tracker search
TRACKER_URL=$(json_val tracker_url "$CONFIG_FILE")
if [[ -n "$TRACKER_URL" ]]; then
  DESCRIPTION=$(TURL="$TRACKER_URL" perl -CSD -MEncode -pe 's/(^|[^=\w])#(\w+)/my $p=$1;my $t=$2;my $e=Encode::encode("UTF-8",$t);$e=~s|([^A-Za-z0-9_.~-])|sprintf("%%%02X",ord($1))|ge;"${p}[url=$ENV{TURL}\/torrents?description=${e}]#${t}[\/url]"/ge' <<< "$DESCRIPTION")
fi

printf '%s\n' "$DESCRIPTION" > "$TORRENT_DESC_FILE"
echo "Torrent description saved to: $TORRENT_DESC_FILE"

# ── Build upload request file ──────────────────────────────────────────

REQUEST_FILE="$OUT_DIR/${TORRENT_NAME}_upload_request.txt"
MEDIAINFO_FILE="$OUT_DIR/${TORRENT_NAME}_mediainfo.txt"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "\e[33mWarning: config file '$CONFIG_FILE' not found, skipping request file\e[0m"
  exit 0
fi

# Read config
TYPE_ID=$(json_num type_id "$CONFIG_FILE")
RESOLUTION_ID=$(json_num resolution_id "$CONFIG_FILE")
TMDB=$(json_num tmdb "$CONFIG_FILE")
IMDB=$(json_num imdb "$CONFIG_FILE")
PERSONAL=$(json_num personal "$CONFIG_FILE")
ANONYMOUS=$(json_num anonymous "$CONFIG_FILE")

# Read categories from categories.jsonc
CATEGORIES_FILE="$ROOT_DIR/shared/categories.jsonc"
CAT_NAMES=()
CAT_IDS=()
CAT_TYPES=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*//.* ]] && continue
  if [[ "$line" =~ \"name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*\"id\"[[:space:]]*:[[:space:]]*([0-9]+).*\"type\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    CAT_NAMES+=("${BASH_REMATCH[1]}")
    CAT_IDS+=("${BASH_REMATCH[2]}")
    CAT_TYPES+=("${BASH_REMATCH[3]}")
  fi
done < "$CATEGORIES_FILE"

# Default: first "movie" category
CATEGORY_ID=""
for i in "${!CAT_TYPES[@]}"; do
  if [[ "${CAT_TYPES[$i]}" == "movie" ]]; then
    CATEGORY_ID="${CAT_IDS[$i]}"
    break
  fi
done
[[ -z "$CATEGORY_ID" ]] && CATEGORY_ID="${CAT_IDS[0]}"

# Override category and extract season/episode for TV uploads
SEASON_NUMBER=0
EPISODE_NUMBER=0
if [[ "$TV_MODE" == true ]]; then
  # Find the first TV category
  for i in "${!CAT_TYPES[@]}"; do
    if [[ "${CAT_TYPES[$i]}" == "tv" ]]; then
      CATEGORY_ID="${CAT_IDS[$i]}"
      break
    fi
  done
  SE=$(echo "$TORRENT_NAME" | grep -oiP 'S\d{2}E\d{2}' | head -1 || true)
  if [[ -n "$SE" ]]; then
    SEASON_NUMBER=$(echo "$SE" | grep -oiP '(?<=S)\d{2}' | sed 's/^0//' || true)
    EPISODE_NUMBER=$(echo "$SE" | grep -oiP '(?<=E)\d{2}' | sed 's/^0//' || true)
  else
    S_ONLY=$(echo "$TORRENT_NAME" | grep -oiP 'S\d{2}' | head -1 || true)
    if [[ -n "$S_ONLY" ]]; then
      SEASON_NUMBER=$(echo "$S_ONLY" | grep -oiP '(?<=S)\d{2}' | sed 's/^0//' || true)
    fi
  fi
  echo "TV mode → category_id=$CATEGORY_ID, season=$SEASON_NUMBER, episode=$EPISODE_NUMBER"
fi

# Detect resolution from directory name
# IDs: 1=4320p 2=2160p 3=1080p 4=1080i 5=720p 6=576p 7=576i 8=480p 9=480i 10=Other
RES_DETECTED=false
case "${TORRENT_NAME,,}" in
  *4320p*|*8k*)  RESOLUTION_ID=1; RES_DETECTED=true ;;
  *2160p*|*4k*|*uhd*) RESOLUTION_ID=2; RES_DETECTED=true ;;
  *1080i*)       RESOLUTION_ID=4; RES_DETECTED=true ;;
  *1080p*)       RESOLUTION_ID=3; RES_DETECTED=true ;;
  *720p*)        RESOLUTION_ID=5; RES_DETECTED=true ;;
  *576i*)        RESOLUTION_ID=7; RES_DETECTED=true ;;
  *576p*)        RESOLUTION_ID=6; RES_DETECTED=true ;;
  *480i*)        RESOLUTION_ID=9; RES_DETECTED=true ;;
  *480p*)        RESOLUTION_ID=8; RES_DETECTED=true ;;
esac

# Fallback: detect resolution from MediaInfo file
resolve_resolution_from_mediainfo() {
  local mi_text="$1"
  local w h
  w=$(echo "$mi_text" | grep "^Width" | head -1 | sed 's/.*:[[:space:]]*//' | tr -d ' ' | grep -oP '^\d+' || true)
  h=$(echo "$mi_text" | grep "^Height" | head -1 | sed 's/.*:[[:space:]]*//' | tr -d ' ' | grep -oP '^\d+' || true)
  [[ -z "$w" && -z "$h" ]] && return 1
  w=${w:-0}; h=${h:-0}
  local label="${w}x${h}"
  if   [[ $w -ge 7000 ]]; then echo "1|$label -> 4320p"
  elif [[ $w -ge 3000 ]]; then echo "2|$label -> 2160p"
  elif [[ $w -ge 1800 ]]; then echo "3|$label -> 1080p"
  elif [[ $w -ge 1200 ]]; then echo "5|$label -> 720p"
  elif [[ $w -ge 700 && $h -ge 560 ]]; then echo "6|$label -> 576p"
  elif [[ $w -ge 700 ]]; then echo "8|$label -> 480p"
  else echo "10|$label -> Other"
  fi
}

if [[ "$RES_DETECTED" == false && -f "$MEDIAINFO_FILE" ]]; then
  MI_RES=$(resolve_resolution_from_mediainfo "$(cat "$MEDIAINFO_FILE")" || true)
  if [[ -n "$MI_RES" ]]; then
    RESOLUTION_ID="${MI_RES%%|*}"
    RES_DETECTED=true
    echo "Detected resolution from MediaInfo file: ${MI_RES#*|} -> resolution_id=$RESOLUTION_ID"
  fi
fi

# Fallback: run MediaInfo.exe directly
if [[ "$RES_DETECTED" == false ]]; then
  MEDIAINFO_EXE="$ROOT_DIR/tools/MediaInfo.exe"
  if [[ -f "$MEDIAINFO_EXE" ]]; then
    if [[ -n "$SINGLE_FILE" ]]; then
      VIDEO_FILE_RES="$SINGLE_FILE"
    else
      VIDEO_FILE_RES=$(find "$CONTENT_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.ts' \) | grep -Eiv 'sample|trailer|featurette' | head -n 1)
    fi
    if [[ -n "$VIDEO_FILE_RES" ]]; then
      VIDEO_FILE_RES_WIN=$(cygpath -w "$VIDEO_FILE_RES")
      MI_RES=$(resolve_resolution_from_mediainfo "$("$MEDIAINFO_EXE" "$VIDEO_FILE_RES_WIN")" || true)
      if [[ -n "$MI_RES" ]]; then
        RESOLUTION_ID="${MI_RES%%|*}"
        RES_DETECTED=true
        echo "Detected resolution from video file: ${MI_RES#*|} -> resolution_id=$RESOLUTION_ID"
      fi
    fi
  fi
fi

[[ "$RES_DETECTED" == true ]] && echo "Resolution: resolution_id=$RESOLUTION_ID"

# Detect type from directory/file name
# IDs: 1=Full Disc 2=Remux 3=Encode 4=WEB-DL 5=WEBRip 6=HDTV
TYPE_DETECTED=false
case "${TORRENT_NAME,,}" in
  *remux*)                    TYPE_ID=2; TYPE_DETECTED=true ;;
  *web-dl*|*webdl*)           TYPE_ID=4; TYPE_DETECTED=true ;;
  *webrip*|*web.rip*)         TYPE_ID=5; TYPE_DETECTED=true ;;
  *hdtv*)                     TYPE_ID=6; TYPE_DETECTED=true ;;
  *bdmv*|*disc*|*.iso)        TYPE_ID=1; TYPE_DETECTED=true ;;
esac
[[ "$TYPE_DETECTED" == true ]] && echo "Detected type: type_id=$TYPE_ID"

# For TV: upgrade to Series/HD (category_id=12) if resolution > 700p
if [[ "$TV_MODE" == true && "$RES_DETECTED" == true ]]; then
  # IDs 1-5 are 4320p, 2160p, 1080p, 1080i, 720p (all > 700p)
  if [[ "$RESOLUTION_ID" -ge 1 && "$RESOLUTION_ID" -le 5 ]]; then
    CATEGORY_ID=12
    echo "TV HD detected -> category_id=$CATEGORY_ID (Series/HD)"
  fi
fi

# Override TMDB/IMDB IDs from output file if available
if [[ -f "$IMDB_FILE" ]]; then
  IMDB_CONTENT=$(tr -d '\r' < "$IMDB_FILE" | sed 's/^\xEF\xBB\xBF//')
  _TMDB=$(echo "$IMDB_CONTENT" | grep "^TMDB ID:" | sed 's/^TMDB ID:[[:space:]]*//' || true)
  _IMDB=$(echo "$IMDB_CONTENT" | grep "^IMDB ID:" | sed 's/^IMDB ID:[[:space:]]*//' | sed 's/^tt//' || true)
  [[ -n "$_TMDB" ]] && TMDB="$_TMDB"
  [[ -n "$_IMDB" ]] && IMDB="$_IMDB"
fi

# Build upload name: append BG title if available
UPLOAD_NAME="$TORRENT_NAME"
if [[ -n "$BG_TITLE" ]]; then
  UPLOAD_NAME="$TORRENT_NAME / $BG_TITLE (${YEAR:-????})"
fi

# Detect Bulgarian audio/subtitles from MediaInfo sections
BG_AUDIO=false
BG_SUBS=false
if [[ -f "$MEDIAINFO_FILE" ]]; then
  eval "$(awk '
    /^Audio/                    { sec="audio" }
    /^Text/                     { sec="text" }
    /^(Video|Menu|General)/     { sec="other" }
    /[Ll]anguage.*:.*[Bb]ulgarian/ {
      if (sec == "audio") print "BG_AUDIO=true"
      if (sec == "text")  print "BG_SUBS=true"
    }
  ' "$MEDIAINFO_FILE")"
fi
# Check for external Bulgarian subtitle files if not found in MediaInfo
if [[ "$BG_SUBS" == false ]]; then
  BG_SRT=$(find "$CONTENT_DIR" -type f -iname '*.srt' | grep -Eiq '\.bg\.|\.bul\.|bulgarian|\.bgforced\.' && echo true || echo false)
  if [[ "$BG_SRT" == false ]]; then
    # Also check for .srt files in Subs/ subdirectory with bg/bul in path
    BG_SRT=$(find "$CONTENT_DIR" -type f -iname '*.srt' -ipath '*bg*' 2>/dev/null | head -1 | grep -q . && echo true || echo false)
  fi
  [[ "$BG_SRT" == true ]] && BG_SUBS=true
fi

BG_FLAG=$(printf '\U0001F1E7\U0001F1EC')
BG_TAGS=""
if [[ "$BG_SUBS" == true ]]; then
  ABCD=$(printf '\U0001F524')
  BG_TAGS="${BG_FLAG}${ABCD}"
  echo "Bulgarian subtitles detected"
fi
if [[ "$BG_AUDIO" == true ]]; then
  SPEAKER=$(printf '\U0001F50A')
  BG_TAGS="${BG_TAGS}${BG_FLAG}${SPEAKER}"
  echo "Bulgarian audio detected"
fi
[[ -n "$BG_TAGS" ]] && UPLOAD_NAME="${UPLOAD_NAME} ${BG_TAGS}"
echo "Upload name: $UPLOAD_NAME"

# Write request file
{
  echo "torrent_name=$TORRENT_NAME"
  echo "name=$UPLOAD_NAME"
  echo "category_id=$CATEGORY_ID"
  echo "type_id=$TYPE_ID"
  echo "resolution_id=$RESOLUTION_ID"
  echo "tmdb=$TMDB"
  echo "imdb=$IMDB"
  echo "personal=$PERSONAL"
  echo "anonymous=$ANONYMOUS"
  echo "season_number=$SEASON_NUMBER"
  echo "episode_number=$EPISODE_NUMBER"
} > "$REQUEST_FILE"
echo "Upload request saved to: $REQUEST_FILE"
