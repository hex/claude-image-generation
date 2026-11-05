#!/usr/bin/env bash
# ABOUTME: Retries a provider's default model once with a configured fallback when the API says the
# ABOUTME: model is unavailable to the key, and remembers that verdict per key for later runs.

# One fallback per provider, as "provider:fallback" tokens. Each id is in its provider's live model
# list, answered both the generate and edit requests, and has no announced shutdown. A fallback
# must be a different model from the default: a dated snapshot or alias of the default would
# re-send the request that just failed.
MODEL_FALLBACKS="gemini:gemini-nano-banana-2.1 openai:gpt-image-2.5-sunburst xai:grok-imagine-image openrouter:google/gemini-nano-banana-2.1"

# How long an "unavailable" verdict holds, in seconds. A retired model stays retired, but a model
# not yet enabled for a key or region can arrive within days. 0 stops runs reading verdicts.
IMAGE_AVAILABILITY_TTL="${IMAGE_AVAILABILITY_TTL:-86400}"
if [[ ! "$IMAGE_AVAILABILITY_TTL" =~ ^[0-9]+$ ]]; then
  echo "Error: IMAGE_AVAILABILITY_TTL must be a whole number of seconds, got '${IMAGE_AVAILABILITY_TTL}'" >&2
  exit 1
fi

# model_fallback_for_default <provider> — the model this run may fall back to: the provider's
# configured fallback, or nothing when <PROVIDER>_IMAGE_MODEL names the model. A model the person
# names is sent as named, so its failure reports that model instead of drawing with another one.
model_fallback_for_default() {
  local override_var token
  override_var="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_IMAGE_MODEL"
  [[ -z "${!override_var:-}" ]] || return 0
  for token in $MODEL_FALLBACKS; do
    if [[ "${token%%:*}" == "$1" ]]; then
      printf '%s' "${token#*:}"
      return 0
    fi
  done
}

__sha256_prefix() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-16
}

# __model_key_hash <provider> — a digest of the provider's API key. Whether a model is available
# depends on the key (its region and tier), so verdicts are kept per key without storing the key.
__model_key_hash() {
  local key_var
  key_var="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_API_KEY"
  printf '%s' "${!key_var:-}" | __sha256_prefix
}

# __model_verdict_file <provider> <model> <key hash> — the model id is hashed so an openrouter
# vendor/model slug stays a single file name.
__model_verdict_file() {
  printf '%s/claude-image-generation/model-verdicts/%s-%s-%s.json' \
    "${XDG_CACHE_HOME:-${HOME}/.cache}" "$1" "$(printf '%s' "$2" | __sha256_prefix)" "$3"
}

# model_unavailable_cached <provider> <model> <key hash> — true while a verdict that the model is
# unavailable to this key is younger than IMAGE_AVAILABILITY_TTL. A verdict whose timestamp cannot
# be read counts as stale, so the default model is tried again rather than aborting the run.
model_unavailable_cached() {
  local file checked_at
  file=$(__model_verdict_file "$1" "$2" "$3")
  [[ -f "$file" ]] || return 1
  checked_at=$(jq -r '.checked_at // 0' "$file" 2>/dev/null) || checked_at=0
  [[ "$checked_at" =~ ^[0-9]+$ ]] || checked_at=0
  [[ $(( $(date +%s) - checked_at )) -lt $IMAGE_AVAILABILITY_TTL ]]
}

# model_unavailable_remember <provider> <model> <key hash> — records the verdict through a temp
# file and a rename, so a provider running alongside reads a whole verdict or none.
model_unavailable_remember() {
  local file tmp
  file=$(__model_verdict_file "$1" "$2" "$3")
  mkdir -p "$(dirname "$file")" || return 1
  tmp="${file}.$$"
  jq -n --arg p "$1" --arg m "$2" --argjson t "$(date +%s)" \
    '{provider: $p, model: $m, checked_at: $t}' > "$tmp" && mv -f "$tmp" "$file" \
    || { rm -f "$tmp"; return 1; }
}

