#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <directory> [output_dir]

Take 3 screenshots from the main video file in <directory> using ffmpeg.
Screenshots are taken at 15%, 50%, and 85% of the video duration.

Arguments:
  directory    Path to the content directory containing the video
  output_dir   Optional output directory (default: ../output)

Options:
  -h, --help   Show this help message
EOF
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -lt 1 ]] && { echo "Error: directory argument required"; usage; }

CONTENT_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_OUT_DIR="$SCRIPT_DIR/../output"
OUT_DIR="${2:-$DEFAULT_OUT_DIR}"
FFMPEG="$SCRIPT_DIR/../tools/ffmpeg.exe"
FFPROBE="$SCRIPT_DIR/../tools/ffprobe.exe"

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

# Check for required tools
for tool in "$FFMPEG" "$FFPROBE"; do
  if [[ ! -f "$tool" ]]; then
    echo -e "\e[33mWarning: '$tool' not found in $SCRIPT_DIR. Run ./install.sh to download it. Skipping.\e[0m"
    exit 0
  fi
done

# Find video file (largest file that looks like a video)
if [[ -n "$SINGLE_FILE" ]]; then
  VIDEO_FILE="$SINGLE_FILE"
else
  VIDEO_FILE=$(find "$CONTENT_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.ts' -o -iname '*.wmv' -o -iname '*.mov' \) | grep -Eiv 'sample|trailer|featurette' | sort | head -n 1)
fi

if [[ -z "$VIDEO_FILE" ]]; then
  echo -e "\e[33mWarning: no video file found in '$CONTENT_DIR'. Skipping.\e[0m"
  exit 0
fi

echo "Found video: $(basename "$VIDEO_FILE")"

# Get duration in seconds (integer)
VIDEO_FILE_WIN=$(cygpath -w "$VIDEO_FILE")
DURATION_FLOAT=$("$FFPROBE" -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE_WIN")
DURATION=${DURATION_FLOAT%.*}

if [[ -z "$DURATION" || "$DURATION" -eq 0 ]]; then
  echo -e "\e[33mWarning: could not determine video duration. Skipping.\e[0m"
  exit 0
fi

echo "Duration: ${DURATION}s"

# Calculate timestamps
T1=$(( DURATION * 15 / 100 ))
T2=$(( DURATION * 50 / 100 ))
T3=$(( DURATION * 85 / 100 ))

mkdir -p "$OUT_DIR"
NAME="$DIR_NAME"

# Convert output paths to Windows format for ffmpeg (handles spaces and brackets)
SCREEN1_WIN=$(cygpath -w "$OUT_DIR/${NAME}_screen01.jpg")
SCREEN2_WIN=$(cygpath -w "$OUT_DIR/${NAME}_screen02.jpg")
SCREEN3_WIN=$(cygpath -w "$OUT_DIR/${NAME}_screen03.jpg")

echo "Taking screenshots..."

# Take screenshots (using fast seek -ss before -i)
"$FFMPEG" -ss "$T1" -i "$VIDEO_FILE_WIN" -vframes 1 -q:v 2 -y "$SCREEN1_WIN" -v error && echo -e "\e[32mSaved: $OUT_DIR/${NAME}_screen01.jpg\e[0m"
"$FFMPEG" -ss "$T2" -i "$VIDEO_FILE_WIN" -vframes 1 -q:v 2 -y "$SCREEN2_WIN" -v error && echo -e "\e[32mSaved: $OUT_DIR/${NAME}_screen02.jpg\e[0m"
"$FFMPEG" -ss "$T3" -i "$VIDEO_FILE_WIN" -vframes 1 -q:v 2 -y "$SCREEN3_WIN" -v error && echo -e "\e[32mSaved: $OUT_DIR/${NAME}_screen03.jpg\e[0m"

echo -e "\e[32mDone.\e[0m"
