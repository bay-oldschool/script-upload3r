#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <directory> [config.jsonc]

Generate a rich Bulgarian description for media using TMDB + MediaInfo + Gemini AI.

Arguments:
  directory      Path to the content directory
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -t, --tv     Search for TV shows instead of movies
  -h, --help   Show this help message
EOF
  exit 0
}

# ── Simple JSON value reader ─────────────────────────────────────────────
json_val() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# ── Parse CLI args ───────────────────────────────────────────────────────
MEDIA_TYPE="movie"
QUERY_OVERRIDE=""
POSITIONAL=()
EXPECT_NEXT=""
for arg in "$@"; do
  if [[ "$EXPECT_NEXT" == "query" ]]; then
    QUERY_OVERRIDE="$arg"; EXPECT_NEXT=""; continue
  fi
  case "$arg" in
    -h|--help) usage ;;
    -t|-tv|--tv) MEDIA_TYPE="tv" ;;
    -q|-query|--query) EXPECT_NEXT="query" ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo "Error: directory argument required"; usage; }

CONTENT_DIR="${POSITIONAL[0]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${POSITIONAL[1]:-$SCRIPT_DIR/../config.jsonc}"
MEDIAINFO="$SCRIPT_DIR/../tools/MediaInfo.exe"

if [[ -f "$CONTENT_DIR" ]]; then
  SINGLE_FILE="$CONTENT_DIR"
  CONTENT_DIR="$(dirname "$CONTENT_DIR")"
else
  SINGLE_FILE=""
fi

if [[ -z "$SINGLE_FILE" && ! -d "$CONTENT_DIR" ]]; then
  echo "Error: '$CONTENT_DIR' is not a directory or file"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "\e[33mWarning: config file '$CONFIG_FILE' not found. Skipping.\e[0m"
  exit 0
fi

TMDB_API_KEY=$(json_val tmdb_api_key "$CONFIG_FILE")
GEMINI_API_KEY=$(json_val gemini_api_key "$CONFIG_FILE")
GEMINI_MODEL=$(json_val gemini_model "$CONFIG_FILE")
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash-lite}"
OLLAMA_MODEL=$(json_val ollama_model "$CONFIG_FILE")
OLLAMA_URL=$(json_val ollama_url "$CONFIG_FILE")
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
AI_PROVIDER_CFG=$(json_val ai_provider "$CONFIG_FILE")

if [[ -z "$TMDB_API_KEY" ]]; then
  echo -e "\e[33mSkipping: 'tmdb_api_key' not configured in $CONFIG_FILE\e[0m"
  exit 0
fi

# Determine AI provider: ai_provider forces choice, else ollama_model set → Ollama, else gemini_api_key → Gemini
if [[ "$AI_PROVIDER_CFG" == "gemini" && -n "$GEMINI_API_KEY" ]]; then
  AI_PROVIDER="gemini"
  AI_MODEL="$GEMINI_MODEL"
elif [[ "$AI_PROVIDER_CFG" == "ollama" && -n "$OLLAMA_MODEL" ]]; then
  AI_PROVIDER="ollama"
  AI_MODEL="$OLLAMA_MODEL"
elif [[ -n "$OLLAMA_MODEL" ]]; then
  AI_PROVIDER="ollama"
  AI_MODEL="$OLLAMA_MODEL"
elif [[ -n "$GEMINI_API_KEY" ]]; then
  AI_PROVIDER="gemini"
  AI_MODEL="$GEMINI_MODEL"
else
  echo -e "\e[33mSkipping: neither 'ollama_model' nor 'gemini_api_key' configured in $CONFIG_FILE\e[0m"
  exit 0
fi

# ── Extract name and year from directory/file name ───────────────────────
if [[ -n "$SINGLE_FILE" ]]; then
  DIR_NAME=$(basename "$SINGLE_FILE" | sed 's/\.[^.]*$//')
else
  DIR_NAME=$(basename "$CONTENT_DIR")
fi
if [[ -n "$QUERY_OVERRIDE" ]]; then
  CLEAN_NAME="$QUERY_OVERRIDE"
  YEAR=$(echo "$QUERY_OVERRIDE" | grep -oP '\b(19|20)\d{2}\b' | head -1 || true)
else
  YEAR=$(echo "$DIR_NAME" | grep -oP '\b(19|20)\d{2}\b' | head -1 || true)
  CLEAN_NAME=$(echo "$DIR_NAME" | sed 's/[._]/ /g' | sed 's/ - [Ss][0-9]\{2\}.*//; s/\b[Ss][0-9]\{2\}\b.*//; s/\b[0-9]\{4\}\b.*//; s/ - WEBDL.*//I; s/ - WEB-DL.*//I; s/[[:space:]([]*$//')
