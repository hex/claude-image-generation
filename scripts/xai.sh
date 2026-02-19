#!/usr/bin/env bash
# ABOUTME: Generates or edits images using xAI Grok Image API.
# ABOUTME: Uses a single /v1/images/generations endpoint for both generation and editing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/display.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --mode <generate|edit> --prompt <text> --output <path> [options]

Options:
  --mode          generate or edit (required)
  --prompt        Text prompt describing the image (required)
  --output        Output file path (required)
  --input-image   Input image path for edit mode (required for edit)
  --aspect-ratio  Aspect ratio: 1:1, 16:9, 9:16, 4:3, 3:4, etc. (default: none)
  --model         xAI model (default: grok-imagine-image)

Environment:
  XAI_API_KEY     xAI API key (or GROK_API_KEY)
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT=""
INPUT_IMAGE=""
ASPECT_RATIO=""
MODEL="${XAI_IMAGE_MODEL:-grok-imagine-image}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --input-image) INPUT_IMAGE="$2"; shift 2 ;;
    --aspect-ratio) ASPECT_RATIO="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$MODE" || -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "Error: --mode, --prompt, and --output are required" >&2
  usage
fi

if [[ "$MODE" == "edit" && -z "$INPUT_IMAGE" ]]; then
  echo "Error: --input-image is required for edit mode" >&2
  usage
fi

XAI_API_KEY="${XAI_API_KEY:-${GROK_API_KEY:-}}"
if [[ -z "$XAI_API_KEY" ]]; then
  echo "Error: XAI_API_KEY or GROK_API_KEY environment variable is not set" >&2
  exit 1
fi

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

echo "Calling xAI API (model: ${MODEL}, mode: ${MODE})..." >&2

# Build request body -- xAI uses the same endpoint for generation and editing.
# For editing, the source image is passed as image_url (public URL or data URI).
REQUEST_BODY=$(jq -n \
  --arg model "$MODEL" \
  --arg prompt "$PROMPT" \
  '{
    "model": $model,
    "prompt": $prompt,
    "n": 1,
    "response_format": "b64_json"
  }')

if [[ -n "$ASPECT_RATIO" ]]; then
  REQUEST_BODY=$(echo "$REQUEST_BODY" | jq --arg ar "$ASPECT_RATIO" '. + {"aspect_ratio": $ar}')
fi

if [[ "$MODE" == "edit" && -n "$INPUT_IMAGE" ]]; then
  local_mime_type="image/png"
  case "${INPUT_IMAGE##*.}" in
    jpg|jpeg) local_mime_type="image/jpeg" ;;
    webp) local_mime_type="image/webp" ;;
    gif) local_mime_type="image/gif" ;;
  esac
  image_b64=$(base64 < "$INPUT_IMAGE" | tr -d '\n')
  data_uri="data:${local_mime_type};base64,${image_b64}"
  REQUEST_BODY=$(echo "$REQUEST_BODY" | jq --arg url "$data_uri" '. + {"image_url": $url}')
fi

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "https://api.x.ai/v1/images/generations" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${XAI_API_KEY}" \
  -d "$REQUEST_BODY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: xAI API returned HTTP ${HTTP_CODE}" >&2
  echo "$BODY" | jq -r '.error.message // .' >&2
  exit 1
fi

IMAGE_DATA=$(echo "$BODY" | jq -r '.data[0].b64_json')

if [[ -z "$IMAGE_DATA" || "$IMAGE_DATA" == "null" ]]; then
  echo "Error: No image data in response" >&2
  echo "$BODY" | jq '.' >&2
  exit 1
fi

if [[ "$(uname)" == "Darwin" ]]; then
  echo "$IMAGE_DATA" | base64 -D > "$OUTPUT"
else
  echo "$IMAGE_DATA" | base64 -d > "$OUTPUT"
fi

REVISED_PROMPT=$(echo "$BODY" | jq -r '.data[0].revised_prompt // empty')

echo "Image saved to: ${OUTPUT}" >&2
echo "Format: png" >&2
if [[ -n "$REVISED_PROMPT" ]]; then
  echo "Revised prompt: ${REVISED_PROMPT}" >&2
fi

display_image "$OUTPUT"

echo "$OUTPUT"
