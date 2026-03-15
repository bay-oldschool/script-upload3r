#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [-t|--tv] <directory> [config.jsonc]

Search IMDB info via TMDB API and display IMDB ID, rating, genres, cast, and more.

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

OMDB_API_KEY=$(json_val omdb_api_key "$CONFIG_FILE")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../output"
mkdir -p "$OUT_DIR"

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

OUTPUT_FILE="$OUT_DIR/${QUERY}_imdb.txt"

YEAR_PARAM=""
if [[ -n "$YEAR" ]]; then
  if [[ "$MEDIA_TYPE" == "movie" ]]; then
    YEAR_PARAM="&year=${YEAR}"
  else
    YEAR_PARAM="&first_air_date_year=${YEAR}"
  fi
  echo "Searching ($MEDIA_TYPE): $CLEAN_QUERY ($YEAR)"
else
  echo "Searching ($MEDIA_TYPE): $CLEAN_QUERY"
fi
echo ""

# ── Search TMDB ──────────────────────────────────────────────────────────
SEARCH_FILE=$(mktemp)

tmdb_search_id() {
  local q="$1" yp="$2" mt="${3:-$MEDIA_TYPE}"
  local eq=$(echo "$q" | sed 's/ /%20/g')
  curl -s "https://api.themoviedb.org/3/search/${mt}?api_key=${TMDB_API_KEY}&query=${eq}${yp}" > "$SEARCH_FILE"
  local sw=$(cygpath -w "$SEARCH_FILE" 2>/dev/null || echo "$SEARCH_FILE")
  powershell -ExecutionPolicy Bypass -Command "
\$r = Get-Content -Raw '$sw' -Encoding UTF8 | ConvertFrom-Json
if (-not \$r.results -or \$r.results.Count -eq 0) { exit }
\$q = ('$q' -replace '[^a-zA-Z0-9]', '').ToLower()
\$yr = '$YEAR'
\$best = \$r.results[0]
\$bestScore = -1
foreach (\$item in \$r.results) {
    if (\$null -eq \$item) { continue }
    \$t = if ('$mt' -eq 'movie') { \$item.title } else { \$item.name }
    \$tn = (\$t -replace '[^a-zA-Z0-9]', '').ToLower()
    \$d = if ('$mt' -eq 'movie') { \$item.release_date } else { \$item.first_air_date }
    \$titleScore = if (\$tn -eq \$q) { 3 } elseif (\$tn.StartsWith(\$q) -or \$q.StartsWith(\$tn)) { 2 } elseif (\$tn.Contains(\$q) -or \$q.Contains(\$tn)) { 1 } else { 0 }
    \$yearBonus = if (\$yr -and \$d -and \$d.StartsWith(\$yr)) { 1 } else { 0 }
    \$score = \$titleScore * 2 + \$yearBonus
    if (\$score -gt \$bestScore) { \$bestScore = \$score; \$best = \$item }
}
Write-Host \$best.id
" | tr -d '\r'
}

TMDB_ID=$(tmdb_search_id "$CLEAN_QUERY" "$YEAR_PARAM")

# Fallback 1: retry without year filter (year may be too restrictive)
if [[ -z "$TMDB_ID" && -n "$YEAR" && -z "$QUERY_OVERRIDE" ]]; then
  echo -e "\e[33mNo results for '$CLEAN_QUERY' ($YEAR), retrying without year filter\e[0m"
  TMDB_ID=$(tmdb_search_id "$CLEAN_QUERY" "")
  if [[ -n "$TMDB_ID" ]]; then
    YEAR=""
    YEAR_PARAM=""
  fi
fi

# Fallback 2: try opposite media type (movie↔tv)
if [[ -z "$TMDB_ID" && -z "$QUERY_OVERRIDE" ]]; then
  if [[ "$MEDIA_TYPE" == "movie" ]]; then ALT_TYPE="tv"; else ALT_TYPE="movie"; fi
  echo -e "\e[33mNo results as '$MEDIA_TYPE', trying as '$ALT_TYPE'\e[0m"
  TMDB_ID=$(tmdb_search_id "$CLEAN_QUERY" "" "$ALT_TYPE")
  if [[ -n "$TMDB_ID" ]]; then
    MEDIA_TYPE="$ALT_TYPE"
  fi