fi

IMAGE_BASE="https://image.tmdb.org/t/p"
OUT_DIR="$SCRIPT_DIR/../output"
mkdir -p "$OUT_DIR"
OUTPUT_FILE="$OUT_DIR/${DIR_NAME}_description.txt"

echo "=== Step 1: Searching TMDB ($MEDIA_TYPE): $CLEAN_NAME ${YEAR:+($YEAR)} ==="

# ── Search TMDB ──────────────────────────────────────────────────────────
YEAR_PARAM=""
if [[ -n "$YEAR" ]]; then
  if [[ "$MEDIA_TYPE" == "movie" ]]; then
    YEAR_PARAM="&year=${YEAR}"
  else
    YEAR_PARAM="&first_air_date_year=${YEAR}"
  fi
fi

TMDB_RESPONSE=$(mktemp)
trap "rm -f $TMDB_RESPONSE" EXIT

tmdb_search_info() {
  local q="$1" yp="$2" mt="${3:-$MEDIA_TYPE}"
  local eq=$(echo "$q" | sed 's/ /%20/g')
  curl -s "https://api.themoviedb.org/3/search/${mt}?api_key=${TMDB_API_KEY}&query=${eq}${yp}" > "$TMDB_RESPONSE"
  local tw=$(cygpath -w "$TMDB_RESPONSE" 2>/dev/null || echo "$TMDB_RESPONSE")
  powershell -ExecutionPolicy Bypass -Command "
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
\$r = Get-Content -Raw '$tw' -Encoding UTF8 | ConvertFrom-Json
if (-not \$r.results -or \$r.results.Count -eq 0) { Write-Host 'NOT_FOUND'; exit }
\$q = ('$q' -replace '[^a-zA-Z0-9]', '').ToLower()
\$yr = '$YEAR'
\$item = \$r.results[0]
\$bestScore = -1
foreach (\$candidate in \$r.results) {
    if (\$null -eq \$candidate) { continue }
    \$t = if ('$mt' -eq 'movie') { \$candidate.title } else { \$candidate.name }
    \$tn = (\$t -replace '[^a-zA-Z0-9]', '').ToLower()
    \$d = if ('$mt' -eq 'movie') { \$candidate.release_date } else { \$candidate.first_air_date }
    \$titleScore = if (\$tn -eq \$q) { 3 } elseif (\$tn.StartsWith(\$q) -or \$q.StartsWith(\$tn)) { 2 } elseif (\$tn.Contains(\$q) -or \$q.Contains(\$tn)) { 1 } else { 0 }
    \$yearBonus = if (\$yr -and \$d -and \$d.StartsWith(\$yr)) { 1 } else { 0 }
    \$score = \$titleScore * 2 + \$yearBonus
    if (\$score -gt \$bestScore) { \$bestScore = \$score; \$item = \$candidate }
}
if (\$null -eq \$item) { Write-Host 'NOT_FOUND'; exit }
\$type = '$mt'
if (\$type -eq 'movie') {
    \$title = \$item.title
    \$date = \$item.release_date
} else {
    \$title = \$item.name
    \$date = \$item.first_air_date
}
Write-Host \"Title: \$title\"
Write-Host \"Date: \$date\"
Write-Host \"ID: \$(\$item.id)\"
Write-Host \"Overview: \$(\$item.overview)\"
Write-Host \"Poster: $IMAGE_BASE/w500\$(\$item.poster_path)\"
Write-Host \"Banner: $IMAGE_BASE/original\$(\$item.backdrop_path)\"
"
}

TMDB_INFO=$(tmdb_search_info "$CLEAN_NAME" "$YEAR_PARAM")

# Fallback 1: retry without year filter (year may be too restrictive)
if [[ "$TMDB_INFO" == "NOT_FOUND" && -n "$YEAR" && -z "$QUERY_OVERRIDE" ]]; then
  echo -e "\e[33mNo results for '$CLEAN_NAME' ($YEAR), retrying without year filter\e[0m"
  TMDB_INFO=$(tmdb_search_info "$CLEAN_NAME" "")
  if [[ "$TMDB_INFO" != "NOT_FOUND" ]]; then
    YEAR=""
    YEAR_PARAM=""
  fi
fi

# Fallback 2: try opposite media type (movie↔tv)
if [[ "$TMDB_INFO" == "NOT_FOUND" && -z "$QUERY_OVERRIDE" ]]; then
  if [[ "$MEDIA_TYPE" == "movie" ]]; then ALT_TYPE="tv"; else ALT_TYPE="movie"; fi
  echo -e "\e[33mNo results as '$MEDIA_TYPE', trying as '$ALT_TYPE'\e[0m"
  TMDB_INFO=$(tmdb_search_info "$CLEAN_NAME" "" "$ALT_TYPE")
  if [[ "$TMDB_INFO" != "NOT_FOUND" ]]; then
    MEDIA_TYPE="$ALT_TYPE"
  fi
