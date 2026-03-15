#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <directory> [config.jsonc]

Upload screenshots for <directory> to onlyimage.org and save URLs to output file.

Arguments:
  directory      Path to the content directory (used to find matching screenshots)
  config.jsonc   Path to JSONC config file (default: ../config.jsonc)

Options:
  -h, --help   Show this help message
EOF
  exit 0
}

# ── Simple JSON value reader ─────────────────────────────────────────────
json_val() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# ── Parse CLI args ───────────────────────────────────────────────────────
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -lt 1 ]] && { echo "Error: directory argument required"; usage; }

CONTENT_DIR="$1"
CONFIG_FILE="${2:-../config.jsonc}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../output"

if [[ -f "$CONTENT_DIR" ]]; then
  SINGLE_FILE="$CONTENT_DIR"
  CONTENT_DIR="$(dirname "$CONTENT_DIR")"
  DIR_NAME=$(basename "$SINGLE_FILE" | sed 's/\.[^.]*$//')
else
  SINGLE_FILE=""
  DIR_NAME=$(basename "$CONTENT_DIR")
fi

if [[ -z "$SINGLE_FILE" && ! -d "$CONTENT_DIR" ]]; then
  echo "Error: '$CONTENT_DIR' is not a directory or file"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "\e[33mWarning: config file '$CONFIG_FILE' not found. Skipping.\e[0m"
  exit 0
fi

API_KEY=$(json_val onlyimage_api_key "$CONFIG_FILE")
if [[ -z "$API_KEY" ]]; then
  echo -e "\e[33mSkipping: 'onlyimage_api_key' not configured in $CONFIG_FILE\e[0m"
  exit 0
fi

# ── Find screenshots ─────────────────────────────────────────────────────
NAME="$DIR_NAME"
SCREENS=("$OUT_DIR/${NAME}_screen01.jpg" "$OUT_DIR/${NAME}_screen02.jpg" "$OUT_DIR/${NAME}_screen03.jpg")

FOUND=()
for f in "${SCREENS[@]}"; do
  if [[ -f "$f" ]]; then
    FOUND+=("$f")
  fi
done

if [[ ${#FOUND[@]} -eq 0 ]]; then
  echo -e "\e[33mWarning: no screenshots found in '$OUT_DIR' for '$NAME'. Run screens.sh first. Skipping.\e[0m"
  exit 0
fi

echo "Found ${#FOUND[@]} screenshot(s) to upload."
echo ""

# ── Upload each screenshot ───────────────────────────────────────────────
OUTPUT_FILE="$OUT_DIR/${NAME}_screens.txt"
> "$OUTPUT_FILE"

SUCCESS=0
FAIL=0

for f in "${FOUND[@]}"; do
  FILENAME=$(basename "$f")
  echo -n "Uploading: $FILENAME ... "

  TMPFILE=$(mktemp --suffix=.jpg)
  cp "$f" "$TMPFILE"
  TMPFILE_WIN=$(cygpath -w "$TMPFILE")

  RESPONSE=$(curl -s -X POST "https://onlyimage.org/api/1/upload" \
    -H "X-API-Key: $API_KEY" \
    -F "source=@$TMPFILE_WIN" \
    -F "format=json")
  rm -f "$TMPFILE"

  STATUS=$(echo "$RESPONSE" | grep -o '"status_code":[0-9]*' | grep -o '[0-9]*' || true)
  URL=$(echo "$RESPONSE" | grep -o '"url":"[^"]*"' | head -1 | sed 's/"url":"\(.*\)"/\1/' || true)

  if [[ "$STATUS" == "200" && -n "$URL" ]]; then
    echo "$URL"
    echo "$URL" >> "$OUTPUT_FILE"
    SUCCESS=$((SUCCESS + 1))
  else
    ERROR=$(echo "$RESPONSE" | grep -o '"status_txt":"[^"]*"' | sed 's/"status_txt":"\(.*\)"/\1/' || true)
    echo -e "\e[33mFAILED (${ERROR:-unknown error})\e[0m"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
if [[ $FAIL -gt 0 ]]; then
  echo -e "\e[33mDone: $SUCCESS uploaded, $FAIL failed -> $OUTPUT_FILE\e[0m"
else
  echo -e "\e[32mDone: $SUCCESS uploaded, $FAIL failed -> $OUTPUT_FILE\e[0m"
fi
