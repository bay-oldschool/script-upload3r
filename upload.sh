#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <directory> [config.jsonc]

Upload a .torrent to a UNIT3D tracker using the pre-built upload request file.
Expects the torrent file, _torrent_description.txt and _upload_request.txt to
already exist in the output directory (run the full pipeline with run.sh first).

Arguments:
  directory      Path to the content directory
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  -a, --auto   Skip interactive prompts, use defaults
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

AUTO=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    -a|-auto|--auto) AUTO=true ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo -e "\e[31mError: directory argument required\e[0m"; usage; }

CONTENT_DIR="${POSITIONAL[0]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${POSITIONAL[1]:-./config.jsonc}"

if [[ -f "$CONTENT_DIR" ]]; then
  SINGLE_FILE="$CONTENT_DIR"
  CONTENT_DIR="$(dirname "$CONTENT_DIR")"
  NAME=$(basename "$SINGLE_FILE" | sed 's/\.[^.]*$//')
else
  SINGLE_FILE=""
  NAME=$(basename "$CONTENT_DIR")
fi

if [[ -z "$SINGLE_FILE" && ! -d "$CONTENT_DIR" ]]; then
  echo -e "\e[31mError: '$CONTENT_DIR' is not a file or directory\e[0m"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo -e "\e[31mError: 'curl' is not installed\e[0m"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "\e[31mError: config file '$CONFIG_FILE' not found. Run ./install.sh to create it from config.example.jsonc\e[0m"
  exit 1
fi

# Read tracker credentials from config
API_KEY=$(json_val api_key "$CONFIG_FILE")
if [[ -z "$API_KEY" ]]; then
  echo -e "\e[33mSkipping: 'api_key' not configured in $CONFIG_FILE\e[0m"
  exit 0
fi
TRACKER_URL=$(json_val tracker_url "$CONFIG_FILE")

OUT_DIR="$SCRIPT_DIR/output"
TORRENT_NAME="$NAME"

REQUEST_FILE="$OUT_DIR/${TORRENT_NAME}_upload_request.txt"
TORRENT_FILE="$OUT_DIR/${TORRENT_NAME}.torrent"
TORRENT_DESC_FILE="$OUT_DIR/${TORRENT_NAME}_torrent_description.txt"

if [[ ! -f "$REQUEST_FILE" ]]; then
  echo -e "\e[31mError: '$REQUEST_FILE' not found. Run the pipeline first.\e[0m"
  exit 1
fi
if [[ ! -f "$TORRENT_FILE" ]]; then
  echo -e "\e[31mError: '$TORRENT_FILE' not found. Run the pipeline first.\e[0m"
  exit 1
fi
if [[ ! -f "$TORRENT_DESC_FILE" ]]; then
  echo -e "\e[31mError: '$TORRENT_DESC_FILE' not found. Run the pipeline first.\e[0m"
  exit 1
fi

# Read request file (key=value format)
req_val() {
  grep "^$1=" "$REQUEST_FILE" | head -1 | sed "s/^$1=//"
}

UPLOAD_NAME=$(req_val name)
CATEGORY_ID=$(req_val category_id)
TYPE_ID=$(req_val type_id)
RESOLUTION_ID=$(req_val resolution_id)
TMDB=$(req_val tmdb)
IMDB=$(req_val imdb)
PERSONAL=$(req_val personal)
ANONYMOUS=$(req_val anonymous)
SEASON_NUMBER=$(req_val season_number)
EPISODE_NUMBER=$(req_val episode_number)