fi

# Fallback 3: try parent directory name (files only), with same title+year then title-only chain
if [[ "$TMDB_INFO" == "NOT_FOUND" && -z "$QUERY_OVERRIDE" && -n "$SINGLE_FILE" ]]; then
  PARENT_DIR=$(basename "$(dirname "$SINGLE_FILE")")
  PARENT_CLEAN=$(echo "$PARENT_DIR" | sed 's/[._]/ /g' | sed 's/ - [Ss][0-9]\{2\}.*//; s/\b[Ss][0-9]\{2\}\b.*//; s/\b[0-9]\{4\}\b.*//; s/ - WEBDL.*//I; s/ - WEB-DL.*//I; s/[[:space:]([]*$//')
  PARENT_YEAR=$(echo "$PARENT_DIR" | grep -oP '\b(19|20)\d{2}\b' | head -1 || true)
  if [[ -n "$PARENT_CLEAN" && "$PARENT_CLEAN" != "$CLEAN_NAME" ]]; then
    PARENT_YEAR_PARAM=""
    if [[ -n "$PARENT_YEAR" ]]; then
      if [[ "$MEDIA_TYPE" == "movie" ]]; then PARENT_YEAR_PARAM="&year=${PARENT_YEAR}"; else PARENT_YEAR_PARAM="&first_air_date_year=${PARENT_YEAR}"; fi
    fi
    echo -e "\e[33mNo results for '$CLEAN_NAME', trying parent dir: '$PARENT_CLEAN'${PARENT_YEAR:+ ($PARENT_YEAR)}\e[0m"
    TMDB_INFO=$(tmdb_search_info "$PARENT_CLEAN" "$PARENT_YEAR_PARAM")
    # Retry parent without year
    if [[ "$TMDB_INFO" == "NOT_FOUND" && -n "$PARENT_YEAR" ]]; then
      echo -e "\e[33mRetrying parent dir without year filter\e[0m"
      TMDB_INFO=$(tmdb_search_info "$PARENT_CLEAN" "")
    fi
    if [[ "$TMDB_INFO" != "NOT_FOUND" ]]; then
      CLEAN_NAME="$PARENT_CLEAN"
    fi
  fi
fi

if [[ "$TMDB_INFO" == "NOT_FOUND" ]]; then
  echo -e "\e[33mWarning: no TMDB results found for '$CLEAN_NAME'. Skipping.\e[0m"
  exit 0
fi

echo "$TMDB_INFO" | head -2
echo ""

