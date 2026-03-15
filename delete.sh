#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <torrent_id> [config.jsonc]

Delete a torrent from a UNIT3D tracker by its ID.
Fetches torrent info via API, asks for confirmation, then deletes via web session.

Requires "username" and "password" in config.jsonc.

Arguments:
  torrent_id       Numeric torrent ID to delete
  config.jsonc     Path to JSONC config file (default: ./config.jsonc)

Options:
  -f, --force    Skip API fetch and delete without confirmation
  -h, --help     Show this help message
EOF
  exit 0
}

# Simple JSON value reader (no jq needed)
json_val() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

POSITIONAL=()
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -f|--force) FORCE=1; shift ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { echo -e "\e[31mError: torrent_id argument required\e[0m"; usage; }

TORRENT_ID="${POSITIONAL[0]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${POSITIONAL[1]:-./config.jsonc}"

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
  echo -e "\e[31mError: 'username' and 'password' must be set in $CONFIG_FILE for deleting\e[0m"
  exit 1
fi

CUR_NAME="Torrent #${TORRENT_ID}"
DELETE_REASON="Deleted by uploader"

if [[ "$FORCE" == "1" ]]; then
  echo "Force mode: skipping fetch, deleting torrent #${TORRENT_ID}..."
else
  # Fetch current torrent data via API
  echo "Fetching torrent #${TORRENT_ID}..."
  API_URL="${TRACKER_URL}/api/torrents/${TORRENT_ID}?api_token=${API_KEY}"
  FETCH_RESPONSE=$(curl -s -w "\n%{http_code}" "$API_URL")
  HTTP_CODE=$(echo "$FETCH_RESPONSE" | tail -n 1)
  BODY=$(echo "$FETCH_RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" == "404" ]]; then
    echo -e "\e[31mError: torrent #${TORRENT_ID} not found.\e[0m"
    exit 1
  elif [[ "$HTTP_CODE" != "200" ]]; then
    echo -e "\e[31mError: failed to fetch torrent (HTTP $HTTP_CODE)\e[0m"
    exit 1
  fi

  # Parse torrent info for confirmation
  API_BODY_FILE=$(mktemp)
  printf '%s' "$BODY" > "$API_BODY_FILE"
  JSON_FIELD="$SCRIPT_DIR/shared/json_field.pl"

  CUR_NAME=$(perl "$JSON_FIELD" name "$API_BODY_FILE")
  CUR_CATEGORY=$(perl "$JSON_FIELD" category "$API_BODY_FILE")
  CUR_TYPE=$(perl "$JSON_FIELD" type "$API_BODY_FILE")
  CUR_RESOLUTION=$(perl "$JSON_FIELD" resolution "$API_BODY_FILE")
  rm -f "$API_BODY_FILE"

  echo ""
  echo "Torrent to delete:"
  echo "  name:          $CUR_NAME"
  echo "  category:      $CUR_CATEGORY"
  echo "  type:          $CUR_TYPE"
  echo "  resolution:    $CUR_RESOLUTION"
  echo ""
  read -rp "Are you sure you want to DELETE this torrent? (yes/no): " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
  read -rp "Reason for deletion: " DELETE_REASON
  if [[ -z "$DELETE_REASON" ]]; then
    DELETE_REASON="Deleted by uploader"
  fi
fi

# Web session login
COOKIE_JAR=$(mktemp)
trap "rm -f $COOKIE_JAR" EXIT

echo ""
echo "Logging in to ${TRACKER_URL}..."

