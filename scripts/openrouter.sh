#!/usr/bin/env bash
# ABOUTME: Generates or edits images using OpenRouter as a model-flexible gateway.
# ABOUTME: Uses chat completions, and the images endpoint for a model chat completions turns away.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"
source "${SCRIPT_DIR}/retry.sh"
source "${SCRIPT_DIR}/input-images.sh"
source "${SCRIPT_DIR}/output-image.sh"
source "${SCRIPT_DIR}/model-fallback.sh"
source "${SCRIPT_DIR}/aspect-ratios.sh"

readonly PROVIDER_NAME="openrouter"

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output <path> [options]

OpenRouter is a gateway: --model accepts any OpenRouter model slug that supports
image output (e.g. google/gemini-3.1-flash-image, google/gemini-3-pro-image).
Every request goes to chat completions first. When that answers HTTP 404 saying the
model is served only on OpenRouter's images endpoint (e.g. openai/gpt-image-2), the
same request goes to the images endpoint once.

Options:
  --mode              generate or edit (required)
  --prompt            Text prompt describing the image (required)
  --output            Output file path (required)
  --input-image       Input image path (required for edit, repeatable; also sent in generate)
  --model             OpenRouter model slug (default: google/gemini-nano-banana-2.1)
  --aspect-ratio      Aspect ratio, sent as image_config.aspect_ratio on chat completions and
                      aspect_ratio on the images endpoint. For google/ and x-ai/ models one the
                      model does not draw is refused before the request; any other model gets it
                      unchecked
  --size-tier         Size tier: 1K, 2K or 4K, sent as image_config.image_size on chat
                      completions and resolution on the images endpoint; x-ai/ models draw 2K
                      for 4K
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
MODEL="${OPENROUTER_IMAGE_MODEL:-google/gemini-nano-banana-2.1}"
ASPECT_RATIO=""
SIZE_TIER=""
FALLBACK_MODEL=$(model_fallback_for_default "$PROVIDER_NAME")
SITE_URL="${OPENROUTER_SITE_URL:-}"
SITE_NAME="${OPENROUTER_SITE_NAME:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --input-image) INPUT_IMAGES+=("$2"); shift 2 ;;
    --model) MODEL="$2"; FALLBACK_MODEL=""; shift 2 ;;
    --aspect-ratio) ASPECT_RATIO="$2"; shift 2 ;;
    --size-tier) SIZE_TIER="$2"; shift 2 ;;
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

if [[ -n "$SIZE_TIER" ]]; then
  case "$SIZE_TIER" in
    1K|2K|4K) ;;
    *) echo "Error: --size-tier must be 1K, 2K or 4K, got '${SIZE_TIER}'" >&2; exit 1 ;;
  esac
fi

