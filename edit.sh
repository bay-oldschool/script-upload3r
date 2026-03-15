#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=en_US.UTF-8

usage() {
  cat <<EOF
Usage: $(basename "$0") <torrent_id> [config.jsonc] [-u upload_request.txt] [-n name.txt] [-d description.txt] [-m mediainfo.txt]

Edit a torrent on a UNIT3D tracker by its ID.
Fetches current values via API, lets you change fields interactively,
then submits the update via web session.

Requires "username" and "password" in config.jsonc.

Arguments:
  torrent_id       Numeric torrent ID to edit
  config.jsonc     Path to JSONC config file (default: ./config.jsonc)

Options:
  -u <file>      Load name/category/type/resolution/tmdb/imdb/personal/anonymous from _upload_request.txt
  -n <file>      Use torrent name from file (preserves emoji from clipboard)
  -d <file>      Use description from file instead of current one
  -m <file>      Use mediainfo from file instead of current one
  -h, --help     Show this help message
EOF
  exit 0
}

# Simple JSON value reader (no jq needed)
json_val() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}


POSITIONAL=()
UPLOAD_REQ_FILE=""
NAME_FILE=""
DESC_FILE=""
MEDIAINFO_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -u) UPLOAD_REQ_FILE="$2"; shift 2 ;;
    -n) NAME_FILE="$2"; shift 2 ;;
    -d) DESC_FILE="$2"; shift 2 ;;
    -m) MEDIAINFO_FILE="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo -e "\e[31mError: torrent_id argument required\e[0m"; usage; }

TORRENT_ID="${POSITIONAL[0]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${POSITIONAL[1]:-./config.jsonc}"

if [[ -n "$UPLOAD_REQ_FILE" && ! -f "$UPLOAD_REQ_FILE" ]]; then
  echo -e "\e[31mError: upload request file '$UPLOAD_REQ_FILE' not found\e[0m"
  exit 1
fi

# Parse upload_request.txt if provided
UPR_NAME="" UPR_CATEGORY_ID="" UPR_TYPE_ID="" UPR_RESOLUTION_ID=""
UPR_TMDB="" UPR_IMDB="" UPR_PERSONAL="" UPR_ANON=""
UPR_SEASON="" UPR_EPISODE=""
if [[ -n "$UPLOAD_REQ_FILE" ]]; then
  while IFS='=' read -r key val; do
    case "$key" in
      name) UPR_NAME="$val" ;;
      category_id) UPR_CATEGORY_ID="$val" ;;
      type_id) UPR_TYPE_ID="$val" ;;
      resolution_id) UPR_RESOLUTION_ID="$val" ;;
      tmdb) UPR_TMDB="$val" ;;
      imdb) UPR_IMDB="$val" ;;
      personal) UPR_PERSONAL="$val" ;;
      anonymous) UPR_ANON="$val" ;;
      season_number) UPR_SEASON="$val" ;;
      episode_number) UPR_EPISODE="$val" ;;
    esac
  done < "$UPLOAD_REQ_FILE"
  echo "Loaded upload request from: $UPLOAD_REQ_FILE"
  # Auto-detect companion description file if -d not specified
  if [[ -z "$DESC_FILE" ]]; then
    AUTO_DESC="${UPLOAD_REQ_FILE%_upload_request.txt}_torrent_description.txt"
    if [[ "$AUTO_DESC" != "$UPLOAD_REQ_FILE" && -f "$AUTO_DESC" ]]; then
      DESC_FILE="$AUTO_DESC"
      echo "Auto-detected description file: $DESC_FILE"
    fi
  fi
fi

if [[ -n "$NAME_FILE" && ! -f "$NAME_FILE" ]]; then
  echo -e "\e[31mError: name file '$NAME_FILE' not found\e[0m"
  exit 1
fi

if [[ -n "$DESC_FILE" && ! -f "$DESC_FILE" ]]; then
  echo -e "\e[31mError: description file '$DESC_FILE' not found\e[0m"
  exit 1
fi

if [[ -n "$MEDIAINFO_FILE" && ! -f "$MEDIAINFO_FILE" ]]; then
  echo -e "\e[31mError: mediainfo file '$MEDIAINFO_FILE' not found\e[0m"
  exit 1
fi