# Read categories from categories.jsonc
CATEGORIES_FILE="$SCRIPT_DIR/shared/categories.jsonc"
ALL_NAMES=()
ALL_IDS=()
ALL_TYPES=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*//.* ]] && continue
  if [[ "$line" =~ \"name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*\"id\"[[:space:]]*:[[:space:]]*([0-9]+).*\"type\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    ALL_NAMES+=("${BASH_REMATCH[1]}")
    ALL_IDS+=("${BASH_REMATCH[2]}")
    ALL_TYPES+=("${BASH_REMATCH[3]}")
  fi
done < "$CATEGORIES_FILE"

# Determine type filter from default category_id
CAT_TYPE="movie"
for i in "${!ALL_IDS[@]}"; do
  if [[ "${ALL_IDS[$i]}" == "$CATEGORY_ID" ]]; then
    CAT_TYPE="${ALL_TYPES[$i]}"
    break
  fi
done

# Filter categories by type
CAT_NAMES=()
CAT_IDS=()
for i in "${!ALL_TYPES[@]}"; do
  if [[ "${ALL_TYPES[$i]}" == "$CAT_TYPE" ]]; then
    CAT_NAMES+=("${ALL_NAMES[$i]}")
    CAT_IDS+=("${ALL_IDS[$i]}")
  fi
done

if [[ "$AUTO" == false ]]; then
  # Show category picker with default preselected
  echo ""
  echo "Select category ($CAT_TYPE):"
  DEFAULT_IDX=0
  for i in "${!CAT_NAMES[@]}"; do
    marker=""
    if [[ "${CAT_IDS[$i]}" == "$CATEGORY_ID" ]]; then
      marker=" *"
      DEFAULT_IDX=$i
    fi
    echo "  $((i+1))) ${CAT_NAMES[$i]} (id=${CAT_IDS[$i]})${marker}"
  done
  read -rp "Category [$(( DEFAULT_IDX + 1 ))]: " CAT_CHOICE
  CAT_CHOICE="${CAT_CHOICE//[^0-9]/}"
  if [[ -z "$CAT_CHOICE" ]]; then
    CAT_CHOICE=$(( DEFAULT_IDX + 1 ))
  fi
  CAT_IDX=$(( CAT_CHOICE - 1 ))
  if [[ $CAT_IDX -ge 0 && $CAT_IDX -lt ${#CAT_IDS[@]} ]]; then
    CATEGORY_ID="${CAT_IDS[$CAT_IDX]}"
    echo "Selected: ${CAT_NAMES[$CAT_IDX]} (category_id=$CATEGORY_ID)"
  else
    echo "Invalid choice, using default: ${CAT_NAMES[$DEFAULT_IDX]}"
  fi

  # Read types from types.jsonc and show picker
  TYPES_FILE="$SCRIPT_DIR/shared/types.jsonc"
  TYPE_NAMES=()
  TYPE_IDS=()
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*//.* ]] && continue
    if [[ "$line" =~ \"name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*\"id\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      TYPE_NAMES+=("${BASH_REMATCH[1]}")
      TYPE_IDS+=("${BASH_REMATCH[2]}")
    fi
  done < "$TYPES_FILE"

  echo ""
  echo "Select type:"
  DEFAULT_IDX=0
  for i in "${!TYPE_NAMES[@]}"; do
    marker=""
    if [[ "${TYPE_IDS[$i]}" == "$TYPE_ID" ]]; then
      marker=" *"
      DEFAULT_IDX=$i
    fi
    echo "  $((i+1))) ${TYPE_NAMES[$i]} (id=${TYPE_IDS[$i]})${marker}"
  done
  read -rp "Type [$(( DEFAULT_IDX + 1 ))]: " TYPE_CHOICE
  TYPE_CHOICE="${TYPE_CHOICE//[^0-9]/}"
  if [[ -z "$TYPE_CHOICE" ]]; then
    TYPE_CHOICE=$(( DEFAULT_IDX + 1 ))
  fi
  TYPE_IDX=$(( TYPE_CHOICE - 1 ))
  if [[ $TYPE_IDX -ge 0 && $TYPE_IDX -lt ${#TYPE_IDS[@]} ]]; then
    TYPE_ID="${TYPE_IDS[$TYPE_IDX]}"
    echo "Selected: ${TYPE_NAMES[$TYPE_IDX]} (type_id=$TYPE_ID)"
  else
    echo "Invalid choice, using default: ${TYPE_NAMES[$DEFAULT_IDX]}"
  fi

  # Read resolutions from resolutions.jsonc and show picker
  RES_FILE="$SCRIPT_DIR/shared/resolutions.jsonc"
  RES_NAMES=()
  RES_IDS=()
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*//.* ]] && continue
    if [[ "$line" =~ \"name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*\"id\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      RES_NAMES+=("${BASH_REMATCH[1]}")
      RES_IDS+=("${BASH_REMATCH[2]}")
    fi
  done < "$RES_FILE"

  echo ""
  echo "Select resolution:"
  DEFAULT_IDX=0
  for i in "${!RES_NAMES[@]}"; do
    marker=""
    if [[ "${RES_IDS[$i]}" == "$RESOLUTION_ID" ]]; then
      marker=" *"
      DEFAULT_IDX=$i
    fi
    echo "  $((i+1))) ${RES_NAMES[$i]} (id=${RES_IDS[$i]})${marker}"
  done
  read -rp "Resolution [$(( DEFAULT_IDX + 1 ))]: " RES_CHOICE
  RES_CHOICE="${RES_CHOICE//[^0-9]/}"
  if [[ -z "$RES_CHOICE" ]]; then
    RES_CHOICE=$(( DEFAULT_IDX + 1 ))
  fi
  RES_IDX=$(( RES_CHOICE - 1 ))
  if [[ $RES_IDX -ge 0 && $RES_IDX -lt ${#RES_IDS[@]} ]]; then
    RESOLUTION_ID="${RES_IDS[$RES_IDX]}"
    echo "Selected: ${RES_NAMES[$RES_IDX]} (resolution_id=$RESOLUTION_ID)"
  else
    echo "Invalid choice, using default: ${RES_NAMES[$DEFAULT_IDX]}"
  fi
  echo ""

  # Personal release picker (default from config)
  CFG_PERSONAL=$(json_num personal "$CONFIG_FILE")
  read -rp "Personal (0/1) [$CFG_PERSONAL]: " P_CHOICE
  P_CHOICE="${P_CHOICE//[^01]/}"
  PERSONAL="${P_CHOICE:-$CFG_PERSONAL}"
  echo "  personal=$PERSONAL"

  # Anonymous upload picker (default from config)
  CFG_ANONYMOUS=$(json_num anonymous "$CONFIG_FILE")
  read -rp "Anonymous (0/1) [$CFG_ANONYMOUS]: " A_CHOICE
  A_CHOICE="${A_CHOICE//[^01]/}"
  ANONYMOUS="${A_CHOICE:-$CFG_ANONYMOUS}"
  echo "  anonymous=$ANONYMOUS"
  echo ""

  # Confirm season/episode for TV uploads
  if [[ "$CAT_TYPE" == "tv" ]]; then
    echo "Season/Episode:"
    read -rp "  Season number [$SEASON_NUMBER]: " INPUT_SEASON
    INPUT_SEASON="${INPUT_SEASON//[^0-9]/}"
    [[ -n "$INPUT_SEASON" ]] && SEASON_NUMBER="$INPUT_SEASON"
    read -rp "  Episode number [$EPISODE_NUMBER]: " INPUT_EPISODE
    INPUT_EPISODE="${INPUT_EPISODE//[^0-9]/}"
    [[ -n "$INPUT_EPISODE" ]] && EPISODE_NUMBER="$INPUT_EPISODE"
    echo "  -> season=$SEASON_NUMBER, episode=$EPISODE_NUMBER"
  fi
  echo ""
else
  echo ""
  echo "Using defaults: category_id=$CATEGORY_ID, type_id=$TYPE_ID, resolution_id=$RESOLUTION_ID"
  if [[ "$CAT_TYPE" == "tv" ]]; then
    echo "  season=$SEASON_NUMBER, episode=$EPISODE_NUMBER"
  fi
  echo ""
fi

echo "Upload name: $UPLOAD_NAME"

# Extract mediainfo (optional)
MEDIAINFO=""
MEDIAINFO_EXE="$SCRIPT_DIR/tools/MediaInfo.exe"
if [[ -f "$MEDIAINFO_EXE" ]]; then
  if [[ -n "$SINGLE_FILE" ]]; then
    VIDEO_FILE="$SINGLE_FILE"
  else
    VIDEO_FILE=$(find "$CONTENT_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.ts' \) | grep -Eiv 'sample|trailer|featurette' | head -n 1)
  fi
  if [[ -n "$VIDEO_FILE" ]]; then
    echo "Running mediainfo on: $(basename "$VIDEO_FILE")"
    VIDEO_FILE_WIN=$(cygpath -w "$VIDEO_FILE")
    MEDIAINFO=$("$MEDIAINFO_EXE" "$VIDEO_FILE_WIN" | grep -v "^Encoding settings")
  fi
fi

# Upload to tracker
UPLOAD_URL="${TRACKER_URL}/api/torrents/upload?api_token=${API_KEY}"
TORRENT_FILE_WIN=$(cygpath -w "$TORRENT_FILE")
TORRENT_DESC_FILE_WIN=$(cygpath -w "$TORRENT_DESC_FILE")

# Copy files to temp paths to avoid special characters breaking curl
TEMP_NAME_FILE=$(mktemp)
TEMP_TORRENT=$(mktemp --suffix=.torrent)
TEMP_DESC=$(mktemp)
TEMP_MEDIAINFO=$(mktemp)
trap "rm -f $TEMP_NAME_FILE $TEMP_TORRENT $TEMP_DESC $TEMP_MEDIAINFO" EXIT

printf '%s' "$UPLOAD_NAME" > "$TEMP_NAME_FILE"
cp "$TORRENT_FILE" "$TEMP_TORRENT"
cp "$TORRENT_DESC_FILE" "$TEMP_DESC"
printf '%s' "$MEDIAINFO" > "$TEMP_MEDIAINFO"

TEMP_NAME_WIN=$(cygpath -w "$TEMP_NAME_FILE")
TEMP_TORRENT_WIN=$(cygpath -w "$TEMP_TORRENT")
TEMP_DESC_WIN=$(cygpath -w "$TEMP_DESC")
TEMP_MEDIAINFO_WIN=$(cygpath -w "$TEMP_MEDIAINFO")

echo "Uploading to ${TRACKER_URL}..."
TV_FIELDS=""
if [[ "$CAT_TYPE" == "tv" ]]; then
  TV_FIELDS="-F season_number=${SEASON_NUMBER} -F episode_number=${EPISODE_NUMBER}"
fi

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -F "torrent=@${TEMP_TORRENT_WIN}" \
  -F "name=<${TEMP_NAME_WIN}" \
  -F "category_id=${CATEGORY_ID}" \
  -F "type_id=${TYPE_ID}" \
  -F "resolution_id=${RESOLUTION_ID}" \
  -F "tmdb=${TMDB}" \
  -F "imdb=${IMDB}" \
  -F "personal_release=${PERSONAL}" \
  -F "anonymous=${ANONYMOUS}" \
  -F "description=<${TEMP_DESC_WIN}" \
  -F "mediainfo=<${TEMP_MEDIAINFO_WIN}" \
  $TV_FIELDS \
  "$UPLOAD_URL")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" =~ ^2 ]]; then
  echo -e "\e[32mHTTP status: $HTTP_CODE\e[0m"
  echo "$BODY"
else
  echo -e "\e[31mUpload failed (HTTP $HTTP_CODE)\e[0m"
  # Try to extract error message from JSON response
  API_MSG=$(echo "$BODY" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//' || true)
  if [[ -n "$API_MSG" ]]; then
    echo -e "\e[31m$API_MSG\e[0m"
  elif echo "$BODY" | grep -q '<!doctype\|<html'; then
    TITLE=$(echo "$BODY" | grep -oP '<title>\K[^<]+' || true)
    echo -e "\e[31mServer returned HTML page: ${TITLE:-unknown}. Check tracker_url in config.\e[0m"
  else
    echo "$BODY"
  fi
fi

# Write upload log
LOG_FILE="$OUT_DIR/${TORRENT_NAME}_upload.log"
{
  echo "=== Upload Log ==="
  echo "Date:          $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Torrent:       $TORRENT_FILE"
  echo ""
  echo "=== Request ==="
  echo "URL:           ${TRACKER_URL}/api/torrents/upload"
  echo "name:          $UPLOAD_NAME"
  echo "category_id:   $CATEGORY_ID"
  echo "type_id:       $TYPE_ID"
  echo "resolution_id: $RESOLUTION_ID"
  echo "tmdb:          $TMDB"
  echo "imdb:          $IMDB"
  echo "personal:      $PERSONAL"
  echo "anonymous:     $ANONYMOUS"
  if [[ "$CAT_TYPE" == "tv" ]]; then
    echo "season_number: $SEASON_NUMBER"
    echo "episode_number: $EPISODE_NUMBER"
  fi
  echo "description:   (from $TORRENT_DESC_FILE)"
  echo "mediainfo:     ($(echo "$MEDIAINFO" | wc -l) lines)"
  echo ""
  echo "=== Response ==="
  echo "HTTP status:   $HTTP_CODE"
  echo "$BODY"
} > "$LOG_FILE"
echo "Log saved to: $LOG_FILE"