if [[ "$MODE" == "edit" && ${#INPUT_IMAGES[@]} -eq 0 ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "Error: OPENROUTER_API_KEY environment variable is not set" >&2
  exit 1
fi

refuse_existing_output "$OUTPUT"
snapshot_input_images

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

# build_image_parts — prints a JSON array holding one image_url part per input image, its url a
# base64 data URL, or [] without input images. Chat completions takes these parts in the user
# message and the images endpoint as input_references, in the same shape.
build_image_parts() {
  local parts="[]" i data_url_file
  for i in "${!INPUT_IMAGES[@]}"; do
    # A normal image exceeds ARG_MAX, so the base64 payload is streamed into jq
    # via --rawfile rather than passed as an argument (mirrors gemini.sh). The
    # data: prefix is prepended into the same file so jq embeds a complete URL.
    data_url_file=$(mktemp -p "$tmpdir")
    printf 'data:%s;base64,' "${INPUT_MIMES[$i]}" > "$data_url_file"
    base64 < "${INPUT_IMAGES[$i]}" | tr -d '\n' >> "$data_url_file"
    parts=$(echo "$parts" | jq --rawfile url "$data_url_file" \
      '. + [{"type": "image_url", "image_url": {"url": $url}}]')
  done
  echo "$parts"
}

# Built once: each body names its model when it is sent, so a fallback reuses the parts.
IMAGE_PARTS=$(build_image_parts)

# Chat completions: the user message is the prompt alone, or a text part followed by the image
# parts, and the model returns images in message.images[].
readonly CHAT_BODY='{
  "model": $model,
  "modalities": ["image", "text"],
  "messages": [{"role": "user", "content": (if length > 0 then [{"type": "text", "text": $prompt}] + . else $prompt end)}]
} + (if $shape == {} then {} else {"image_config": ($shape | with_entries(.key |= if . == "size" then "image_size" else . end))} end)'

# The images endpoint: the prompt, and the image parts as input_references to edit or guide. The
# image comes back as base64 in data[].b64_json.
readonly IMAGES_BODY='{"model": $model, "prompt": $prompt, "response_format": "b64_json"}
  + (if length > 0 then {"input_references": .} else {} end)
  + ($shape | with_entries(.key |= if . == "size" then "resolution" else . end))'

# model_aspect_ratios <model> — prints the ratios <model> draws, for the vendors whose own scripts
# know their models, or nothing for any other model.
model_aspect_ratios() {
  case "$1" in
    google/*) gemini_aspect_ratios "${1#google/}" ;;
    x-ai/*) xai_aspect_ratios "${1#x-ai/}" ;;
  esac
}

# check_request_fits <model> — exits 1 naming the ratios <model> draws when it does not draw the
# asked one, or when it is a google/ model that takes no image size and a tier is asked. Run for the
# model the request goes to first, and for a fallback before it is sent.
check_request_fits() {
  [[ -z "$ASPECT_RATIO" ]] || check_aspect_ratio "$1" "$ASPECT_RATIO" "$(model_aspect_ratios "$1")"
  [[ -z "$SIZE_TIER" ]] || check_gemini_image_size "$1" "$SIZE_TIER"
}

use_remembered_fallback
if [[ "$MODEL" == x-ai/* && "$SIZE_TIER" == 4K ]]; then
  SIZE_TIER=2K
  echo "xAI draws at most 2K; drawing 2K for the 4K size tier" >&2
fi
# xAI draws an edit of a single image at that image's shape, whatever aspect_ratio asks.
if [[ "$MODEL" == x-ai/* && -n "$ASPECT_RATIO" && ${#INPUT_IMAGES[@]} -eq 1 ]]; then
  echo "xAI keeps the input image's shape on a single-image edit, so it ignores aspect ratio ${ASPECT_RATIO}" >&2
fi
check_request_fits "$MODEL"
# The ratio and tier each body carries, under the names CHAT_BODY and IMAGES_BODY give them.
SHAPE=$(jq -n --arg ratio "$ASPECT_RATIO" --arg size "$SIZE_TIER" \
  '(if $ratio == "" then {} else {"aspect_ratio": $ratio} end) + (if $size == "" then {} else {"size": $size} end)')
echo "Calling OpenRouter API (model: ${MODEL}, mode: ${MODE})..." >&2
display_pane_begin "$PROVIDER_NAME" "$MODEL" "$PROMPT"

CURL_HEADERS=(-H "Content-Type: application/json" -H "Authorization: Bearer ${OPENROUTER_API_KEY}")
[[ -n "$SITE_URL" ]] && CURL_HEADERS+=(-H "HTTP-Referer: ${SITE_URL}")
[[ -n "$SITE_NAME" ]] && CURL_HEADERS+=(-H "X-Title: ${SITE_NAME}")

# send_to <endpoint> <body filter> <model> — posts the body for this model to OpenRouter's endpoint
# and prints curl_with_retry's body and status. The parts can hold a multi-megabyte base64 image, so
# they enter jq on stdin as the main input rather than as --argjson, and the body reaches curl on
# stdin (--data-binary @-) rather than as -d; either argument would exceed ARG_MAX.
send_to() {
  printf '%s' "$IMAGE_PARTS" | jq --arg model "$3" --arg prompt "$PROMPT" --argjson shape "$SHAPE" "$2" \
    | curl_with_retry -s -w "\n%{http_code}" \
      -X POST "https://openrouter.ai/api/v1/$1" \
      "${CURL_HEADERS[@]}" \
      --data-binary @-
}

send_chat_request() {
  send_to chat/completions "$CHAT_BODY" "$1"
}

# images_endpoint_answer <response> — true when chat completions answered HTTP 404 with one of the
# messages OpenRouter gives a model it serves only through its images endpoint, measured 2026-11-26:
# the first for openai/gpt-image-2, the second for x-ai/grok-imagine-image-2.0. The second also
# answers a model with no image output at all, whose images request then reports its own error.
images_endpoint_answer() {
  local msg
  [[ "${1##*$'\n'}" == 404 ]] || return 1
  msg=$(jq -r '.error.message? // empty' <<< "${1%$'\n'*}" 2>/dev/null) || return 1
  case "$msg" in
    *"cannot be used with the chat/completions endpoint. Use the /api/v1/images endpoint instead."|\
    "No endpoints found that support the requested output modalities: image, text") return 0 ;;
    *) return 1 ;;
  esac
}

ENDPOINT="chat/completions"
request_with_model_fallback send_chat_request check_request_fits
if images_endpoint_answer "$RESPONSE"; then
  echo "${MODEL} is not served on chat completions (HTTP 404); sending the request to OpenRouter's images endpoint" >&2
  ENDPOINT="images"
  RESPONSE=$(send_to images "$IMAGES_BODY" "$MODEL")
fi

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  api_msg=$(echo "$BODY" | jq -r '.error.message // .error // .' 2>/dev/null || echo "$BODY")
  provider_die "OpenRouter API returned HTTP ${HTTP_CODE}: ${api_msg}"
fi

if [[ "$ENDPOINT" == images ]]; then
  IMAGE_DATA=$(echo "$BODY" | jq -r '.data[0].b64_json // empty' 2>/dev/null || true)
  if [[ -z "$IMAGE_DATA" ]]; then
    provider_die "No image data in response: $(echo "$BODY" | jq -c '.' 2>/dev/null || echo "$BODY")"
  fi
else
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
fi

save_image "$OUTPUT" <<< "$IMAGE_DATA"

echo "Image saved to: ${OUTPUT}" >&2
echo "Model: ${MODEL}" >&2

provider_finish "$OUTPUT"

echo "$OUTPUT"