# Step 1: GET /login to get CSRF token, captcha, and hidden anti-bot fields
LOGIN_PAGE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" "${TRACKER_URL}/login")
CSRF_TOKEN=$(echo "$LOGIN_PAGE" | grep -o 'name="_token"[[:space:]]*value="[^"]*"' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/')
CAPTCHA=$(echo "$LOGIN_PAGE" | grep -o 'name="_captcha"[[:space:]]*value="[^"]*"' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/')
# Extract random-named hidden timestamp field (16-char alphanumeric name, numeric value)
RANDOM_FIELD=$(echo "$LOGIN_PAGE" | grep -oP 'name="([A-Za-z0-9]{16})"[[:space:]]*value="[0-9]+"' | head -1)
RANDOM_NAME=$(echo "$RANDOM_FIELD" | sed 's/name="\([^"]*\)".*/\1/')
RANDOM_VALUE=$(echo "$RANDOM_FIELD" | sed 's/.*value="\([^"]*\)".*/\1/')

if [[ -z "$CSRF_TOKEN" ]]; then
  echo -e "\e[31mError: could not get CSRF token from login page\e[0m"
  exit 1
fi

# Step 2: POST /login with all anti-bot fields
LOGIN_HEADER=$(mktemp)
curl -s -D "$LOGIN_HEADER" -o /dev/null -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -d "_token=${CSRF_TOKEN}" \
  -d "_captcha=${CAPTCHA}" \
  -d "_username=" \
  -d "username=${USERNAME}" \
  --data-urlencode "password=${PASSWORD}" \
  -d "remember=on" \
  ${RANDOM_NAME:+-d "${RANDOM_NAME}=${RANDOM_VALUE}"} \
  "${TRACKER_URL}/login"

LOGIN_LOCATION=$(grep -i "^Location:" "$LOGIN_HEADER" 2>/dev/null | sed 's/Location:[[:space:]]*//' | tr -d '\r' || true)
rm -f "$LOGIN_HEADER"

if echo "$LOGIN_LOCATION" | grep -q "/login"; then
  echo -e "\e[31mError: login failed. Check username/password in config.\e[0m"
  exit 1
fi
echo "Logged in. Redirect: $LOGIN_LOCATION"

# Follow the redirect to finalize session
curl -s -o /dev/null -c "$COOKIE_JAR" -b "$COOKIE_JAR" --max-time 15 "$LOGIN_LOCATION"

# Step 3: GET torrent page to get _token for CSRF
echo "Fetching CSRF token..."
TORRENT_PAGE=$(curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" --max-time 30 "${TRACKER_URL}/torrents/${TORRENT_ID}")
FORM_TOKEN=$(echo "$TORRENT_PAGE" | grep -o 'name="_token"[[:space:]]*value="[^"]*"' | head -1 | sed 's/.*value="\([^"]*\)".*/\1/')

if [[ -z "$FORM_TOKEN" ]]; then
  echo -e "\e[31mError: could not get _token from torrent page. You may not have permission to delete this torrent.\e[0m"
  exit 1
fi

# Step 4: POST with _method=DELETE (requires type, id, title, message fields)
echo "Deleting torrent #${TORRENT_ID}..."
HEADER_FILE=$(mktemp)
TEMP_NAME=$(mktemp)
trap "rm -f $COOKIE_JAR $HEADER_FILE $TEMP_NAME" EXIT

# Write name to temp file to preserve special characters
printf '%s' "$CUR_NAME" > "$TEMP_NAME"
TEMP_NAME_WIN=$(cygpath -w "$TEMP_NAME")

RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 30 \
  -D "$HEADER_FILE" \
  -b "$COOKIE_JAR" \
  -X POST \
  -F "_token=${FORM_TOKEN}" \
  -F "_method=DELETE" \
  -F "type=Torrent" \
  -F "id=${TORRENT_ID}" \
  -F "title=<${TEMP_NAME_WIN}" \
  --form-string "message=${DELETE_REASON}" \
  "${TRACKER_URL}/torrents/${TORRENT_ID}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
BODY=$(echo "$RESPONSE" | sed '$d')
LOCATION=$(grep -i "^Location:" "$HEADER_FILE" 2>/dev/null | sed 's/Location:[[:space:]]*//' | tr -d '\r' || true)

echo "HTTP status: $HTTP_CODE"
[[ -n "$LOCATION" ]] && echo "Redirect: $LOCATION"
if [[ "$HTTP_CODE" == "302" ]]; then
  if echo "$LOCATION" | grep -q "/login"; then
    echo -e "\e[31mError: session expired. Please try again.\e[0m"
  elif echo "$LOCATION" | grep -q "/torrents/${TORRENT_ID}"; then
    echo -e "\e[31mError: delete failed (redirected back to torrent page).\e[0m"
  else
    echo -e "\e[32mTorrent deleted successfully.\e[0m"
  fi
elif [[ "$HTTP_CODE" == "200" ]]; then
  echo -e "\e[32mTorrent deleted successfully.\e[0m"
elif [[ "$HTTP_CODE" == "403" ]]; then
  echo -e "\e[31mError: no permission to delete this torrent.\e[0m"
  ERROR_TITLE=$(echo "$BODY" | grep -oP '<title>[^<]+</title>' | sed 's/<[^>]*>//g')
  [[ -n "$ERROR_TITLE" ]] && echo "  $ERROR_TITLE"
elif [[ "$HTTP_CODE" == "419" ]]; then
  echo -e "\e[31mError: CSRF token expired or invalid.\e[0m"
else
  ERROR_TITLE=$(echo "$BODY" | grep -oP '<title>[^<]+</title>' | sed 's/<[^>]*>//g')
  ERROR_MSG=$(echo "$BODY" | grep -oP 'class="error__body">[^<]+<' | sed 's/class="error__body">//;s/<$//')
  echo -e "\e[31mError: ${ERROR_TITLE:-unexpected response}\e[0m"
  [[ -n "$ERROR_MSG" ]] && echo "  $ERROR_MSG"
fi
