#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <directory> [config.jsonc]

Create a .torrent file from <directory>.

Arguments:
  directory      Path to the content directory
  config.jsonc   Path to JSONC config file (default: ./config.jsonc)

Options:
  --dht        Enable DHT (disabled by default)
  -h, --help   Show this help message
EOF
  exit 0
}

# ── Simple JSON value reader (no jq needed) ──────────────────────────────
json_val() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# ── Parse CLI args ───────────────────────────────────────────────────────
DHT=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    --dht) DHT=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo "Error: directory argument required"; usage; }

CONTENT_DIR="${POSITIONAL[0]}"
CONFIG_FILE="${POSITIONAL[1]:-../config.jsonc}"

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../output"
mkdir -p "$OUT_DIR"

ANNOUNCE_URL=$(json_val announce_url "$CONFIG_FILE")
if [[ -z "$ANNOUNCE_URL" ]]; then
  echo -e "\e[33mSkipping: 'announce_url' not configured in $CONFIG_FILE\e[0m"
  exit 0
fi
TORRENT_NAME="$DIR_NAME"
TORRENT_FILE="$OUT_DIR/${TORRENT_NAME}.torrent"

PRIVATE=$((1 - DHT))
if [[ -n "$SINGLE_FILE" ]]; then
  CONTENT_DIR_WIN=$(cygpath -w "$SINGLE_FILE")
else
  CONTENT_DIR_WIN=$(cygpath -w "$CONTENT_DIR")
fi
TORRENT_FILE_WIN=$(cygpath -w "$TORRENT_FILE")
MKTORRENT_WIN=$(cygpath -w "$SCRIPT_DIR/../shared/mktorrent.ps1")

echo "Creating torrent: $TORRENT_FILE (DHT: $([ $DHT -eq 1 ] && echo on || echo off))"
powershell -ExecutionPolicy Bypass -File "$MKTORRENT_WIN" \
  -path "$CONTENT_DIR_WIN" \
  -announceurl "$ANNOUNCE_URL" \
  -outputfile "$TORRENT_FILE_WIN" \
  -private $PRIVATE