if [[ ! "$TORRENT_ID" =~ ^[0-9]+$ ]]; then
  echo -e "\e[31mError: torrent_id must be a number\e[0m"
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
USERNAME=$(json_val username "$CONFIG_FILE")
PASSWORD=$(json_val password "$CONFIG_FILE")

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
  echo -e "\e[31mError: 'username' and 'password' must be set in $CONFIG_FILE for editing\e[0m"
  exit 1
fi

# Web session helper: login and set COOKIE_JAR
COOKIE_JAR=$(mktemp)
TEMP_NAME=$(mktemp)
TEMP_DESC=$(mktemp)
trap "rm -f $COOKIE_JAR $TEMP_NAME $TEMP_DESC" EXIT
WEB_LOGGED_IN=0

web_login() {
  [[ "$WEB_LOGGED_IN" == "1" ]] && return
  echo "Logging in to ${TRACKER_URL}..."
  LOGIN_PAGE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" "${TRACKER_URL}/login")
  CSRF_TOKEN=$(echo "$LOGIN_PAGE" | grep -o 'name="_token"[[:space:]]*value="[^"]*"' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/')
  CAPTCHA=$(echo "$LOGIN_PAGE" | grep -o 'name="_captcha"[[:space:]]*value="[^"]*"' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/')
  RANDOM_FIELD=$(echo "$LOGIN_PAGE" | grep -oP 'name="([A-Za-z0-9]{16})"[[:space:]]*value="[0-9]+"' | head -1)
  RANDOM_NAME=$(echo "$RANDOM_FIELD" | sed 's/name="\([^"]*\)".*/\1/')
  RANDOM_VALUE=$(echo "$RANDOM_FIELD" | sed 's/.*value="\([^"]*\)".*/\1/')
  if [[ -z "$CSRF_TOKEN" ]]; then
    echo -e "\e[31mError: could not get CSRF token from login page\e[0m"
    exit 1
  fi
  LOGIN_HEADER=$(mktemp)
  curl -s -D "$LOGIN_HEADER" -o /dev/null -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -d "_token=${CSRF_TOKEN}" -d "_captcha=${CAPTCHA}" -d "_username=" \
    -d "username=${USERNAME}" --data-urlencode "password=${PASSWORD}" \
    -d "remember=on" ${RANDOM_NAME:+-d "${RANDOM_NAME}=${RANDOM_VALUE}"} \
    "${TRACKER_URL}/login"
  LOGIN_LOCATION=$(grep -i "^Location:" "$LOGIN_HEADER" 2>/dev/null | sed 's/Location:[[:space:]]*//' | tr -d '\r' || true)
  rm -f "$LOGIN_HEADER"
  if echo "$LOGIN_LOCATION" | grep -q "/login"; then
    echo -e "\e[31mError: login failed. Check username/password in config.\e[0m"
    exit 1
  fi
  echo "Logged in."
  curl -s -o /dev/null -c "$COOKIE_JAR" -b "$COOKIE_JAR" --max-time 15 "$LOGIN_LOCATION"
  WEB_LOGGED_IN=1
}

# Fetch current torrent data via API
echo "Fetching torrent #${TORRENT_ID}..."
API_URL="${TRACKER_URL}/api/torrents/${TORRENT_ID}?api_token=${API_KEY}"
FETCH_RESPONSE=$(curl -s -w "\n%{http_code}" "$API_URL")
HTTP_CODE=$(echo "$FETCH_RESPONSE" | tail -n 1)
BODY=$(echo "$FETCH_RESPONSE" | sed '$d')
JSON_FIELD="$SCRIPT_DIR/shared/json_field.pl"
WEB_FALLBACK=0

if [[ "$HTTP_CODE" == "200" ]]; then
  # Parse current values from API response
  API_BODY_FILE=$(mktemp)
  printf '%s' "$BODY" > "$API_BODY_FILE"
  CUR_NAME=$(perl "$JSON_FIELD" name "$API_BODY_FILE")
  CUR_CATEGORY_ID=$(perl "$JSON_FIELD" -n category_id "$API_BODY_FILE")
  CUR_TYPE_ID=$(perl "$JSON_FIELD" -n type_id "$API_BODY_FILE")
  CUR_RESOLUTION_ID=$(perl "$JSON_FIELD" -n resolution_id "$API_BODY_FILE")
  CUR_TMDB=$(perl "$JSON_FIELD" -n tmdb_id "$API_BODY_FILE")
  CUR_IMDB=$(perl "$JSON_FIELD" -n imdb_id "$API_BODY_FILE")
  CUR_SEASON=$(perl "$JSON_FIELD" -n season_number "$API_BODY_FILE" 2>/dev/null || echo "0")
  CUR_EPISODE=$(perl "$JSON_FIELD" -n episode_number "$API_BODY_FILE" 2>/dev/null || echo "0")
  [[ -z "$CUR_SEASON" ]] && CUR_SEASON=0
  [[ -z "$CUR_EPISODE" ]] && CUR_EPISODE=0
  CUR_PERSONAL=$(grep -q '"personal_release"[[:space:]]*:[[:space:]]*true' "$API_BODY_FILE" && echo 1 || echo 0)
  CUR_ANON=$(grep -q '"anon"[[:space:]]*:[[:space:]]*1\|"anonymous"[[:space:]]*:[[:space:]]*true' "$API_BODY_FILE" && echo 1 || echo 0)
  CUR_CATEGORY=$(perl "$JSON_FIELD" category "$API_BODY_FILE")
  CUR_TYPE=$(perl "$JSON_FIELD" type "$API_BODY_FILE")
  CUR_RESOLUTION=$(perl "$JSON_FIELD" resolution "$API_BODY_FILE")
  if [[ -n "$DESC_FILE" ]]; then
    CUR_DESC=$(cat "$DESC_FILE")
    echo "Using description from: $DESC_FILE"
  else
    CUR_DESC=$(perl "$JSON_FIELD" description "$API_BODY_FILE")
    CUR_DESC=$(printf '%s' "$CUR_DESC" | perl -CSD -pe 's,\x5C(\P{ASCII}),$1,g')
  fi
  if [[ -n "$MEDIAINFO_FILE" ]]; then
    CUR_MEDIAINFO=$(grep -v "^Encoding settings" "$MEDIAINFO_FILE")
    echo "Using mediainfo from: $MEDIAINFO_FILE"
  else
    CUR_MEDIAINFO=$(perl "$JSON_FIELD" media_info "$API_BODY_FILE" | grep -v "^Encoding settings")
  fi
  rm -f "$API_BODY_FILE"
else
  # API failed — fall back to web edit page
  echo "API fetch failed (HTTP $HTTP_CODE), falling back to web..."
  web_login
  echo "Fetching edit page..."
  EDIT_PAGE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" --max-time 30 "${TRACKER_URL}/torrents/${TORRENT_ID}/edit")
  FORM_TOKEN=$(echo "$EDIT_PAGE" | grep -o 'name="_token"[[:space:]]*value="[^"]*"' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/')
  if [[ -z "$FORM_TOKEN" ]]; then
    echo -e "\e[31mError: could not access edit page. Torrent may not exist or you lack permission.\e[0m"
    exit 1
  fi
  WEB_FALLBACK=1
  # Extract name from input field (value is on the next line), decode HTML entities
  CUR_NAME=$(echo "$EDIT_PAGE" | grep -A2 'name="name"' | sed -n 's/.*value="\(.*\)"/\1/p' | head -1)
  CUR_NAME=$(perl -CSD -pe 's/&#x([0-9a-fA-F]+);/chr(hex($1))/ge; s/&#(\d+);/chr($1)/ge; s/&amp;/&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g' <<< "$CUR_NAME")
  # Extract selected IDs from dropdowns
  CUR_CATEGORY_ID=$(echo "$EDIT_PAGE" | grep -A200 'name="category_id"' | grep -m1 'selected' | grep -o 'value="[0-9]*"' | sed 's/[^0-9]//g' || true)
  CUR_TYPE_ID=$(echo "$EDIT_PAGE" | grep -A200 'name="type_id"' | grep -m1 'selected' | grep -o 'value="[0-9]*"' | sed 's/[^0-9]//g' || true)
  CUR_RESOLUTION_ID=$(echo "$EDIT_PAGE" | grep -A200 'name="resolution_id"' | grep -B1 -m1 'selected' | grep -o 'value="[0-9]*"' | sed 's/[^0-9]//g' || true)
  # Extract TMDB/IMDB — use perl to find the visible input (with id=) value, skipping hidden inputs
  CUR_TMDB=$(printf '%s' "$EDIT_PAGE" | perl -0777 -ne 'print $1 if /id="tmdb_movie_id"[^>]*value="(\d+)"/' || true)
  [[ -z "$CUR_TMDB" || "$CUR_TMDB" == "0" ]] && CUR_TMDB=$(printf '%s' "$EDIT_PAGE" | perl -0777 -ne 'print $1 if /id="tmdb_tv_id"[^>]*value="(\d+)"/' || true)
  [[ -z "$CUR_TMDB" ]] && CUR_TMDB=0
  CUR_IMDB=$(printf '%s' "$EDIT_PAGE" | perl -0777 -ne 'print $1 if /id="imdb"[^>]*value="(\d+)"/' || true)
  CUR_SEASON=$(echo "$EDIT_PAGE" | grep -A5 'name="season_number"' | grep -o 'value="[^"]*"' | head -1 | sed 's/value="\([^"]*\)"/\1/' || true)
  CUR_EPISODE=$(echo "$EDIT_PAGE" | grep -A5 'name="episode_number"' | grep -o 'value="[^"]*"' | head -1 | sed 's/value="\([^"]*\)"/\1/' || true)
  [[ -z "$CUR_SEASON" ]] && CUR_SEASON=0
  [[ -z "$CUR_EPISODE" ]] && CUR_EPISODE=0
  # Extract personal/anonymous checkboxes (checked attribute present = enabled)
  CUR_PERSONAL=0
  echo "$EDIT_PAGE" | grep -A8 'id="personal_release"' | grep -q 'checked' && CUR_PERSONAL=1
  CUR_ANON=0
  echo "$EDIT_PAGE" | grep -A8 'id="anon"' | grep -q 'checked' && CUR_ANON=1
  CUR_CATEGORY="" CUR_TYPE="" CUR_RESOLUTION=""
  # Extract description from Livewire data (contentBbcode JSON field)
  if [[ -n "$DESC_FILE" ]]; then
    CUR_DESC=$(cat "$DESC_FILE")
    echo "Using description from: $DESC_FILE"
  else
    CUR_DESC=$(printf '%s' "$EDIT_PAGE" | perl "$SCRIPT_DIR/shared/extract_livewire_desc.pl")
  fi
  # Extract mediainfo from textarea
  if [[ -n "$MEDIAINFO_FILE" ]]; then
    CUR_MEDIAINFO=$(grep -v "^Encoding settings" "$MEDIAINFO_FILE")
    echo "Using mediainfo from: $MEDIAINFO_FILE"
  else
    CUR_MEDIAINFO=$(echo "$EDIT_PAGE" | sed -n '/name="mediainfo"/,/<\/textarea/p' | sed '1d;$d' | grep -v "^Encoding settings")
  fi
fi

echo ""
echo "Current values:"
echo "  name:          $CUR_NAME"
echo "  category:      $CUR_CATEGORY (id=$CUR_CATEGORY_ID)"
echo "  type:          $CUR_TYPE (id=$CUR_TYPE_ID)"
echo "  resolution:    $CUR_RESOLUTION (id=$CUR_RESOLUTION_ID)"
echo "  tmdb_id:       $CUR_TMDB"
echo "  imdb_id:       $CUR_IMDB"
echo "  season:        $CUR_SEASON"
echo "  episode:       $CUR_EPISODE"
echo "  personal:      $CUR_PERSONAL"
echo "  anonymous:     $CUR_ANON"
echo ""

# Interactive editing
if [[ -n "$NAME_FILE" ]]; then
  NEW_NAME=$(cat "$NAME_FILE")
  echo "Using name from: $NAME_FILE"
  echo "  -> $NEW_NAME"
elif [[ -n "$UPR_NAME" ]]; then
  NEW_NAME="$UPR_NAME"
  echo "Using name from upload request: $NEW_NAME"
else
  printf "Name [%s]: " "$CUR_NAME"
  NEW_NAME=$(perl -CSD -le 'my $l = <STDIN>; chomp $l; print $l')
  NEW_NAME="${NEW_NAME:-$CUR_NAME}"
fi

# Read categories and determine type for each
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

if [[ -n "$UPR_CATEGORY_ID" ]]; then
  NEW_CATEGORY_ID="$UPR_CATEGORY_ID"
  CAT_TYPE="movie"
  for i in "${!ALL_IDS[@]}"; do
    if [[ "${ALL_IDS[$i]}" == "$UPR_CATEGORY_ID" ]]; then
      CAT_TYPE="${ALL_TYPES[$i]}"
      echo "Category from upload request: ${ALL_NAMES[$i]} (category_id=$NEW_CATEGORY_ID, $CAT_TYPE)"
      break
    fi
  done
else
  echo ""
  echo "Select category:"
  DEFAULT_IDX=0
  for i in "${!ALL_NAMES[@]}"; do
    marker=""
    if [[ "${ALL_IDS[$i]}" == "$CUR_CATEGORY_ID" ]]; then
      marker=" *"
      DEFAULT_IDX=$i
    fi
    echo "  $((i+1))) ${ALL_NAMES[$i]} (id=${ALL_IDS[$i]}, ${ALL_TYPES[$i]})${marker}"
  done
  read -rp "Category [$(( DEFAULT_IDX + 1 ))]: " CAT_CHOICE
  CAT_CHOICE="${CAT_CHOICE//[^0-9]/}"
  if [[ -z "$CAT_CHOICE" ]]; then
    CAT_CHOICE=$(( DEFAULT_IDX + 1 ))
  fi
  CAT_IDX=$(( CAT_CHOICE - 1 ))
  if [[ $CAT_IDX -ge 0 && $CAT_IDX -lt ${#ALL_IDS[@]} ]]; then
    NEW_CATEGORY_ID="${ALL_IDS[$CAT_IDX]}"
    CAT_TYPE="${ALL_TYPES[$CAT_IDX]}"
    echo "Selected: ${ALL_NAMES[$CAT_IDX]} (category_id=$NEW_CATEGORY_ID, $CAT_TYPE)"
  else
    NEW_CATEGORY_ID="$CUR_CATEGORY_ID"
    CAT_TYPE="movie"
    for i in "${!ALL_IDS[@]}"; do
      if [[ "${ALL_IDS[$i]}" == "$CUR_CATEGORY_ID" ]]; then
        CAT_TYPE="${ALL_TYPES[$i]}"
        break
      fi
    done
    echo "Invalid choice, keeping: $CUR_CATEGORY"
  fi
fi

# Type picker
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

if [[ -n "$UPR_TYPE_ID" ]]; then
  NEW_TYPE_ID="$UPR_TYPE_ID"
  for i in "${!TYPE_IDS[@]}"; do
    if [[ "${TYPE_IDS[$i]}" == "$UPR_TYPE_ID" ]]; then
      echo "Type from upload request: ${TYPE_NAMES[$i]} (type_id=$NEW_TYPE_ID)"
      break
    fi
  done
else
  echo ""
  echo "Select type:"
  DEFAULT_IDX=0
  for i in "${!TYPE_NAMES[@]}"; do
    marker=""
    if [[ "${TYPE_IDS[$i]}" == "$CUR_TYPE_ID" ]]; then
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
    NEW_TYPE_ID="${TYPE_IDS[$TYPE_IDX]}"
    echo "Selected: ${TYPE_NAMES[$TYPE_IDX]} (type_id=$NEW_TYPE_ID)"
  else
    NEW_TYPE_ID="$CUR_TYPE_ID"
    echo "Invalid choice, keeping: $CUR_TYPE"
  fi
fi

# Resolution picker
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

if [[ -n "$UPR_RESOLUTION_ID" ]]; then
  NEW_RESOLUTION_ID="$UPR_RESOLUTION_ID"
  for i in "${!RES_IDS[@]}"; do
    if [[ "${RES_IDS[$i]}" == "$UPR_RESOLUTION_ID" ]]; then
      echo "Resolution from upload request: ${RES_NAMES[$i]} (resolution_id=$NEW_RESOLUTION_ID)"
      break
    fi
  done
else
  echo ""
  echo "Select resolution:"
  DEFAULT_IDX=0
  for i in "${!RES_NAMES[@]}"; do
    marker=""
    if [[ "${RES_IDS[$i]}" == "$CUR_RESOLUTION_ID" ]]; then
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
    NEW_RESOLUTION_ID="${RES_IDS[$RES_IDX]}"
    echo "Selected: ${RES_NAMES[$RES_IDX]} (resolution_id=$NEW_RESOLUTION_ID)"
  else
    NEW_RESOLUTION_ID="$CUR_RESOLUTION_ID"
    echo "Invalid choice, keeping: $CUR_RESOLUTION"
  fi
fi

if [[ -n "$UPLOAD_REQ_FILE" ]]; then
  NEW_TMDB="${UPR_TMDB:-$CUR_TMDB}"
  NEW_IMDB="${UPR_IMDB:-$CUR_IMDB}"
  NEW_SEASON="${UPR_SEASON:-$CUR_SEASON}"
  NEW_EPISODE="${UPR_EPISODE:-$CUR_EPISODE}"
  NEW_PERSONAL="${UPR_PERSONAL:-$CUR_PERSONAL}"
  NEW_ANON="${UPR_ANON:-$CUR_ANON}"
  echo "TMDB=$NEW_TMDB  IMDB=$NEW_IMDB  season=$NEW_SEASON  episode=$NEW_EPISODE  personal=$NEW_PERSONAL  anonymous=$NEW_ANON"
else
  echo ""
  read -rp "TMDB ID [$CUR_TMDB]: " NEW_TMDB
  NEW_TMDB="${NEW_TMDB:-$CUR_TMDB}"
  read -rp "IMDB ID [$CUR_IMDB]: " NEW_IMDB
  NEW_IMDB="${NEW_IMDB:-$CUR_IMDB}"
  if [[ "$CAT_TYPE" == "tv" ]]; then
    read -rp "Season [$CUR_SEASON]: " NEW_SEASON
    NEW_SEASON="${NEW_SEASON:-$CUR_SEASON}"
    read -rp "Episode [$CUR_EPISODE]: " NEW_EPISODE
    NEW_EPISODE="${NEW_EPISODE:-$CUR_EPISODE}"
  else
    NEW_SEASON="$CUR_SEASON"
    NEW_EPISODE="$CUR_EPISODE"
  fi
  read -rp "Personal release (0/1) [$CUR_PERSONAL]: " NEW_PERSONAL
  NEW_PERSONAL="${NEW_PERSONAL:-$CUR_PERSONAL}"
  read -rp "Anonymous (0/1) [$CUR_ANON]: " NEW_ANON
  NEW_ANON="${NEW_ANON:-$CUR_ANON}"
fi
echo ""

# Login and get CSRF token from edit page
web_login

if [[ "$WEB_FALLBACK" != "1" ]]; then
  echo "Fetching edit page..."
  EDIT_PAGE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" --max-time 30 "${TRACKER_URL}/torrents/${TORRENT_ID}/edit")
  FORM_TOKEN=$(echo "$EDIT_PAGE" | grep -o 'name="_token"[[:space:]]*value="[^"]*"' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/')
  if [[ -z "$FORM_TOKEN" ]]; then
    echo -e "\e[31mError: could not get _token from edit page. You may not have permission to edit this torrent.\e[0m"
    exit 1
  fi
  # If no explicit description provided, get from edit page (API may return incomplete version)
  if [[ -z "$DESC_FILE" ]]; then
    LV_DESC=$(printf '%s' "$EDIT_PAGE" | perl "$SCRIPT_DIR/shared/extract_livewire_desc.pl")
    if [[ -n "$LV_DESC" ]]; then
      CUR_DESC="$LV_DESC"
    fi
  fi
fi
# FORM_TOKEN is already set when WEB_FALLBACK=1

# Write fields to temp files to preserve special characters
perl -e 'use Encode; binmode STDOUT, ":raw"; print encode("UTF-8", decode("UTF-8", $ARGV[0]))' "$NEW_NAME" > "$TEMP_NAME"
printf '%s' "$CUR_DESC" > "$TEMP_DESC"
TEMP_MEDIAINFO=$(mktemp)
printf '%s' "$CUR_MEDIAINFO" > "$TEMP_MEDIAINFO"
TEMP_NAME_WIN=$(cygpath -w "$TEMP_NAME")
TEMP_DESC_WIN=$(cygpath -w "$TEMP_DESC")
TEMP_MEDIAINFO_WIN=$(cygpath -w "$TEMP_MEDIAINFO")

# Build TMDB/IMDB fields based on category type
# Only send *_exists_on_*=1 checkboxes when ID is non-zero (Laravel required_with validation)
EXTRA_FIELDS=()
if [[ "$CAT_TYPE" == "movie" ]]; then
  if [[ -n "$NEW_TMDB" && "$NEW_TMDB" != "0" ]]; then
    EXTRA_FIELDS+=(-F "movie_exists_on_tmdb=1" -F "tmdb_movie_id=${NEW_TMDB}")
  fi
elif [[ "$CAT_TYPE" == "tv" ]]; then
  if [[ -n "$NEW_TMDB" && "$NEW_TMDB" != "0" ]]; then
    EXTRA_FIELDS+=(-F "tv_exists_on_tmdb=1" -F "tmdb_tv_id=${NEW_TMDB}")
  fi
  EXTRA_FIELDS+=(-F "season_number=${NEW_SEASON}" -F "episode_number=${NEW_EPISODE}")
fi
if [[ -n "$NEW_IMDB" && "$NEW_IMDB" != "0" ]]; then
  EXTRA_FIELDS+=(-F "title_exists_on_imdb=1" -F "imdb=${NEW_IMDB}")
fi

# Step 3: POST torrent update with _method=PATCH
echo "Updating torrent #${TORRENT_ID}..."
HEADER_FILE=$(mktemp)
trap "rm -f $COOKIE_JAR $TEMP_NAME $TEMP_DESC $TEMP_MEDIAINFO $HEADER_FILE" EXIT

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -D "$HEADER_FILE" \
  -b "$COOKIE_JAR" \
  -X POST \
  -F "_token=${FORM_TOKEN}" \
  -F "_method=PATCH" \
  -F "name=<${TEMP_NAME_WIN}" \
  -F "description=<${TEMP_DESC_WIN}" \
  -F "mediainfo=<${TEMP_MEDIAINFO_WIN}" \
  -F "category_id=${NEW_CATEGORY_ID}" \
  -F "type_id=${NEW_TYPE_ID}" \
  -F "resolution_id=${NEW_RESOLUTION_ID}" \
  "${EXTRA_FIELDS[@]}" \
  -F "anon=${NEW_ANON}" \
  -F "personal_release=${NEW_PERSONAL}" \
  "${TRACKER_URL}/torrents/${TORRENT_ID}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
BODY=$(echo "$RESPONSE" | sed '$d')
LOCATION=$(grep -i "^Location:" "$HEADER_FILE" 2>/dev/null | sed 's/Location:[[:space:]]*//' | tr -d '\r' || true)

echo "HTTP status: $HTTP_CODE"
echo "Redirect: $LOCATION"
if [[ "$HTTP_CODE" == "302" ]]; then
  if echo "$LOCATION" | grep -q "/edit\|/login"; then
    echo -e "\e[31mError: update failed. Fetching error details...\e[0m"
    # Follow redirect to get validation error messages
    ERROR_PAGE=$(curl -s -L --max-time 15 -b "$COOKIE_JAR" "$LOCATION")
    # Extract Laravel validation errors from <li> tags
    ERRORS=$(echo "$ERROR_PAGE" | grep -oP '<li>[^<]+</li>' | sed 's/<[^>]*>//g' | head -10)
    if [[ -n "$ERRORS" ]]; then
      echo "$ERRORS"
    else
      echo "(Could not extract specific error messages)"
    fi
  else
    echo -e "\e[32mTorrent updated successfully.\e[0m"
  fi
elif [[ "$HTTP_CODE" == "200" ]]; then
  echo -e "\e[32mTorrent updated successfully.\e[0m"
elif [[ "$HTTP_CODE" == "403" ]]; then
  echo -e "\e[31mError: no permission to edit this torrent.\e[0m"
  echo "You can only edit your own torrents within 24h of upload, or be a moderator/editor."
elif [[ "$HTTP_CODE" == "419" ]]; then
  echo -e "\e[31mError: CSRF token expired or invalid.\e[0m"
else
  echo "Response:"
  echo "$BODY" | head -20
fi
