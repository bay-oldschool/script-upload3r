#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <directory|file> [config.jsonc]

Run pipeline steps for a given media directory or file.

Arguments:
  directory|file Path to the content directory or a media file
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -t, --tv           Search for TV shows instead of movies
  --dht              Enable DHT for torrent (disabled by default)
  -q, --query QUERY  Override auto-detected title for TMDB/IMDB search
  -s, --steps STEPS  Comma-separated list of steps to run (default: all)
  -h, --help         Show this help message

Available steps:
  1  parse       - Extract MediaInfo from video files
  2  create      - Create .torrent file
  3  screens     - Take screenshots at 15%, 50%, 85%
  4  tmdb        - Search TMDB for metadata and BG title
  5  imdb        - Fetch IMDB details (rating, cast, etc.)
  6  describe    - Generate AI description via Gemini
  7  upload      - Upload screenshots to onlyimage.org
  8  description - Build final BBCode torrent description

Examples:
  # Run all steps (default)
  ./run.sh "/d/media/Pacific.Rim.2013.1080p.BluRay"

  # Run only TMDB + IMDB + description steps
  ./run.sh -s 4,5,8 "/d/media/Pacific.Rim.2013.1080p.BluRay"

  # Run steps 1 through 3
  ./run.sh --steps 1,2,3 "/d/media/Pacific.Rim.2013.1080p.BluRay"

  # TV show with specific steps
  ./run.sh --tv -s 4,5,6 "/d/media/Dexter.Original.Sin.S01"

  # Override search query (e.g. Cyrillic title not found by Latin name)
  ./run.sh -t -q "Мамник" "/d/media/Mamnik.S01/Mamnik.s01e09.mp4"

  # Run by step name
  ./run.sh -s parse,screens,description "/d/media/Pacific.Rim.2013.1080p.BluRay"
EOF
  exit 0
}

MEDIA_TYPE=""
DHT=""
STEPS_ARG=""
QUERY_OVERRIDE=""
POSITIONAL=()
EXPECT_NEXT=""
for arg in "$@"; do
  if [[ "$EXPECT_NEXT" == "steps" ]]; then
    STEPS_ARG="$arg"; EXPECT_NEXT=""; continue
  elif [[ "$EXPECT_NEXT" == "query" ]]; then
    QUERY_OVERRIDE="$arg"; EXPECT_NEXT=""; continue
  fi
  case "$arg" in
    -h|--help) usage ;;
    -t|-tv|--tv) MEDIA_TYPE="--tv" ;;
    -dht|--dht) DHT="--dht" ;;
    -s|-steps|--steps) EXPECT_NEXT="steps" ;;
    -q|-query|--query) EXPECT_NEXT="query" ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo -e "\e[31mError: directory argument required\e[0m"; usage; }

CONTENT_DIR="${POSITIONAL[0]}"
CONFIG_FILE="${POSITIONAL[1]:-./config.jsonc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$CONTENT_DIR" && ! -d "$CONTENT_DIR" ]]; then
  echo -e "\e[31mError: '$CONTENT_DIR' is not a file or directory\e[0m"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "\e[31mError: config file '$CONFIG_FILE' not found. Run ./install.sh to create it from config.example.jsonc\e[0m"
  exit 1
fi

# Resolve step names to numbers
resolve_step() {
  case "$1" in
    1|parse)       echo 1 ;;
    2|create)      echo 2 ;;
    3|screens)     echo 3 ;;
    4|tmdb)        echo 4 ;;
    5|imdb)        echo 5 ;;
    6|describe)    echo 6 ;;
    7|upload)      echo 7 ;;
    8|description) echo 8 ;;
    *) echo -e "\e[31mError: unknown step '$1'\e[0m" >&2; exit 1 ;;
  esac
}

# Build list of steps to run
RUN_STEPS=""
if [[ -z "$STEPS_ARG" || "$STEPS_ARG" == "__NEXT__" ]]; then
  RUN_STEPS="1,2,3,4,5,6,7,8"
else
  for s in $(echo "$STEPS_ARG" | tr ',' ' '); do
    n=$(resolve_step "$s")
    RUN_STEPS="${RUN_STEPS:+$RUN_STEPS,}$n"
  done
fi

should_run() { echo ",$RUN_STEPS," | grep -q ",$1,"; }

QUERY_ARGS=()
if [[ -n "$QUERY_OVERRIDE" ]]; then
  QUERY_ARGS=("--query" "$QUERY_OVERRIDE")
fi

TOTAL=$(echo "$RUN_STEPS" | tr ',' '\n' | wc -l)
CURRENT=0

run_step() {
  CURRENT=$((CURRENT + 1))
  echo -e "\e[34m========================================"
  echo "  $CURRENT/$TOTAL  $1"
  echo -e "========================================\e[0m"
}

if should_run 1; then
  run_step "MediaInfo"
  bash "$SCRIPT_DIR/bash/parse.sh" "$CONTENT_DIR"
  echo ""
fi

if should_run 2; then
  run_step "Create Torrent"
  bash "$SCRIPT_DIR/bash/create.sh" $DHT "$CONTENT_DIR" "$CONFIG_FILE"
  echo ""
fi

if should_run 3; then
  run_step "Screenshots"
  bash "$SCRIPT_DIR/bash/screens.sh" "$CONTENT_DIR"
  echo ""
fi

if should_run 4; then
  run_step "TMDB Search"
  bash "$SCRIPT_DIR/bash/tmdb.sh" $MEDIA_TYPE "${QUERY_ARGS[@]}" "$CONTENT_DIR" "$CONFIG_FILE"
  echo ""
fi

if should_run 5; then
  run_step "IMDB Lookup"
  bash "$SCRIPT_DIR/bash/imdb.sh" $MEDIA_TYPE "${QUERY_ARGS[@]}" "$CONTENT_DIR" "$CONFIG_FILE"
  echo ""
fi

if should_run 6; then
  run_step "AI Description"
  bash "$SCRIPT_DIR/bash/describe.sh" $MEDIA_TYPE "${QUERY_ARGS[@]}" "$CONTENT_DIR" "$CONFIG_FILE"
  echo ""
fi

if should_run 7; then
  run_step "Upload Screenshots"
  bash "$SCRIPT_DIR/bash/upload.sh" "$CONTENT_DIR" "$CONFIG_FILE"
  echo ""
fi

if should_run 8; then
  run_step "Build Torrent Description"
  bash "$SCRIPT_DIR/bash/description.sh" $MEDIA_TYPE "$CONTENT_DIR" "$CONFIG_FILE"
  echo ""
fi

if [[ -f "$CONTENT_DIR" ]]; then
  OUTPUT_NAME=$(basename "$CONTENT_DIR" | sed 's/\.[^.]*$//')
else
  OUTPUT_NAME=$(basename "$CONTENT_DIR")
fi

echo -e "\e[32m========================================"
echo "  Done! Files for: $OUTPUT_NAME"
echo -e "========================================\e[0m"
ls -lh "$SCRIPT_DIR/output/" | grep "$OUTPUT_NAME"
