#!/usr/bin/env bash
# ABOUTME: Generates or edits images using Google Gemini API.
# ABOUTME: Supports text-to-image and image editing via generateContent endpoint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output <path> [options]

Options:
  --mode              generate or edit (required)
  --prompt            Text prompt describing the image (required)
  --output            Output file path (required)
  --input-image       Input image path for edit mode (required for edit)
  --aspect-ratio      Aspect ratio (default: 1:1)
                      Standard: 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 4:5, 5:4, 21:9
                      Extreme (3.1 Flash only): 1:4, 4:1, 1:8, 8:1
  --image-size        Output resolution: 512, 1K, 2K, 4K (UPPERCASE required)
                      512 requires gemini-3.1-flash-image-preview (Pro supports 1K/2K/4K)
  --thinking-level    Thinking level: minimal, High (default: minimal)
  --image-only        Return only image, no text description (responseModalities: IMAGE)
  --search-grounding  Enable Google Search grounding (tools: google_search)
  --model             Gemini model (default: gemini-3-pro-image-preview)
                      For extreme aspect ratios (1:4, 4:1, 1:8, 8:1) or 4K @ 512px,
                      use gemini-3.1-flash-image-preview instead.

Environment:
  GEMINI_API_KEY          Google AI API key (required)
  GEMINI_IMAGE_MODEL      Override default model
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT=""
INPUT_IMAGE=""
ASPECT_RATIO="1:1"
IMAGE_SIZE=""
THINKING_LEVEL=""
IMAGE_ONLY=""
SEARCH_GROUNDING=""
MODEL="${GEMINI_IMAGE_MODEL:-gemini-3-pro-image-preview}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --input-image) INPUT_IMAGE="$2"; shift 2 ;;
    --aspect-ratio) ASPECT_RATIO="$2"; shift 2 ;;
    --image-size) IMAGE_SIZE="$2"; shift 2 ;;
    --thinking-level) THINKING_LEVEL="$2"; shift 2 ;;
    --image-only) IMAGE_ONLY=1; shift ;;
    --search-grounding) SEARCH_GROUNDING=1; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -n "$IMAGE_SIZE" ]]; then
  case "$IMAGE_SIZE" in
    512|1K|2K|4K) ;;
    *) echo "Error: --image-size must be one of 512, 1K, 2K, 4K (uppercase required)" >&2; exit 1 ;;
  esac
fi

if [[ -n "$THINKING_LEVEL" ]]; then
  case "$THINKING_LEVEL" in
    minimal|High) ;;
    *) echo "Error: --thinking-level must be 'minimal' or 'High' (capital H)" >&2; exit 1 ;;
  esac
fi

if [[ -z "$MODE" || -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "Error: --mode, --prompt, and --output are required" >&2
  usage
fi

if [[ "$MODE" == "edit" && -z "$INPUT_IMAGE" ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  echo "Error: GEMINI_API_KEY environment variable is not set" >&2
  exit 1
fi

API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

build_request_body() {
  local parts="[]"

  if [[ "$MODE" == "edit" && -n "$INPUT_IMAGE" ]]; then
    local mime_type
    case "${INPUT_IMAGE##*.}" in
      png) mime_type="image/png" ;;
      jpg|jpeg) mime_type="image/jpeg" ;;
      webp) mime_type="image/webp" ;;
      *) mime_type="image/png" ;;
    esac
    local image_b64
    image_b64=$(base64 < "$INPUT_IMAGE" | tr -d '\n')
    parts=$(jq -n --arg mime "$mime_type" --arg data "$image_b64" \
      '[{"inlineData": {"mimeType": $mime, "data": $data}}]')
  fi

  parts=$(echo "$parts" | jq --arg prompt "$PROMPT" '. + [{"text": $prompt}]')

  local modalities='["TEXT", "IMAGE"]'
  if [[ -n "$IMAGE_ONLY" ]]; then
    modalities='["IMAGE"]'
  fi

  local image_config
  image_config=$(jq -n --arg aspect "$ASPECT_RATIO" '{"aspectRatio": $aspect}')
  if [[ -n "$IMAGE_SIZE" ]]; then
    image_config=$(echo "$image_config" | jq --arg size "$IMAGE_SIZE" '. + {"imageSize": $size}')
  fi

  local gen_config
  gen_config=$(jq -n \
    --argjson modalities "$modalities" \
    --argjson imageConfig "$image_config" \
    '{"responseModalities": $modalities, "imageConfig": $imageConfig}')

  if [[ -n "$THINKING_LEVEL" ]]; then
    gen_config=$(echo "$gen_config" | jq --arg level "$THINKING_LEVEL" \
      '. + {"thinkingConfig": {"thinkingLevel": $level}}')
  fi

  local request
  request=$(jq -n \
    --argjson parts "$parts" \
    --argjson gen "$gen_config" \
    '{"contents": [{"parts": $parts}], "generationConfig": $gen}')

  if [[ -n "$SEARCH_GROUNDING" ]]; then
    request=$(echo "$request" | jq '. + {"tools": [{"google_search": {}}]}')
  fi

  echo "$request"
}

REQUEST_BODY=$(build_request_body)

echo "Calling Gemini API (model: ${MODEL}, mode: ${MODE})..." >&2

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${API_URL}" \
  -H "Content-Type: application/json" \
  -H "x-goog-api-key: ${GEMINI_API_KEY}" \
  -d "$REQUEST_BODY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: Gemini API returned HTTP ${HTTP_CODE}" >&2
  echo "$BODY" | jq -r '.error.message // .' >&2
  exit 1
fi

IMAGE_DATA=$(echo "$BODY" | jq -r '
  .candidates[0].content.parts[]
  | select(.inlineData != null)
  | .inlineData.data' | head -1)

if [[ -z "$IMAGE_DATA" || "$IMAGE_DATA" == "null" ]]; then
  echo "Error: No image data in response" >&2
  TEXT_RESPONSE=$(echo "$BODY" | jq -r '.candidates[0].content.parts[] | select(.text != null) | .text' 2>/dev/null || true)
  if [[ -n "$TEXT_RESPONSE" ]]; then
    echo "Model response: ${TEXT_RESPONSE}" >&2
  fi
  exit 1
fi

MIME_TYPE=$(echo "$BODY" | jq -r '
  .candidates[0].content.parts[]
  | select(.inlineData != null)
  | .inlineData.mimeType' | head -1)

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "$IMAGE_DATA" | base64 -D > "$OUTPUT"
else
  echo "$IMAGE_DATA" | base64 -d > "$OUTPUT"
fi

TEXT_RESPONSE=$(echo "$BODY" | jq -r '
  .candidates[0].content.parts[]
  | select(.text != null)
  | .text' 2>/dev/null | head -1 || true)

echo "Image saved to: ${OUTPUT}" >&2
echo "Format: ${MIME_TYPE}" >&2
if [[ -n "$TEXT_RESPONSE" && "$TEXT_RESPONSE" != "null" ]]; then
  echo "Description: ${TEXT_RESPONSE}" >&2
fi

display_image "$OUTPUT"

echo "$OUTPUT"
