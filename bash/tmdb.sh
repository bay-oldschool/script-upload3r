#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-t|--tv] <directory> [config.jsonc]

Search TMDB for a movie or TV show and display ID, poster, and banner URLs.

Arguments:
  directory      Path to the content directory (name used as search query)
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

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo "Error: search query required"; usage; }

# Support single file path: strip extension for query name
CONTENT_DIR="${POSITIONAL[0]}"
if [[ -f "$CONTENT_DIR" ]]; then
  QUERY=$(basename "$CONTENT_DIR" | sed 's/\.[^.]*$//')
else
  QUERY=$(basename "$CONTENT_DIR")
fi
CONFIG_FILE="${POSITIONAL[1]:-../config.jsonc}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "\e[33mWarning: config file '$CONFIG_FILE' not found. Skipping.\e[0m"
  exit 0
fi

TMDB_API_KEY=$(json_val tmdb_api_key "$CONFIG_FILE")
if [[ -z "$TMDB_API_KEY" ]]; then
  echo -e "\e[33mSkipping: 'tmdb_api_key' not configured in $CONFIG_FILE\e[0m"
  exit 0
fi

GOOGLE_API_KEY=$(json_val google_api_key "$CONFIG_FILE")
TRANSLATE_LANG=$(json_val translate_lang "$CONFIG_FILE")

# ── Extract name and year from input ──────────────────────────────────────
if [[ -n "$QUERY_OVERRIDE" ]]; then
  CLEAN_QUERY="$QUERY_OVERRIDE"
  YEAR=$(echo "$QUERY_OVERRIDE" | grep -oP '\b(19|20)\d{2}\b' | head -1 || true)
else
  YEAR=$(echo "$QUERY" | grep -oP '\b(19|20)\d{2}\b' | head -1 || true)
  CLEAN_QUERY=$(echo "$QUERY" | sed 's/[._]/ /g' | sed 's/ - [Ss][0-9]\{2\}.*//; s/\b[Ss][0-9]\{2\}\b.*//; s/\b[0-9]\{4\}\b.*//; s/ - WEBDL.*//I; s/ - WEB-DL.*//I; s/[[:space:]([]*$//')
  if [[ -z "$CLEAN_QUERY" ]]; then
    CLEAN_QUERY="$QUERY"
  fi
fi

IMAGE_BASE="https://image.tmdb.org/t/p"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../output"
mkdir -p "$OUT_DIR"
OUTPUT_FILE="$OUT_DIR/${QUERY}_tmdb.txt"

YEAR_PARAM=""
if [[ -n "$YEAR" ]]; then
  if [[ "$MEDIA_TYPE" == "movie" ]]; then
    YEAR_PARAM="&year=${YEAR}"
  else
    YEAR_PARAM="&first_air_date_year=${YEAR}"
  fi
  echo "Searching TMDB ($MEDIA_TYPE): $CLEAN_QUERY ($YEAR)"
else
  echo "Searching TMDB ($MEDIA_TYPE): $CLEAN_QUERY"
fi
echo ""

# ── Search TMDB ──────────────────────────────────────────────────────────
ENCODED_QUERY=$(echo "$CLEAN_QUERY" | sed 's/ /%20/g')
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

curl -s "https://api.themoviedb.org/3/search/${MEDIA_TYPE}?api_key=${TMDB_API_KEY}&query=${ENCODED_QUERY}${YEAR_PARAM}" > "$TMPFILE"

TOTAL=$(grep -o '"total_results":[0-9]*' "$TMPFILE" | head -1 | sed 's/.*://' || true)

# ── Fallback searches ────────────────────────────────────────────────────
tmdb_search() {
  local q="$1" yp="$2" mt="${3:-$MEDIA_TYPE}"
  local eq=$(echo "$q" | sed 's/ /%20/g')
  curl -s "https://api.themoviedb.org/3/search/${mt}?api_key=${TMDB_API_KEY}&query=${eq}${yp}" > "$TMPFILE"
  grep -o '"total_results":[0-9]*' "$TMPFILE" | head -1 | sed 's/.*://' || true
}

# Fallback 1: retry without year filter (year may be too restrictive)
if [[ ("$TOTAL" == "0" || -z "$TOTAL") && -n "$YEAR" && -z "$QUERY_OVERRIDE" ]]; then
  echo -e "\e[33mNo results for '$CLEAN_QUERY' ($YEAR), retrying without year filter\e[0m"
  TOTAL=$(tmdb_search "$CLEAN_QUERY" "")
  if [[ "$TOTAL" != "0" && -n "$TOTAL" ]]; then
    YEAR=""
    YEAR_PARAM=""
  fi
fi

# Fallback 2: try opposite media type (movie↔tv)
if [[ ("$TOTAL" == "0" || -z "$TOTAL") && -z "$QUERY_OVERRIDE" ]]; then
  if [[ "$MEDIA_TYPE" == "movie" ]]; then ALT_TYPE="tv"; else ALT_TYPE="movie"; fi
  echo -e "\e[33mNo results as '$MEDIA_TYPE', trying as '$ALT_TYPE'\e[0m"
  TOTAL=$(tmdb_search "$CLEAN_QUERY" "" "$ALT_TYPE")
  if [[ "$TOTAL" != "0" && -n "$TOTAL" ]]; then
    MEDIA_TYPE="$ALT_TYPE"
  fi
fi

# Fallback 3: try parent directory name (files only), with same title+year then title-only chain
if [[ ("$TOTAL" == "0" || -z "$TOTAL") && -z "$QUERY_OVERRIDE" && -f "${POSITIONAL[0]}" ]]; then
  PARENT_DIR=$(basename "$(dirname "${POSITIONAL[0]}")")
  PARENT_CLEAN=$(echo "$PARENT_DIR" | sed 's/[._]/ /g' | sed 's/ - [Ss][0-9]\{2\}.*//; s/\b[Ss][0-9]\{2\}\b.*//; s/\b[0-9]\{4\}\b.*//; s/ - WEBDL.*//I; s/ - WEB-DL.*//I; s/[[:space:]([]*$//')
  PARENT_YEAR=$(echo "$PARENT_DIR" | grep -oP '\b(19|20)\d{2}\b' | head -1 || true)
  if [[ -n "$PARENT_CLEAN" && "$PARENT_CLEAN" != "$CLEAN_QUERY" ]]; then
    PARENT_YEAR_PARAM=""
    if [[ -n "$PARENT_YEAR" ]]; then
      if [[ "$MEDIA_TYPE" == "movie" ]]; then PARENT_YEAR_PARAM="&year=${PARENT_YEAR}"; else PARENT_YEAR_PARAM="&first_air_date_year=${PARENT_YEAR}"; fi
    fi
    echo -e "\e[33mNo results for '$CLEAN_QUERY', trying parent dir: '$PARENT_CLEAN'${PARENT_YEAR:+ ($PARENT_YEAR)}\e[0m"
    TOTAL=$(tmdb_search "$PARENT_CLEAN" "$PARENT_YEAR_PARAM")
    # Retry parent without year
    if [[ ("$TOTAL" == "0" || -z "$TOTAL") && -n "$PARENT_YEAR" ]]; then
      echo -e "\e[33mRetrying parent dir without year filter\e[0m"
      TOTAL=$(tmdb_search "$PARENT_CLEAN" "")
      PARENT_YEAR=""
    fi
    if [[ "$TOTAL" != "0" && -n "$TOTAL" ]]; then
      CLEAN_QUERY="$PARENT_CLEAN"
      YEAR="${PARENT_YEAR:-}"
      YEAR_PARAM=""
      if [[ -n "$YEAR" ]]; then
        if [[ "$MEDIA_TYPE" == "movie" ]]; then YEAR_PARAM="&year=${YEAR}"; else YEAR_PARAM="&first_air_date_year=${YEAR}"; fi
      fi
    fi
  fi
fi

if [[ "$TOTAL" == "0" || -z "$TOTAL" ]]; then
  echo -e "\e[33mWarning: no TMDB results found. Skipping.\e[0m"
  exit 0
fi

# ── Parse results using PowerShell for reliable JSON parsing ─────────────
TMPFILE_WIN=$(cygpath -w "$TMPFILE" 2>/dev/null || echo "$TMPFILE")

OUTPUT_FILE_WIN=$(cygpath -w "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")

powershell -ExecutionPolicy Bypass -Command "
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
\$r = Get-Content -Raw '$TMPFILE_WIN' -Encoding UTF8 | ConvertFrom-Json
\$base = '$IMAGE_BASE'
\$type = '$MEDIA_TYPE'
\$out = '$OUTPUT_FILE_WIN'
\$gkey = '$GOOGLE_API_KEY'
\$lang = '$TRANSLATE_LANG'
\$lines = @()
\$i = 0
foreach (\$item in \$r.results[0..4]) {
    if (\$null -eq \$item) { continue }
    \$i++
    if (\$type -eq 'movie') {
        \$title = \$item.title
        \$date = \$item.release_date
    } else {
        \$title = \$item.name
        \$date = \$item.first_air_date
    }
    \$year = if (\$date) { \$date.Substring(0,4) } else { '????' }
    \$id = \$item.id
    \$desc = \$item.overview
    \$translated = ''
    if (\$gkey -and \$lang -and \$desc) {
        try {
            \$body = @{ q = \$desc; target = \$lang; source = 'en' } | ConvertTo-Json
            \$resp = Invoke-RestMethod -Uri \"https://translation.googleapis.com/language/translate/v2?key=\$gkey\" -Method POST -ContentType 'application/json' -Body \$body
            \$translated = \$resp.data.translations[0].translatedText
        } catch {
            \$translated = '(translation failed)'
        }
    }
    \$poster = if (\$item.poster_path) { \"\$base/w500\$(\$item.poster_path)\" } else { '(none)' }
    \$banner = if (\$item.backdrop_path) { \"\$base/original\$(\$item.backdrop_path)\" } else { '(none)' }
    \$line1 = \"[\$i] \$title (\$year)\"
    \$line2 = \"    TMDB ID:      \$id\"
    \$line3 = \"    Description:  \$desc\"
    if (\$translated -and \$translated -ne '(translation failed)') {
        \$line3t = \"    (\$lang):  \$translated\"
    } else {
        \$line3t = ''
    }
    \$line4 = \"    Poster:       \$poster\"
    \$line5 = \"    Banner:       \$banner\"
    \$lines += \$line1, \$line2, \$line3
    if (\$line3t) { \$lines += \$line3t }
    \$lines += \$line4, \$line5, ''
    Write-Host \$line1
    Write-Host \$line2
    Write-Host \$line3
    if (\$line3t) { Write-Host \$line3t }
    Write-Host \$line4
    Write-Host \$line5
    Write-Host ''
}
\$lines | Out-File -LiteralPath \$out -Encoding UTF8
"

# Fetch Bulgarian title for best-matching result using curl and insert into file
FILE_CLEAN=$(tr -d '\r' < "$OUTPUT_FILE" | sed 's/^\xEF\xBB\xBF//')

# Use title similarity to pick the best TMDB ID (same logic as imdb.sh)
BEST_TMDB_ID=$(powershell -ExecutionPolicy Bypass -Command "
\$r = Get-Content -Raw '$TMPFILE_WIN' -Encoding UTF8 | ConvertFrom-Json
if (-not \$r.results -or \$r.results.Count -eq 0) { exit }
\$q = ('$CLEAN_QUERY' -replace '[^a-zA-Z0-9]', '').ToLower()
\$yr = '$YEAR'
\$best = \$r.results[0]
\$bestScore = -1
foreach (\$item in \$r.results) {
    if (\$null -eq \$item) { continue }
    \$t = if ('$MEDIA_TYPE' -eq 'movie') { \$item.title } else { \$item.name }
    \$tn = (\$t -replace '[^a-zA-Z0-9]', '').ToLower()
    \$d = if ('$MEDIA_TYPE' -eq 'movie') { \$item.release_date } else { \$item.first_air_date }
    \$titleScore = if (\$tn -eq \$q) { 3 } elseif (\$tn.StartsWith(\$q) -or \$q.StartsWith(\$tn)) { 2 } elseif (\$tn.Contains(\$q) -or \$q.Contains(\$tn)) { 1 } else { 0 }
    \$yearBonus = if (\$yr -and \$d -and \$d.StartsWith(\$yr)) { 1 } else { 0 }
    \$score = \$titleScore * 2 + \$yearBonus
    if (\$score -gt \$bestScore) { \$bestScore = \$score; \$best = \$item }
}
Write-Host \$best.id
" | tr -d '\r')

FIRST_TMDB_ID="${BEST_TMDB_ID:-$(echo "$FILE_CLEAN" | grep -m1 "^    TMDB ID:" | sed 's/^    TMDB ID:[[:space:]]*//' || true)}"
EN_TITLE_LINE=$(echo "$FILE_CLEAN" | grep -m1 "^\[1\]" || true)
FIRST_EN_TITLE=$(echo "$EN_TITLE_LINE" | sed 's/^\[1\] \(.*\) ([0-9]\{4\})$/\1/')

if [[ -n "$FIRST_TMDB_ID" && -n "$TMDB_API_KEY" ]]; then
  ENDPOINT="movie"
  [[ "$MEDIA_TYPE" == "tv" ]] && ENDPOINT="tv"
  BG_TMPFILE=$(mktemp)
  BG_TITLE_FILE=$(mktemp)
  curl -s "https://api.themoviedb.org/3/${ENDPOINT}/${FIRST_TMDB_ID}?api_key=${TMDB_API_KEY}&language=bg" > "$BG_TMPFILE"
  BG_TMPFILE_WIN=$(cygpath -w "$BG_TMPFILE" 2>/dev/null || echo "$BG_TMPFILE")
  BG_TITLE_FILE_WIN=$(cygpath -w "$BG_TITLE_FILE" 2>/dev/null || echo "$BG_TITLE_FILE")
  powershell -ExecutionPolicy Bypass -Command "
    \$d = Get-Content -Raw '$BG_TMPFILE_WIN' -Encoding UTF8 | ConvertFrom-Json
    \$t = if ('$MEDIA_TYPE' -eq 'tv') { \$d.name } else { \$d.title }
    [System.IO.File]::WriteAllText('$BG_TITLE_FILE_WIN', \$t, (New-Object System.Text.UTF8Encoding \$false))
  "
  BG_TITLE=$(cat "$BG_TITLE_FILE")
  rm -f "$BG_TMPFILE" "$BG_TITLE_FILE"
  if [[ -n "$BG_TITLE" && "$BG_TITLE" != "$FIRST_EN_TITLE" ]]; then
    echo "    BG Title:     $BG_TITLE"
    TMPOUT=$(mktemp)
    awk -v bg="    BG Title:     $BG_TITLE" -v tid="$FIRST_TMDB_ID" '
      /^    TMDB ID:/ { found_id = ($NF == tid) }
      found_id && /^    Banner:/ { print; print bg; found_id=0; next }
      { print }
    ' "$OUTPUT_FILE" > "$TMPOUT" && mv "$TMPOUT" "$OUTPUT_FILE"
  fi
fi

echo -e "\e[32mSaved to: $OUTPUT_FILE\e[0m"
