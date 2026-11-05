#!/usr/bin/env bash
# ABOUTME: Reports per image provider whether its API key is set and accepted, and whether
# ABOUTME: the model its script would use is in the provider's live model list. GET requests only.

set -euo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required to read the providers' answers"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Response bodies land here. OpenAI's 401 body quotes part of the key, so none is printed and
# the folder goes on exit. A bare mktemp -d ignores TMPDIR on macOS, hence the template.
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/image-status.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

# provider_spec <provider> — sets what one provider's check needs: the key variables in the
# order its script reads them, the auth header prefix, the URL that proves the key, the model
# list URL when that is a different one, and jq filters over the answers. REJECTED reads a 400
# body: Gemini and xAI answer a bad key with 400, which they also use for unrelated faults.
provider_spec() {
  case "$1" in
    gemini)
      KEY_VARS="GEMINI_API_KEY"
      AUTH="x-goog-api-key: "
      KEY_URL="https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"
      LIST_URL=""
      REJECTED='any(.error.details[]?; .reason == "API_KEY_INVALID")'
      LISTED='if any(.models[]; .name == "models/" + $model) then "yes"
              elif .nextPageToken then "unknown (list has more pages)" else "no" end'
      ;;
    openai)
      KEY_VARS="OPENAI_API_KEY"
      AUTH="Authorization: Bearer "
      KEY_URL="https://api.openai.com/v1/models"
      LIST_URL=""
      REJECTED='false'
      LISTED='if any(.data[]; .id == $model) then "yes" else "no" end'
      ;;
    xai)
      KEY_VARS="XAI_API_KEY GROK_API_KEY"
      AUTH="Authorization: Bearer "
      KEY_URL="https://api.x.ai/v1/image-generation-models"
      LIST_URL=""
      REJECTED='.code == "invalid-argument" and (.error | ascii_downcase | contains("api key"))'
      LISTED='if any(.models[]; .id == $model or any(.aliases[]?; . == $model)) then "yes" else "no" end'
      ;;
    openrouter)
      # The model list answers without a key, so the key is proven against /key first.
      KEY_VARS="OPENROUTER_API_KEY"
      AUTH="Authorization: Bearer "
      KEY_URL="https://openrouter.ai/api/v1/key"
      LIST_URL="https://openrouter.ai/api/v1/models"
      REJECTED='false'
      LISTED='if any(.data[]; .id == $model and any(.architecture.output_modalities[]?; . == "image"))
              then "yes" else "no" end'
      ;;
  esac
}

# configured_model <provider> — sets MODEL and MODEL_SOURCE from the provider script's own
# MODEL="${VAR:-default}" line, so this check reports the model that script would send.
configured_model() {
  local script="$1.sh" pattern='^MODEL="\$\{([A-Z_]+):-([^}]+)\}"$' line var
  if ! line=$(grep -E "$pattern" "${SCRIPT_DIR}/${script}") || ! [[ "$line" =~ $pattern ]]; then
    die "${script} has no MODEL=\"\${<VARIABLE>:-<default>}\" line to read its model from"
  fi
  var="${BASH_REMATCH[1]}"
  MODEL="${!var:-${BASH_REMATCH[2]}}"
  MODEL_SOURCE=""
  if [[ -n "${!var:-}" ]]; then
    MODEL_SOURCE=" (${var})"
  fi
}

# fetch <url> <header> <body file> — prints the HTTP status, or "curl exit <n>" when no answer
# came back. The header reaches curl on stdin so the key never shows in the process list.
fetch() {
  local code
  if code=$(printf '%s\n' "$2" | curl -s -o "$3" -w '%{http_code}' --max-time 15 -H @- "$1"); then
    echo "$code"
  else
    echo "curl exit $?"
  fi
}

# classify_key <fetch result> <body file>
classify_key() {
  case "$1" in
    200) echo "accepted" ;;
    401|403) echo "rejected (HTTP $1)" ;;
    400)
      if jq -e "try (${REJECTED}) catch false" "$2" >/dev/null 2>&1; then
        echo "rejected (HTTP 400)"
      else
        echo "unexpected HTTP 400"
      fi
      ;;
    "curl exit "*) echo "no answer ($1)" ;;
    *) echo "unexpected HTTP $1" ;;
  esac
}

# classify_listing <fetch result> <body file>
classify_listing() {
  case "$1" in
    200) jq -r --arg model "$MODEL" "$LISTED" "$2" 2>/dev/null || echo "unreadable model list" ;;
    "curl exit "*) echo "no answer ($1)" ;;
    *) echo "unexpected HTTP $1" ;;
  esac
}

ROW_PROVIDER=("provider")
ROW_KEY=("key")
ROW_LISTED=("model listed")
ROW_MODEL=("model")

check_provider() {
  local provider="$1" body="${TMP_DIR}/$1.json" key="" var result key_state listed="not checked"
  provider_spec "$provider"
  configured_model "$provider"
  for var in $KEY_VARS; do
    if [[ -n "${!var:-}" ]]; then
      key="${!var}"
      break
    fi
  done

  if [[ -z "$key" ]]; then
    key_state="not set (${KEY_VARS%% *})"
  else
    result=$(fetch "$KEY_URL" "${AUTH}${key}" "$body")
    key_state=$(classify_key "$result" "$body")
    if [[ "$key_state" == "accepted" ]]; then
      if [[ -n "$LIST_URL" ]]; then
        result=$(fetch "$LIST_URL" "${AUTH}${key}" "$body")
      fi
      listed=$(classify_listing "$result" "$body")
    fi
  fi

  ROW_PROVIDER+=("$provider")
  ROW_KEY+=("$key_state")
  ROW_LISTED+=("$listed")
  ROW_MODEL+=("${MODEL}${MODEL_SOURCE}")
}

# width <value>... — the length of the longest value.
width() {
  local w=0 v
  for v in "$@"; do
    if (( ${#v} > w )); then
      w=${#v}
    fi
  done
  echo "$w"
}

for provider in gemini openai xai openrouter; do
  check_provider "$provider"
done

provider_w=$(width "${ROW_PROVIDER[@]}")
key_w=$(width "${ROW_KEY[@]}")
listed_w=$(width "${ROW_LISTED[@]}")
for i in "${!ROW_PROVIDER[@]}"; do
  printf '%-*s  %-*s  %-*s  %s\n' "$provider_w" "${ROW_PROVIDER[$i]}" "$key_w" "${ROW_KEY[$i]}" \
    "$listed_w" "${ROW_LISTED[$i]}" "${ROW_MODEL[$i]}"
done