fi

# Fallback 3: try parent directory name (files only), with same title+year then title-only chain
if [[ -z "$TMDB_ID" && -z "$QUERY_OVERRIDE" && -f "${POSITIONAL[0]}" ]]; then
  PARENT_DIR=$(basename "$(dirname "${POSITIONAL[0]}")")
  PARENT_CLEAN=$(echo "$PARENT_DIR" | sed 's/[._]/ /g' | sed 's/ - [Ss][0-9]\{2\}.*//; s/\b[Ss][0-9]\{2\}\b.*//; s/\b[0-9]\{4\}\b.*//; s/ - WEBDL.*//I; s/ - WEB-DL.*//I; s/[[:space:]([]*$//')
  PARENT_YEAR=$(echo "$PARENT_DIR" | grep -oP '\b(19|20)\d{2}\b' | head -1 || true)
  if [[ -n "$PARENT_CLEAN" && "$PARENT_CLEAN" != "$CLEAN_QUERY" ]]; then
    PARENT_YEAR_PARAM=""
    if [[ -n "$PARENT_YEAR" ]]; then
      if [[ "$MEDIA_TYPE" == "movie" ]]; then PARENT_YEAR_PARAM="&year=${PARENT_YEAR}"; else PARENT_YEAR_PARAM="&first_air_date_year=${PARENT_YEAR}"; fi
    fi
    echo -e "\e[33mNo results for '$CLEAN_QUERY', trying parent dir: '$PARENT_CLEAN'${PARENT_YEAR:+ ($PARENT_YEAR)}\e[0m"
    TMDB_ID=$(tmdb_search_id "$PARENT_CLEAN" "$PARENT_YEAR_PARAM")
    # Retry parent without year
    if [[ -z "$TMDB_ID" && -n "$PARENT_YEAR" ]]; then
      echo -e "\e[33mRetrying parent dir without year filter\e[0m"
      TMDB_ID=$(tmdb_search_id "$PARENT_CLEAN" "")
      PARENT_YEAR=""
    fi
    if [[ -n "$TMDB_ID" ]]; then
      CLEAN_QUERY="$PARENT_CLEAN"
      YEAR="${PARENT_YEAR:-}"
    fi
  fi
fi

if [[ -z "$TMDB_ID" ]]; then
  echo -e "\e[33mWarning: no TMDB results found. Skipping.\e[0m"
  exit 0
fi

# ── Get full details + credits from TMDB ──────────────────────────────────
DETAILS_FILE=$(mktemp)
CREDITS_FILE=$(mktemp)
trap "rm -f $SEARCH_FILE $DETAILS_FILE $CREDITS_FILE" EXIT

curl -s "https://api.themoviedb.org/3/${MEDIA_TYPE}/${TMDB_ID}?api_key=${TMDB_API_KEY}" > "$DETAILS_FILE"

if [[ "$MEDIA_TYPE" == "tv" ]]; then
  EXTERNAL_FILE=$(mktemp)
  curl -s "https://api.themoviedb.org/3/tv/${TMDB_ID}/external_ids?api_key=${TMDB_API_KEY}" > "$EXTERNAL_FILE"
fi

curl -s "https://api.themoviedb.org/3/${MEDIA_TYPE}/${TMDB_ID}/credits?api_key=${TMDB_API_KEY}" > "$CREDITS_FILE"

# ── Fetch Rotten Tomatoes rating via OMDB ────────────────────────────────
OMDB_FILE=""
if [[ -n "$OMDB_API_KEY" ]]; then
  OMDB_FILE=$(mktemp)
fi

# ── Parse with PowerShell ────────────────────────────────────────────────
DETAILS_WIN=$(cygpath -w "$DETAILS_FILE" 2>/dev/null || echo "$DETAILS_FILE")
CREDITS_WIN=$(cygpath -w "$CREDITS_FILE" 2>/dev/null || echo "$CREDITS_FILE")
OUTPUT_WIN=$(cygpath -w "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")