# __api_message <body> — the error message in a provider's error body: .error is an object for
# gemini, openai and openrouter, and a bare string for xai.
__api_message() {
  jq -r 'if (.error | type) == "object" then (.error.message // "")
         elif (.error | type) == "string" then .error else "" end' <<<"$1" 2>/dev/null
}

# model_unavailable_response <provider> <http code> <body> — true when the answer says the model
# itself is out of reach of this key: unknown, retired, or not enabled for it. That is the one
# failure a different model can fix; a bad key, a bad parameter, a refused prompt, a rate limit or
# a server error would fail the same way on the fallback.
model_unavailable_response() {
  local msg
  case "$2" in
    404) return 0 ;;
    # OpenRouter answers 403 for a prompt its moderation flagged, which no other model fixes.
    403) [[ "$1" == openrouter ]] && return 1; return 0 ;;
    400) ;;
    *) return 1 ;;
  esac
  # A 400 also covers ordinary bad parameters and bad keys, so only a message that names the
  # model and says it is unknown qualifies. "not supported" is left out on purpose: a parameter
  # one model lacks is reported as "... is not supported with the '<model>' model".
  msg=$(__api_message "$3" | tr '[:upper:]' '[:lower:]') || return 1
  case "$msg" in
    *model*) ;;
    *) return 1 ;;
  esac
  case "$msg" in
    *"does not exist"*|*"not a valid model"*|*"model not found"*|*"model_not_found"*|\
    *"invalid model"*|*"no access to model"*) return 0 ;;
    *) return 1 ;;
  esac
}

# use_remembered_fallback — when the default model is remembered as unavailable to this key,
# switches MODEL to FALLBACK_MODEL before the first request, so the run does not spend a request
# that would fail again. Call it before the provider announces its model.
use_remembered_fallback() {
  [[ -n "$FALLBACK_MODEL" ]] || return 0
  model_unavailable_cached "$PROVIDER_NAME" "$MODEL" "$(__model_key_hash "$PROVIDER_NAME")" || return 0
  echo "${MODEL} is remembered as unavailable to this key; drawing with fallback ${FALLBACK_MODEL}" >&2
  MODEL="$FALLBACK_MODEL"
  FALLBACK_MODEL=""
}

# request_with_model_fallback <send> — runs `<send> <model>`, which sends the request for that
# model and prints curl_with_retry's output (body, newline, status), and leaves the output in
# RESPONSE. When the answer says MODEL is unavailable and FALLBACK_MODEL is set, MODEL becomes the
# fallback and the request goes once more. The verdict is remembered only when the fallback
# answers 200: a refusal that covers the whole account fails both models, and must not be pinned
# on the default for a day.
request_with_model_fallback() {
  local send="$1" preferred="$MODEL" code body
  RESPONSE=$("$send" "$MODEL")
  [[ -n "$FALLBACK_MODEL" ]] || return 0
  code="${RESPONSE##*$'\n'}"
  body="${RESPONSE%$'\n'*}"
  model_unavailable_response "$PROVIDER_NAME" "$code" "$body" || return 0

  echo "${MODEL} is unavailable to this key (HTTP ${code}: $(__api_message "$body")); drawing with fallback ${FALLBACK_MODEL}" >&2
  MODEL="$FALLBACK_MODEL"
  FALLBACK_MODEL=""
  if [[ -n "${DISPLAY_PANE_DIR:-}" && -d "${DISPLAY_PANE_DIR:-}" ]]; then
    display_pane_status "$PROVIDER_NAME" querying "" "$MODEL"
  fi
  RESPONSE=$("$send" "$MODEL")
  [[ "${RESPONSE##*$'\n'}" == 200 ]] || return 0
  model_unavailable_remember "$PROVIDER_NAME" "$preferred" "$(__model_key_hash "$PROVIDER_NAME")" \
    || echo "warning: could not record that ${preferred} is unavailable; the next run will try it first again" >&2
}
