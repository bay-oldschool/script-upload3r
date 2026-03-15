#!/bin/bash
# Download required tools if not present

START_TIME=$SECONDS
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/tools"
mkdir -p "$TOOLS_DIR"

FFMPEG_URL="https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
MEDIAINFO_URL="https://mediaarea.net/download/binary/mediainfo/26.01/MediaInfo_CLI_26.01_Windows_x64.zip"

# --- config ---
if [[ ! -f "$SCRIPT_DIR/config.jsonc" ]]; then
    cp "$SCRIPT_DIR/config.example.jsonc" "$SCRIPT_DIR/config.jsonc"
    echo -e "\e[32mCreated config.jsonc from example. Edit it with your settings.\e[0m"
else
    echo "config.jsonc already exists, skipping."
fi

# --- ffmpeg & ffprobe ---
if [[ ! -f "$TOOLS_DIR/ffmpeg.exe" || ! -f "$TOOLS_DIR/ffprobe.exe" ]]; then
    echo "Downloading ffmpeg..."
    TMP="$TOOLS_DIR/ffmpeg.zip"
    curl -L -o "$TMP" "$FFMPEG_URL"
    # Extract only the exe files from bin/ inside the versioned folder
    unzip -o -j "$TMP" "*/bin/ffmpeg.exe" "*/bin/ffprobe.exe" -d "$TOOLS_DIR"
    rm -f "$TMP"
    echo "ffmpeg & ffprobe installed."
else
    echo "ffmpeg & ffprobe already present, skipping."
fi

# --- MediaInfo ---
if [[ ! -f "$TOOLS_DIR/MediaInfo.exe" ]]; then
    echo "Downloading MediaInfo..."
    TMP="$TOOLS_DIR/mediainfo.zip"
    curl -L -o "$TMP" "$MEDIAINFO_URL"
    unzip -o -j "$TMP" "MediaInfo.exe" -d "$TOOLS_DIR"
    rm -f "$TMP"
    echo "MediaInfo installed."
else
    echo "MediaInfo already present, skipping."
fi

echo -e "\e[32mAll tools ready. Took $((SECONDS - START_TIME))s\e[0m"