EXTERNAL_WIN=""
if [[ "$MEDIA_TYPE" == "tv" ]]; then
  EXTERNAL_WIN=$(cygpath -w "$EXTERNAL_FILE" 2>/dev/null || echo "$EXTERNAL_FILE")
fi

powershell -ExecutionPolicy Bypass -Command "
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
\$d = Get-Content -Raw '$DETAILS_WIN' -Encoding UTF8 | ConvertFrom-Json
\$c = Get-Content -Raw '$CREDITS_WIN' -Encoding UTF8 | ConvertFrom-Json
\$type = '$MEDIA_TYPE'
\$out = '$OUTPUT_WIN'
\$extWin = '$EXTERNAL_WIN'

if (\$type -eq 'movie') {
    \$title = \$d.title
    \$date = \$d.release_date
    \$imdbId = \$d.imdb_id
    \$runtime = \"\$(\$d.runtime) min\"
} else {
    \$title = \$d.name
    \$date = \$d.first_air_date
    if (\$extWin) {
        \$ext = Get-Content -Raw \$extWin -Encoding UTF8 | ConvertFrom-Json
        \$imdbId = \$ext.imdb_id
    } else {
        \$imdbId = ''
    }
    \$seasons = \$d.number_of_seasons
    \$episodes = \$d.number_of_episodes
    \$runtime = \"\$seasons season(s), \$episodes episode(s)\"
}

\$year = if (\$date) { \$date.Substring(0,4) } else { '????' }
\$rating = [math]::Round(\$d.vote_average, 1)
\$votes = \$d.vote_count
\$genres = (\$d.genres | ForEach-Object { \$_.name }) -join ', '
\$overview = \$d.overview
\$tagline = \$d.tagline
\$status = \$d.status

# Director(s)
\$directors = (\$c.crew | Where-Object { \$_.job -eq 'Director' } | ForEach-Object { \$_.name }) -join ', '
if (-not \$directors) { \$directors = '(n/a)' }

# Top 5 cast
\$cast = (\$c.cast[0..4] | ForEach-Object { \"\$(\$_.name) (\$(\$_.character))\" }) -join ', '

\$imdbUrl = if (\$imdbId) { \"https://www.imdb.com/title/\$imdbId/\" } else { '(not available)' }

# Fetch Rotten Tomatoes rating via OMDB
\$rtRating = ''
\$omdbKey = '$OMDB_API_KEY'
if (\$omdbKey -and \$imdbId) {
    try {
        \$omdb = Invoke-RestMethod -Uri \"http://www.omdbapi.com/?i=\$imdbId&apikey=\$omdbKey\"
        if (\$omdb.Ratings) {
            \$rt = \$omdb.Ratings | Where-Object { \$_.Source -eq 'Rotten Tomatoes' }
            if (\$rt) { \$rtRating = \$rt.Value }
        }
    } catch { }
}

\$lines = @()
\$lines += \"=== \$title (\$year) ===\"
\$lines += ''
\$lines += \"IMDB ID:      \$imdbId\"
\$lines += \"IMDB URL:     \$imdbUrl\"
\$lines += \"TMDB ID:      \$(\$d.id)\"
\$lines += \"Rating:       \$rating/10 (\$votes votes)\"
if (\$rtRating) { \$lines += \"RT Rating:    \$rtRating\" }
\$lines += \"Genres:       \$genres\"
\$lines += \"Runtime:      \$runtime\"
\$lines += \"Status:       \$status\"
if (\$tagline) { \$lines += \"Tagline:      \$tagline\" }
\$lines += ''
\$lines += \"Director(s):  \$directors\"
\$lines += \"Cast:         \$cast\"
\$lines += ''
\$lines += \"Overview:\"
\$lines += \$overview
\$lines += ''

foreach (\$l in \$lines) { Write-Host \$l }
[System.IO.File]::WriteAllLines(\$out, \$lines, [System.Text.Encoding]::UTF8)
"

echo ""
echo -e "\e[32mSaved to: $OUTPUT_FILE\e[0m"
