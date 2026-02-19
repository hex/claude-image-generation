#!/usr/bin/env bash
# ABOUTME: Generates or edits images using OpenAI GPT Image 1.5 API.
# ABOUTME: Supports text-to-image and image editing via separate endpoints.

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
  --size          Image size: 1024x1024, 1536x1024, 1024x1536 (default: 1024x1024)
  --quality       Quality: low, medium, high (default: high)
  --background    Background: transparent, opaque, auto (default: auto)
  --model         OpenAI model (default: gpt-image-1.5)

Environment:
  OPENAI_API_KEY  OpenAI API key (required)
EOF
  exit 1
}

MODE=""
PROMPT=""
OUTPUT=""
INPUT_IMAGE=""
SIZE="1024x1024"
QUALITY="high"
BACKGROUND="auto"
MODEL="${OPENAI_IMAGE_MODEL:-gpt-image-1.5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --input-image) INPUT_IMAGE="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --quality) QUALITY="$2"; shift 2 ;;
    --background) BACKGROUND="$2"; shift 2 ;;
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

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "Error: OPENAI_API_KEY environment variable is not set" >&2
  exit 1
fi

OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

if [[ "$MODE" == "generate" ]]; then
  echo "Calling OpenAI API (model: ${MODEL}, mode: generate)..." >&2

  REQUEST_BODY=$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$PROMPT" \
    --arg size "$SIZE" \
    --arg quality "$QUALITY" \
    --arg background "$BACKGROUND" \
    '{
      "model": $model,
      "prompt": $prompt,
      "n": 1,
      "size": $size,
      "quality": $quality,
      "output_format": "png",
      "background": $background
    }')

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.openai.com/v1/images/generations" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -d "$REQUEST_BODY")

elif [[ "$MODE" == "edit" ]]; then
  echo "Calling OpenAI API (model: ${MODEL}, mode: edit)..." >&2

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.openai.com/v1/images/edits" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -F "model=${MODEL}" \
    -F "prompt=${PROMPT}" \
    -F "image=@${INPUT_IMAGE}" \
    -F "size=${SIZE}")
fi

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Error: OpenAI API returned HTTP ${HTTP_CODE}" >&2
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

echo "Image saved to: ${OUTPUT}" >&2
echo "Format: png" >&2
echo "Size: ${SIZE}" >&2
echo "Quality: ${QUALITY}" >&2

display_image "$OUTPUT"

echo "$OUTPUT"
