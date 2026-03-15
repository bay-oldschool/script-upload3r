#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <directory> [output.txt]

Run MediaInfo on all video files in <directory> and save output to a text file.

Arguments:
  directory    Path to the content directory
  output.txt   Output file path (default: <directory_name>_mediainfo.txt)

Options:
  -h, --help   Show this help message
EOF
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -lt 1 ]] && { echo "Error: directory argument required"; usage; }

CONTENT_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MEDIAINFO="$SCRIPT_DIR/../tools/MediaInfo.exe"

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

if [[ ! -f "$MEDIAINFO" ]]; then
  echo -e "\e[33mWarning: MediaInfo.exe not found in $SCRIPT_DIR. Run ./install.sh to download it. Skipping.\e[0m"
  exit 0
fi
OUT_DIR="$SCRIPT_DIR/../output"
mkdir -p "$OUT_DIR"
OUTPUT_FILE="${2:-$OUT_DIR/${DIR_NAME}_mediainfo.txt}"

# Find all video files
if [[ -n "$SINGLE_FILE" ]]; then
  VIDEO_FILES="$SINGLE_FILE"
else
  VIDEO_FILES=$(find "$CONTENT_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.ts' -o -iname '*.wmv' -o -iname '*.flv' -o -iname '*.m4v' -o -iname '*.mov' \) | grep -Eiv 'sample|trailer|featurette' | sort)
fi

if [[ -z "$VIDEO_FILES" ]]; then
  echo -e "\e[33mWarning: no video files found in '$CONTENT_DIR'. Skipping.\e[0m"
  exit 0
fi

> "$OUTPUT_FILE"

COUNT=0
while IFS= read -r file; do
  COUNT=$((COUNT + 1))
  FILENAME=$(basename "$file")
  echo "Parsing: $FILENAME"

  if [[ $COUNT -gt 1 ]]; then
    echo "" >> "$OUTPUT_FILE"
    echo "================================================================================" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
  fi

  if [[ -n "$SINGLE_FILE" ]]; then
    REL_PATH=$(basename "$file")
  else
    REL_PATH="$DIR_NAME/$(basename "$file")"
  fi
  FILE_WIN=$(cygpath -w "$file")
  "$MEDIAINFO" "$FILE_WIN" | sed "s|Complete name *: .*|Complete name                            : $REL_PATH|" >> "$OUTPUT_FILE"
done <<< "$VIDEO_FILES"

echo -e "\e[32mDone: $COUNT file(s) parsed -> $OUTPUT_FILE\e[0m"
