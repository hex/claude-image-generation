#!/usr/bin/env bash
# ABOUTME: Generates or edits images using OpenRouter as a model-flexible gateway.
# ABOUTME: Uses the chat-completions endpoint with image output modalities.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"
source "${SCRIPT_DIR}/retry.sh"

readonly PROVIDER_NAME="openrouter"

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output <path> [options]

OpenRouter is a gateway: --model accepts any OpenRouter model slug that supports
image output (e.g. google/gemini-3.1-flash-image, openai/gpt-5-image).

Options:
  --mode              generate or edit (required)
  --prompt            Text prompt describing the image (required)
  --output            Output file path (required)
  --input-image       Input image path for edit mode (required for edit, repeatable)
  --model             OpenRouter model slug (default: google/gemini-3.1-flash-image)
  --site-url          Sent as HTTP-Referer for OpenRouter attribution (optional)
  --site-name         Sent as X-Title for OpenRouter attribution (optional)

Environment:
  OPENROUTER_API_KEY     OpenRouter API key (required)
  OPENROUTER_IMAGE_MODEL Override default model
  OPENROUTER_SITE_URL    Default --site-url
  OPENROUTER_SITE_NAME   Default --site-name
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT=""
INPUT_IMAGES=()
MODEL="${OPENROUTER_IMAGE_MODEL:-google/gemini-3.1-flash-image}"
SITE_URL="${OPENROUTER_SITE_URL:-}"
SITE_NAME="${OPENROUTER_SITE_NAME:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --input-image) INPUT_IMAGES+=("$2"); shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --site-url) SITE_URL="$2"; shift 2 ;;
    --site-name) SITE_NAME="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$MODE" || -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "Error: --mode, --prompt, and --output are required" >&2
  usage
fi

case "$MODE" in
  generate|edit) ;;
  *) echo "Error: --mode must be 'generate' or 'edit'" >&2; exit 1 ;;
esac

if [[ "$MODE" == "edit" && ${#INPUT_IMAGES[@]} -eq 0 ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "Error: OPENROUTER_API_KEY environment variable is not set" >&2
  exit 1
fi

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

# OpenRouter does image generation through chat completions: the user message
# holds the prompt (and, in edit mode, one image_url part per input image as a
# base64 data URL), and the model returns images in message.images[].
build_request_body() {
  local content

  if [[ ${#INPUT_IMAGES[@]} -gt 0 ]]; then
    content="[]"
    local img mime_type data_url_file
    for img in "${INPUT_IMAGES[@]}"; do
      case "${img##*.}" in
        png) mime_type="image/png" ;;
        jpg|jpeg) mime_type="image/jpeg" ;;
        webp) mime_type="image/webp" ;;
        gif) mime_type="image/gif" ;;
        *) mime_type="image/png" ;;
      esac
      # A normal image exceeds ARG_MAX, so the base64 payload is streamed into jq
      # via --rawfile rather than passed as an argument (mirrors gemini.sh). The
      # data: prefix is prepended into the same file so jq embeds a complete URL.
      data_url_file=$(mktemp -p "$tmpdir")
      printf 'data:%s;base64,' "$mime_type" > "$data_url_file"
      base64 < "$img" | tr -d '\n' >> "$data_url_file"
      content=$(echo "$content" | jq --rawfile url "$data_url_file" \
        '. + [{"type": "image_url", "image_url": {"url": $url}}]')
    done
    content=$(echo "$content" | jq --arg prompt "$PROMPT" \
      '[{"type": "text", "text": $prompt}] + .')
  else
    # Generate mode: a plain string content keeps the body small enough to pass
    # inline, but we still build it with jq for correct escaping.
    content=$(jq -n --arg prompt "$PROMPT" '$prompt')
  fi

  # content can hold a multi-megabyte base64 image, so it enters jq on stdin as
  # the main input rather than as --argjson, which would exceed ARG_MAX.
  echo "$content" | jq \
    --arg model "$MODEL" \
    '{
      "model": $model,
      "modalities": ["image", "text"],
      "messages": [{"role": "user", "content": .}]
    }'
}

if [[ ${#INPUT_IMAGES[@]} -gt 0 ]]; then
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
fi
REQUEST_BODY=$(build_request_body)

echo "Calling OpenRouter API (model: ${MODEL}, mode: ${MODE})..." >&2
display_pane_begin "$PROVIDER_NAME" "$MODEL"

CURL_HEADERS=(-H "Content-Type: application/json" -H "Authorization: Bearer ${OPENROUTER_API_KEY}")
[[ -n "$SITE_URL" ]] && CURL_HEADERS+=(-H "HTTP-Referer: ${SITE_URL}")
[[ -n "$SITE_NAME" ]] && CURL_HEADERS+=(-H "X-Title: ${SITE_NAME}")

# The body embeds the base64 image in edit mode, so it is streamed to curl on
# stdin (--data-binary @-) instead of passed as -d, which would exceed ARG_MAX.
RESPONSE=$(printf '%s' "$REQUEST_BODY" | curl_with_retry -s -w "\n%{http_code}" \
  -X POST "https://openrouter.ai/api/v1/chat/completions" \
  "${CURL_HEADERS[@]}" \
  --data-binary @-)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  api_msg=$(echo "$BODY" | jq -r '.error.message // .error // .' 2>/dev/null || echo "$BODY")
  provider_die "OpenRouter API returned HTTP ${HTTP_CODE}: ${api_msg}"
fi

DATA_URL=$(echo "$BODY" | jq -r '.choices[0].message.images[0].image_url.url // empty')

if [[ -z "$DATA_URL" ]]; then
  # A mid-generation upstream failure arrives as HTTP 200 with the error on the
  # choice, not at the top level, so it is named here rather than dumped as a body.
  CHOICE_ERROR=$(echo "$BODY" | jq -r '
    (.choices[0].error)? // empty
    | select(type == "object")
    | "(" + ((.code // "?") | tostring) + "): " + ((.message // "") | tostring)' 2>/dev/null || true)
  if [[ -n "$CHOICE_ERROR" ]]; then
    provider_die "OpenRouter provider error ${CHOICE_ERROR}"
  fi
  TEXT_RESPONSE=$(echo "$BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
  if [[ -n "$TEXT_RESPONSE" ]]; then
    provider_die "No image data in response. Model said: ${TEXT_RESPONSE}"
  fi
  provider_die "No image data in response: $(echo "$BODY" | jq -c '.' 2>/dev/null || echo "$BODY")"
fi

# Strip the "data:<mime>;base64," prefix, leaving raw base64 to decode.
IMAGE_DATA="${DATA_URL#data:*;base64,}"

if [[ "$IMAGE_DATA" == "$DATA_URL" ]]; then
  provider_die "Unexpected image URL format (not a base64 data URL): ${DATA_URL:0:64}..."
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "$IMAGE_DATA" | base64 -D > "$OUTPUT"
else
  echo "$IMAGE_DATA" | base64 -d > "$OUTPUT"
fi

echo "Image saved to: ${OUTPUT}" >&2
echo "Model: ${MODEL}" >&2

provider_finish "$OUTPUT"

echo "$OUTPUT"