# ── Get MediaInfo ────────────────────────────────────────────────────────
echo "=== Step 2: Extracting MediaInfo ==="
MEDIA_INFO_TEXT=""
if [[ -f "$MEDIAINFO" ]]; then
  if [[ -n "$SINGLE_FILE" ]]; then
    VIDEO_FILE="$SINGLE_FILE"
  else
    VIDEO_FILE=$(find "$CONTENT_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.ts' \) | grep -Eiv 'sample|trailer|featurette' | sort | head -n 1 || true)
  fi
  if [[ -n "$VIDEO_FILE" ]]; then
    echo "Parsing: $(basename "$VIDEO_FILE")"
    VIDEO_FILE_WIN=$(cygpath -w "$VIDEO_FILE")
    MEDIA_INFO_TEXT=$("$MEDIAINFO" "$VIDEO_FILE_WIN")
  fi
fi
echo ""

# ── Build AI prompt ──────────────────────────────────────────────────────
echo "=== Step 3: Generating description with $AI_PROVIDER ($AI_MODEL) ==="

PROMPT_FILE=$(mktemp)
SYSTEM_FILE="$SCRIPT_DIR/../shared/ai_system_prompt.txt"

# Extract release year from TMDB Date field
RELEASE_YEAR=$(echo "$TMDB_INFO" | grep '^Date:' | grep -oP '\d{4}' | head -1 || true)

# Build concise MediaInfo summary (resolution, codec, audio langs, subs)
MEDIA_SUMMARY=""
if [[ -n "$MEDIA_INFO_TEXT" ]]; then
  MI_RES=$(echo "$MEDIA_INFO_TEXT" | grep -m1 'Width' | sed 's/.*: *//' || true)
  MI_HEIGHT=$(echo "$MEDIA_INFO_TEXT" | grep -m1 'Height' | sed 's/.*: *//' || true)
  MI_CODEC=$(echo "$MEDIA_INFO_TEXT" | grep -m1 'Format/Info' | sed 's/.*: *//' || true)
  MI_DURATION=$(echo "$MEDIA_INFO_TEXT" | grep -m1 'Duration' | sed 's/.*: *//' || true)
  MI_AUDIO=$(echo "$MEDIA_INFO_TEXT" | grep -i '^\s*Language' | sed 's/.*: *//' | sort -u | paste -sd', ' || true)
  MEDIA_SUMMARY="Resolution: ${MI_RES}x${MI_HEIGHT}, Codec: ${MI_CODEC}, Duration: ${MI_DURATION}, Audio: ${MI_AUDIO}"
fi

# Load BG title from TMDB output file if available
TMDB_OUT_FILE="$OUT_DIR/${DIR_NAME}_tmdb.txt"
BG_TITLE=""
if [[ -f "$TMDB_OUT_FILE" ]]; then
  BG_TITLE=$(tr -d '\r' < "$TMDB_OUT_FILE" | sed 's/^\xEF\xBB\xBF//' | grep "^    BG Title:" | head -1 | sed 's/^    BG Title:[[:space:]]*//' || true)
fi

# Load cast/credits from IMDB file if available
IMDB_FILE="$OUT_DIR/${DIR_NAME}_imdb.txt"
IMDB_CAST=""
IMDB_DIRECTORS=""
IMDB_GENRES=""
IMDB_RATING=""
if [[ -f "$IMDB_FILE" ]]; then
  _IMDB_RAW=$(tr -d '\r' < "$IMDB_FILE" | sed 's/^\xEF\xBB\xBF//')
  IMDB_CAST=$(echo "$_IMDB_RAW" | grep "^Cast:" | sed 's/^Cast:[[:space:]]*//' || true)
  IMDB_DIRECTORS=$(echo "$_IMDB_RAW" | grep "^Director" | sed 's/^Director(s):[[:space:]]*//' || true)
  IMDB_GENRES=$(echo "$_IMDB_RAW" | grep "^Genres:" | sed 's/^Genres:[[:space:]]*//' || true)
  IMDB_RATING=$(echo "$_IMDB_RAW" | grep "^Rating:" | sed 's/^Rating:[[:space:]]*//' || true)
  IMDB_RT=$(echo "$_IMDB_RAW" | grep "^RT Rating:" | sed 's/^RT Rating:[[:space:]]*//' || true)
fi

# User prompt: only data
{
  echo "$TMDB_INFO"
  if [[ -n "$BG_TITLE" ]]; then
    echo "BG Title: $BG_TITLE"
  fi
  echo "Година на издаване: ${RELEASE_YEAR}"
  echo "Директория: $DIR_NAME"
  if [[ -n "$IMDB_CAST" ]]; then
    echo "Cast: $IMDB_CAST"
  fi
  if [[ -n "$IMDB_DIRECTORS" ]]; then
    echo "Director(s): $IMDB_DIRECTORS"
  fi
  if [[ -n "$IMDB_GENRES" ]]; then
    echo "Genres: $IMDB_GENRES"
  fi
  if [[ -n "$IMDB_RATING" ]]; then
    echo "Rating: $IMDB_RATING"
  fi
  if [[ -n "$IMDB_RT" ]]; then
    echo "Rotten Tomatoes: $IMDB_RT"
  fi
  if [[ -n "$MEDIA_SUMMARY" ]]; then
    echo "Технически данни: $MEDIA_SUMMARY"
  fi
  echo ""
  echo "Напиши описание на БЪЛГАРСКИ ЕЗИК по формата от инструкциите."
} > "$PROMPT_FILE"

PROMPT_WIN=$(cygpath -w "$PROMPT_FILE" 2>/dev/null || echo "$PROMPT_FILE")
OUTPUT_WIN=$(cygpath -w "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")
SYSTEM_WIN=$(cygpath -w "$SYSTEM_FILE" 2>/dev/null || echo "$SYSTEM_FILE")

powershell -ExecutionPolicy Bypass -File "$SCRIPT_DIR/../shared/ai_call.ps1" \
  -promptfile "$PROMPT_WIN" \
  -outputfile "$OUTPUT_WIN" \
  -provider "$AI_PROVIDER" \
  -model "$AI_MODEL" \
  -apikey "$GEMINI_API_KEY" \
  -baseurl "$OLLAMA_URL" \
  -systemfile "$SYSTEM_WIN" || echo -e "\e[33mWarning: AI description skipped\e[0m"

rm -f "$PROMPT_FILE"

echo ""
echo -e "\e[32mSaved to: $OUTPUT_FILE\e[0m"
